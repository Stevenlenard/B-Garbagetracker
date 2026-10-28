import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/driver_lifecycle.dart';
import 'package:garbage_tracking_app/services/driver_session_guard.dart';
import 'package:garbage_tracking_app/services/offline_point_queue.dart';
import 'support/fake_rtdb.dart';

/// Phone storage stand-in: the queue is rebuilt from [value] the way it is after an app restart.
class MemoryStore {
  String? value;
  OfflinePointQueue queue({int Function()? nowMs}) =>
      OfflinePointQueue(load: () async => value, save: (String v) async => value = v, nowMs: nowMs);
}

QueuedPoint point(String key, {String trip = 'trip1', int at = 1000}) => QueuedPoint(
      key: key,
      root: 'driver_routes',
      tripId: trip,
      point: <String, Object?>{'lat': 14.0, 'lng': 121.0, 'timestamp': at},
      queuedAtMs: at,
    );

void main() {
  group('OfflinePointQueue', () {
    test('points survive an app restart until they are removed', () async {
      final MemoryStore store = MemoryStore();
      final OfflinePointQueue q = store.queue(nowMs: () => 2000);
      await q.add(point('a', at: 1000));
      await q.add(point('b', at: 1500));
      await q.remove('a');

      final OfflinePointQueue restarted = store.queue(nowMs: () => 2000);
      final List<QueuedPoint> left = await restarted.pendingFor('trip1');
      expect(left.map((QueuedPoint p) => p.key), <String>['b']);
      expect(left.single.point['lat'], 14.0);
    });

    test('only the points of the requested trip are returned, oldest first', () async {
      final OfflinePointQueue q = MemoryStore().queue(nowMs: () => 5000);
      await q.add(point('late', at: 3000));
      await q.add(point('other', trip: 'trip2', at: 1000));
      await q.add(point('early', at: 2000));
      expect((await q.pendingFor('trip1')).map((QueuedPoint p) => p.key), <String>['early', 'late']);
    });

    test('adding the same key twice keeps one point', () async {
      final OfflinePointQueue q = MemoryStore().queue(nowMs: () => 2000);
      await q.add(point('a'));
      await q.add(point('a'));
      expect(await q.length, 1);
    });

    test('points older than 24 hours are dropped', () async {
      final MemoryStore store = MemoryStore();
      await store.queue(nowMs: () => 1000).add(point('old', at: 1000));
      final int dayLater = 1000 + OfflinePointQueue.maxAge.inMilliseconds + 1;
      expect(await store.queue(nowMs: () => dayLater).pendingFor('trip1'), isEmpty);
    });

    test('concurrent adds are all kept', () async {
      final MemoryStore store = MemoryStore();
      final OfflinePointQueue q = store.queue(nowMs: () => 2000);
      await Future.wait(<Future<void>>[for (int i = 0; i < 20; i++) q.add(point('k$i', at: 1000 + i))]);
      expect(await store.queue(nowMs: () => 2000).length, 20);
    });

    test('unreadable storage starts an empty queue', () async {
      final MemoryStore store = MemoryStore()..value = 'not json';
      expect(await store.queue().length, 0);
    });
  });

  group('TripRouteWriter with a fixed point key', () {
    test('resending a stored point replaces it instead of adding a duplicate', () async {
      final FakeRtdb db = FakeRtdb();
      final DriverSessionGuard g = DriverSessionGuard(db: db, driverId: '7', runtimeLabel: 'A', token: 'tok-A');
      await g.claim(truckId: 'GT-007');
      await g.bindTrip('trip1');
      final TripRouteWriter w = TripRouteWriter(db: db, guard: g, verifyTtlMs: 0);

      for (int i = 0; i < 2; i++) {
        final TripWriteResult r = await w.write(
          tripId: 'trip1', tripFinished: false, finishing: false,
          point: <String, Object?>{'lat': 14.0}, pointKey: '-Nkey1',
        );
        expect(r.written, isTrue);
      }
      expect(db.childCount('driver_routes/trip1/route'), 1);
      expect((db.read('driver_routes/trip1/route/-Nkey1') as Map)['lat'], 14.0);
    });
  });
}
