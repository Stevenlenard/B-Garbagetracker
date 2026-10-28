import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/approach_tracking.dart';
import 'package:garbage_tracking_app/utils/eta_evaluation.dart';
import 'package:garbage_tracking_app/utils/eta_policy.dart';

void main() {
  const int min = 60000;

  group('RecentTravelSpeed', () {
    test('includes stops: 2 km in 10 min of stop-and-go is 12 km/h', () {
      final RecentTravelSpeed s = RecentTravelSpeed();
      // drives 1 km, stops 4 min, drives 1 km, stops 4 min
      s.add(0, 0.0);
      s.add(1 * min, 1.0);
      s.add(5 * min, 1.0);
      s.add(6 * min, 2.0);
      s.add(10 * min, 2.0);
      expect(s.kmhAt(10 * min), closeTo(12.0, 0.01));
    });

    test('unknown until 3 minutes of history exist', () {
      final RecentTravelSpeed s = RecentTravelSpeed();
      s.add(0, 0.0);
      s.add(2 * min, 0.8);
      expect(s.kmhAt(2 * min), isNull);
    });

    test('only the last 10 minutes count', () {
      final RecentTravelSpeed s = RecentTravelSpeed();
      s.add(0, 0.0);
      s.add(10 * min, 5.0); // fast earlier
      s.add(20 * min, 6.0); // slow now: 1 km in 10 min
      expect(s.kmhAt(20 * min), closeTo(6.0, 0.01));
    });
  });

  group('ApproachDetector', () {
    test('never on the first fix', () {
      final ApproachDetector d = ApproachDetector();
      d.add('purok-2', 0, 1500);
      expect(d.isApproaching('purok-2', 0), isFalse);
    });

    test('GPS wander of a few metres is not approaching', () {
      final ApproachDetector d = ApproachDetector();
      for (int i = 0; i < 12; i++) {
        d.add('purok-2', i * 15000, 1500.0 - (i.isEven ? 0 : 8));
      }
      expect(d.isApproaching('purok-2', 11 * 15000), isFalse);
    });

    test('sustained closing over a minute is approaching', () {
      final ApproachDetector d = ApproachDetector();
      for (int i = 0; i <= 8; i++) {
        d.add('central', i * 15000, 1500.0 - i * 30);
      }
      expect(d.isApproaching('central', 8 * 15000), isTrue);
    });

    test('moving away again is not approaching', () {
      final ApproachDetector d = ApproachDetector();
      for (int i = 0; i <= 6; i++) {
        d.add('central', i * 15000, 1500.0 - i * 40);
      }
      d.add('central', 7 * 15000, 1400);
      expect(d.isApproaching('central', 7 * 15000), isFalse);
    });
  });

  test('straight-line distance is scaled to a road distance', () {
    expect(EtaPolicy.roadDistanceKm(1.0), closeTo(1.3, 1e-9));
  });

  test('ETA evaluation ignores approach alerts from the superseded method', () {
    final int t0 = DateTime.utc(2026, 10, 28, 0).millisecondsSinceEpoch;
    final Map<String, Object?> raw = <String, Object?>{
      'old': <String, Object?>{'type': 'auto_approach', 'purok': 'Purok 2', 'trip_id': 'T1', 'truck_id': 'GT-001', 'eta_minutes': 5, 'timestamp': t0},
      'new': <String, Object?>{'type': 'auto_approach', 'purok': 'Central', 'trip_id': 'T1', 'truck_id': 'GT-001', 'eta_minutes': 9, 'timestamp': t0, 'eta_method': EtaPolicy.method},
      'arr': <String, Object?>{'type': 'auto_arrival', 'purok': 'Central', 'trip_id': 'T1', 'truck_id': 'GT-001', 'timestamp': t0 + 10 * min},
    };
    final List<EtaVisit> visits = EtaEvaluation.build(raw, nowMs: t0 + 20 * min, requiredMethod: EtaPolicy.method);
    expect(visits.length, 1);
    final EtaSummary s = EtaEvaluation.summarize(visits);
    expect(s.evaluatedVisits, 1);
    expect(EtaEvaluation.build(raw, nowMs: t0 + 20 * min).length, 2); // unchanged without the filter
  });
}
