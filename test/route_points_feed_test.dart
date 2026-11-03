import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/route_points_feed.dart';
import 'package:garbage_tracking_app/utils/route_geometry.dart';

/// The maps now follow a trip's route by its changes instead of re-reading the whole route for every new point. The line
/// that is drawn must be exactly the same one.
void main() {
  Map pt(int ms, double north, {double acc = 8}) =>
      <String, Object?>{'lat': 13.95 + north / 111320, 'lng': 121.16, 'timestamp': ms, 'accuracy': acc, 'color': 'GREEN'};

  test('the points replayed when the feed starts arrive as one list, sorted by time', () {
    fakeAsync((FakeAsync async) {
      final StreamController<RoutePointEvent> c = StreamController<RoutePointEvent>();
      final List<List<Map>> got = <List<Map>>[];
      RoutePointsFeed.fromEvents(c.stream, got.add);
      for (int i = 0; i < 300; i++) {
        c.add(RoutePointEvent('k$i', pt(1000 + i * 1000, i * 8.0)));
      }
      async.elapse(const Duration(milliseconds: 600));
      expect(got, hasLength(1));
      expect(got.single, hasLength(300));
      for (int i = 1; i < 300; i++) {
        expect((got.single[i]['timestamp'] as int) > (got.single[i - 1]['timestamp'] as int), isTrue);
      }
    });
  });

  test('new points reach the screen within about a second, and never more than once per second', () {
    fakeAsync((FakeAsync async) {
      final StreamController<RoutePointEvent> c = StreamController<RoutePointEvent>();
      final List<DateTime> times = <DateTime>[];
      final List<int> sizes = <int>[];
      RoutePointsFeed.fromEvents(c.stream, (List<Map> p) {
        times.add(async.getClock(DateTime(2026, 11, 4)).now());
        sizes.add(p.length);
      });
      c.add(RoutePointEvent('a', pt(1000, 0)));
      async.elapse(const Duration(milliseconds: 300));
      expect(sizes, <int>[1]);
      // a point every 200 ms for 3 seconds
      for (int i = 1; i <= 15; i++) {
        c.add(RoutePointEvent('p$i', pt(1000 + i * 200, i * 3.0)));
        async.elapse(const Duration(milliseconds: 200));
      }
      async.elapse(const Duration(seconds: 2));
      for (int i = 1; i < times.length; i++) {
        expect(times[i].difference(times[i - 1]).inMilliseconds, greaterThanOrEqualTo(950));
      }
      expect(sizes.last, 16, reason: 'the last point is never left out');
      expect(times.length, lessThanOrEqualTo(5));
    });
  });

  test('a late or out-of-order point is placed by its time', () {
    fakeAsync((FakeAsync async) {
      final StreamController<RoutePointEvent> c = StreamController<RoutePointEvent>();
      List<Map> last = <Map>[];
      RoutePointsFeed.fromEvents(c.stream, (List<Map> p) => last = p);
      c.add(RoutePointEvent('b', pt(3000, 24)));
      c.add(RoutePointEvent('a', pt(1000, 0)));
      c.add(RoutePointEvent('c', pt(2000, 12))); // arrives last, belongs in the middle
      async.elapse(const Duration(seconds: 1));
      expect(last.map((Map p) => p['timestamp']).toList(), <Object?>[1000, 2000, 3000]);
    });
  });

  test('a changed point replaces the old one, a removed point goes', () {
    fakeAsync((FakeAsync async) {
      final StreamController<RoutePointEvent> c = StreamController<RoutePointEvent>();
      List<Map> last = <Map>[];
      RoutePointsFeed.fromEvents(c.stream, (List<Map> p) => last = p);
      c.add(RoutePointEvent('a', pt(1000, 0)));
      c.add(RoutePointEvent('b', pt(2000, 10)));
      async.elapse(const Duration(seconds: 1));
      c.add(RoutePointEvent('b', pt(2000, 99)));
      c.add(RoutePointEvent('a', null));
      async.elapse(const Duration(seconds: 2));
      expect(last, hasLength(1));
      expect((last.single['lat'] as double) > 13.95 + 90 / 111320, isTrue);
    });
  });

  test('after cancel nothing more is delivered', () {
    fakeAsync((FakeAsync async) {
      final StreamController<RoutePointEvent> c = StreamController<RoutePointEvent>();
      int calls = 0;
      final RoutePointsSubscription s = RoutePointsFeed.fromEvents(c.stream, (List<Map> p) => calls++);
      c.add(RoutePointEvent('a', pt(1000, 0)));
      s.cancel();
      async.elapse(const Duration(seconds: 2));
      expect(calls, 0);
    });
  });

  test('the line drawn from the feed is the same line as from the whole route', () {
    final List<Map> whole = <Map>[for (int i = 0; i < 120; i++) pt(1700000000000 + i * 3000, i * 15.0)];
    fakeAsync((FakeAsync async) {
      final StreamController<RoutePointEvent> c = StreamController<RoutePointEvent>();
      List<Map> fed = <Map>[];
      RoutePointsFeed.fromEvents(c.stream, (List<Map> p) => fed = p);
      final List<Map> shuffled = List<Map>.of(whole)..shuffle();
      for (int i = 0; i < shuffled.length; i++) {
        c.add(RoutePointEvent('k$i', shuffled[i]));
      }
      async.elapse(const Duration(seconds: 2));
      expect(RouteGeometry.lineFeatures(fed), RouteGeometry.lineFeatures(whole));
    });
  });

  group("ChildrenFeed (the trips of driver_routes, the admin's window of them)", () {
    Map trip(int n) => <String, Object?>{"driver_id": "7", "n": n};

    test("the trips replayed at the start arrive as one map, and a change brings only that trip", () {
      fakeAsync((FakeAsync async) {
        final StreamController<RoutePointEvent> c = StreamController<RoutePointEvent>();
        final List<Map<dynamic, dynamic>> got = <Map<dynamic, dynamic>>[];
        ChildrenFeed.fromEvents(c.stream, got.add, minGap: const Duration(seconds: 10));
        for (int i = 0; i < 325; i++) {
          c.add(RoutePointEvent("t$i", trip(i)));
        }
        async.elapse(const Duration(seconds: 1));
        expect(got, hasLength(1));
        expect(got.single, hasLength(325));
        c.add(RoutePointEvent("t7", trip(999)));
        async.elapse(const Duration(seconds: 1));
        expect(got, hasLength(1), reason: "inside the gap: not recomputed yet");
        async.elapse(const Duration(seconds: 10));
        expect(got, hasLength(2));
        expect((got.last["t7"] as Map)["n"], 999);
        expect(got.last, hasLength(325));
      });
    });

    test("a burst of route points (two drivers recording) causes at most one recompute per gap", () {
      fakeAsync((FakeAsync async) {
        final StreamController<RoutePointEvent> c = StreamController<RoutePointEvent>();
        int calls = 0;
        ChildrenFeed.fromEvents(c.stream, (Map<dynamic, dynamic> _) => calls++, minGap: const Duration(seconds: 10));
        c.add(RoutePointEvent("a", trip(0)));
        async.elapse(const Duration(seconds: 1));
        expect(calls, 1);
        // 2 drivers, a point per second each, for a minute
        for (int s = 0; s < 60; s++) {
          c.add(RoutePointEvent("a", trip(s)));
          c.add(RoutePointEvent("b", trip(s)));
          async.elapse(const Duration(seconds: 1));
        }
        async.elapse(const Duration(seconds: 10));
        expect(calls, lessThanOrEqualTo(8), reason: "was 120 recomputes of every trip in that minute");
      });
    });

    test("a removed trip leaves the map", () {
      fakeAsync((FakeAsync async) {
        final StreamController<RoutePointEvent> c = StreamController<RoutePointEvent>();
        Map<dynamic, dynamic> last = <dynamic, dynamic>{};
        ChildrenFeed.fromEvents(c.stream, (Map<dynamic, dynamic> m) => last = m, minGap: const Duration(seconds: 1));
        c.add(RoutePointEvent("a", trip(1)));
        c.add(RoutePointEvent("b", trip(2)));
        async.elapse(const Duration(seconds: 1));
        c.add(RoutePointEvent("a", null));
        async.elapse(const Duration(seconds: 3));
        expect(last.keys, <dynamic>["b"]);
      });
    });
  });
}
