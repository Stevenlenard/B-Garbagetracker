import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/driver_lifecycle.dart';
import 'package:garbage_tracking_app/services/driver_session_guard.dart';
import 'package:garbage_tracking_app/services/rtdb_port.dart';
import 'package:garbage_tracking_app/utils/fleet_status.dart';

import 'support/fake_rtdb.dart';

const String kDriver = '7';
const String kTruck = 'GT-007';
const String kTruckPath = 'truck_locations/GT-007';

DriverSessionGuard runtime(FakeRtdb db, String label, {String? token}) =>
    DriverSessionGuard(db: db, driverId: kDriver, runtimeLabel: label, token: token ?? 'tok-$label');

OwnedNodePublisher truckPub(FakeRtdb db, DriverSessionGuard g) =>
    OwnedNodePublisher(db: db, path: kTruckPath, guard: g);

Map<String, Object?> fix(double lat, {String status = 'ACTIVE', String? session}) => <String, Object?>{
      'latitude': lat,
      'longitude': 121.0,
      'status': status,
      'isOnline': true,
      if (session != null) 'current_session': session,
      'lastSeen': kServerTimestamp,
    };

void main() {
  group('Two simultaneous runtimes for the same driver', () {
    test('the newest runtime owns the session; the older one loses authority', () async {
      final db = FakeRtdb();
      final a = runtime(db, 'A');
      final b = runtime(db, 'B');

      expect(await a.claim(truckId: kTruck), isTrue);
      expect(a.canWrite, isTrue);
      expect(await b.claim(truckId: kTruck), isTrue);

      expect(b.canWrite, isTrue);
      expect(a.canWrite, isFalse, reason: 'listener revokes the displaced runtime');
      expect(a.state, OwnershipState.lost);
      final record = SessionRecord.fromValue(db.read('driver_sessions/$kDriver'));
      expect(record!.token, 'tok-B');
      expect(record.epoch, 2, reason: 'epoch increases on every takeover');
    });

    test('claims serialise: both end up consistent with exactly one owner', () async {
      final db = FakeRtdb();
      final a = runtime(db, 'A');
      final b = runtime(db, 'B');
      await Future.wait([a.claim(truckId: kTruck), b.claim(truckId: kTruck)]);
      expect([a.canWrite, b.canWrite].where((x) => x).length, 1);
      final owner = SessionRecord.fromValue(db.read('driver_sessions/$kDriver'))!.token;
      expect(owner, a.canWrite ? 'tok-A' : 'tok-B');
    });

    test('a replaced runtime cannot publish; the owner can', () async {
      final db = FakeRtdb();
      final a = runtime(db, 'A');
      final b = runtime(db, 'B');
      await a.claim(truckId: kTruck);
      await b.claim(truckId: kTruck);

      final r = await truckPub(db, b).publish(fix(14.0, session: 'tripB'));
      expect(r, PublishResult.committed);
      final blocked = await truckPub(db, a).publish(fix(99.0, session: 'tripA'));
      expect(blocked, PublishResult.notOwner);

      final node = db.read(kTruckPath) as Map;
      expect(node['latitude'], 14.0);
      expect(node['current_session'], 'tripB');
      expect(node['owner_token'], 'tok-B');
    });
  });

  group('Old runtime publishing after ownership changed (listener lagging)', () {
    test('the server-side transaction rejects it even though its local state is stale', () async {
      final db = FakeRtdb();
      final a = runtime(db, 'A');
      final b = runtime(db, 'B');
      await a.claim(truckId: kTruck);
      final pubA = truckPub(db, a);
      await pubA.publish(fix(14.0, session: 'tripA'));

      db.deliverEvents = false; // A has not been told yet
      await b.claim(truckId: kTruck);
      await truckPub(db, b).publish(fix(15.0, session: 'tripB'));
      expect(a.canWrite, isTrue, reason: 'A still believes it owns the session');

      final r = await pubA.publish(fix(99.0, session: 'tripA'));
      expect(r, PublishResult.replaced);

      final node = db.read(kTruckPath) as Map;
      expect(node['latitude'], 15.0, reason: 'newer owner data is untouched');
      expect(node['current_session'], 'tripB');
      expect(a.canWrite, isFalse, reason: 'the failed write revalidated and revoked authority');
    });

    test('reconnecting never reclaims ownership from a newer runtime', () async {
      final db = FakeRtdb();
      final a = runtime(db, 'A');
      final b = runtime(db, 'B');
      await a.claim(truckId: kTruck);
      await b.claim(truckId: kTruck);

      expect(await a.validate(), isFalse);
      expect(a.state, OwnershipState.lost);
      expect(SessionRecord.fromValue(db.read('driver_sessions/$kDriver'))!.token, 'tok-B');
    });

    test('a replaced runtime cannot bind a trip or release the newer owner\'s record', () async {
      final db = FakeRtdb();
      final a = runtime(db, 'A');
      final b = runtime(db, 'B');
      await a.claim(truckId: kTruck);
      await b.claim(truckId: kTruck);

      expect(await a.bindTrip('tripA'), isFalse);
      await a.release();
      final record = SessionRecord.fromValue(db.read('driver_sessions/$kDriver'));
      expect(record, isNotNull, reason: 'logout of the old runtime must not erase the new owner');
      expect(record!.token, 'tok-B');
    });
  });

  group('Logout / relogin keeps the epoch monotonic', () {
    test('release keeps a tombstone with the epoch and drops the token', () async {
      final db = FakeRtdb();
      final a = runtime(db, 'A');
      await a.claim(truckId: kTruck);
      await a.release();
      final rec = db.read('driver_sessions/$kDriver') as Map;
      expect(rec['epoch'], 1);
      expect(rec.containsKey('token'), isFalse);
      expect(rec['released_at'], isNotNull);
    });

    test('a relogin after logout can still publish to a node stamped by the previous session', () async {
      final db = FakeRtdb();
      final first = runtime(db, 'A1');
      await first.claim(truckId: kTruck);
      await truckPub(db, first).publish(fix(10.0, session: 't1'));
      await first.release();

      final second = runtime(db, 'A2');
      expect(await second.claim(truckId: kTruck), isTrue);
      expect(second.epoch, 2, reason: 'epoch continues after the tombstone, it does not restart');
      expect(await truckPub(db, second).publish(fix(11.0, session: 't2')), PublishResult.committed);
      expect((db.read(kTruckPath) as Map)['latitude'], 11.0);
    });
  });

  group('Completed trips never receive GPS points', () {
    test('DONE seals the trip; later points and metadata are refused', () async {
      final db = FakeRtdb();
      final g = runtime(db, 'A');
      await g.claim(truckId: kTruck);
      await g.bindTrip('trip1');
      final writer = TripRouteWriter(db: db, guard: g);

      final ok = await writer.write(
        tripId: 'trip1', tripFinished: false, finishing: false,
        point: <String, Object?>{'lat': 14.0}, meta: <String, Object?>{'total_distance': 1.0},
      );
      expect(ok.written, isTrue);
      expect(db.childCount('driver_routes/trip1/route'), 1);

      final fin = await TripFinalizer.finish(
        db: db, guard: g, tripId: 'trip1', fields: <String, Object?>{'route_status': 'COMPLETED'},
      );
      expect(fin, FinishResult.finished);
      expect((db.read('driver_routes/trip1') as Map)['isFinished'], true);

      final late = await writer.write(
        tripId: 'trip1', tripFinished: false /* local flag is stale */, finishing: false,
        point: <String, Object?>{'lat': 99.0},
      );
      expect(late.written, isFalse);
      expect(db.childCount('driver_routes/trip1/route'), 1, reason: 'no point after DONE');
    });

    test('the server-side isFinished check stops a runtime whose local state is stale', () async {
      final db = FakeRtdb();
      final g = runtime(db, 'A');
      await g.claim(truckId: kTruck);
      await g.bindTrip('trip1');
      // Another session finished the trip behind this runtime's back.
      db.seed('driver_routes/trip1', <String, Object?>{'isFinished': true, 'route_status': 'COMPLETED'});

      final res = await TripRouteWriter(db: db, guard: g).write(
        tripId: 'trip1', tripFinished: false, finishing: false, point: <String, Object?>{'lat': 1.0},
      );
      expect(res.denial, WriteDenial.tripFinished);
      expect(db.childCount('driver_routes/trip1/route'), 0);
    });

    test('finishing twice is idempotent (second call reports already finished)', () async {
      final db = FakeRtdb();
      final g = runtime(db, 'A');
      await g.claim(truckId: kTruck);
      await g.bindTrip('trip1');
      expect(await TripFinalizer.finish(db: db, guard: g, tripId: 'trip1', fields: {}), FinishResult.finished);
      await g.bindTrip('trip1'); // even if something re-bound it
      expect(await TripFinalizer.finish(db: db, guard: g, tripId: 'trip1', fields: {}), FinishResult.alreadyFinished);
    });

    test('DONE revokes this runtime\'s authority for the trip', () async {
      final db = FakeRtdb();
      final g = runtime(db, 'A');
      await g.claim(truckId: kTruck);
      await g.bindTrip('trip1');
      await TripFinalizer.finish(db: db, guard: g, tripId: 'trip1', fields: {});
      expect(g.tripId, isNull);
      expect(g.canWrite, isTrue, reason: 'still the session owner (online), but holds no trip');
      final d = TripWriteGate.decide(
        ownership: g.state, localTripId: 'trip1', boundTripId: g.tripId, tripFinished: false, finishing: false,
      );
      expect(d.allowed, isFalse);
      expect(d.denial, WriteDenial.tripMismatch);
    });
  });

  group('START after DONE', () {
    test('a new trip is bound and writable; the completed trip stays immutable', () async {
      final db = FakeRtdb();
      final g = runtime(db, 'A');
      await g.claim(truckId: kTruck);
      await g.bindTrip('trip1');
      await TripRouteWriter(db: db, guard: g).write(
        tripId: 'trip1', tripFinished: false, finishing: false, point: <String, Object?>{'n': 1},
      );
      await TripFinalizer.finish(db: db, guard: g, tripId: 'trip1', fields: <String, Object?>{'route_status': 'COMPLETED'});

      expect(await g.bindTrip('trip2'), isTrue);
      final w = TripRouteWriter(db: db, guard: g);
      expect((await w.write(tripId: 'trip2', tripFinished: false, finishing: false, point: <String, Object?>{'n': 1})).written, isTrue);
      expect((await w.write(tripId: 'trip1', tripFinished: false, finishing: false, point: <String, Object?>{'n': 2})).written, isFalse);
      expect(db.childCount('driver_routes/trip1/route'), 1);
      expect(db.childCount('driver_routes/trip2/route'), 1);
      expect((db.read('driver_routes/trip1') as Map)['route_status'], 'COMPLETED');
    });
  });

  group('Reconnect policy', () {
    test('FULL stays FULL after reconnecting', () {
      final d = ReconnectPolicy.onReconnect(ownership: OwnershipState.owner, status: 'FULL', hasTrip: true);
      expect(d.action, ReconnectAction.assertPresence);
      expect(d.statusToPublish, 'FULL');
    });

    test('IDLE (paused) stays IDLE and ACTIVE stays ACTIVE', () {
      expect(ReconnectPolicy.onReconnect(ownership: OwnershipState.owner, status: 'IDLE', hasTrip: true).statusToPublish, 'IDLE');
      expect(ReconnectPolicy.onReconnect(ownership: OwnershipState.owner, status: 'ACTIVE', hasTrip: true).statusToPublish, 'ACTIVE');
    });

    test('COMPLETED is never re-asserted on reconnect', () {
      for (final s in ['COMPLETED', 'FINISHED']) {
        final d = ReconnectPolicy.onReconnect(ownership: OwnershipState.owner, status: s, hasTrip: false);
        expect(d.action, ReconnectAction.ignore);
      }
    });

    test('a runtime that lost ownership does nothing on reconnect', () {
      for (final o in [OwnershipState.lost, OwnershipState.unclaimed]) {
        final d = ReconnectPolicy.onReconnect(ownership: o, status: 'ACTIVE', hasTrip: true);
        expect(d.action, ReconnectAction.ignore);
      }
    });

    test('FULL survives a reconnect end-to-end through the publisher', () async {
      final db = FakeRtdb();
      final g = runtime(db, 'A');
      await g.claim(truckId: kTruck);
      final pub = truckPub(db, g);
      await pub.publish(fix(14.0, status: 'FULL', session: 'trip1'));

      final d = ReconnectPolicy.onReconnect(ownership: g.state, status: 'FULL', hasTrip: true);
      await pub.publish(<String, Object?>{'isOnline': true, 'status': d.statusToPublish, 'offline_token': null});
      expect((db.read(kTruckPath) as Map)['status'], 'FULL');
    });
  });

  group('Restoring an unfinished trip', () {
    Map<String, Object?> trip({String status = 'ACTIVE', Object? finished, Object? driver = 7, Object? sim, Object? start = 100}) =>
        <String, Object?>{
          'route_status': status,
          if (finished != null) 'isFinished': finished,
          'driver_id': driver,
          if (sim != null) 'is_simulation': sim,
          'server_start_time': start,
        };

    test('only this driver\'s ACTIVE, unfinished, non-simulation trip is resumable', () {
      expect(TripResumePolicy.isResumable(trip(), driverId: '7', nowMs: 1000), isTrue);
      expect(TripResumePolicy.isResumable(trip(status: 'COMPLETED'), driverId: '7', nowMs: 1000), isFalse);
      expect(TripResumePolicy.isResumable(trip(finished: true), driverId: '7', nowMs: 1000), isFalse);
      expect(TripResumePolicy.isResumable(trip(driver: 8), driverId: '7', nowMs: 1000), isFalse);
      expect(TripResumePolicy.isResumable(trip(sim: true), driverId: '7', nowMs: 1000), isFalse);
      expect(TripResumePolicy.isResumable(null, driverId: '7', nowMs: 1000), isFalse);
    });

    test('a finished trip with ACTIVE status text is still refused (isFinished wins)', () {
      expect(TripResumePolicy.isResumable(trip(status: 'ACTIVE', finished: true), driverId: '7', nowMs: 1000), isFalse);
    });

    test('the newest resumable trip is chosen', () {
      final id = TripResumePolicy.pickNewest(<String, Object?>{
        'old': trip(start: 100),
        'new': trip(start: 300),
        'done': trip(status: 'COMPLETED', start: 900),
        'other': trip(driver: 9, start: 800),
      }, driverId: '7', nowMs: 1000);
      expect(id, 'new');
    });

    test('resuming keeps the trip identity while the runtime changes', () async {
      final db = FakeRtdb();
      db.seed('driver_routes/tripX', <String, Object?>{
        'route_status': 'ACTIVE', 'driver_id': 7, 'total_distance': 2.5, 'owner_token': 'tok-OLD',
      });
      final fresh = runtime(db, 'NEW');
      await fresh.claim(truckId: kTruck);
      expect(TripResumePolicy.isResumable(db.read('driver_routes/tripX'), driverId: '7'), isTrue);
      expect(await fresh.bindTrip('tripX'), isTrue);
      expect(fresh.tripId, 'tripX');
      // The old runtime's token is not the session owner, so it cannot write the trip.
      final stale = runtime(db, 'OLD', token: 'tok-OLD');
      expect(TripWriteGate.decide(
        ownership: stale.state, localTripId: 'tripX', boundTripId: 'tripX', tripFinished: false, finishing: false,
      ).denial, WriteDenial.notOwner);
    });
  });

  group('Obsolete disconnect handlers', () {
    test('a replaced runtime\'s late disconnect does not mark the new session offline', () {
      final Map<String, Object?> node = <String, Object?>{
        'isOnline': true,
        'owner_token': 'tok-B',
        'offline_token': 'tok-A', // written late by A's disconnect handler
      };
      expect(FleetStatus.hasOnlineFlag(node), isTrue);
    });

    test('the current owner\'s own disconnect does mark it offline', () {
      final Map<String, Object?> node = <String, Object?>{
        'isOnline': true,
        'owner_token': 'tok-B',
        'offline_token': 'tok-B',
      };
      expect(FleetStatus.hasOnlineFlag(node), isFalse);
    });

    test('reconnect clears the marker and the node is online again', () async {
      final db = FakeRtdb();
      final g = runtime(db, 'B');
      await g.claim(truckId: kTruck);
      final pub = truckPub(db, g);
      await pub.publish(fix(14.0));
      await db.update(kTruckPath, <String, Object?>{'offline_token': g.token}); // handler fired
      expect(FleetStatus.hasOnlineFlag(db.read(kTruckPath) as Map), isFalse);
      await pub.publish(<String, Object?>{'isOnline': true, 'offline_token': null});
      expect(FleetStatus.hasOnlineFlag(db.read(kTruckPath) as Map), isTrue);
    });

    test('an old connection\'s handler firing AFTER the reconnect is healed by the next heartbeat', () async {
      final db = FakeRtdb();
      final g = runtime(db, 'B');
      await g.claim(truckId: kTruck);
      final pub = truckPub(db, g);
      await pub.publish(fix(14.0));
      // Back from the background: reconnect clears the marker first ...
      await pub.publish(<String, Object?>{'isOnline': true, 'offline_token': null});
      // ... then the server notices the dead socket and runs the old handler (same runtime token).
      await db.update(kTruckPath, <String, Object?>{'offline_token': g.token});
      expect(FleetStatus.hasOnlineFlag(db.read(kTruckPath) as Map), isFalse);
      await pub.publish(PresenceBeat.fields(status: 'ACTIVE', loginTime: 1));
      final Map node = db.read(kTruckPath) as Map;
      expect(FleetStatus.hasOnlineFlag(node), isTrue);
      expect(node['status'], 'ACTIVE');
      expect(node['login_time'], 1);
    });

    test('the heartbeat never revives a node for a replaced runtime', () async {
      final db = FakeRtdb();
      final a = runtime(db, 'A');
      await a.claim(truckId: kTruck);
      final b = runtime(db, 'B');
      await b.claim(truckId: kTruck);
      await truckPub(db, b).publish(fix(14.0));
      await db.update(kTruckPath, <String, Object?>{'offline_token': b.token}); // B disconnected
      await truckPub(db, a).publish(PresenceBeat.fields(status: 'ACTIVE'));
      expect(FleetStatus.hasOnlineFlag(db.read(kTruckPath) as Map), isFalse);
    });
  });

  group('Marker and route consistency', () {
    test('position, status and current_session are committed in one write', () async {
      final db = FakeRtdb();
      final g = runtime(db, 'A');
      await g.claim(truckId: kTruck);
      await truckPub(db, g).publish(fix(14.5, status: 'ACTIVE', session: 'tripA'));
      final node = db.read(kTruckPath) as Map;
      expect(node['latitude'], 14.5);
      expect(node['current_session'], 'tripA');
      expect(node['owner_token'], g.token);
      expect(db.pathsWritten.where((p) => p == kTruckPath).length, greaterThanOrEqualTo(1));
    });

    test('after a takeover the marker and session come from the same (new) runtime', () async {
      final db = FakeRtdb();
      final a = runtime(db, 'A');
      final b = runtime(db, 'B');
      await a.claim(truckId: kTruck);
      await truckPub(db, a).publish(fix(10.0, session: 'tripA'));
      await b.claim(truckId: kTruck);
      await truckPub(db, b).publish(fix(20.0, session: 'tripB'));
      await truckPub(db, a).publish(fix(11.0, session: 'tripA')); // refused

      final node = db.read(kTruckPath) as Map;
      expect(node['latitude'], 20.0);
      expect(node['current_session'], 'tripB');
      expect(node['owner_token'], 'tok-B');
    });

    test('older APK writes (no epoch) never block a new owner', () async {
      final db = FakeRtdb();
      db.seed(kTruckPath, <String, Object?>{'latitude': 1.0, 'longitude': 2.0, 'status': 'ACTIVE', 'isOnline': true});
      final g = runtime(db, 'A');
      await g.claim(truckId: kTruck);
      expect(await truckPub(db, g).publish(fix(14.0, session: 'tripA')), PublishResult.committed);
      expect((db.read(kTruckPath) as Map)['owner_token'], g.token);
    });
  });

  group('Publisher semantics', () {
    test('rapid publishes are coalesced; the newest value per key wins', () async {
      final db = FakeRtdb();
      final g = runtime(db, 'A');
      await g.claim(truckId: kTruck);
      final pub = truckPub(db, g);
      final before = db.transactionCount;
      final results = await Future.wait([
        pub.publish(<String, Object?>{'latitude': 1.0, 'status': 'ACTIVE'}),
        pub.publish(<String, Object?>{'latitude': 2.0}),
        pub.publish(<String, Object?>{'latitude': 3.0, 'status': 'FULL'}),
      ]);
      expect(results.every((r) => r == PublishResult.committed), isTrue);
      final node = db.read(kTruckPath) as Map;
      expect(node['latitude'], 3.0);
      expect(node['status'], 'FULL');
      expect(db.transactionCount - before, lessThan(3));
    });

    test('a null value removes the field and the write sequence increases', () async {
      final db = FakeRtdb();
      final g = runtime(db, 'A');
      await g.claim(truckId: kTruck);
      final pub = truckPub(db, g);
      await pub.publish(<String, Object?>{'latitude': 1.0, 'current_session': 'tripA'});
      final s1 = (db.read(kTruckPath) as Map)['wseq'] as int;
      await pub.publish(<String, Object?>{'current_session': null});
      final node = db.read(kTruckPath) as Map;
      expect(node.containsKey('current_session'), isFalse);
      expect(node['wseq'], s1 + 1);
    });

    test('server timestamps resolve to a server value, not a literal map', () async {
      final db = FakeRtdb();
      final g = runtime(db, 'A');
      await g.claim(truckId: kTruck);
      await truckPub(db, g).publish(<String, Object?>{'lastSeen': kServerTimestamp, 'isOnline': true});
      expect((db.read(kTruckPath) as Map)['lastSeen'], isA<int>());
    });

    test('nothing is published before the session is claimed', () async {
      final db = FakeRtdb();
      final g = runtime(db, 'A'); // never claimed
      expect(await truckPub(db, g).publish(fix(1.0)), PublishResult.notOwner);
      expect(db.read(kTruckPath), isNull);
    });
  });

  group('Driver / truck deduplication', () {
    Map<String, Object?> live(String id, int seen, {String name = 'Test Driver'}) =>
        <String, Object?>{'driver_id': id, 'driver_name': name, 'lastSeen': seen, 'isOnline': true, 'status': 'ACTIVE'};

    test('two nodes for one driver count once, keeping the newest', () {
      final result = FleetStatus.latestPerKey([
        MapEntry(FleetStatus.driverKey(live('7', 100)), live('7', 100)..['truck_id'] = 'GT-007'),
        MapEntry(FleetStatus.driverKey(live('7', 500)), live('7', 500)..['truck_id'] = 'UNKNOWN'),
      ]);
      expect(result.length, 1);
      expect(result['7']!['truck_id'], 'UNKNOWN', reason: 'newest lastSeen wins');
    });

    test('different drivers are counted separately', () {
      final result = FleetStatus.latestPerKey([
        MapEntry(FleetStatus.driverKey(live('7', 1)), live('7', 1)),
        MapEntry(FleetStatus.driverKey(live('8', 1)), live('8', 1)),
      ]);
      expect(result.length, 2);
    });

    test('a node without driver id falls back to the upper-cased name', () {
      expect(FleetStatus.driverKey(<String, Object?>{'driver_name': ' juan '}), 'JUAN');
      expect(FleetStatus.driverKey(<String, Object?>{'driver_id': 'null', 'driver_name': 'a'}), 'A');
    });
  });

  group('TripWriteGate', () {
    WriteDecision d({
      OwnershipState o = OwnershipState.owner,
      String? local = 't1',
      String? bound = 't1',
      bool finished = false,
      bool finishing = false,
    }) =>
        TripWriteGate.decide(ownership: o, localTripId: local, boundTripId: bound, tripFinished: finished, finishing: finishing);

    test('allows only an owner with a bound, open trip', () {
      expect(d().allowed, isTrue);
      expect(d(o: OwnershipState.lost).denial, WriteDenial.notOwner);
      expect(d(o: OwnershipState.unclaimed).denial, WriteDenial.notOwner);
      expect(d(local: null).denial, WriteDenial.noTrip);
      expect(d(bound: 't2').denial, WriteDenial.tripMismatch);
      expect(d(finished: true).denial, WriteDenial.tripFinished);
      expect(d(finishing: true).denial, WriteDenial.finishing);
    });
  });
}
