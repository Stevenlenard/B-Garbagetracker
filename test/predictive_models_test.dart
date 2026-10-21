import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/collection_visits.dart';
import 'package:garbage_tracking_app/utils/predictive_models.dart';

void main() {
  group('ErrorMetrics', () {
    test('MAE, RMSE and R² of the textbook example (5 trips)', () {
      final m = ErrorMetrics.of(<double>[12, 14, 11, 18, 14], <double>[10, 15, 8, 20, 12]);
      expect(m.n, 5);
      expect(m.mae, closeTo(2.0, 1e-9));
      expect(m.rmse, closeTo(2.0976, 1e-3)); // sqrt(22 / 5)
      expect(m.r2, closeTo(1 - 22 / 28.8, 1e-9)); // SSres 22, SStot 28.8: about 0.24 (not 0.82)
    });

    test('R² is negative when the predictions are worse than the mean, and null without variation', () {
      expect(ErrorMetrics.of(<double>[1, 2, 3], <double>[3, 2, 1]).r2, lessThan(0));
      expect(ErrorMetrics.of(<double>[5, 5], <double>[4, 6]).r2, isNull);
      expect(ErrorMetrics.of(<double>[], <double>[]).mae, isNull);
    });
  });

  test('LinearFit recovers a known line', () {
    final f = LinearFit.fit(<double>[0, 1, 2, 3], <double>[2, 5, 8, 11])!;
    expect(f.intercept, closeTo(2, 1e-9));
    expect(f.slope, closeTo(3, 1e-9));
    expect(LinearFit.fit(<double>[1, 1], <double>[2, 3]), isNull);
  });

  test('arrival samples come only from moving fixes before the first entry into an area', () {
    const area = AreaGeofence(name: 'Central', lat: 13.9530, lng: 121.1588, radiusM: 100);
    final int t0 = DateTime.utc(2026, 10, 21, 1).millisecondsSinceEpoch;
    // approaching from 1.1 km south at about 20 km/h, one fix every 30 s, entering after ~3.3 minutes
    final route = <String, Object?>{};
    for (int i = 0; i <= 8; i++) {
      route['p$i'] = <String, Object?>{
        'lat': 13.9430 + i * 0.00125,
        'lng': 121.1588,
        'timestamp': t0 + i * 30000,
        'status': 'ACTIVE',
        'accuracy': 6,
        'speed': 20,
      };
    }
    final s = ArrivalRegression.extract(<String, Object?>{'t1': <String, Object?>{'route': route}}, const <AreaGeofence>[area]);
    expect(s, isNotEmpty);
    expect(s.first.actualMin, greaterThan(0));
    expect(s.first.distanceKm, greaterThan(0));
    expect(s.first.baselineMin, isNotNull);
    // a simulated trip gives no sample
    expect(
        ArrivalRegression.extract(<String, Object?>{'t1': <String, Object?>{'route': route, 'is_simulation': true}},
            const <AreaGeofence>[area]),
        isEmpty);
  });

  test('moving average: one-day-ahead forecasts and the next-day forecast', () {
    final days = List<DateTime>.generate(5, (i) => DateTime.utc(2026, 10, 1 + i));
    final r = MovingAverageForecast.evaluate(days, <double>[0, 5000, 5000, 0, 10000], window: 2);
    expect(r.backtestForecast, <double>[2500, 5000, 2500]);
    expect(r.backtestActual, <double>[5000, 0, 10000]);
    expect(r.nextForecast, 5000);
    expect(r.metrics.n, 3);
  });

  test('daily loads use finalized collections of real trips in Asia/Manila days', () {
    final trips = <String, Object?>{
      'a': <String, Object?>{'collection': <String, Object?>{'finalized_at_ms': DateTime.utc(2026, 10, 20, 2).millisecondsSinceEpoch, 'weight_kg': 5000}},
      'b': <String, Object?>{'collection': <String, Object?>{'finalized_at_ms': DateTime.utc(2026, 10, 20, 17).millisecondsSinceEpoch, 'weight_kg': 3000}},
      'sim': <String, Object?>{'is_simulation': true, 'collection': <String, Object?>{'finalized_at_ms': DateTime.utc(2026, 10, 20, 2).millisecondsSinceEpoch, 'weight_kg': 9000}},
    };
    final d = MovingAverageForecast.dailyLoads(trips, from: DateTime(2026, 10, 20), to: DateTime(2026, 10, 21));
    expect(d.kg, <double>[5000, 3000]); // 17:00 UTC on the 20th is already the 21st in Manila
  });
}
