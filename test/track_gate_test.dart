import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/gps_quality.dart';

void main() {
  const double lat = 13.9500, lng = 121.1600;
  // ~0.00001 deg lat = 1.11 m
  double north(double m) => lat + m / 111000.0;

  test('a lone 498 m spike is held and then dropped when the next fix returns to the path', () {
    final g = TrackGate();
    expect(g.offer(lat, lng, 0), TrackGateVerdict.accept);
    expect(g.offer(north(5), lng, 3000), TrackGateVerdict.accept);
    expect(g.offer(north(498), lng, 6000, accuracyM: 16), TrackGateVerdict.hold);
    expect(g.offer(north(9), lng, 9000), TrackGateVerdict.reject);
    expect(g.offer(north(14), lng, 12000), TrackGateVerdict.accept);
  });

  test('real fast travel confirmed by the next fix is accepted', () {
    final g = TrackGate();
    g.offer(lat, lng, 0);
    expect(g.offer(north(300), lng, 5000), TrackGateVerdict.hold);
    expect(g.offer(north(330), lng, 7000), TrackGateVerdict.accept);
  });

  test('a long gap with distance covered is plausible and accepted at once', () {
    final g = TrackGate();
    g.offer(lat, lng, 0);
    expect(g.offer(north(500), lng, 120000), TrackGateVerdict.accept);
  });

  test('speed smoother ignores stops and one noisy reading', () {
    final s = SpeedSmoother();
    s.add(0, 20);
    s.add(2000, 0.5);
    s.add(4000, 22);
    expect(s.valueAt(5000), isNull);
    s.add(6000, 95);
    s.add(8000, 21);
    expect(s.valueAt(9000), 21.5);
  });
}
