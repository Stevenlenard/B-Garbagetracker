import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/eta_policy.dart';

void main() {
  tearDown(() => EtaPolicy.model = EtaModel.defaults);

  EtaResult eta(double straightKm, double kmh, {bool withModel = true}) => EtaPolicy.evaluate(
        status: 'ACTIVE',
        gpsAgeMs: 0,
        distanceKm: EtaPolicy.roadDistanceKm(straightKm),
        straightKm: withModel ? straightKm : null,
        speedKmh: kmh,
        arrivalRadiusM: 0,
      );

  test('a nearby area is not promised in 1-2 minutes: recorded trips took ~6 min plus 1.8 min per km', () {
    // Purok 3, 0.37 km at 39.5 km/h: the speed alone said 1 min; the truck arrived 6.6 min later.
    expect(eta(0.37, 39.5, withModel: false).minutes, 1);
    expect(eta(0.37, 39.5).minutes, 7); // 5.78 + 1.79 x 0.37 = 6.4 -> 7
  });

  test('a slow truck far away keeps the speed estimate when it is longer', () {
    expect(eta(2.0, 6.0).minutes, 26); // 2.0 x 1.3 / 6 x 60 = 26 > 9.4
  });

  test('a stored fit replaces the defaults only when it is plausible and rests on 10+ samples', () {
    expect(EtaModel.fromJson(<String, Object?>{'intercept': 4.0, 'slope': 2.0, 'samples': 25})!.intercept, 4.0);
    expect(EtaModel.fromJson(<String, Object?>{'intercept': 4.0, 'slope': 2.0, 'samples': 5}), isNull);
    expect(EtaModel.fromJson(<String, Object?>{'intercept': -1.0, 'slope': 2.0, 'samples': 25}), isNull);
    expect(EtaModel.fromJson(<String, Object?>{'intercept': 4.0, 'slope': 0.0, 'samples': 25}), isNull);
    expect(EtaModel.fromJson(null), isNull);
    EtaPolicy.model = const EtaModel(3.0, 1.0, samples: 30);
    expect(eta(1.0, 60.0).minutes, 4); // 3 + 1 x 1 = 4 > 1.3 min by speed
  });
}
