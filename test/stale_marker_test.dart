import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/fleet_status.dart';

void main() {
  const int now = 10000000;
  Map<String, Object?> node({
    String driver = '7',
    bool online = false,
    String status = 'ACTIVE',
    bool trip = true,
    int seenAgoMs = 5 * 60000,
    double lat = 13.95,
    double lng = 121.16,
  }) =>
      <String, Object?>{
        'driver_id': driver,
        'isOnline': online,
        'status': status,
        'trip_active': trip,
        'lastSeen': now - seenAgoMs,
        'latitude': lat,
        'longitude': lng,
      };

  test('a truck that stopped reporting during its trip keeps a last-known marker', () {
    expect(FleetStatus.staleMarkers(<Map>[node()], nowMs: now), hasLength(1));
  });

  test('a live truck is never also drawn as stale', () {
    expect(FleetStatus.staleMarkers(<Map>[node(online: true)], nowMs: now), isEmpty);
  });

  test('an older node of a driver that has a live node is not a second truck', () {
    final List<Map> r = FleetStatus.staleMarkers(<Map>[node(online: true), node(seenAgoMs: 60000)], nowMs: now);
    expect(r, isEmpty);
  });

  test('only the newest stale node of one driver is drawn', () {
    final Map newer = node(seenAgoMs: 60000);
    final List<Map> r = FleetStatus.staleMarkers(<Map>[node(seenAgoMs: 600000), newer], nowMs: now);
    expect(r, <Map>[newer]);
  });

  test('ended, logged out, tripless, positionless or long-silent trucks are not drawn', () {
    expect(FleetStatus.staleMarkers(<Map>[node(status: 'COMPLETED')], nowMs: now), isEmpty);
    expect(FleetStatus.staleMarkers(<Map>[node(status: 'OFFLINE')], nowMs: now), isEmpty);
    expect(FleetStatus.staleMarkers(<Map>[node(trip: false)], nowMs: now), isEmpty);
    expect(FleetStatus.staleMarkers(<Map>[node(lat: 0, lng: 0)], nowMs: now), isEmpty);
    expect(FleetStatus.staleMarkers(<Map>[node(seenAgoMs: FleetStatus.staleMarkerWindowMs + 1000)], nowMs: now), isEmpty);
  });

  test('a FULL or paused truck that loses connection is still shown as last known', () {
    expect(FleetStatus.staleMarkers(<Map>[node(status: 'FULL'), node(driver: '8', status: 'IDLE')], nowMs: now), hasLength(2));
  });

  test('the stale label says how long ago', () {
    expect(FleetStatus.lastSeenLabel(node(seenAgoMs: 4 * 60000 + 5000), nowMs: now), 'Last seen 4 min ago');
    expect(FleetStatus.lastSeenLabel(node(seenAgoMs: 20000), nowMs: now), 'Last seen just now');
  });
}
