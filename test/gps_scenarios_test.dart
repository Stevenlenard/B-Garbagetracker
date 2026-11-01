import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/models/driver_trip.dart';
import 'package:garbage_tracking_app/utils/gps_quality.dart';
import 'package:garbage_tracking_app/utils/route_geometry.dart';

/// End-to-end behaviour of the recording rules on simulated drives (no device needed):
/// the same RoutePointPolicy the driver app applies to every fix, then the same RouteJitter / RouteGeometry that
/// every map applies to the stored points.
void main() {
  const double mPerDegLat = 111320;
  final DateTime t0 = DateTime(2026, 11, 1, 8, 0, 0);

  GpsPoint pt(double lat, double lng, int sec, {double acc = 8, double kmh = 0}) =>
      GpsPoint(latitude: lat, longitude: lng, accuracyM: acc, speedKmh: kmh, timestamp: t0.add(Duration(seconds: sec)));

  /// Replays fixes through the recorder's decision and returns what would be stored.
  List<GpsPoint> record(List<GpsPoint> fixes) {
    final List<GpsPoint> stored = <GpsPoint>[];
    GpsPoint? last;
    for (final GpsPoint f in fixes) {
      final double d = last == null ? 0 : gpsDistanceM(last.latitude, last.longitude, f.latitude, f.longitude);
      final int since = last == null ? 1 << 30 : f.timestamp.difference(last.timestamp).inSeconds;
      final RouteRecordKind k = RoutePointPolicy.decide(
        hasLastRecorded: last != null,
        distFromLastM: d,
        accuracyM: f.accuracyM,
        lastAccuracyM: last?.accuracyM ?? 0,
        secondsSinceLast: since,
        speedMps: f.speedKmh / 3.6,
      );
      if (k != RouteRecordKind.skip) {
        stored.add(f);
        last = f;
      }
    }
    return stored;
  }

  double lengthM(List<GpsPoint> p) {
    double m = 0;
    for (int i = 1; i < p.length; i++) {
      m += gpsDistanceM(p[i - 1].latitude, p[i - 1].longitude, p[i].latitude, p[i].longitude);
    }
    return m;
  }

  test('A. five minutes parked with GPS wander: no movement, no zigzag line', () {
    final math.Random rnd = math.Random(7);
    final List<GpsPoint> fixes = <GpsPoint>[
      for (int s = 0; s < 300; s++)
        pt(13.9541 + (rnd.nextDouble() - 0.5) * 30 / mPerDegLat, 121.1601 + (rnd.nextDouble() - 0.5) * 30 / mPerDegLat, s,
            acc: 10 + rnd.nextDouble() * 20),
    ];
    final List<GpsPoint> shown = RouteJitter.collapse(record(fixes));
    expect(lengthM(shown), lessThan(1.0), reason: 'standing still must add no distance');
    final List<Map<String, dynamic>> lines = RouteGeometry.lineFeatures(<Map>[
      for (final GpsPoint p in shown) {'lat': p.latitude, 'lng': p.longitude, 'timestamp': p.timestamp.millisecondsSinceEpoch, 'accuracy': p.accuracyM},
    ]);
    for (final Map<String, dynamic> f in lines) {
      final List coords = (f['geometry'] as Map)['coordinates'] as List;
      final Set<String> distinct = <String>{for (final List c in coords) '${c[0]},${c[1]}'};
      expect(distinct.length, lessThanOrEqualTo(1), reason: 'a parked truck draws a point, not a web');
    }
  });

  test('B. parked, then driving off: movement is picked up within a few fixes and follows the road', () {
    final List<GpsPoint> fixes = <GpsPoint>[
      for (int s = 0; s < 120; s++) pt(13.9541, 121.1601, s),
      // 5 m/s (18 km/h) heading north
      for (int s = 0; s < 60; s++) pt(13.9541 + 5.0 * (s + 1) / mPerDegLat, 121.1601, 120 + s, kmh: 18),
    ];
    final List<GpsPoint> shown = RouteJitter.collapse(record(fixes));
    expect(lengthM(shown), closeTo(300, 20), reason: 'about 300 m driven');
    final GpsPoint firstMoved = shown.firstWhere((p) => p.latitude > 13.9541 + 1e-9);
    expect(firstMoved.timestamp.difference(t0.add(const Duration(seconds: 120))).inSeconds, lessThanOrEqualTo(3));
  });

  test('C. straight, turn, reverse, stop: slow driving and reversing are kept, the stop is not drawn as travel', () {
    final List<GpsPoint> fixes = <GpsPoint>[];
    int s = 0;
    double lat = 13.9541, lng = 121.1601;
    for (int i = 0; i < 30; i++) { lat += 4 / mPerDegLat; fixes.add(pt(lat, lng, s++, kmh: 14)); } // north 120 m
    for (int i = 0; i < 30; i++) { lng += 4 / (mPerDegLat * math.cos(lat * math.pi / 180)); fixes.add(pt(lat, lng, s++, kmh: 14)); } // turn east 120 m
    final double turnLng = lng;
    for (int i = 0; i < 20; i++) { lng -= 2 / (mPerDegLat * math.cos(lat * math.pi / 180)); fixes.add(pt(lat, lng, s++, kmh: 7)); } // reverse 40 m
    for (int i = 0; i < 90; i++) { fixes.add(pt(lat, lng, s++)); } // collection stop
    final List<GpsPoint> shown = RouteJitter.collapse(record(fixes));
    expect(lengthM(shown), closeTo(272, 35), reason: 'about 116 m north, 116 m east, 40 m back; the 8 m noise threshold may trim a corner');
    expect(shown.last.longitude, lessThan(turnLng - 25 / (mPerDegLat * math.cos(lat * math.pi / 180))), reason: 'the reversing is drawn');
    expect(shown.last.speedKmh, 0);
  });

  group('I. filtering never erases a recorded route', () {
    test('a trip recorded under poor signal (60-90 m fixes) still gets its line', () {
      final List<GpsPoint> poor = <GpsPoint>[
        for (int i = 0; i < 6; i++) pt(13.9541 + i * 40 / mPerDegLat, 121.1601, i * 90, acc: 60.0 + i * 5),
      ];
      expect(RoutePointSelection.usable(poor), hasLength(6));
    });

    test('good fixes win when there are enough of them', () {
      final List<GpsPoint> mixed = <GpsPoint>[
        pt(13.9541, 121.1601, 0, acc: 8),
        pt(13.9542, 121.1601, 10, acc: 90),
        pt(13.9543, 121.1601, 20, acc: 12),
      ];
      expect(RoutePointSelection.usable(mixed), hasLength(2));
    });

    test('(0,0) fixes and fixes worse than 100 m are never used', () {
      final List<GpsPoint> bad = <GpsPoint>[pt(0, 0, 0), pt(13.9541, 121.1601, 10, acc: 150), pt(13.9542, 121.1601, 20, acc: 150)];
      expect(RoutePointSelection.usable(bad), isEmpty);
    });

    test('points come back in time order', () {
      final List<GpsPoint> shuffled = <GpsPoint>[pt(13.9542, 121.1601, 20), pt(13.9541, 121.1601, 0)];
      expect(RoutePointSelection.usable(shuffled).first.timestamp, t0);
    });
  });
}
