import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/route_geometry.dart';

void main() {
  Map<String, Object?> pt(double lat, double lng, int ts) => <String, Object?>{'lat': lat, 'lng': lng, 'timestamp': ts, 'accuracy': 8, 'status': 'ACTIVE'};

  test('the line reaches the live marker even 300 m past the last saved point (no trailing gap, not treated as a jump)', () {
    final pts = <Map>[pt(13.9500, 121.1600, 0), pt(13.9505, 121.1600, 5000)];
    final withTail = RouteGeometry.withLiveTail(pts, 13.9532, 121.1600);
    final coords = (RouteGeometry.lineFeatures(withTail).single['geometry'] as Map)['coordinates'] as List;
    expect(coords.length, 3);
    expect((coords.last as List)[1], 13.9532);
  });

  test('no tail when the live position is missing or on top of the last point', () {
    final pts = <Map>[pt(13.9500, 121.1600, 0), pt(13.9505, 121.1600, 5000)];
    expect(RouteGeometry.withLiveTail(pts, null, null).length, 2);
    expect(RouteGeometry.withLiveTail(pts, 13.95051, 121.1600).length, 2);
  });
}
