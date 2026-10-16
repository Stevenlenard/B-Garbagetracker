import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

enum ChildEventType { added, changed, removed }

class ChildEvent {
  final ChildEventType type;
  final String key;
  final Object? value;
  const ChildEvent(this.type, this.key, [this.value]);
}

/// Minimal stand-in for a `DatabaseEvent.snapshot` so existing listeners keep
/// working unchanged (`event.snapshot.exists` / `event.snapshot.value`).
class TruckLocationsSnapshot {
  TruckLocationsSnapshot(Map<String, dynamic> value) : _value = value;
  final Map<String, dynamic> _value;
  bool get exists => _value.isNotEmpty;
  Object? get value => _value.isEmpty ? null : _value;
}

class TruckLocationsEvent {
  TruckLocationsEvent(Map<String, dynamic> value) : snapshot = TruckLocationsSnapshot(value);
  final TruckLocationsSnapshot snapshot;
}

/// One shared, incremental view of `truck_locations`.
///
/// Why: listening with `onValue` on the parent re-delivers the WHOLE node on every
/// change. Production's `truck_locations/GT-001/route_history` alone is ~2.3 MB of
/// legacy data, so every GPS update of every truck made every dashboard rebuild and
/// re-deserialise that 2.3 MB. Child events deliver only the truck that changed
/// (~0.6 KB); `route_history` is also dropped locally so consumers never hold it.
///
/// Updates arriving in the same event-loop turn are coalesced into one emission
/// (no artificial delay). Late subscribers are immediately given the current state.
class TruckLocationsFeed {
  TruckLocationsFeed(
    this._sourceFactory, {
    Set<String>? dropFields,
    this.emptyGrace = const Duration(seconds: 3),
  }) : dropFields = dropFields ?? const <String>{'route_history'};

  static TruckLocationsFeed? _shared;

  /// The production feed (one Firebase subscription shared by all screens).
  static TruckLocationsFeed shared() => _shared ??= TruckLocationsFeed(_firebaseChildEvents);

  /// Creates a fresh source each time the feed (re)starts, so it can be stopped
  /// when nobody listens and restarted later.
  final Stream<ChildEvent> Function() _sourceFactory;
  final Set<String> dropFields;

  /// If no child event arrives within this time the node is treated as empty.
  final Duration emptyGrace;

  final Map<String, dynamic> _map = <String, dynamic>{};
  final StreamController<TruckLocationsEvent> _out = StreamController<TruckLocationsEvent>.broadcast();
  StreamSubscription<ChildEvent>? _sourceSub;
  Timer? _graceTimer;
  bool _emitScheduled = false;
  bool _loaded = false;
  int _listeners = 0;

  /// Current assembled map (read-only copy).
  Map<String, dynamic> get current => Map<String, dynamic>.from(_map);

  Stream<TruckLocationsEvent> get events {
    late final StreamController<TruckLocationsEvent> c;
    StreamSubscription<TruckLocationsEvent>? sub;
    c = StreamController<TruckLocationsEvent>(
      onListen: () {
        _listeners++;
        _ensureStarted();
        if (_loaded) {
          scheduleMicrotask(() {
            if (!c.isClosed) c.add(_snapshotEvent());
          });
        }
        sub = _out.stream.listen(c.add, onError: c.addError);
      },
      onCancel: () async {
        await sub?.cancel();
        _listeners--;
        if (_listeners <= 0) _stop();
      },
    );
    return c.stream;
  }

  TruckLocationsEvent _snapshotEvent() => TruckLocationsEvent(current);

  void _ensureStarted() {
    if (_sourceSub != null) return;
    _sourceSub = _sourceFactory().listen(_onChild, onError: (Object e, StackTrace st) {
      debugPrint('[TRUCK FEED] source error: $e');
      if (!_out.isClosed) _out.addError(e, st);
    });
    _graceTimer = Timer(emptyGrace, () {
      if (!_loaded) {
        _loaded = true;
        _emit();
      }
    });
  }

  void _stop() {
    _graceTimer?.cancel();
    _graceTimer = null;
    _sourceSub?.cancel();
    _sourceSub = null;
    _map.clear();
    _loaded = false;
    _emitScheduled = false;
  }

  void _onChild(ChildEvent e) {
    switch (e.type) {
      case ChildEventType.added:
      case ChildEventType.changed:
        final Object? v = e.value;
        if (v is Map) {
          final Map<String, dynamic> node = <String, dynamic>{};
          v.forEach((k, val) {
            final String key = k.toString();
            if (!dropFields.contains(key)) node[key] = val;
          });
          _map[e.key] = node;
        } else if (v == null) {
          _map.remove(e.key);
        } else {
          _map[e.key] = v;
        }
        break;
      case ChildEventType.removed:
        _map.remove(e.key);
        break;
    }
    _loaded = true;
    _graceTimer?.cancel();
    if (!_emitScheduled) {
      _emitScheduled = true;
      // Events delivered in the same turn collapse into ONE emission. A zero-duration
      // timer runs after the pending microtasks, so a burst is merged without any
      // artificial delay.
      Timer(Duration.zero, () {
        _emitScheduled = false;
        _emit();
      });
    }
  }

  void _emit() {
    if (_out.isClosed || _sourceSub == null) return;
    _out.add(_snapshotEvent());
  }
}

Stream<ChildEvent> _firebaseChildEvents() {
  final DatabaseReference ref = FirebaseDatabase.instance.ref('truck_locations');
  late final StreamController<ChildEvent> c;
  final List<StreamSubscription<DatabaseEvent>> subs = <StreamSubscription<DatabaseEvent>>[];
  c = StreamController<ChildEvent>(
    onListen: () {
      void forward(Stream<DatabaseEvent> s, ChildEventType t) {
        subs.add(s.listen((DatabaseEvent e) {
          final String? key = e.snapshot.key;
          if (key == null) return;
          c.add(ChildEvent(t, key, t == ChildEventType.removed ? null : e.snapshot.value));
        }, onError: c.addError));
      }

      forward(ref.onChildAdded, ChildEventType.added);
      forward(ref.onChildChanged, ChildEventType.changed);
      forward(ref.onChildRemoved, ChildEventType.removed);
    },
    onCancel: () async {
      for (final StreamSubscription<DatabaseEvent> s in subs) {
        await s.cancel();
      }
      subs.clear();
    },
  );
  return c.stream;
}
