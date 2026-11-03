import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

/// One change of a trip's recorded points: [value] null means the point was removed.
class RoutePointEvent {
  const RoutePointEvent(this.key, this.value);

  final String key;
  final Map? value;
}

/// A running feed; cancel it when the map stops following the trip.
class RoutePointsSubscription {
  RoutePointsSubscription._(this._cancel);

  final Future<void> Function() _cancel;

  Future<void> cancel() => _cancel();
}

/// The recorded points of one trip (`driver_routes/{trip}/route`), kept up to date from the CHANGES only.
///
/// The maps used to listen to the whole `route` node with `onValue`: every new point made Firebase hand the app the entire
/// route again (up to ~800 points, twice on some screens) which was turned into Dart objects, sorted, smoothed and drawn,
/// for every truck watched and every user watching. Here the app reads each point once (`onChildAdded` also replays the
/// existing points when the feed starts) and applies new points one by one; the screens get the full, time-sorted list
/// (the same list `onValue` gave) at most once per [minGap]. Points that arrive late or out of order are placed by their
/// time, as before, so the drawn line is the same one.
///
/// A new batch is announced after [settle] (so the points replayed at the start arrive as ONE list, not hundreds), and
/// afterwards at most once per [minGap]; the end of the line is still joined to the live marker by the screens.
class RoutePointsFeed {
  RoutePointsFeed._();

  static const Duration defaultSettle = Duration(milliseconds: 250);
  static const Duration defaultMinGap = Duration(milliseconds: 1000);

  static num _ts(Map p) {
    final Object? t = p['timestamp'];
    if (t is num) return t;
    return num.tryParse('${t ?? ''}') ?? 0;
  }

  /// Time-sorted copy of [points]; equal times keep their key order so the list never jumps between calls.
  static List<Map> sorted(Map<String, Map> points) {
    final List<MapEntry<String, Map>> entries = points.entries.toList()
      ..sort((MapEntry<String, Map> a, MapEntry<String, Map> b) {
        final int c = _ts(a.value).compareTo(_ts(b.value));
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return <Map>[for (final MapEntry<String, Map> e in entries) e.value];
  }

  /// Applies [events] and calls [onChange] with the full sorted list, throttled as described above.
  static RoutePointsSubscription fromEvents(
    Stream<RoutePointEvent> events,
    void Function(List<Map> points) onChange, {
    Duration settle = defaultSettle,
    Duration minGap = defaultMinGap,
  }) {
    final Map<String, Map> points = <String, Map>{};
    Timer? timer;
    DateTime? lastEmit;
    bool closed = false;

    void emit() {
      timer = null;
      if (closed || points.isEmpty) return;
      lastEmit = DateTime.now();
      onChange(sorted(points));
    }

    void touch() {
      if (timer != null || closed) return;
      Duration wait = settle;
      if (lastEmit != null) {
        final Duration since = DateTime.now().difference(lastEmit!);
        final Duration rest = minGap - since;
        if (rest > wait) wait = rest;
      }
      timer = Timer(wait, emit);
    }

    final StreamSubscription<RoutePointEvent> sub = events.listen((RoutePointEvent e) {
      if (e.value == null) {
        if (points.remove(e.key) == null) return;
      } else {
        points[e.key] = e.value!;
      }
      touch();
    }, onError: (Object _) {});

    return RoutePointsSubscription._(() async {
      closed = true;
      timer?.cancel();
      await sub.cancel();
    });
  }

  /// The feed of the route node of a trip.
  static RoutePointsSubscription listen(
    DatabaseReference route,
    void Function(List<Map> points) onChange, {
    Duration settle = defaultSettle,
    Duration minGap = defaultMinGap,
  }) {
    final StreamController<RoutePointEvent> merged = StreamController<RoutePointEvent>();
    Map? asMap(Object? v) => v is Map ? v : null;
    final List<StreamSubscription<DatabaseEvent>> subs = <StreamSubscription<DatabaseEvent>>[
      route.onChildAdded.listen((DatabaseEvent e) {
        final Map? v = asMap(e.snapshot.value);
        if (v != null && e.snapshot.key != null) merged.add(RoutePointEvent(e.snapshot.key!, v));
      }, onError: (Object _) {}),
      route.onChildChanged.listen((DatabaseEvent e) {
        final Map? v = asMap(e.snapshot.value);
        if (v != null && e.snapshot.key != null) merged.add(RoutePointEvent(e.snapshot.key!, v));
      }, onError: (Object _) {}),
      route.onChildRemoved.listen((DatabaseEvent e) {
        if (e.snapshot.key != null) merged.add(RoutePointEvent(e.snapshot.key!, null));
      }, onError: (Object _) {}),
    ];
    final RoutePointsSubscription inner = fromEvents(merged.stream, onChange, settle: settle, minGap: minGap);
    return RoutePointsSubscription._(() async {
      for (final StreamSubscription<DatabaseEvent> s in subs) {
        await s.cancel();
      }
      await inner.cancel();
      await merged.close();
    });
  }
}

/// The children of a node (for example the trips of `driver_routes`, or a window of them) kept up to date from the
/// CHANGES only, handed over as one map at most once per [minGap].
///
/// Listening to the whole node with `onValue` handed the app every trip again (4 MB and growing) with every route point
/// any driver recorded, and the screens then recomputed everything from it. A change now only brings the child that
/// changed; the screen recomputes at most once per [minGap].
class ChildrenFeed {
  ChildrenFeed._();

  static RoutePointsSubscription fromEvents(
    Stream<RoutePointEvent> events,
    void Function(Map<dynamic, dynamic> children) onChange, {
    Duration settle = const Duration(milliseconds: 400),
    required Duration minGap,
  }) {
    final Map<dynamic, dynamic> children = <dynamic, dynamic>{};
    Timer? timer;
    DateTime? lastEmit;
    bool closed = false;

    void emit() {
      timer = null;
      if (closed) return;
      lastEmit = DateTime.now();
      onChange(Map<dynamic, dynamic>.of(children));
    }

    void touch() {
      if (timer != null || closed) return;
      Duration wait = settle;
      if (lastEmit != null) {
        final Duration rest = minGap - DateTime.now().difference(lastEmit!);
        if (rest > wait) wait = rest;
      }
      timer = Timer(wait, emit);
    }

    final StreamSubscription<RoutePointEvent> sub = events.listen((RoutePointEvent e) {
      if (e.value == null) {
        if (children.remove(e.key) == null) return;
      } else {
        children[e.key] = e.value;
      }
      touch();
    }, onError: (Object _) {});

    return RoutePointsSubscription._(() async {
      closed = true;
      timer?.cancel();
      await sub.cancel();
    });
  }

  static RoutePointsSubscription listen(
    Query query,
    void Function(Map<dynamic, dynamic> children) onChange, {
    Duration settle = const Duration(milliseconds: 400),
    required Duration minGap,
  }) {
    final StreamController<RoutePointEvent> merged = StreamController<RoutePointEvent>();
    void put(DatabaseEvent e) {
      final Object? v = e.snapshot.value;
      if (v is Map && e.snapshot.key != null) merged.add(RoutePointEvent(e.snapshot.key!, v));
    }

    final List<StreamSubscription<DatabaseEvent>> subs = <StreamSubscription<DatabaseEvent>>[
      query.onChildAdded.listen(put, onError: (Object _) {}),
      query.onChildChanged.listen(put, onError: (Object _) {}),
      query.onChildRemoved.listen((DatabaseEvent e) {
        if (e.snapshot.key != null) merged.add(RoutePointEvent(e.snapshot.key!, null));
      }, onError: (Object _) {}),
    ];
    final RoutePointsSubscription inner = fromEvents(merged.stream, onChange, settle: settle, minGap: minGap);
    return RoutePointsSubscription._(() async {
      for (final StreamSubscription<DatabaseEvent> s in subs) {
        await s.cancel();
      }
      await inner.cancel();
      await merged.close();
    });
  }
}
