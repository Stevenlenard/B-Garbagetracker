import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/models/driver_trip.dart';
import 'package:garbage_tracking_app/utils/gps_quality.dart';

void main() {
  standingWanderTests();
  final DateTime t0 = DateTime(2026, 10, 18, 11, 20, 55);
  FixSample fix(double lat, double lng, double acc, int sec) => FixSample(lat, lng, acc, t0.add(Duration(seconds: sec)));

  group('StartFixPicker', () {
    test("Darna's login: the first fix (150 m off) is not the start; the confirmed one is", () {
      // Real data of trip -P4C0hC9kuXJlQl_fu4G (2026-10-18): the truck never left 13.94753, 121.08232.
      final List<FixSample> fixes = <FixSample>[
        fix(13.9483983, 121.0813183, 10.9, 0), // cached/wrong
        fix(13.9476061, 121.0822787, 31.0, 6),
        fix(13.9475665, 121.0823835, 3.9, 12),
        fix(13.9475637, 121.0823916, 6.5, 17),
      ];
      final int? i = StartFixPicker.pick(fixes, now: t0.add(const Duration(seconds: 17)));
      expect(i, 2);
      expect(gpsDistanceM(fixes[i!].lat, fixes[i].lng, 13.94753, 121.08232), lessThan(15));
    });

    test('a single fix waits for confirmation, then is used after the patience time', () {
      final List<FixSample> one = <FixSample>[fix(13.9540, 121.1601, 12, 0)];
      expect(StartFixPicker.pick(one, now: t0.add(const Duration(seconds: 5))), isNull);
      expect(StartFixPicker.pick(one, now: t0.add(const Duration(seconds: 21))), 0);
    });

    test('two agreeing fixes start immediately and keep the more accurate one', () {
      final List<FixSample> f = <FixSample>[fix(13.9540, 121.1601, 20, 0), fix(13.95401, 121.16011, 8, 2)];
      expect(StartFixPicker.pick(f, now: t0.add(const Duration(seconds: 2))), 1);
    });

    test('poor fixes (> 100 m) never confirm a start, but after the patience time the best one is used', () {
      final List<FixSample> f = <FixSample>[fix(13.9540, 121.1601, 300, 0), fix(13.9541, 121.1601, 250, 3)];
      expect(StartFixPicker.pick(f, now: t0.add(const Duration(seconds: 10))), isNull);
      expect(StartFixPicker.pick(f, now: t0.add(const Duration(seconds: 40))), 1);
    });

    test('nothing yet means keep waiting', () {
      expect(StartFixPicker.pick(<FixSample>[], now: t0), isNull);
    });
  });

  group('RoutePointPolicy', () {
    RouteRecordKind d(double dist, {double acc = 10, double lastAcc = 10, int sec = 5, bool has = true}) => RoutePointPolicy.decide(
        hasLastRecorded: has, distFromLastM: dist, accuracyM: acc, lastAccuracyM: lastAcc, secondsSinceLast: sec);

    test('first point is always recorded', () => expect(d(0, has: false), RouteRecordKind.moved));

    test('GPS wander while standing still is not drawn', () {
      expect(d(5), RouteRecordKind.skip);
      expect(d(14, acc: 25, lastAcc: 25), RouteRecordKind.skip); // below 0.75 x 25 m
      expect(d(5, sec: 30), RouteRecordKind.skip);
    });

    test('real movement is recorded; a standing truck gets one heartbeat a minute', () {
      expect(d(20), RouteRecordKind.moved);
      expect(d(50, sec: 1), RouteRecordKind.moved);
      expect(d(20, sec: 1), RouteRecordKind.skip);
      expect(d(3, sec: 60), RouteRecordKind.heartbeat);
    });

    test('poor fixes are not drawn, but a long silence still gets a heartbeat', () {
      expect(d(200, acc: 134), RouteRecordKind.skip);
      expect(d(200, acc: 323, sec: 120), RouteRecordKind.heartbeat);
    });
  });

  group('RouteJitter', () {
    GpsPoint p(double lat, double lng, int sec, {double acc = 20, double speed = 0, bool gap = false}) =>
        GpsPoint(latitude: lat, longitude: lng, accuracyM: acc, speedKmh: speed, timestamp: t0.add(Duration(seconds: sec)), isGapStart: gap);

    double length(List<GpsPoint> pts) {
      double m = 0;
      for (int i = 1; i < pts.length; i++) {
        m += gpsDistanceM(pts[i - 1].latitude, pts[i - 1].longitude, pts[i].latitude, pts[i].longitude);
      }
      return m;
    }

    test("Arian's stationary wander (about 60 m of fake distance) collapses to a point, keeping the time", () {
      final List<GpsPoint> raw = <GpsPoint>[
        p(13.9540586, 121.1601018, 0, speed: 14),
        p(13.9540655, 121.1601112, 10, speed: 18),
        p(13.9540394, 121.1601138, 21, speed: 11),
        p(13.9540495, 121.1601042, 30, speed: 18),
        p(13.9540814, 121.1600923, 35, speed: 14),
        p(13.9541293, 121.1601122, 3000, acc: 7, speed: 1),
      ];
      expect(length(raw), greaterThan(15));
      final List<GpsPoint> clean = RouteJitter.collapse(raw);
      expect(clean.length, raw.length); // stops keep their duration
      expect(length(clean), lessThan(1));
      expect(clean.skip(1).every((GpsPoint x) => x.speedKmh == 0), isTrue);
      expect(clean.last.timestamp, raw.last.timestamp);
    });

    test('real travel is untouched', () {
      final List<GpsPoint> raw = <GpsPoint>[
        p(13.9540, 121.1600, 0, acc: 5),
        p(13.9543, 121.1600, 5, acc: 5, speed: 20),
        p(13.9546, 121.1600, 10, acc: 5, speed: 20),
        p(13.9549, 121.1600, 15, acc: 5, speed: 20),
      ];
      final List<GpsPoint> clean = RouteJitter.collapse(raw);
      expect(length(clean), closeTo(length(raw), 0.01));
    });

    test('a gap start is always kept as its own point', () {
      final List<GpsPoint> raw = <GpsPoint>[p(13.9540, 121.1600, 0), p(13.95401, 121.16001, 400, gap: true)];
      expect(RouteJitter.collapse(raw)[1].latitude, 13.95401);
    });

    test('raw map points collapse the same way', () {
      final List<Map> raw = <Map>[
        <String, dynamic>{'lat': 13.9540586, 'lng': 121.1601018, 'accuracy': 20, 'speed': 14, 'timestamp': 1},
        <String, dynamic>{'lat': 13.9540655, 'lng': 121.1601112, 'accuracy': 20, 'speed': 18, 'timestamp': 2},
        <String, dynamic>{'lat': 13.9560000, 'lng': 121.1601112, 'accuracy': 8, 'speed': 30, 'timestamp': 3},
      ];
      final List<Map> clean = RouteJitter.collapseMaps(raw);
      expect(clean[1]['lat'], 13.9540586);
      expect(clean[1]['speed'], 0.0);
      expect(clean[2]['lat'], 13.9560000);
    });
  });
}

void standingWanderTests() {
  test('standing still (receiver speed 0): a 50 m indoor wander is not recorded, a moving fix is', () {
    expect(
        RoutePointPolicy.decide(
            hasLastRecorded: true, distFromLastM: 50, accuracyM: 20, lastAccuracyM: 20, secondsSinceLast: 5, speedMps: 0.0),
        RouteRecordKind.skip);
    expect(
        RoutePointPolicy.decide(
            hasLastRecorded: true, distFromLastM: 50, accuracyM: 20, lastAccuracyM: 20, secondsSinceLast: 5, speedMps: 6.0),
        RouteRecordKind.moved);
  });
}
