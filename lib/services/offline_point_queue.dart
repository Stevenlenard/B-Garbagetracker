import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A GPS route point that has not yet been confirmed by Firebase.
class QueuedPoint {
  const QueuedPoint({
    required this.key,
    required this.root,
    required this.tripId,
    required this.point,
    required this.queuedAtMs,
    this.allowWhileFinishing = false,
  });

  /// Push key generated on the phone when the fix was taken; the point is always written under it.
  final String key;
  final String root;
  final String tripId;
  final Map<String, Object?> point;
  final int queuedAtMs;
  final bool allowWhileFinishing;

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        'root': root,
        'tripId': tripId,
        'point': point,
        'queuedAtMs': queuedAtMs,
        'allowWhileFinishing': allowWhileFinishing,
      };

  static QueuedPoint? fromJson(Object? j) {
    if (j is! Map) return null;
    final Object? key = j['key'], root = j['root'], trip = j['tripId'], point = j['point'], at = j['queuedAtMs'];
    if (key is! String || root is! String || trip is! String || point is! Map || at is! num) return null;
    return QueuedPoint(
      key: key,
      root: root,
      tripId: trip,
      point: point.map((k, v) => MapEntry(k.toString(), v)),
      queuedAtMs: at.toInt(),
      allowWhileFinishing: j['allowWhileFinishing'] == true,
    );
  }
}

/// Offline storage of the driver's route points.
///
/// Every point is stored on the phone before it is sent and removed only after Firebase has
/// confirmed it. The Firebase client already holds unsent writes in memory while the app runs;
/// this queue keeps them when the app is closed or the phone restarts without a connection, and
/// the dashboard sends them again when the trip continues. Points older than [maxAge] are dropped,
/// and at most [maxPoints] are kept (the oldest go first).
class OfflinePointQueue {
  OfflinePointQueue({
    required Future<String?> Function() load,
    required Future<void> Function(String) save,
    int Function()? nowMs,
  })  : _load = load,
        _save = save,
        _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Backed by SharedPreferences (one JSON list under [prefsKey]).
  factory OfflinePointQueue.sharedPreferences() => OfflinePointQueue(
        load: () async => (await SharedPreferences.getInstance()).getString(prefsKey),
        save: (String v) async {
          await (await SharedPreferences.getInstance()).setString(prefsKey, v);
        },
      );

  static const String prefsKey = 'offline_route_points_v1';
  static const Duration maxAge = Duration(hours: 24);
  static const int maxPoints = 5000;

  final Future<String?> Function() _load;
  final Future<void> Function(String) _save;
  final int Function() _nowMs;

  List<QueuedPoint>? _items;
  Future<void> _chain = Future<void>.value();

  /// Runs [op] after every earlier operation, so concurrent fixes never overwrite each other's changes.
  Future<T> _serial<T>(Future<T> Function() op) {
    final Future<T> result = _chain.then((_) => op());
    _chain = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<List<QueuedPoint>> _all() async {
    if (_items != null) return _items!;
    List<QueuedPoint> items = <QueuedPoint>[];
    try {
      final String? raw = await _load();
      if (raw != null && raw.isNotEmpty) {
        final Object? list = jsonDecode(raw);
        if (list is List) items = list.map(QueuedPoint.fromJson).whereType<QueuedPoint>().toList();
      }
    } catch (_) {
      items = <QueuedPoint>[];
    }
    final int cutoff = _nowMs() - maxAge.inMilliseconds;
    items.removeWhere((QueuedPoint p) => p.queuedAtMs < cutoff);
    return _items = items;
  }

  Future<void> _persist() => _save(jsonEncode(_items!.map((QueuedPoint p) => p.toJson()).toList()));

  Future<void> add(QueuedPoint p) => _serial(() async {
        final List<QueuedPoint> items = await _all();
        items.removeWhere((QueuedPoint q) => q.key == p.key);
        items.add(p);
        if (items.length > maxPoints) items.removeRange(0, items.length - maxPoints);
        await _persist();
      });

  Future<void> remove(String key) => _serial(() async {
        final List<QueuedPoint> items = await _all();
        final int before = items.length;
        items.removeWhere((QueuedPoint q) => q.key == key);
        if (items.length != before) await _persist();
      });

  /// Unconfirmed points of [tripId], oldest first.
  Future<List<QueuedPoint>> pendingFor(String tripId) => _serial(() async {
        final List<QueuedPoint> items = await _all();
        return items.where((QueuedPoint q) => q.tripId == tripId).toList()
          ..sort((QueuedPoint a, QueuedPoint b) => a.queuedAtMs.compareTo(b.queuedAtMs));
      });

  Future<int> get length => _serial(() async => (await _all()).length);
}
