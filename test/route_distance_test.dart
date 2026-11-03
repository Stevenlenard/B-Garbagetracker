import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/driver_lifecycle.dart';
import 'package:garbage_tracking_app/utils/route_distance.dart';

/// The distance frozen when the driver presses FULL is measured from the stored route, not taken from the phone's running
/// total (which counted GPS wander as driving: 7.233 km recorded on 3 Nov 2026 for a route of about 1.2 km).
void main() {
  const double lat0 = 13.95, lng0 = 121.16;
  final double kLng = math.cos(lat0 * math.pi / 180);
  final int base = DateTime(2026, 11, 3, 10, 3, 11).millisecondsSinceEpoch;

  final Map<String, dynamic> fixture = jsonDecode(File('test/fixtures/nov3_stationary_trip.json').readAsStringSync()) as Map<String, dynamic>;
  final List<Map> stored = <Map>[
    for (final dynamic r in fixture['fixes'] as List)
      <String, Object?>{
        'lat': lat0 + (r[2] as num) / 111320,
        'lng': lng0 + (r[1] as num) / (111320 * kLng),
        'timestamp': base + (r[0] as num).toInt(),
        'accuracy': (r[3] as num).toDouble(),
        'speed': (r[4] as num).toDouble(),
      },
  ];

  group('3 Nov 2026 trip', () {
    test('the stored route measures about 1.2 km, not the 7.233 km the phone added up', () {
      final double km = RouteDistance.correctedKm(stored);
      // ignore: avoid_print
      print('Nov 3: phone 7.233 km -> measured from the stored points ${km.toStringAsFixed(3)} km');
      expect(km, inInclusiveRange(1.0, 1.4));
    });

    test('the frozen distance is the measured one, and the phone figure is kept on the record', () {
      final double km = RouteDistance.chooseKm(deviceKm: 7.233, correctedKm: RouteDistance.correctedKm(stored), fixes: stored.length, lastFixAgeMs: 4000);
      expect(km, lessThan(1.4));
      final Map<String, Object?> rec = CollectionRecord.build(
          startMs: 0, nowMs: 60000, distanceKm: km, weightKg: 5000, weightType: 'ESTIMATED', via: 'FULL', deviceDistanceKm: 7.233);
      expect(rec['distance_km'], lessThan(1.4));
      expect(rec['distance_km_device'], 7.233);
    });

    test('the stored route is not modified', () {
      final List<Object?> before = <Object?>[for (final Map p in stored) p['lat']];
      RouteDistance.correctedKm(stored);
      expect(<Object?>[for (final Map p in stored) p['lat']], before);
    });

    test('the order the points are stored in does not matter', () {
      final List<Map> shuffled = List<Map>.of(stored)..shuffle(math.Random(5));
      expect(RouteDistance.correctedKm(shuffled), closeTo(RouteDistance.correctedKm(stored), 1e-9));
    });
  });

  group('genuine distance is kept', () {
    List<Map> drive(double metres, {double mps = 8, int stepS = 3}) => <Map>[
          for (int s = 0; s * mps <= metres; s += stepS)
            <String, Object?>{'lat': lat0 + mps * s / 111320, 'lng': lng0, 'timestamp': base + s * 1000, 'accuracy': 8, 'speed': mps * 3.6},
        ];

    test('2 km of driving measures 2 km', () {
      expect(RouteDistance.correctedKm(drive(2000)), closeTo(2.0, 0.1));
    });

    test('a truck that never moved measures 0', () {
      final List<Map> parked = <Map>[
        for (int s = 0; s < 3600; s += 60) <String, Object?>{'lat': lat0, 'lng': lng0, 'timestamp': base + s * 1000, 'accuracy': 8, 'speed': 0},
      ];
      expect(RouteDistance.correctedKm(parked), 0);
    });

    test('a move nobody could make (the truck moved untracked) is not counted as travel', () {
      final List<Map> pts = <Map>[
        ...drive(500),
        for (int s = 0; s < 40; s += 3)
          <String, Object?>{'lat': lat0 + (12000 + 8.0 * s) / 111320, 'lng': lng0, 'timestamp': base + (90 + s) * 1000, 'accuracy': 8, 'speed': 29},
      ];
      expect(RouteDistance.correctedKm(pts), lessThan(1.1));
    });
  });

  group('when the stored route cannot be trusted the phone figure is kept', () {
    test('no stored points, one point, or an unreadable route', () {
      expect(RouteDistance.chooseKm(deviceKm: 3.2, correctedKm: null, fixes: 0, lastFixAgeMs: null), 3.2);
      expect(RouteDistance.chooseKm(deviceKm: 3.2, correctedKm: 0, fixes: 1, lastFixAgeMs: 1000), 3.2);
    });

    test('the server does not hold the latest points yet (they are still on the phone)', () {
      expect(RouteDistance.chooseKm(deviceKm: 3.2, correctedKm: 1.0, fixes: 200, lastFixAgeMs: 10 * 60 * 1000), 3.2);
      expect(RouteDistance.chooseKm(deviceKm: 3.2, correctedKm: 1.0, fixes: 200, lastFixAgeMs: null), 3.2);
    });

    test('the measured distance can only remove distance, never add it', () {
      expect(RouteDistance.chooseKm(deviceKm: 1.0, correctedKm: 1.4, fixes: 200, lastFixAgeMs: 2000), 1.0);
      expect(RouteDistance.chooseKm(deviceKm: 3.0, correctedKm: 1.4, fixes: 200, lastFixAgeMs: 2000), 1.4);
    });

    test('the phone figure is only stored separately when it differs', () {
      final Map<String, Object?> same =
          CollectionRecord.build(startMs: 0, nowMs: 1000, distanceKm: 1.5, weightKg: 5000, weightType: 'ESTIMATED', via: 'FULL', deviceDistanceKm: 1.5);
      expect(same.containsKey('distance_km_device'), isFalse);
    });
  });

  test('the driver app freezes the measured distance at FULL, after the stored points were sent', () {
    final String d = File('lib/screens/driver_dashboard.dart').readAsStringSync();
    expect(d.contains('_measuredRouteKm(root, tripId, deviceDistance)'), isTrue);
    expect(d.contains('deviceDistanceKm: deviceDistance'), isTrue);
    expect(RegExp(r'_measuredRouteKm\(String root[\s\S]{0,400}_flushQueuedPoints\(\)').hasMatch(d), isTrue);
  });
}
