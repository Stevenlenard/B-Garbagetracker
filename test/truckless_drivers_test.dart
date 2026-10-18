import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/truckless_drivers.dart';

void main() {
  const int now = 1792291000000;
  Map<String, dynamic> driver({Object? truck, bool online = true, String role = 'driver', int seenAgo = 5000, Object? trip = 'T1', String status = 'ACTIVE'}) => <String, dynamic>{
        'role': role,
        'isOnline': online,
        'status': status,
        'lastSeen': now - seenAgo,
        'login_time': now - 600000,
        'current_trip_id': trip,
        if (truck != null) 'preferred_truck': truck,
        'name': 'Arian Joy',
      };

  test('a signed-in driver on a trip with no truck is listed, with their trip id', () {
    expect(TrucklessDrivers.candidates(<String, dynamic>{'20': driver()}, now), <String, String>{'20': 'T1'});
    expect(TrucklessDrivers.candidates(<String, dynamic>{'20': driver(truck: 'Unknown')}, now).keys, <String>['20']);
  });

  test('drivers with a truck, offline, stale, non-drivers, ended or tripless are not listed', () {
    final Map<String, dynamic> users = <String, dynamic>{
      '1': driver(truck: 'GT-003'),
      '2': driver(online: false),
      '3': driver(seenAgo: 400000),
      '4': driver(role: 'resident'),
      '5': driver(status: 'OFFLINE'),
      '6': driver(trip: null),
    };
    expect(TrucklessDrivers.candidates(users, now), isEmpty);
  });

  test('a stationary driver stays visible: freshness comes from the account heartbeat, not the last GPS fix', () {
    final Map<String, dynamic>? n = TrucklessDrivers.buildNode(
        driverId: '20', user: driver(), lat: 13.954, lng: 121.16, routeStatus: 'ACTIVE', isSimulation: false);
    expect(n!['lastSeen'], now - 5000);
    expect(n['isOnline'], true);
    expect(n['truck_id'], 'No truck');
  });

  test('simulated trips, ended trips and missing fixes never produce a node', () {
    Map<String, dynamic>? b(Object? lat, Object? rs, Object? sim) =>
        TrucklessDrivers.buildNode(driverId: '20', user: driver(), lat: lat, lng: 121.16, routeStatus: rs, isSimulation: sim);
    expect(b(13.95, 'ACTIVE', true), isNull);
    expect(b(13.95, 'COMPLETED', false), isNull);
    expect(b(null, 'ACTIVE', false), isNull);
    expect(b(13.95, 'ACTIVE', false), isNotNull);
  });
}
