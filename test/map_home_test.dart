import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/map_home.dart';

void main() {
  test('globe / region views go back to Balintawak; views inside the barangay are kept', () {
    expect(MapHome.needsHome(1.5, 30, 0), isTrue); // the whole-globe default camera
    expect(MapHome.needsHome(6, 13.9565, 121.1620), isTrue); // zoomed out to the region
    expect(MapHome.needsHome(14, 14.5995, 120.9842), isTrue); // Manila, far from Lipa
    expect(MapHome.needsHome(14.2, 13.9565, 121.1620), isFalse);
    expect(MapHome.needsHome(17.5, 13.9600, 121.1650), isFalse); // focused on a truck
  });
}
