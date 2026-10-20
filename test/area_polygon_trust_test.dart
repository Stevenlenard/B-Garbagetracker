import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/collection_visits.dart';

void main() {
  // the stored Brixton Homes box (about 650 x 670 m) and a fix near Dali, 232 m from Brixton's area point
  const brixtonBox = <List<double>>[[121.1537, 13.9581], [121.1597, 13.9581], [121.1597, 13.9521], [121.1537, 13.9521], [121.1537, 13.9581]];

  test('a placeholder box is not trusted: a walk near Dali is not a Brixton Homes visit', () {
    const g = AreaGeofence(name: 'Brixton Homes', lat: 13.9551652, lng: 121.1567505, radiusM: 65, polygon: brixtonBox);
    expect(g.usesPolygon, isFalse);
    expect(g.contains(13.9545, 121.1590), isFalse);
    expect(g.contains(13.9552, 121.1568), isTrue);
  });

  test('a box that does not contain its own area point (Central, 1.2 km away) is not trusted', () {
    const centralBox = <List<double>>[[121.157, 13.9435], [121.1615, 13.945], [121.163, 13.941], [121.159, 13.9385], [121.157, 13.9435]];
    const g = AreaGeofence(name: 'Central', lat: 13.953, lng: 121.1588, radiusM: 60, polygon: centralBox);
    expect(g.usesPolygon, isFalse);
    expect(g.contains(13.9532, 121.1589), isTrue);
  });

  test('a real, small boundary around its area is used', () {
    const small = <List<double>>[[121.1495, 13.9672], [121.1508, 13.9672], [121.1508, 13.9660], [121.1495, 13.9660], [121.1495, 13.9672]];
    const g = AreaGeofence(name: 'Purok 4', lat: 13.9665, lng: 121.1501, radiusM: 70, polygon: small);
    expect(g.usesPolygon, isTrue);
  });
}
