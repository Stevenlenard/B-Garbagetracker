import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/models/driver_trip.dart';
import 'package:garbage_tracking_app/services/driver_lifecycle.dart';
import 'package:garbage_tracking_app/services/driver_session_guard.dart';
import 'package:garbage_tracking_app/services/rtdb_port.dart';
import 'package:garbage_tracking_app/utils/load_history.dart';

import 'support/fake_rtdb.dart';

const int kNow = 5000; // the fake database's server clock is a small counter

DriverSessionGuard guardFor(FakeRtdb db, String driver, String label) =>
    DriverSessionGuard(db: db, driverId: driver, runtimeLabel: label, token: 'tok-$label');

Future<String> startTrip(FakeRtdb db, DriverSessionGuard g,
    {String driver = '7', String truck = 'GT-007', String id = 'trip-1', String? pending}) async {
  final TripOpenResult r = await TripOpener.open(
    db: db,
    guard: g,
    driverId: driver,
    truckId: truck,
    driverName: 'Driver $driver',
    newTripId: id,
    pendingTripId: pending,
    startLat: 13.75,
    startLng: 121.05,
    startTimeLabel: '8:00 AM',
    nowMs: kNow,
  );
  expect(r.ok, isTrue);
  return r.tripId!;
}

/// Appends collection GPS points through the guarded route writer.
Future<void> addPoints(FakeRtdb db, DriverSessionGuard g, String tripId, int n, {double startLat = 13.75}) async {
  final writer = TripRouteWriter(db: db, guard: g, verifyTtlMs: 0);
  for (int i = 0; i < n; i++) {
    final res = await writer.write(
      tripId: tripId,
      tripFinished: false,
      finishing: false,
      point: <String, Object?>{
        'lat': startLat + i * 0.0005,
        'lng': 121.05,
        'latitude': startLat + i * 0.0005,
        'longitude': 121.05,
        'timestamp': 1000 + i * 1000,
        'accuracy': 5.0,
        'tripId': tripId,
      },
    );
    expect(res.denial, isNull);
  }
}

Map<String, Object?> frozen({double km = 0.5, int start = 1000, int end = 9000, String via = 'FULL'}) =>
    CollectionRecord.build(
      startMs: start,
      nowMs: end,
      distanceKm: km,
      weightKg: 5000,
      weightType: 'ESTIMATED',
      via: via,
      endLat: 13.76,
      endLng: 121.05,
    );

/// What the Route History screen builds from Firebase.
DriverTrip routeHistoryView(FakeRtdb db, String tripId) {
  final Map raw = Map<String, dynamic>.from(db.read('driver_routes/$tripId') as Map);
  final List<GpsPoint> pts = <GpsPoint>[];
  final Object? route = raw['route'];
  if (route is Map) {
    route.forEach((_, v) => pts.add(GpsPoint.fromJson(Map<String, dynamic>.from(v as Map))));
    pts.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }
  final Map<String, dynamic> json = Map<String, dynamic>.from(raw)..['trip_id'] = tripId;
  return DriverTrip.fromJson(json, pointsList: pts);
}

/// What get_load_history.php returns for the same trip (MySQL row).
DriverTrip loadHistoryView(String tripId, {String status = 'FULL', double km = 0.5, String driver = '7', String truck = 'GT-007'}) =>
    DriverTrip.fromJson(<String, dynamic>{
      'trip_id': tripId,
      'driver_id': driver,
      'driver_name': 'Driver $driver',
      'truck_id': truck,
      'route_status': status,
      'full_time': '9:00 AM', // display string, as PHP returns it
      'raw_full_time': '2026-10-12 09:00:00',
      'start_time': '2026-10-12 08:00:00',
      'total_distance_km': km,
      'weight_kg': 5000.0,
      'weight_type': 'ESTIMATED',
      'has_full_event': true,
    });

void main() {
  group('One trip id across Route History, Load History and the summary', () {
    test('LOGIN creates one trip; reconnect resumes the SAME id', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      final id = await startTrip(db, g, id: 'trip-1');
      final g2 = guardFor(db, '7', 'B');
      await g2.claim(truckId: 'GT-007');
      final again = await startTrip(db, g2, id: 'would-be-new', pending: id);
      expect(again, id);
      expect((db.read('driver_routes') as Map).length, 1);
    });

    test('FULL finalizes one collection; the trip id is the same everywhere', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      final id = await startTrip(db, g);
      await addPoints(db, g, id, 6);
      final r = await CollectionFinalizer.finalize(db: db, guard: g, tripId: id, record: frozen());
      expect(r, CollectionFinalResult.finalized);

      final DriverTrip route = routeHistoryView(db, id);
      final DriverTrip load = loadHistoryView(id);
      expect(route.tripId, id);
      expect(load.tripId, id);
      expect(route.driverId.toString(), '7');
      expect(route.truckId, 'GT-007');

      final loads = LoadHistory.uniqueLoads([route, load]);
      expect(loads.length, 1, reason: 'both views describe ONE finalized collection');
      expect(loads.single.tripId, id);
    });

    test('repeated FULL does not create a second load record', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      final id = await startTrip(db, g);
      await addPoints(db, g, id, 4);
      await CollectionFinalizer.finalize(db: db, guard: g, tripId: id, record: frozen());
      final second = await CollectionFinalizer.finalize(db: db, guard: g, tripId: id, record: frozen(km: 9));
      final third = await CollectionFinalizer.finalize(db: db, guard: g, tripId: id, record: frozen(km: 12));
      expect(second, CollectionFinalResult.alreadyFinalized);
      expect(third, CollectionFinalResult.alreadyFinalized);
      final DriverTrip t = routeHistoryView(db, id);
      expect(LoadHistory.uniqueLoads([t, t, t]).length, 1);
      expect(t.totalDistanceKm, 0.5, reason: 'the frozen distance, not a retry value');
    });

    test('COMPLETED updates the same record: no second trip or load, duration not extended', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      final id = await startTrip(db, g);
      await addPoints(db, g, id, 5);
      await CollectionFinalizer.finalize(db: db, guard: g, tripId: id, record: frozen(start: 1000, end: 61000));
      final DriverTrip atFull = routeHistoryView(db, id);

      await TripFinalizer.finish(
        db: db,
        guard: g,
        tripId: id,
        fields: <String, Object?>{
          ...CollectionRecord.completionFields(nowMs: 7200000, endTimeLabel: '11:00 AM', postFullDistanceKm: 14.2),
          'finishTime': 7200000,
        },
      );
      final DriverTrip afterDone = routeHistoryView(db, id);

      expect((db.read('driver_routes') as Map).length, 1);
      expect(afterDone.routeStatus, 'COMPLETED');
      expect(afterDone.totalDistanceKm, atFull.totalDistanceKm);
      expect(afterDone.collectionSeconds, 60, reason: 'LOGIN -> FULL (60 s), not LOGIN -> unloading');
      expect(afterDone.collectionSeconds, atFull.collectionSeconds);
      expect(LoadHistory.uniqueLoads([atFull, afterDone]).length, 1);
    });

    test('post-FULL points never extend the finalized collection', () async {
      final db = FakeRtdb();
      final g = guardFor(db, '7', 'A');
      await g.claim(truckId: 'GT-007');
      final id = await startTrip(db, g);
      await addPoints(db, g, id, 4);
      await CollectionFinalizer.finalize(db: db, guard: g, tripId: id, record: frozen(km: 0.5));
      // An old runtime keeps appending points after FULL.
      await addPoints(db, g, id, 40, startLat: 13.9);
      final DriverTrip t = routeHistoryView(db, id);
      expect(t.points.length, greaterThan(40));
      expect(t.totalDistanceKm, 0.5, reason: 'the frozen record wins over late points');
    });
  });

  group('Waste Collection Summary uses the same loads', () {
    test('unfinished trips with movement are not loads', () {
      final active = DriverTrip.fromJson({
        'trip_id': 'abandoned-1',
        'driver_id': 7,
        'route_status': 'ACTIVE',
        'total_distance_km': 12.0,
        'start_time': '2026-10-01 08:00:00',
      });
      expect(LoadHistory.isLoad(active), isFalse);
      expect(LoadHistory.uniqueLoads([active]), isEmpty);
    });

    test('each trip is counted once across sources; totals and chart agree', () {
      final a1 = loadHistoryView('a');
      final a2 = loadHistoryView('a'); // same trip from another source
      final b = loadHistoryView('b', km: 2.0);
      final c = loadHistoryView('c', status: 'COMPLETED', km: 3.0);
      final loads = LoadHistory.uniqueLoads([a1, a2, b, c]);
      expect(loads.length, 3);

      final totals = LoadHistory.totals(loads);
      expect(totals.trips, 3);
      expect(totals.weightKg, 15000);
      expect(totals.tonsLabel, '15 tons');
      expect(totals.isEstimate, isTrue);

      final months = LoadHistory.monthly(loads, 2026);
      final october = months[9];
      expect(october['trip_count'], 3);
      expect(october['total_weight_tons'], 15.0);
      expect(months.where((m) => m['has_data'] == true).length, 1);
      // the chart total equals the summary total
      final double chartKg = months.fold<double>(0, (s, m) => s + (m['total_weight_kg'] as double));
      expect(chartKg, totals.weightKg);
    });

    test('a measured weight replaces the estimate for that trip only', () {
      final est = loadHistoryView('a');
      final other = loadHistoryView('b');
      final measuredStub = DriverTrip.fromJson({
        'trip_id': 'a',
        'weight_kg': 4200.0,
        'weight_type': 'MEASURED',
      });
      final loads = LoadHistory.uniqueLoads([est, other, measuredStub]);
      final a = loads.firstWhere((t) => t.tripId == 'a');
      final b = loads.firstWhere((t) => t.tripId == 'b');
      expect(a.weightKg, 4200);
      expect(a.isMeasured, isTrue);
      expect(b.weightKg, 5000);
      final totals = LoadHistory.totals(loads);
      expect(totals.measuredCount, 1);
      expect(totals.estimatedCount, 1);
      expect(totals.isEstimate, isTrue, reason: 'any estimate keeps the total labelled as an estimate');
    });

    test('period bounds use the FULL time and are inclusive', () {
      final inDay = loadHistoryView('a');
      final loads = [inDay];
      expect(LoadHistory.inRange(loads, DateTime(2026, 10, 12), DateTime(2026, 10, 12)).length, 1);
      expect(LoadHistory.inRange(loads, DateTime(2026, 10, 13), DateTime(2026, 10, 20)).length, 0);
      expect(LoadHistory.inRange(loads, null, null).length, 1);
    });
  });

  group('Drivers and trucks stay separate', () {
    test('two drivers: separate trips, routes, loads and totals', () async {
      final db = FakeRtdb();
      final g7 = guardFor(db, '7', 'A');
      final g9 = guardFor(db, '9', 'B');
      await g7.claim(truckId: 'GT-007');
      await g9.claim(truckId: 'GT-009');
      final t7 = await startTrip(db, g7, driver: '7', truck: 'GT-007', id: 'trip-7');
      final t9 = await startTrip(db, g9, driver: '9', truck: 'GT-009', id: 'trip-9');
      await addPoints(db, g7, t7, 3, startLat: 13.70);
      await addPoints(db, g9, t9, 5, startLat: 14.10);
      await CollectionFinalizer.finalize(db: db, guard: g7, tripId: t7, record: frozen(km: 0.4));
      await CollectionFinalizer.finalize(db: db, guard: g9, tripId: t9, record: frozen(km: 0.9));

      final DriverTrip r7 = routeHistoryView(db, t7);
      final DriverTrip r9 = routeHistoryView(db, t9);
      expect(r7.points.length, 3);
      expect(r9.points.length, 5);
      expect(r7.points.every((p) => p.latitude < 14), isTrue, reason: 'no coordinates of driver 9 in driver 7 route');
      expect(r9.points.every((p) => p.latitude > 14), isTrue);
      expect(r7.driverId.toString(), '7');
      expect(r9.driverId.toString(), '9');
      expect(r7.truckId, 'GT-007');
      expect(r9.truckId, 'GT-009');

      final loads = LoadHistory.uniqueLoads([r7, r9]);
      expect(loads.map((t) => t.tripId).toSet(), {t7, t9});
      expect(LoadHistory.totals(loads).trips, 2);
    });

    test('a second runtime of the same driver cannot create a second authoritative trip', () async {
      final db = FakeRtdb();
      final a = guardFor(db, '7', 'A');
      await a.claim(truckId: 'GT-007');
      await startTrip(db, a, id: 'trip-A');
      final b = guardFor(db, '7', 'B');
      await b.claim(truckId: 'GT-007'); // displaces A
      final late = await TripOpener.open(
        db: db,
        guard: a,
        driverId: '7',
        truckId: 'GT-007',
        driverName: 'D',
        newTripId: 'trip-A2',
        startLat: 1,
        startLng: 1,
        startTimeLabel: 'x',
        nowMs: kNow,
      );
      expect(late.status, TripOpenStatus.notOwner);
      expect(db.read('driver_routes/trip-A2'), isNull);
    });
  });

  group('Historical records are read, never rewritten', () {
    test('aggregation does not mutate its inputs', () {
      final input = [loadHistoryView('a'), loadHistoryView('b')];
      final before = input.map((t) => '${t.tripId}|${t.weightKg}|${t.weightType}|${t.totalDistanceKm}').toList();
      LoadHistory.uniqueLoads(input);
      LoadHistory.totals(input);
      LoadHistory.monthly(input, 2026);
      final after = input.map((t) => '${t.tripId}|${t.weightKg}|${t.weightType}|${t.totalDistanceKm}').toList();
      expect(after, before);
    });

    test('a legacy COMPLETED trip without a collection record keeps its own distance', () {
      final legacy = DriverTrip.fromJson({
        'trip_id': 'legacy-1',
        'driver_id': 7,
        'route_status': 'COMPLETED',
        'total_distance_km': 8.5,
        'start_time': '2026-08-01 08:00:00',
        'end_time': '2026-08-01 10:00:00',
      });
      expect(legacy.totalDistanceKm, 8.5);
      expect(LoadHistory.isLoad(legacy), isTrue);
      expect(legacy.hasFullEvent, isFalse);
    });

    test('a finished trip that never moved is not a load, even with a FULL event', () {
      final stub = DriverTrip.fromJson({
        'trip_id': 'stub',
        'route_status': 'COMPLETED',
        'total_distance_km': 0,
        'start_time': '2026-08-01 08:00:00',
      });
      expect(LoadHistory.isLoad(stub), isFalse);
      final fullAtZero = DriverTrip.fromJson({
        'trip_id': 'fz',
        'route_status': 'FULL',
        'total_distance_km': 0,
        'start_time': '2026-08-01 08:00:00',
      });
      expect(LoadHistory.isLoad(fullAtZero), isFalse);
      final fullMoved = DriverTrip.fromJson({
        'trip_id': 'fm',
        'route_status': 'FULL',
        'total_distance_km': 2.3,
        'start_time': '2026-08-01 08:00:00',
      });
      expect(LoadHistory.isLoad(fullMoved), isTrue);
    });

    test('PHP display string for full_time no longer hides the real FULL time', () {
      final t = loadHistoryView('x');
      expect(t.fullTime, isNotNull);
      expect(t.fullTime!.hour, 9);
      expect(t.fullTimeDisplay, isNot('Not recorded'));
    });
  });
}
