import 'dart:async';
import 'dart:convert';

import 'package:garbage_tracking_app/services/rtdb_port.dart';

/// In-memory stand-in for the Realtime Database used by the session tests.
///
/// It reproduces the property that matters: [transaction] runs the handler against
/// the CURRENT stored value and commits only if the handler succeeds, atomically
/// (no other operation can interleave between the read and the write), exactly
/// like a server-side compare-and-set. Server timestamps resolve to an increasing
/// counter.
class FakeRtdb implements RtdbPort {
  final Map<String, Object?> _root = <String, Object?>{};
  int _clock = 1000;
  int _pushCounter = 0;
  final List<_Watcher> _watchers = <_Watcher>[];

  /// When false, watch events are held back (simulates a slow listener) until
  /// [flushEvents] is called. Transactions are unaffected.
  bool deliverEvents = true;
  final List<void Function()> _held = <void Function()>[];

  int transactionCount = 0;
  int abortedTransactionCount = 0;

  List<String> pathsWritten = <String>[];

  // ---- helpers ------------------------------------------------------------

  static List<String> _seg(String path) => path.split('/').where((s) => s.isNotEmpty).toList();

  Object? _deepCopy(Object? v) => v == null ? null : jsonDecode(jsonEncode(v));

  Object? _resolve(Object? v) {
    if (isServerTimestamp(v)) return ++_clock;
    if (v is Map) return <String, Object?>{for (final e in v.entries) e.key.toString(): _resolve(e.value)};
    return v;
  }

  Object? _getAt(String path) {
    Object? cur = _root;
    for (final String k in _seg(path)) {
      if (cur is Map && cur.containsKey(k)) {
        cur = cur[k];
      } else {
        return null;
      }
    }
    return cur;
  }

  void _setAt(String path, Object? value) {
    final List<String> seg = _seg(path);
    Map<String, Object?> cur = _root;
    for (int i = 0; i < seg.length - 1; i++) {
      final Object? next = cur[seg[i]];
      if (next is Map<String, Object?>) {
        cur = next;
      } else {
        final Map<String, Object?> created = <String, Object?>{};
        cur[seg[i]] = created;
        cur = created;
      }
    }
    if (value == null) {
      cur.remove(seg.last);
    } else {
      cur[seg.last] = value;
    }
    pathsWritten.add(path);
  }

  void _notify() {
    for (final _Watcher w in List<_Watcher>.from(_watchers)) {
      final String now = jsonEncode(_getAt(w.path));
      if (now == w.last) continue;
      w.last = now;
      final Object? v = _deepCopy(_getAt(w.path));
      void emit() {
        if (!w.controller.isClosed) w.controller.add(v);
      }

      if (deliverEvents) {
        emit();
      } else {
        _held.add(emit);
      }
    }
  }

  void flushEvents() {
    final List<void Function()> pending = List<void Function()>.from(_held);
    _held.clear();
    for (final void Function() e in pending) {
      e();
    }
  }

  // ---- test accessors -----------------------------------------------------

  Object? read(String path) => _deepCopy(_getAt(path));

  void seed(String path, Object? value) {
    _setAt(path, _resolve(value));
    _notify();
  }

  int childCount(String path) {
    final Object? v = _getAt(path);
    return v is Map ? v.length : 0;
  }

  // ---- RtdbPort -----------------------------------------------------------

  @override
  Future<bool> transaction(String path, TxHandler handler) async {
    transactionCount++;
    final TxOutcome outcome = handler(_deepCopy(_getAt(path)));
    if (outcome.isAbort) {
      abortedTransactionCount++;
      return false;
    }
    _setAt(path, _resolve(outcome.value));
    _notify();
    return true;
  }

  @override
  Stream<Object?> watch(String path) {
    late final _Watcher w;
    final StreamController<Object?> c = StreamController<Object?>.broadcast(
      onCancel: () => _watchers.removeWhere((x) => identical(x, w)),
    );
    w = _Watcher(path, c, jsonEncode(_getAt(path)));
    _watchers.add(w);
    // Initial value, like a real listener.
    scheduleMicrotask(() {
      if (!c.isClosed) c.add(_deepCopy(_getAt(path)));
    });
    return c.stream;
  }

  @override
  Future<void> update(String path, Map<String, Object?> values) async {
    final Object? existing = _getAt(path);
    final Map<String, Object?> node =
        existing is Map ? Map<String, Object?>.from(existing) : <String, Object?>{};
    final Map<String, Object?> deep = <String, Object?>{};
    values.forEach((k, v) {
      final Object? r = _resolve(v);
      if (k.contains('/')) {
        // Like the real database: a multi-segment key is a path below this node.
        deep[k] = r;
      } else if (r == null) {
        node.remove(k);
      } else {
        node[k] = r;
      }
    });
    _setAt(path, node.isEmpty && deep.isEmpty ? null : node);
    deep.forEach((k, r) => _setAt('$path/$k', r));
    _notify();
  }

  @override
  Future<void> push(String path, Map<String, Object?> value) async {
    final String id = 'p${(++_pushCounter).toString().padLeft(6, '0')}';
    _setAt('$path/$id', _resolve(value));
    _notify();
  }

  @override
  Future<Object?> get(String path) async => _deepCopy(_getAt(path));
}

class _Watcher {
  _Watcher(this.path, this.controller, this.last);
  final String path;
  final StreamController<Object?> controller;
  String last;
}
