import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/fleet_snapshot.dart';
import 'package:garbage_tracking_app/utils/fleet_status.dart';

void main() {
  const int t0 = 1760000000000; // fixed "now" so every test is deterministic
  final int window = FleetStatus.freshnessWindowMs;

  Map<String, Object?> node({
    String driver = '7',
    String status = 'ACTIVE',
    bool online = true,
    int ageMs = 1000,
    bool trip = true,
    String? session = 'trip-1',
    double lat = 13.75,
    double lng = 121.05,
    String? ownerToken,
    String? offlineToken,
    int? loginAgeMs,
  }) =>
      {
        'driver_id': driver,
        'driver_name': 'Driver $driver',
        'status': status,
        'isOnline': online,
        'lastSeen': t0 - ageMs,
        'trip_active': trip,
        'current_session': session,
        'latitude': lat,
        'longitude': lng,
        if (ownerToken != null) 'owner_token': ownerToken,
        if (offlineToken != null) 'offline_token': offlineToken,
        if (loginAgeMs != null) 'login_time': t0 - loginAgeMs,
      };

  FleetSnapshot derive(Map<String, Object?> raw, {int? now, bool coords = false}) =>
      FleetSnapshot.derive(raw, nowMs: now ?? t0, requireCoords: coords);

  group('single policy: counts and markers come from one snapshot', () {
    test('Active Fleets == Online Drivers == marker count', () {
      final raw = {
        'GT-001': node(driver: '7'),
        'GT-002': node(driver: '9', status: 'IDLE'),
        'GT-003': node(driver: '12', status: 'FULL'),
      };
      final FleetSnapshot cards = derive(raw);
      final FleetSnapshot map = derive(raw, coords: true);
      expect(cards.activeFleets, 3);
      expect(cards.onlineDrivers, cards.activeFleets);
      expect(map.nodeKeys.toSet(), cards.nodeKeys.toSet());
    });

    test('driver with two nodes counted once and one marker (newest wins)', () {
      final raw = {
        'GT-001': node(driver: '7', ageMs: 5000),
        'GT-009': node(driver: '7', ageMs: 100),
      };
      final FleetSnapshot s = derive(raw, coords: true);
      expect(s.count, 1);
      expect(s.trucks.single.nodeKey, 'GT-009');
    });

    test('older duplicate runtime cannot override the current state', () {
      final raw = {
        'GT-001': node(driver: '7', status: 'FULL', ageMs: 200),
        'GT-OLD': node(driver: '7', status: 'ACTIVE', ageMs: 60000),
      };
      expect(derive(raw).trucks.single.node['status'], 'FULL');
    });

    test('map intentionally hides a live truck with no coordinates, cards still count it', () {
      final raw = {'GT-001': node(lat: 0, lng: 0)};
      expect(derive(raw).count, 1);
      expect(derive(raw, coords: true).count, 0);
    });
  });

  group('freshness is evaluated against time, not events', () {
    test('same data ages out of the fleet with no new event', () {
      final raw = {'GT-001': node(ageMs: 0)};
      expect(derive(raw, now: t0 + window - 1).count, 1);
      expect(derive(raw, now: t0 + window + 1).count, 0);
      expect(derive(raw, now: t0 + window + 1).rejections[FleetRejection.stale], 1);
    });

    test('stale isOnline:true is not connectivity', () {
      final n = node(ageMs: window + 60000);
      expect(n['isOnline'], true);
      expect(FleetStatus.isConnected(n, nowMs: t0), isFalse);
      expect(derive({'GT-001': n}).count, 0);
    });

    test('expired 12 h session is not live', () {
      final n = node(loginAgeMs: FleetStatus.sessionLimitMs + 1000);
      expect(derive({'GT-001': n}).count, 0);
    });

    test('one threshold everywhere: exactly the shared window', () {
      expect(FleetStatus.freshnessWindowMs, 180000);
    });
  });

  group('status transitions (Firebase state -> Admin/Resident view)', () {
    int count(Map<String, Object?> n) => derive({'GT-001': n}).count;

    test('1 login: online, not ACTIVE, no trip', () {
      final n = node(status: 'IDLE', trip: false, session: null);
      expect(count(n), 1);
      expect(FleetStatus.hasActiveTrip(n), isFalse);
      expect(FleetStatus.isCollecting(n), isFalse);
    });

    test('2 START: ACTIVE with an open trip', () {
      final n = node(status: 'ACTIVE');
      expect(count(n), 1);
      expect(FleetStatus.hasActiveTrip(n), isTrue);
      expect(FleetStatus.isCollecting(n), isTrue);
    });

    test('3 PAUSE: IDLE stays online and keeps the open trip, not collecting', () {
      final n = node(status: 'IDLE');
      expect(count(n), 1);
      expect(FleetStatus.hasActiveTrip(n), isTrue);
      expect(FleetStatus.isCollecting(n), isFalse);
    });

    test('4 resume: ACTIVE again', () {
      expect(FleetStatus.isCollecting(node(status: 'ACTIVE')), isTrue);
    });

    test('5 FULL: stays in the fleet, never treated as offline', () {
      final n = node(status: 'FULL');
      expect(count(n), 1);
      expect(FleetStatus.isConnected(n, nowMs: t0), isTrue);
      expect(FleetStatus.isCollecting(n), isFalse);
    });

    test('6 reconnect while FULL: still FULL and counted once', () {
      final raw = {
        'GT-001': node(status: 'FULL', ageMs: 100, ownerToken: 'tok-2'),
      };
      final FleetSnapshot s = derive(raw);
      expect(s.count, 1);
      expect(s.byStatus, {'FULL': 1});
    });

    test('7 DONE: COMPLETED leaves the fleet and carries no active trip', () {
      final n = node(status: 'COMPLETED', trip: false, session: null);
      expect(count(n), 0);
      expect(FleetStatus.hasActiveTrip(node(status: 'COMPLETED')), isFalse);
    });

    test('8 disconnect: connectivity goes offline without corrupting status', () {
      final n = node(status: 'FULL', ownerToken: 'tok-1', offlineToken: 'tok-1');
      expect(count(n), 0);
      expect(n['status'], 'FULL'); // collection state untouched
      expect(FleetStatus.collectionState(n), 'FULL');
    });

    test('9 reconnect: a new owner token makes the node live again', () {
      final n = node(status: 'FULL', ownerToken: 'tok-2', offlineToken: 'tok-1');
      expect(count(n), 1);
    });

    test('10 obsolete runtime disconnecting late cannot mark the new session offline', () {
      final n = node(ownerToken: 'tok-new', offlineToken: 'tok-old');
      expect(count(n), 1);
    });

    test('legacy "IDLE (LOST)" is treated as IDLE, not offline', () {
      expect(count(node(status: 'IDLE (LOST)')), 1);
    });
  });

  group('non-driver nodes', () {
    test('resident/admin/archived/system nodes never count', () {
      final raw = {
        'R': {...node(driver: '1'), 'role': 'resident'},
        'A': {...node(driver: '2'), 'role': 'admin'},
        'ARCH': {...node(driver: '3'), 'is_archived': true},
        'SYSTEM-1': node(driver: '4'),
        'GT-001': node(driver: '7'),
      };
      final s = derive(raw);
      expect(s.nodeKeys.toList(), ['GT-001']);
    });
  });

  group('rapid and out-of-order updates', () {
    test('the newest lastSeen wins regardless of node order', () {
      final both = {
        'GT-001': node(ageMs: 5000),
        'GT-002': node(ageMs: 100),
      };
      expect(derive(both).trucks.single.nodeKey, 'GT-002');
      final reversed = {
        'GT-002': node(ageMs: 100),
        'GT-001': node(ageMs: 5000),
      };
      expect(derive(reversed).trucks.single.nodeKey, 'GT-002');
    });

    test('100 rapid snapshots keep the count stable at one driver', () {
      for (int i = 0; i < 100; i++) {
        expect(derive({'GT-001': node(ageMs: i)}).count, 1);
      }
    });
  });
}
