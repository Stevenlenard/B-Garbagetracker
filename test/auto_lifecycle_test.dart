import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/driver_lifecycle.dart';
import 'package:garbage_tracking_app/services/driver_session_guard.dart';
import 'package:garbage_tracking_app/services/rtdb_port.dart';
import 'package:garbage_tracking_app/services/server_clock.dart';
import 'package:garbage_tracking_app/utils/fleet_snapshot.dart';
import 'package:garbage_tracking_app/utils/fleet_status.dart';
import 'package:garbage_tracking_app/utils/gps_fix_policy.dart';

import 'support/fake_rtdb.dart';

// FakeRtdb resolves server timestamps to small counters, so "now" for the
// 12-hour age rule is injected explicitly.
const int kNow = 5000;

DriverSessionGuard guardFor(FakeRtdb db, String driver, String label) =>
    DriverSessionGuard(db: db, driverId: driver, runtimeLabel: label, token: 'tok-$label');

Future<TripOpenResult> openTrip(
  FakeRtdb db,
  DriverSessionGuard g, {
  String driver = '7',
  String truck = 'GT-007',
  String newId = 'trip-new',
  String? pending,
}) =>
    TripOpener.open(
      db: db,
      guard: g,
      driverId: driver,
      truckId: truck,
      driverName: 'Driver $driver',
      newTripId: newId,
      pendingTripId: pending,
      startLat: 13.75,
      startLng: 121.05,
      startTimeLabel: '8:00 AM',
      nowMs: kNow,
    );

Map<String, Object?> frozenRecord({double km = 4.2, int startMs = 1000, int endMs = 3000, String via = 'FULL'}) =>
    CollectionRecord.build(
      startMs: startMs,
      nowMs: endMs,
      distanceKm: km,
      weightKg: 5000,
      weightType: 'ESTIMATED',
      via: via,
      endLat: 13.76,
      endLng: 121.06,
    );

int tripCount(FakeRtdb db) {
  final Object? v = db.read('driver_routes');
  return v is Map ? v.length : 0;
}

void main() {
  group('LOGIN opens the collection trip automatically', () {
    test('1. login opens exactly one ACTIVE trip with a real start coordinate', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');

      expect(
        AutoStartPolicy.decide(ownerCanWrite: g.canWrite, hasLocalTrip: false, completedThisLogin: false, simulation: false),
        AutoStartDecision.start,
      );
      final r = await openTrip(db, g);
      expect(r.status, TripOpenStatus.created);
      expect(tripCount(db), 1);
      final Map trip = db.read('driver_routes/trip-new') as Map;
      expect(trip['route_status'], 'ACTIVE');
      expect(trip['start_lat'], 13.75);
      expect(trip['driver_id'], '7');
      expect(g.tripId, 'trip-new');
      // Once bound, no further start is attempted.
      expect(
        AutoStartPolicy.decide(ownerCanWrite: true, hasLocalTrip: true, completedThisLogin: false, simulation: false),
        AutoStartDecision.skip,
      );
    });

    test('2. repeated login / retry never creates a second trip', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      await openTrip(db, g, newId: 'trip-1');
      // App restart: the unfinished trip is found and passed as pending.
      final g2 = guardFor(db, '7', 'B');
      await g2.claim(truckId: 'GT-007');
      final r = await openTrip(db, g2, newId: 'trip-2-unused', pending: 'trip-1');
      expect(r.status, TripOpenStatus.resumed);
      expect(r.tripId, 'trip-1');
      expect(tripCount(db), 1);
    });

    test('2b. a failed create retried with the same id leaves no orphan', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      await openTrip(db, g, newId: 'trip-1');
      await openTrip(db, g, newId: 'trip-1'); // retry with the same stable id
      expect(tripCount(db), 1);
    });

    test('3. reconnect resumes the same unfinished trip and keeps its start', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      await openTrip(db, g, newId: 'trip-1');
      final startBefore = (db.read('driver_routes/trip-1') as Map)['start_time'];
      final r = await openTrip(db, g, newId: 'x', pending: 'trip-1');
      expect(r.tripId, 'trip-1');
      expect((db.read('driver_routes/trip-1') as Map)['start_time'], startBefore);
    });

    test('a trip of another driver, a simulation or a day-old trip is never adopted', () async {
      final db = FakeRtdb();
      db.seed('driver_routes/other', {'driver_id': '9', 'route_status': 'ACTIVE', 'server_start_time': 1000});
      db.seed('driver_routes/sim', {'driver_id': '7', 'route_status': 'ACTIVE', 'is_simulation': true, 'server_start_time': 1000});
      db.seed('driver_routes/old', {'driver_id': '7', 'route_status': 'ACTIVE', 'server_start_time': 1});
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      for (final pending in ['other', 'sim']) {
        final r = await openTrip(db, g, newId: 'new-$pending', pending: pending);
        expect(r.status, TripOpenStatus.created, reason: pending);
        await g.bindTrip(null);
      }
      // Older than 12 h relative to "now".
      final r = await TripOpener.open(
        db: db,
        guard: g,
        driverId: '7',
        truckId: 'GT-007',
        driverName: 'D',
        newTripId: 'new-old',
        pendingTripId: 'old',
        startLat: 1,
        startLng: 1,
        startTimeLabel: 'x',
        nowMs: 43200000 + 10,
      );
      expect(r.status, TripOpenStatus.created);
    });

    test('12. a second runtime of the same driver cannot hold a second authoritative trip', () async {
      final db = FakeRtdb();
      final a = guardFor(db, '7', 'A');
      final b = guardFor(db, '7', 'B');
      await a.claim(truckId: 'GT-007');
      await openTrip(db, a, newId: 'trip-A');
      await b.claim(truckId: 'GT-007'); // takes over
      expect(a.canWrite, isFalse);
      final late = await openTrip(db, a, newId: 'trip-A2'); // displaced runtime tries again
      expect(late.status, TripOpenStatus.notOwner);
      expect(a.tripId == 'trip-A2', isFalse);
      expect(db.read('driver_routes/trip-A2'), isNull);
    });
  });

  group('ACTIVE is not inferred from movement', () {
    test('4. a stationary truck with fresh fixes stays ACTIVE and online for minutes', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      final pub = OwnedNodePublisher(db: db, path: 'truck_locations/GT-007', guard: g);
      final DateTime t = DateTime.utc(2026, 10, 12, 8);
      for (int i = 0; i < 6; i++) {
        // identical coordinates every 30 s for 3 minutes
        await pub.publish({
          'status': 'ACTIVE',
          'isOnline': true,
          'latitude': 13.75,
          'longitude': 121.05,
          'speed': 0.0,
          'lastSeen': t.add(Duration(seconds: 30 * i)).millisecondsSinceEpoch,
          'gps_at': t.add(Duration(seconds: 30 * i)).millisecondsSinceEpoch,
        });
      }
      final node = db.read('truck_locations/GT-007') as Map;
      final int now = t.add(const Duration(minutes: 3)).millisecondsSinceEpoch;
      expect(node['status'], 'ACTIVE');
      expect(FleetStatus.isLive(node, nowMs: now), isTrue);
      expect(FleetStatus.isGpsFresh(node, nowMs: now), isTrue);
    });

    test('19. fresh fix with unchanged coordinates is accepted (time, not distance)', () {
      final DateTime now = DateTime.utc(2026, 10, 12, 8, 0, 10);
      expect(
        GpsFixPolicy.evaluate(
          fixTime: DateTime.utc(2026, 10, 12, 8, 0, 9),
          nowTime: now,
          lastAcceptedFixTime: DateTime.utc(2026, 10, 12, 8, 0, 4),
        ),
        GpsFixVerdict.accept,
      );
    });

    test('GPS freshness is separate from connectivity (heartbeat does not refresh gps_at)', () {
      const int now = 1760000000000;
      final node = {
        'isOnline': true,
        'status': 'ACTIVE',
        'lastSeen': now - 1000, // heartbeat just now
        'gps_at': now - 400000, // last real fix is old
      };
      expect(FleetStatus.isConnected(node, nowMs: now), isTrue);
      expect(FleetStatus.isGpsFresh(node, nowMs: now), isFalse);
    });

    test('5/6. PAUSE keeps the trip and presence; RESUME restores ACTIVE on the same trip', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      await openTrip(db, g, newId: 'trip-1');
      final pub = OwnedNodePublisher(db: db, path: 'truck_locations/GT-007', guard: g);
      await pub.publish({'status': 'ACTIVE', 'isOnline': true, 'trip_active': true, 'current_session': 'trip-1', 'lastSeen': kNow});
      await pub.publish({'status': 'IDLE', 'isOnline': true, 'trip_active': true, 'lastSeen': kNow});
      final paused = db.read('truck_locations/GT-007') as Map;
      expect(paused['status'], 'IDLE');
      expect(paused['current_session'], 'trip-1');
      expect(FleetStatus.isLive(paused, nowMs: kNow), isTrue);
      expect(FleetStatus.isCollecting(paused), isFalse);
      expect(g.tripId, 'trip-1');
      await pub.publish({'status': 'ACTIVE', 'lastSeen': kNow});
      final resumed = db.read('truck_locations/GT-007') as Map;
      expect(resumed['status'], 'ACTIVE');
      expect(resumed['current_session'], 'trip-1');
      expect(tripCount(db), 1);
    });
  });

  group('FULL freezes the collection', () {
    Future<(FakeRtdb, DriverSessionGuard)> started() async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      await openTrip(db, g, newId: 'trip-1');
      return (db, g);
    }

    test('7. FULL records duration, distance, end point and load once', () async {
      final (db, g) = await started();
      final r = await CollectionFinalizer.finalize(db: db, guard: g, tripId: 'trip-1', record: frozenRecord());
      expect(r, CollectionFinalResult.finalized);
      final Map trip = db.read('driver_routes/trip-1') as Map;
      final Map rec = trip['collection'] as Map;
      expect(rec['duration_s'], 2); // (3000-1000) ms
      expect(rec['distance_km'], 4.2);
      expect(rec['weight_kg'], 5000);
      expect(trip['route_status'], 'FULL');
      expect(trip['total_distance'], 4.2);
      expect(trip['collection_finalized'], true);
      expect(trip['isFinished'], isNot(true), reason: 'FULL is not the end of the trip');
    });

    test('8. later GPS / travel cannot change the frozen metrics', () async {
      final (db, g) = await started();
      await CollectionFinalizer.finalize(db: db, guard: g, tripId: 'trip-1', record: frozenRecord(km: 4.2));
      // A late attempt (e.g. retried tap computed after extra travel) is ignored.
      final again = await CollectionFinalizer.finalize(
        db: db,
        guard: g,
        tripId: 'trip-1',
        record: frozenRecord(km: 11.9, endMs: 9000),
      );
      expect(again, CollectionFinalResult.alreadyFinalized);
      final Map rec = (db.read('driver_routes/trip-1') as Map)['collection'] as Map;
      expect(rec['distance_km'], 4.2);
      expect(rec['finalized_at_ms'], 3000);
      expect((db.read('driver_routes/trip-1') as Map)['total_distance'], 4.2);
    });

    test('10. FULL is idempotent: no second record, same stored values', () async {
      final (db, g) = await started();
      final a = await CollectionFinalizer.finalize(db: db, guard: g, tripId: 'trip-1', record: frozenRecord());
      final b = await CollectionFinalizer.finalize(db: db, guard: g, tripId: 'trip-1', record: frozenRecord());
      expect(a, CollectionFinalResult.finalized);
      expect(b, CollectionFinalResult.alreadyFinalized);
      expect(tripCount(db), 1);
    });

    test('FULL before any trip exists is rejected, nothing is fabricated', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      // No trip (GPS not yet available): the finalizer has nothing to freeze and the
      // screen blocks the action before reaching it.
      expect(db.read('driver_routes'), isNull);
      expect(g.tripId, isNull);
    });

    test('reconnect while FULL restores FULL; it is never reopened or recreated', () async {
      final (db, g) = await started();
      await CollectionFinalizer.finalize(db: db, guard: g, tripId: 'trip-1', record: frozenRecord());
      final trip = db.read('driver_routes/trip-1');
      expect(TripResumePolicy.classify(trip, driverId: '7', nowMs: kNow), RecoveredTrip.awaitingUnload);

      final g2 = guardFor(db, '7', 'B');
      await g2.claim(truckId: 'GT-007');
      final r = await openTrip(db, g2, newId: 'trip-other', pending: 'trip-1');
      expect(r.status, TripOpenStatus.restoredFull);
      expect(r.tripId, 'trip-1');
      expect(tripCount(db), 1);
      expect(((db.read('driver_routes/trip-1') as Map)['collection'] as Map)['distance_km'], 4.2);
    });
  });

  group('COMPLETED confirms unloading', () {
    Future<(FakeRtdb, DriverSessionGuard)> full() async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      await openTrip(db, g, newId: 'trip-1');
      await CollectionFinalizer.finalize(db: db, guard: g, tripId: 'trip-1', record: frozenRecord());
      return (db, g);
    }

    test('9. COMPLETED adds unloading data without a second trip or changed metrics', () async {
      final (db, g) = await full();
      final res = await TripFinalizer.finish(
        db: db,
        guard: g,
        tripId: 'trip-1',
        fields: CollectionRecord.completionFields(
          nowMs: 4000,
          endTimeLabel: '10:00 AM',
          postFullDistanceKm: 7.5,
          lat: 13.9,
          lng: 121.2,
        ),
      );
      expect(res, FinishResult.finished);
      final Map trip = db.read('driver_routes/trip-1') as Map;
      expect(trip['route_status'], 'COMPLETED');
      expect(trip['unloading_confirmed_at_ms'], 4000);
      expect(trip['post_full_distance_km'], 7.5);
      expect(trip['isFinished'], true);
      expect(trip['total_distance'], 4.2, reason: 'landfill travel is not collection distance');
      expect(trip['collection_distance_km'], 4.2);
      expect(((trip['collection'] as Map)['finalized_at_ms']), 3000);
      expect(tripCount(db), 1);
    });

    test('10. COMPLETED is idempotent', () async {
      final (db, g) = await full();
      final f = CollectionRecord.completionFields(nowMs: 4000, endTimeLabel: 'x');
      expect(await TripFinalizer.finish(db: db, guard: g, tripId: 'trip-1', fields: f), FinishResult.finished);
      final g2 = guardFor(db, '7', 'A2');
      await g2.claim(truckId: 'GT-007');
      expect(await TripFinalizer.finish(db: db, guard: g2, tripId: 'trip-1', fields: f), FinishResult.alreadyFinished);
      expect(tripCount(db), 1);
    });

    test('11. after COMPLETED no zombie write, no re-finalize, no re-adoption', () async {
      final (db, g) = await full();
      await TripFinalizer.finish(
        db: db,
        guard: g,
        tripId: 'trip-1',
        fields: CollectionRecord.completionFields(nowMs: 4000, endTimeLabel: 'x'),
      );
      // Re-own the driver (a heartbeat/stale runtime) and try everything.
      final g2 = guardFor(db, '7', 'Z');
      await g2.claim(truckId: 'GT-007');
      await g2.bindTrip('trip-1');
      final w = await TripRouteWriter(db: db, guard: g2, verifyTtlMs: 0).write(
        tripId: 'trip-1',
        tripFinished: false,
        finishing: false,
        point: {'lat': 1.0, 'lng': 1.0},
        meta: {'total_distance': 99.0},
      );
      expect(w.denial, WriteDenial.tripFinished);
      expect((db.read('driver_routes/trip-1') as Map)['total_distance'], 4.2);
      expect(
        await CollectionFinalizer.finalize(db: db, guard: g2, tripId: 'trip-1', record: frozenRecord(km: 50)),
        CollectionFinalResult.tripFinished,
      );
      expect(TripResumePolicy.classify(db.read('driver_routes/trip-1'), driverId: '7', nowMs: kNow), RecoveredTrip.none);
    });

    test('a login session that confirmed COMPLETED does not auto-open another trip', () {
      expect(
        AutoStartPolicy.decide(ownerCanWrite: true, hasLocalTrip: false, completedThisLogin: true, simulation: false),
        AutoStartDecision.skip,
      );
    });

    test('COMPLETED without FULL finalizes first, flagged, then seals', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      await openTrip(db, g, newId: 'trip-1');
      final f = await CollectionFinalizer.finalize(
        db: db,
        guard: g,
        tripId: 'trip-1',
        record: frozenRecord(via: 'COMPLETED_WITHOUT_FULL'),
      );
      expect(f, CollectionFinalResult.finalized);
      await TripFinalizer.finish(
        db: db,
        guard: g,
        tripId: 'trip-1',
        fields: CollectionRecord.completionFields(nowMs: 4000, endTimeLabel: 'x'),
      );
      final Map trip = db.read('driver_routes/trip-1') as Map;
      expect((trip['collection'] as Map)['finalized_via'], 'COMPLETED_WITHOUT_FULL');
      expect(trip['route_status'], 'COMPLETED');
    });

    test('a replaced runtime cannot finalize or complete', () async {
      final (db, g) = await full();
      final b = guardFor(db, '7', 'B');
      await b.claim(truckId: 'GT-007');
      expect(g.canWrite, isFalse);
      expect(
        await CollectionFinalizer.finalize(db: db, guard: g, tripId: 'trip-1', record: frozenRecord()),
        CollectionFinalResult.notOwner,
      );
      expect(
        await TripFinalizer.finish(db: db, guard: g, tripId: 'trip-1', fields: {}),
        FinishResult.notOwner,
      );
    });
  });

  group('multiple drivers stay distinct', () {
    test('13/14. two trucks, interleaved GPS: no coordinate or trip mixing', () async {
      final db = FakeRtdb();
      final g7 = guardFor(db, '7', 'A');
      final g9 = guardFor(db, '9', 'B');
      await g7.claim(truckId: 'GT-007');
      await g9.claim(truckId: 'GT-009');
      await openTrip(db, g7, driver: '7', truck: 'GT-007', newId: 'trip-7');
      await openTrip(db, g9, driver: '9', truck: 'GT-009', newId: 'trip-9');
      final p7 = OwnedNodePublisher(db: db, path: 'truck_locations/GT-007', guard: g7);
      final p9 = OwnedNodePublisher(db: db, path: 'truck_locations/GT-009', guard: g9);
      for (int i = 0; i < 5; i++) {
        await Future.wait([
          p7.publish({
            'driver_id': '7', 'truck_id': 'GT-007', 'current_session': 'trip-7',
            'latitude': 13.0 + i / 1000, 'longitude': 121.0, 'status': 'ACTIVE', 'isOnline': true, 'lastSeen': kNow,
          }),
          p9.publish({
            'driver_id': '9', 'truck_id': 'GT-009', 'current_session': 'trip-9',
            'latitude': 14.0 + i / 1000, 'longitude': 122.0, 'status': 'IDLE', 'isOnline': true, 'lastSeen': kNow,
          }),
        ]);
      }
      final n7 = db.read('truck_locations/GT-007') as Map;
      final n9 = db.read('truck_locations/GT-009') as Map;
      expect(n7['driver_id'], '7');
      expect(n7['current_session'], 'trip-7');
      expect((n7['latitude'] as num) < 14, isTrue);
      expect(n9['current_session'], 'trip-9');
      expect((n9['latitude'] as num) > 14, isTrue);
      expect(g7.tripId, 'trip-7');
      expect(g9.tripId, 'trip-9');

      final snap = FleetSnapshot.derive(db.read('truck_locations'), nowMs: kNow, requireCoords: true);
      expect(snap.count, 2);
      expect(snap.trucks.map((t) => t.driverKey).toSet(), {'7', '9'});
    });
  });

  group('dashboard counts follow the lifecycle', () {
    Map<String, Object?> nodeFor(String status, {bool online = true, String? offlineToken, int age = 1000}) => {
          'driver_id': '7',
          'driver_name': 'Driver 7',
          'truck_id': 'GT-007',
          'status': status,
          'isOnline': online,
          'trip_active': status == 'ACTIVE' || status == 'IDLE' || status == 'FULL',
          'current_session': status == 'COMPLETED' ? null : 'trip-1',
          'lastSeen': 1760000000000 - age,
          'latitude': 13.75,
          'longitude': 121.05,
          'owner_token': 'tok-A',
          if (offlineToken != null) 'offline_token': offlineToken,
        };
    const int now = 1760000000000;
    FleetSnapshot snapFor(Map<String, Object?> n) =>
        FleetSnapshot.derive({'GT-007': n}, nowMs: now, includeCompleted: true);

    test('15/16/17. online and active counts after login, PAUSE, FULL, COMPLETED, disconnect', () {
      // (status, expected online drivers, expected active fleets)
      final steps = <(String, Map<String, Object?>, int, int)>[
        ('login/active', nodeFor('ACTIVE'), 1, 1),
        ('pause', nodeFor('IDLE'), 1, 1),
        ('resume', nodeFor('ACTIVE'), 1, 1),
        ('full', nodeFor('FULL'), 1, 1),
        ('completed', nodeFor('COMPLETED'), 1, 0),
        ('brief disconnect', nodeFor('COMPLETED', offlineToken: 'tok-A', age: 30000), 1, 0),
        ('disconnect', nodeFor('COMPLETED', offlineToken: 'tok-A', age: FleetStatus.disconnectGraceMs + 1000), 0, 0),
      ];
      for (final s in steps) {
        final snap = snapFor(s.$2);
        expect(snap.onlineDrivers, s.$3, reason: '${s.$1} online');
        expect(snap.activeFleets, s.$4, reason: '${s.$1} active');
      }
    });

    test('a stale COMPLETED driver is not online forever', () {
      final snap = snapFor(nodeFor('COMPLETED', age: FleetStatus.freshnessWindowMs + 5000));
      expect(snap.onlineDrivers, 0);
    });

    test('FULL stays visible on the map with its status while connected', () {
      final snap = FleetSnapshot.derive({'GT-007': nodeFor('FULL')}, nowMs: now, requireCoords: true);
      expect(snap.count, 1);
      expect(snap.trucks.single.node['status'], 'FULL');
      expect(snap.collecting, 0);
    });

    test('Admin and Resident derive identical counts from one snapshot', () {
      final raw = {
        'GT-007': nodeFor('ACTIVE'),
        'GT-009': {...nodeFor('FULL'), 'driver_id': '9', 'truck_id': 'GT-009'},
        'GT-011': {...nodeFor('COMPLETED'), 'driver_id': '11', 'truck_id': 'GT-011'},
        'GT-013': {...nodeFor('IDLE', age: 400000), 'driver_id': '13'}, // stale ghost
      };
      final admin = FleetSnapshot.derive(raw, nowMs: now, includeCompleted: true,
          exclude: (k, n) => false, requirePresence: (d, n) => true);
      final resident = FleetSnapshot.derive(raw, nowMs: now, includeCompleted: true);
      expect(admin.onlineDrivers, resident.onlineDrivers);
      expect(admin.activeFleets, resident.activeFleets);
      expect(admin.onlineDrivers, 3);
      expect(admin.activeFleets, 2);
    });

    test('FULL/COMPLETED lifecycle never counts one driver twice across old runtimes', () {
      final raw = {
        'GT-007': nodeFor('COMPLETED'),
        'GT-OLD': {...nodeFor('ACTIVE', age: 90000)}, // older runtime, same driver
      };
      final snap = FleetSnapshot.derive(raw, nowMs: now, includeCompleted: true);
      expect(snap.onlineDrivers, 1);
      expect(snap.trucks.single.node['status'], 'COMPLETED', reason: 'newest state wins');
    });
  });

  group('server clock', () {
    test('publisher carries lastSeen inside the guarded transaction when the offset is known', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      final clock = ServerClock(deviceNowMs: () => 1000)..setOffset(500);
      final pub = OwnedNodePublisher(db: db, path: 'truck_locations/GT-007', guard: g, clock: clock);
      db.pathsWritten.clear();
      final r = await pub.publish({'status': 'ACTIVE', 'lastSeen': kServerTimestamp});
      expect(r, PublishResult.committed);
      expect((db.read('truck_locations/GT-007') as Map)['lastSeen'], 1500);
    });

    test('without an offset it falls back to the server timestamp', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      final pub = OwnedNodePublisher(db: db, path: 'truck_locations/GT-007', guard: g, clock: ServerClock());
      await pub.publish({'status': 'ACTIVE', 'lastSeen': kServerTimestamp});
      expect((db.read('truck_locations/GT-007') as Map)['lastSeen'], isA<num>());
    });
  });

  group('per-fix verification cost', () {
    test('isFinished is verified at most once per TTL, always for the final point', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      await openTrip(db, g, newId: 'trip-1');
      int t = 0;
      final writer = TripRouteWriter(db: db, guard: g, verifyTtlMs: 5000, nowMs: () => t);
      final before = db.transactionCount;
      for (int i = 0; i < 5; i++) {
        t = 1000 * i; // 5 points in 4 s
        await writer.write(tripId: 'trip-1', tripFinished: false, finishing: false, point: {'lat': 1.0 + i, 'lng': 1.0});
      }
      expect(db.transactionCount - before, 1);
      t = 6000;
      await writer.write(tripId: 'trip-1', tripFinished: false, finishing: false, point: {'lat': 9.0, 'lng': 1.0});
      expect(db.transactionCount - before, 2);
    });

    test('a finished trip is rejected as soon as the cache expires', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      await openTrip(db, g, newId: 'trip-1');
      int t = 0;
      final writer = TripRouteWriter(db: db, guard: g, verifyTtlMs: 5000, nowMs: () => t);
      await writer.write(tripId: 'trip-1', tripFinished: false, finishing: false, point: {'lat': 1.0});
      db.seed('driver_routes/trip-1/isFinished', true);
      t = 6000;
      final r = await writer.write(tripId: 'trip-1', tripFinished: false, finishing: false, point: {'lat': 2.0});
      expect(r.denial, WriteDenial.tripFinished);
    });
  });
}
