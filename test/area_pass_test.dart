import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/area_pass.dart';
import 'package:garbage_tracking_app/utils/gps_quality.dart';

void main() {
  // Ayala Highway: entrance 13.95272,121.16271 -> end 13.94579,121.15499 (about 1 km road)
  const eLat = 13.952721960507304, eLng = 121.16270755525296, nLat = 13.945787777551367, nLng = 121.15499253664089;

  test('driving along the highway segment far from its entrance counts as a pass', () {
    expect(
        AreaPass.touches(
            lat: 13.9490, lng: 121.1585, prevLat: 13.9492, prevLng: 121.1587, stepSeconds: 6,
            entranceLat: eLat, entranceLng: eLng, endLat: nLat, endLng: nLng, radiusM: 80),
        isTrue);
  });

  test('a road 300 m away is not a pass', () {
    expect(
        AreaPass.touches(
            lat: 13.9490, lng: 121.1640, prevLat: 13.9495, prevLng: 121.1641, stepSeconds: 6,
            entranceLat: eLat, entranceLng: eLng, endLat: nLat, endLng: nLng, radiusM: 80),
        isFalse);
  });

  test('a point area is touched by a step that crosses it between two sparse fixes', () {
    // Central entrance, a 60 m step passing 20 m from it
    expect(
        AreaPass.touches(
            lat: 13.95330, lng: 121.15880, prevLat: 13.95276, prevLng: 121.15880, stepSeconds: 6,
            entranceLat: 13.95302, entranceLng: 121.15900, radiusM: 60),
        isTrue);
  });

  test('an old previous fix is not trusted as a straight path', () {
    expect(
        AreaPass.touches(
            lat: 13.9600, lng: 121.1700, prevLat: 13.95302, prevLng: 121.15900, stepSeconds: 300,
            entranceLat: 13.95302, entranceLng: 121.15900, radiusM: 60),
        isFalse);
  });

  test('moving vehicle: every fix that advanced is recorded, even small steps', () {
    expect(
        RoutePointPolicy.decide(hasLastRecorded: true, distFromLastM: 4, accuracyM: 12, lastAccuracyM: 12, secondsSinceLast: 1, speedMps: 8),
        RouteRecordKind.moved);
    expect(
        RoutePointPolicy.decide(hasLastRecorded: true, distFromLastM: 4, accuracyM: 12, lastAccuracyM: 12, secondsSinceLast: 1, speedMps: 0.2),
        RouteRecordKind.skip);
  });
}
