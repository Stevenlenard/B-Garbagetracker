import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/eta_policy.dart';

/// A collecting truck stops all the time: 41% of the one-minute windows of the recorded trips (7,495 windows, 310 trips)
/// were slower than 3 km/h. The estimate used to disappear at every stop ("ETA unavailable", no alert, nothing in
/// Collection status). Without a travel speed it now falls back to what recorded trips took for the distance.
void main() {
  EtaResult stopped({double? straightKm, double speed = 0, double avg = 0.6, String status = 'ACTIVE', int gpsAgeMs = 0}) =>
      EtaPolicy.evaluate(
        status: status,
        gpsAgeMs: gpsAgeMs,
        distanceKm: straightKm == null ? 1.0 : EtaPolicy.roadDistanceKm(straightKm),
        straightKm: straightKm,
        speedKmh: speed,
        averageSpeedKmh: avg,
        arrivalRadiusM: 0,
      );

  setUp(() => EtaPolicy.model = EtaModel.defaults);

  test('a stopped truck 1 km away still gets an estimate from the recorded-trip model, at the 10-minute stage', () {
    final EtaResult r = stopped(straightKm: 1.0);
    expect(r.isAvailable, isTrue);
    expect(r.fromModel, isTrue);
    expect(r.minutes, EtaModel.defaults.minutesFor(1.0).ceil()); // 7.57 -> 8
    expect(r.stage, 10);
    expect(r.label, '~8 min');
  });

  test('close to the area the delay is proportionally small, so the 5-minute stage can be reached', () {
    final EtaResult r = stopped(straightKm: 0.2);
    expect(r.fromModel, isTrue);
    expect(r.minutes, lessThanOrEqualTo(5));
    expect(r.stage, 5);
  });

  test('stopped and still far (model says more than 30 minutes): unavailable, not a guess', () {
    final EtaResult r = stopped(straightKm: 20);
    expect(r.isAvailable, isFalse);
    expect(r.reason, contains('far'));
  });

  test('without a distance for the model there is still no estimate', () {
    expect(stopped().isAvailable, isFalse);
  });

  test('a moving truck is unchanged: distance / speed against the model, and not marked as model-only', () {
    final EtaResult r = EtaPolicy.evaluate(
        status: 'ACTIVE', gpsAgeMs: 0, distanceKm: 1.3, straightKm: 1.0, speedKmh: 20, arrivalRadiusM: 0);
    expect(r.fromModel, isFalse);
    expect(r.minutes, 8); // max(3.9 by speed, 7.57 by model)
  });

  test('the fallback never applies to a truck that is not collecting or whose GPS is old', () {
    expect(stopped(straightKm: 1.0, status: 'PAUSED').isAvailable, isFalse);
    expect(stopped(straightKm: 1.0, status: 'OFFLINE').isAvailable, isFalse);
    expect(stopped(straightKm: 1.0, gpsAgeMs: 400000).isAvailable, isFalse);
  });

  test('arrival is still a measured fact, not a model output', () {
    final EtaResult r = EtaPolicy.evaluate(
        status: 'ACTIVE', gpsAgeMs: 0, distanceKm: 0.03, straightKm: 0.03, speedKmh: 0, arrivalRadiusM: 60);
    expect(r.kind, EtaKind.arrived);
  });
}
