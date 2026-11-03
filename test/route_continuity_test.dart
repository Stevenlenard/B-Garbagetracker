import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/models/driver_trip.dart';
import 'package:garbage_tracking_app/services/driver_route_history_service.dart';
import 'package:garbage_tracking_app/services/offline_point_queue.dart';
import 'package:garbage_tracking_app/utils/gps_quality.dart';
import 'package:garbage_tracking_app/utils/route_geometry.dart';
import 'package:garbage_tracking_app/utils/route_link.dart';

/// Regression tests for continuous route lines: normal tracking is never split, a recording gap never discards the
/// route, bad fixes never poison what follows, and the live maps and the saved history apply the same rules.
void main() {
  const double mLat = 1 / 111320.0; // degrees per metre (north)
  const double lat0 = 13.9541, lng0 = 121.1601;
  final int t0 = DateTime(2026, 11, 1, 8).millisecondsSinceEpoch;

  /// A truck driving north at [mps], one fix every [stepS] seconds from [fromS] to [toS] (seconds after t0).
  List<Map> drive(int fromS, int toS, {double mps = 8, int stepS = 3, double acc = 8, double startNorthM = 0, String color = 'GREEN'}) => <Map>[
        for (int s = fromS; s <= toS; s += stepS)
          <String, Object?>{
            'lat': lat0 + (startNorthM + mps * (s - fromS)) * mLat,
            'lng': lng0,
            'timestamp': t0 + s * 1000,
            'accuracy': acc,
            'color': color,
          },
      ];

  double northAt(List<Map> pts, int s) => ((pts.firstWhere((p) => p['timestamp'] == t0 + s * 1000)['lat'] as double) - lat0) / mLat;

  List<Map<String, dynamic>> solid(List<Map<String, dynamic>> f) => f.where((x) => (x['properties'] as Map)[RouteGeometry.linkKey] == null).toList();
  List<Map<String, dynamic>> links(List<Map<String, dynamic>> f) => f.where((x) => (x['properties'] as Map)[RouteGeometry.linkKey] == 'uncertain').toList();
  List coords(Map<String, dynamic> f) => (f['geometry'] as Map)['coordinates'] as List;

  group('link rules (RouteLinkPolicy)', () {
    test('normal tracking is solid: a delayed fix at normal speed, weak signal, a rejected fix in between', () {
      expect(RouteLinkPolicy.classify(dtSec: 33, distM: 331), RouteLink.solid);
      expect(RouteLinkPolicy.classify(dtSec: 90, distM: 900), RouteLink.solid); // 10 m/s, one heartbeat missed
      expect(RouteLinkPolicy.classify(dtSec: 170, distM: 1400), RouteLink.solid); // nearly 3 minutes of poor GPS
      expect(RouteLinkPolicy.classify(dtSec: 180, distM: 1400), RouteLink.solid);
    });

    test('a parked truck never breaks the line, however long nothing was recorded', () {
      expect(RouteLinkPolicy.classify(dtSec: 900, distM: 4), RouteLink.solid);
      expect(RouteLinkPolicy.classify(dtSec: 7200, distM: 30), RouteLink.solid);
    });

    test('poor accuracy widens what counts as the same place', () {
      expect(RouteLinkPolicy.classify(dtSec: 600, distM: 110, accuracyA: 60, accuracyB: 60), RouteLink.solid);
      expect(RouteLinkPolicy.classify(dtSec: 600, distM: 110, accuracyA: 5, accuracyB: 5), RouteLink.uncertain);
    });

    test('minutes without a recording but a possible move: kept, joined as uncertain', () {
      expect(RouteLinkPolicy.classify(dtSec: 240, distM: 700), RouteLink.uncertain);
      expect(RouteLinkPolicy.classify(dtSec: 1500, distM: 3000), RouteLink.uncertain);
    });

    test('an impossible move, or a gap too long to bridge, breaks the line', () {
      expect(RouteLinkPolicy.classify(dtSec: 5, distM: 400), RouteLink.broken); // ~68 m/s
      expect(RouteLinkPolicy.classify(dtSec: 0, distM: 350), RouteLink.broken);
      expect(RouteLinkPolicy.classify(dtSec: 60, distM: 10500), RouteLink.broken); // the 10.5 km jump of 29 Oct
      expect(RouteLinkPolicy.classify(dtSec: 2400, distM: 3000), RouteLink.broken);
    });
  });

  group('live maps: one continuous line while tracking is normal', () {
    test('driving, turning, slowing, stopping and driving on is ONE line with every recorded stretch', () {
      final List<Map> pts = <Map>[
        ...drive(0, 120, mps: 8), // straight
        ...drive(123, 180, mps: 2, startNorthM: 8 * 120 + 6, stepS: 3), // slowing for houses
        for (int s = 183; s <= 480; s += 60) <String, Object?>{'lat': lat0 + (8 * 120 + 6 + 2 * 57) * mLat, 'lng': lng0, 'timestamp': t0 + s * 1000, 'accuracy': 8, 'color': 'GREEN'}, // collecting stop: heartbeats
        ...drive(483, 600, mps: 8, startNorthM: 8 * 120 + 6 + 2 * 57 + 20),
      ];
      final List<Map<String, dynamic>> f = RouteGeometry.lineFeatures(pts);
      expect(solid(f), hasLength(1));
      expect(links(f), isEmpty);
      expect(coords(solid(f).single).length, greaterThan(20));
    });

    test('a short GPS delay (45 s at 8 m/s) does not split the line', () {
      final List<Map> pts = <Map>[...drive(0, 60), ...drive(105, 200, startNorthM: 8 * 105)];
      final List<Map<String, dynamic>> f = RouteGeometry.lineFeatures(pts);
      expect(solid(f), hasLength(1));
      expect(links(f), isEmpty);
    });

    test('about 3 minutes of rejected (poor accuracy) fixes in between do not split the line', () {
      final List<Map> good1 = drive(0, 60);
      final List<Map> rejected = drive(63, 230, acc: 160, startNorthM: 8 * 63); // dropped: accuracy over 100 m
      final List<Map> good2 = drive(233, 330, startNorthM: 8 * 233);
      final List<Map<String, dynamic>> f = RouteGeometry.lineFeatures(<Map>[...good1, ...rejected, ...good2]);
      expect(solid(f), hasLength(1));
      expect(links(f), isEmpty);
    });

    test('internet interruption: the points stored on the phone arrive late and out of order and give the same line', () {
      final List<Map> pts = <Map>[...drive(0, 300)];
      final List<Map> onTime = <Map>[...pts.where((p) => (p['timestamp'] as int) < t0 + 100000 || (p['timestamp'] as int) > t0 + 200000)];
      final List<Map> late = pts.where((p) => !onTime.contains(p)).toList().reversed.toList(); // flushed newest first
      final List<Map<String, dynamic>> whileDown = RouteGeometry.lineFeatures(onTime);
      final List<Map<String, dynamic>> afterFlush = RouteGeometry.lineFeatures(<Map>[...onTime, ...late]);
      final List<Map<String, dynamic>> never = RouteGeometry.lineFeatures(pts);
      // while the connection was down the 100 s hole is a plausible move: still one route (a dashed link at most)
      expect(solid(whileDown).length, lessThanOrEqualTo(2));
      // after the flush the line is exactly the continuous one, whatever order the points arrived in
      expect(afterFlush.length, never.length);
      expect(solid(afterFlush), hasLength(1));
      expect(links(afterFlush), isEmpty);
      expect(coords(solid(afterFlush).single), coords(solid(never).single));
    });

    test('a parked truck: a 10 minute stop with drifting fixes draws no scribble and no break', () {
      final List<Map> stop = <Map>[
        for (int s = 123; s <= 723; s += 20)
          <String, Object?>{
            'lat': lat0 + (8 * 120 + (s % 3) * 4) * mLat,
            'lng': lng0 + ((s % 5) - 2) * 3 * mLat,
            'timestamp': t0 + s * 1000,
            'accuracy': 20,
            'color': 'GREEN',
          },
      ];
      // as every map does: the stationary wander of the stored points is collapsed first (RouteJitter), then the line is built
      final List<Map> stored = RouteJitter.collapseMaps(<Map>[...drive(0, 120), ...stop, ...drive(726, 800, startNorthM: 8 * 120 + 30)]);
      final List<Map<String, dynamic>> f = RouteGeometry.lineFeatures(stored);
      expect(solid(f), hasLength(1));
      expect(links(f), isEmpty);
      // 41 + 25 fixes were driven; the 31 drifting fixes of the stop add (almost) nothing, and none of the driving is lost
      expect(coords(solid(f).single).length, inInclusiveRange(60, 70));
    });
  });

  group('bad fixes and gaps never discard the route', () {
    test('one wild fix 10 km away is dropped; the line goes on from the last good fix and later points are still drawn', () {
      final List<Map> a = drive(0, 90);
      final List<Map> b = drive(96, 200, startNorthM: 8 * 96);
      final Map wild = <String, Object?>{'lat': lat0 + 10500 * mLat, 'lng': lng0 + 0.05, 'timestamp': t0 + 93 * 1000, 'accuracy': 15, 'color': 'GREEN'};
      final List<Map<String, dynamic>> f = RouteGeometry.lineFeatures(<Map>[...a, wild, ...b]);
      expect(solid(f), hasLength(1));
      expect(links(f), isEmpty);
      final List c = coords(solid(f).single);
      expect((c.last as List)[1], greaterThan(lat0 + 8 * 190 * mLat)); // reaches the end of the drive
      for (final dynamic p in c) {
        expect((p as List)[0], closeTo(lng0, 0.001)); // never pulled towards the wild fix
      }
    });

    test('a long recording gap (4 min, 600 m) keeps the earlier route and joins it with one dashed link, nothing invented', () {
      final List<Map> a = drive(0, 120);
      final List<Map> b = drive(360, 450, startNorthM: 8 * 120 + 600);
      final List<Map<String, dynamic>> f = RouteGeometry.lineFeatures(<Map>[...a, ...b]);
      expect(links(f), hasLength(1));
      expect(solid(f), hasLength(2));
      expect(coords(links(f).single), hasLength(2)); // only the two known points
      final List before = coords(solid(f).first), after = coords(solid(f).last);
      expect(coords(links(f).single).first, before.last);
      expect(coords(links(f).single).last, after.first);
      expect(before.length, greaterThan(10)); // the earlier route is still all there
    });

    test('a real relocation (the truck moved untracked) starts a new stretch with no connection; the earlier route stays', () {
      final List<Map> a = drive(0, 90);
      final List<Map> b = drive(120, 200, startNorthM: 8 * 90 + 12000); // 12 km away 30 s later
      final List<Map<String, dynamic>> f = RouteGeometry.lineFeatures(<Map>[...a, ...b]);
      expect(solid(f), hasLength(2));
      expect(links(f), isEmpty);
      expect(coords(solid(f).first).length, greaterThan(10));
    });

    test('the live position at the end is joined, never treated as a jump', () {
      final List<Map> a = drive(0, 90);
      final List<Map> withTail = RouteGeometry.withLiveTail(a, lat0 + (8 * 90 + 500) * mLat, lng0, accuracyM: 5);
      final List<Map<String, dynamic>> f = RouteGeometry.lineFeatures(withTail);
      expect(solid(f), hasLength(1));
      expect((coords(solid(f).single).last as List)[1], closeTo(lat0 + (8 * 90 + 500) * mLat, 1e-9));
    });
  });

  group('saved route history applies the same rules', () {
    GpsPoint gp(int s, double northM, {double acc = 8, double kmh = 29}) => GpsPoint(
        latitude: lat0 + northM * mLat, longitude: lng0, accuracyM: acc, speedKmh: kmh, timestamp: DateTime.fromMillisecondsSinceEpoch(t0 + s * 1000));
    List<GpsPoint> driveGp(int from, int to, {double startM = 0, int step = 3}) =>
        <GpsPoint>[for (int s = from; s <= to; s += step) gp(s, startM + 8.0 * (s - from))];

    test('a normal trip has no break and no link', () {
      final List<GpsPoint> r = DriverRouteHistoryService.smoothForDisplay(<GpsPoint>[...driveGp(0, 120), ...driveGp(165, 300, startM: 8 * 165)]);
      expect(r.where((p) => p.isGapStart || p.uncertainLink), isEmpty);
    });

    test('one wild fix does not cut the saved line (it used to: the fix before AND after were flagged)', () {
      final List<GpsPoint> pts = <GpsPoint>[...driveGp(0, 90), gp(93, 11000), ...driveGp(96, 200, startM: 8 * 96)];
      final List<GpsPoint> r = DriverRouteHistoryService.smoothForDisplay(pts);
      expect(r.where((p) => p.isGapStart || p.uncertainLink), isEmpty);
      expect(r.last.latitude, greaterThan(lat0 + 8 * 190 * mLat));
    });

    test('a long recording gap is one uncertain link; the route before it is kept', () {
      final List<GpsPoint> pts = <GpsPoint>[...driveGp(0, 120), ...driveGp(360, 450, startM: 8 * 120 + 600)];
      final List<GpsPoint> r = DriverRouteHistoryService.smoothForDisplay(pts);
      expect(r.where((p) => p.uncertainLink), hasLength(1));
      expect(r.where((p) => p.isGapStart), isEmpty);
      expect(r.length, greaterThan(20));
    });

    test('a real relocation starts a new stretch', () {
      final List<GpsPoint> r = DriverRouteHistoryService.smoothForDisplay(<GpsPoint>[...driveGp(0, 90), ...driveGp(120, 200, startM: 8 * 90 + 12000)]);
      expect(r.where((p) => p.isGapStart), hasLength(1));
    });

    test('the saved history and the live map agree on the same trip (same stretches, same links)', () {
      final List<Map> live = <Map>[...drive(0, 120), ...drive(360, 450, startNorthM: 8 * 120 + 600), ...drive(480, 560, startNorthM: 8 * 120 + 600 + 8 * 90 + 12000)];
      final List<GpsPoint> saved = <GpsPoint>[
        for (final Map p in live)
          GpsPoint(
              latitude: p['lat'] as double,
              longitude: p['lng'] as double,
              accuracyM: 8,
              speedKmh: 29,
              timestamp: DateTime.fromMillisecondsSinceEpoch(p['timestamp'] as int)),
      ];
      final List<Map<String, dynamic>> f = RouteGeometry.lineFeatures(live);
      final List<GpsPoint> r = DriverRouteHistoryService.smoothForDisplay(saved);
      expect(r.where((p) => p.uncertainLink).length, links(f).length);
      final int liveStretches = solid(f).length;
      final int savedStretches = 1 + r.where((p) => p.isGapStart || p.uncertainLink).length;
      expect(savedStretches, liveStretches);
    });

    test('replay uses the displayed points: a stationary stop is collapsed, history before and after is untouched', () {
      final List<GpsPoint> pts = <GpsPoint>[
        ...driveGp(0, 120),
        for (int s = 123; s <= 423; s += 15) gp(s, 8.0 * 120 + (s % 3) * 2, kmh: 0),
        ...driveGp(426, 540, startM: 8 * 120 + 10),
      ];
      final List<GpsPoint> r = DriverRouteHistoryService.smoothForDisplay(pts);
      expect(r.first.latitude, closeTo(lat0, 5 * mLat));
      expect(r.last.latitude, closeTo(lat0 + (8 * 120 + 10 + 8 * 114) * mLat, 15 * mLat));
      expect(r.length, lessThan(pts.length)); // drift removed, route kept
    });
  });

  group('points stored on the phone while offline', () {
    test('they stay until confirmed and are resent oldest first, whatever order they were stored in', () async {
      String? stored;
      final OfflinePointQueue q = OfflinePointQueue(load: () async => stored, save: (String s) async => stored = s, nowMs: () => t0);
      QueuedPoint qp(String key, int at) =>
          QueuedPoint(key: key, root: 'driver_routes', tripId: 'trip-1', queuedAtMs: at, point: <String, Object?>{'lat': 13.95, 'lng': 121.16, 'timestamp': at});
      await q.add(qp('c', t0 + 3000));
      await q.add(qp('a', t0 + 1000));
      await q.add(qp('b', t0 + 2000));
      expect((await q.pendingFor('trip-1')).map((e) => e.key), <String>['a', 'b', 'c']);
      await q.remove('b'); // only a confirmed point leaves
      expect((await q.pendingFor('trip-1')).map((e) => e.key), <String>['a', 'c']);
    });
  });

  group('a long stop is not a recording gap', () {
    test('the first move after a 10 minute stop (heartbeats at the same place) is joined solid, no dashed link', () {
      final List<Map> stop = <Map>[
        for (int s = 120; s <= 720; s += 60) <String, Object?>{'lat': lat0 + 8 * 120 * mLat, 'lng': lng0, 'timestamp': t0 + s * 1000, 'accuracy': 8, 'color': 'GREEN'},
      ];
      final List<Map> after = drive(723, 760, startNorthM: 8 * 120 + 110); // 110 m on, the first fix after the stop
      final List<Map<String, dynamic>> f = RouteGeometry.lineFeatures(<Map>[...drive(0, 117), ...stop, ...after]);
      expect(links(f), isEmpty);
      expect(solid(f), hasLength(1));
    });

    test('the same for the saved history', () {
      GpsPoint gp(int s, double northM) => GpsPoint(latitude: lat0 + northM * mLat, longitude: lng0, accuracyM: 8, speedKmh: 0, timestamp: DateTime.fromMillisecondsSinceEpoch(t0 + s * 1000));
      final List<GpsPoint> pts = <GpsPoint>[for (int s = 0; s <= 120; s += 3) gp(s, 8.0 * s), for (int s = 180; s <= 720; s += 60) gp(s, 960), gp(723, 1070), gp(726, 1094)];
      final List<GpsPoint> r = DriverRouteHistoryService.smoothForDisplay(pts);
      expect(r.where((p) => p.uncertainLink || p.isGapStart), isEmpty);
    });
  });
}
