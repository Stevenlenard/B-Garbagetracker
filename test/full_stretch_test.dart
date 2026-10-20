import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/route_geometry.dart';

void main() {
  test('the stretch driven while FULL is its own (red) feature, connected to the collecting part', () {
    Map<String, Object?> p(double lat, int s, String color) =>
        {'lat': lat, 'lng': 121.16, 'timestamp': s * 5000, 'accuracy': 8, 'color': color};
    final f = RouteGeometry.lineFeatures(<Map>[
      p(13.9500, 0, 'GREEN'), p(13.9505, 1, 'GREEN'), p(13.9510, 2, 'PINK'), p(13.9515, 3, 'PINK'),
    ]);
    expect(f.length, 2);
    expect(RouteGeometry.isFullStretch(f[0]), isFalse);
    expect(RouteGeometry.isFullStretch(f[1]), isTrue);
    final a = (f[0]['geometry'] as Map)['coordinates'] as List, b = (f[1]['geometry'] as Map)['coordinates'] as List;
    expect(a.last, b.first); // no gap between collecting and FULL travel
  });
}
