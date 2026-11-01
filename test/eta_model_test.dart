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

  test('a nearby area is not promised in 1-2 minutes when the truck is fast but not at the area (recorded trips)', () {
    // Purok 3, 0.37 km at 39.5 km/h: the speed alone said 1 min; the truck arrived 6.6 min later.
    expect(eta(0.37, 39.5, withModel: false).minutes, 1);
    // the delay on the way builds up over the first 500 m: 5.78 x 0.74 + 1.79 x 0.37 = 4.9 -> 5
    expect(eta(0.37, 39.5).minutes, 5);
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

  group('short distances are no longer held at the model\'s constant minimum', () {
    test('the delay applies in proportion to the distance still to drive, in full from 500 m', () {
      const EtaModel m = EtaModel(7.569, 2.302, samples: 188);
      expect(m.minutesFor(0), 0);
      expect(m.minutesFor(0.25), closeTo(7.569 * 0.5 + 2.302 * 0.25, 1e-9));
      expect(m.minutesFor(0.5), closeTo(7.569 + 2.302 * 0.5, 1e-9));
      expect(m.minutesFor(2.0), closeTo(7.569 + 2.302 * 2.0, 1e-9)); // far away: the fitted line, unchanged
    });

    test('a truck at the edge of the area is minutes away, not 6-8', () {
      EtaPolicy.model = const EtaModel(7.569, 2.302, samples: 188);
      expect(eta(0.02, 6.0).minutes, 1);
      expect(eta(0.1, 6.0).minutes, 2);
      expect(eta(0.2, 6.0).minutes, 4);
    });

    test('estimates never fall as the truck gets farther away (monotone)', () {
      EtaPolicy.model = const EtaModel(7.569, 2.302, samples: 188);
      int last = 0;
      for (double km = 0.02; km <= 3.0; km += 0.02) {
        final int m = eta(km, 6.0).minutes!;
        expect(m, greaterThanOrEqualTo(last), reason: '$km km');
        last = m;
      }
    });

    test('a slow truck keeps the speed estimate when it is longer than the model', () {
      EtaPolicy.model = const EtaModel(7.569, 2.302, samples: 188);
      expect(eta(0.6, 3.5).minutes, 14); // 0.6 x 1.3 / 3.5 x 60 = 13.4 > the model's 9.0
    });

    test('without a stored fit the documented defaults apply, with the same short-distance behaviour', () {
      EtaPolicy.model = EtaModel.defaults;
      expect(eta(0.1, 6.0).minutes, 2);
      expect(eta(0.5, 6.0).minutes, 7); // 5.78 + 1.79 x 0.5 = 6.7
    });
  });

  group('the 15 / 10 / 5 minute alerts can all be sent again', () {
    test('stages follow the minutes', () {
      expect(EtaPolicy.stageFor(16), isNull);
      expect(EtaPolicy.stageFor(15), 15);
      expect(EtaPolicy.stageFor(11), 15);
      expect(EtaPolicy.stageFor(10), 10);
      expect(EtaPolicy.stageFor(6), 10);
      expect(EtaPolicy.stageFor(5), 5);
      expect(EtaPolicy.stageFor(1), 5);
    });

    test('a truck approaching an area passes through the 15, 10 and 5 minute stages in order', () {
      EtaPolicy.model = const EtaModel(7.569, 2.302, samples: 188);
      final List<int> stages = <int>[];
      for (double km = 3.0; km >= 0.03; km -= 0.02) {
        final int? s = eta(km, 6.0).stage;
        if (s != null && (stages.isEmpty || stages.last != s)) stages.add(s);
      }
      expect(stages, <int>[15, 10, 5]);
    });

    test('the 5 minute stage is reached with the fitted model too (it never was with a constant minimum)', () {
      EtaPolicy.model = const EtaModel(7.569, 2.302, samples: 188);
      expect(eta(0.25, 6.0).stage, 5);
      expect(eta(0.25, 12.0).stage, 5);
    });
  });

}
