import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/driver_route_history_service.dart';

void main() {
  test("a short GPS drop at normal speed does not cut the route line (real trip of 19 Oct 2026)", () {
    expect(DriverRouteHistoryService.isRouteBreak(33, 331), isFalse); // 08:46:27, 36 km/h
    expect(DriverRouteHistoryService.isRouteBreak(29, 365), isFalse); // 08:47:01
    expect(DriverRouteHistoryService.isRouteBreak(51, 158), isFalse); // 08:48:28
  });

  test('a real outage or an impossible jump still cuts the line', () {
    expect(DriverRouteHistoryService.isRouteBreak(200, 10), isTrue); // more than 3 minutes without GPS
    expect(DriverRouteHistoryService.isRouteBreak(5, 400), isTrue); // 80 m/s
    expect(DriverRouteHistoryService.isRouteBreak(0, 350), isTrue);
    expect(DriverRouteHistoryService.isRouteBreak(5, 40), isFalse);
  });
}
