import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/fleet_snapshot.dart';

void main() {
  const int t0 = 1760000000000;

  Map<String, Object?> node(String driver,
          {String status = 'ACTIVE', bool online = true, int ageMs = 1000}) =>
      {
        'driver_id': driver,
        'driver_name': 'Driver $driver',
        'status': status,
        'isOnline': online,
        'lastSeen': t0 - ageMs,
        'trip_active': true,
        'current_session': 'trip-$driver',
        'latitude': 13.75,
        'longitude': 121.05,
      };

  FleetSnapshot snap(Map<String, Object?> raw) => FleetSnapshot.derive(raw, nowMs: t0, includeCompleted: true);

  test('two online drivers -> 2; one offline -> 1; both offline -> 0', () {
    expect(snap({'GT-1': node('7'), 'GT-2': node('9')}).onlineDrivers, 2);
    expect(snap({'GT-1': node('7'), 'GT-2': node('9', online: false)}).onlineDrivers, 1);
    expect(snap({'GT-1': node('7', online: false), 'GT-2': node('9', online: false)}).onlineDrivers, 0);
    // removed nodes / expired heartbeat
    expect(snap(<String, Object?>{}).onlineDrivers, 0);
    expect(snap({'GT-1': node('7', ageMs: 10 * 60 * 1000)}).onlineDrivers, 0);
  });

  test('PAUSED and FULL are still online', () {
    final s = snap({'GT-1': node('7', status: 'IDLE'), 'GT-2': node('9', status: 'FULL')});
    expect(s.onlineDrivers, 2);
    expect(s.byStatus['IDLE'], 1);
    expect(s.byStatus['FULL'], 1);
  });

  test('duplicate sessions of one driver count once', () {
    final s = snap({'GT-1': node('7'), 'GT-1-dup': node('7')});
    expect(s.onlineDrivers, 1);
  });

  test('Overview and Fleet Status agree on one snapshot', () {
    final s = snap({'GT-1': node('7'), 'GT-2': node('9', status: 'FULL')});
    expect(s.onlineDrivers, s.count);
    expect(s.fleetTrucks.length, s.activeFleets);
    expect(s.onlineDrivers, s.nodeKeys.length);
  });

  test('connected COMPLETED driver leaving changes the signature (no stale count)', () {
    final before = snap({'GT-1': node('7', status: 'COMPLETED'), 'GT-2': node('9', status: 'COMPLETED')});
    expect(before.onlineDrivers, 2);
    expect(before.fleetTrucks, isEmpty); // the fleet list alone would not change on disconnect
    final after = snap({
      'GT-1': node('7', status: 'COMPLETED', online: false),
      'GT-2': node('9', status: 'COMPLETED', online: false),
    });
    expect(after.onlineDrivers, 0);
    expect(after.signature, isNot(before.signature));
  });

  test('Fleet Status list (all live trucks) equals the Online Drivers count', () {
    final s = snap({
      'GT-1': node('7', status: 'ACTIVE'),
      'GT-2': node('9', status: 'COMPLETED'),
      'GT-3': node('11', status: 'COMPLETED', online: false),
    });
    expect(s.trucks.length, s.onlineDrivers); // what Fleet Status now lists
    expect(s.trucks.where((t) => t.isCompleted).length, 1); // shown with a COMPLETED badge
    expect(s.activeFleets, 1); // the COMPLETED driver is not an active (collecting) fleet
    expect(s.collecting, 1);
  });
}
