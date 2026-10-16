import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/models/driver_trip.dart';
import 'package:garbage_tracking_app/services/load_history_repository.dart';
import 'package:garbage_tracking_app/utils/load_history.dart';

/// A trip as get_load_history.php / driver_routes would describe it.
DriverTrip trip(
  String id, {
  String status = 'FULL',
  String full = '2026-10-12 09:00:00',
  String start = '2026-10-12 08:00:00',
  double km = 1.0,
  String driver = '7',
  String truck = 'GT-007',
  double? weight,
  String? weightType,
  bool collectionRecord = false,
  bool hasFullEvent = true,
}) {
  final Map<String, dynamic> json = <String, dynamic>{
    'trip_id': id,
    'driver_id': driver,
    'driver_name': 'Driver $driver',
    'truck_id': truck,
    'route_status': status,
    'start_time': start,
    'total_distance_km': km,
    if (status == 'FULL' || status == 'COMPLETED' || status == 'FINISHED') 'raw_full_time': full,
    if (status == 'FULL' || status == 'COMPLETED' || status == 'FINISHED') 'full_time': '9:00 AM',
    if (hasFullEvent && status != 'ACTIVE') 'has_full_event': true,
    if (weight != null) 'weight_kg': weight,
    if (weightType != null) 'weight_type': weightType,
    if (collectionRecord)
      'collection': <String, dynamic>{
        'finalized_at_ms': DateTime.parse(full.replaceFirst(' ', 'T')).millisecondsSinceEpoch,
        'distance_km': km,
        'duration_s': 3600,
        'weight_kg': 5000,
        'weight_type': 'ESTIMATED',
      },
  };
  return DriverTrip.fromJson(json);
}

LoadHistoryRepository repo({
  List<DriverTrip> mysql = const [],
  List<DriverTrip> firebase = const [],
  List<DriverTrip> measured = const [],
  bool mysqlFails = false,
  bool firebaseFails = false,
  bool measuredFails = false,
}) =>
    LoadHistoryRepository(
      fetchMysql: (s, e) async {
        if (mysqlFails) throw StateError('mysql down');
        return mysql;
      },
      fetchFirebaseRoutes: () async {
        if (firebaseFails) throw StateError('firebase down');
        return firebase;
      },
      fetchMeasuredWeights: () async {
        if (measuredFails) throw StateError('measured down');
        return measured;
      },
    );

void main() {
  group('Summary and Load History count the same finalized trips', () {
    test('five finalized trips -> five trips and 25 tons', () async {
      final r = await repo(mysql: [for (int i = 1; i <= 5; i++) trip('t$i')]).load();
      expect(r.loads.length, 5);
      final totals = LoadHistory.totals(r.loads);
      expect(totals.trips, 5);
      expect(totals.weightKg, 25000);
      expect(totals.tonsLabel, '25 tons');
      expect(totals.isEstimate, isTrue);
    });

    test('the daily dialog and the monthly summary agree when the day is inside the month', () async {
      final r = await repo(mysql: [
        for (int i = 1; i <= 5; i++) trip('d$i', full: '2026-10-12 1$i:00:00'),
        trip('earlier', full: '2026-10-03 09:00:00', start: '2026-10-03 08:00:00'),
      ]).load();
      final day = LoadHistory.inRange(r.loads, DateTime(2026, 10, 12), DateTime(2026, 10, 12));
      final month = LoadHistory.inRange(r.loads, DateTime(2026, 10, 1), DateTime(2026, 10, 31));
      expect(day.length, 5, reason: 'dialog filter: October 12');
      expect(month.length, 6, reason: 'summary filter: October');
      expect(day.every((t) => month.any((m) => m.tripId == t.tripId)), isTrue,
          reason: 'every day trip is inside the month total');
      expect(LoadHistory.totals(month).weightKg, 30000);
    });

    test('the filters legitimately differ: another day is not in the day dialog', () async {
      final r = await repo(mysql: [trip('a'), trip('b', full: '2026-10-05 09:00:00', start: '2026-10-05 08:00:00')]).load();
      expect(LoadHistory.inRange(r.loads, DateTime(2026, 10, 12), DateTime(2026, 10, 12)).map((t) => t.tripId), ['a']);
      expect(LoadHistory.inRange(r.loads, DateTime(2026, 10, 1), DateTime(2026, 10, 31)).length, 2);
    });

    test('late evening FULL stays on its own local day (timezone safe)', () async {
      final r = await repo(mysql: [trip('late', full: '2026-10-12 23:45:00', start: '2026-10-12 22:00:00')]).load();
      expect(LoadHistory.inRange(r.loads, DateTime(2026, 10, 12), DateTime(2026, 10, 12)).length, 1);
      expect(LoadHistory.inRange(r.loads, DateTime(2026, 10, 13), DateTime(2026, 10, 13)).length, 0);
      expect(LoadHistory.monthly(r.loads, 2026)[9]['trip_count'], 1);
    });
  });

  group('What qualifies', () {
    test('ACTIVE and other unfinished trips are excluded (and reported as not counted)', () async {
      final r = await repo(
        mysql: [trip('full-1')],
        firebase: [
          trip('abandoned-1', status: 'ACTIVE', km: 12.0, hasFullEvent: false),
          trip('idle-1', status: 'IDLE', km: 3.0, hasFullEvent: false),
        ],
      ).load();
      expect(r.loads.map((t) => t.tripId), ['full-1']);
      expect(r.unfinished.map((t) => t.tripId).toSet(), {'abandoned-1', 'idle-1'});
      expect(LoadHistory.totals(r.loads).trips, 1);
    });

    test('FULL qualifies before unloading is confirmed', () async {
      final r = await repo(firebase: [trip('f', status: 'FULL', collectionRecord: true)]).load();
      expect(r.loads.length, 1);
      expect(r.loads.single.routeStatus, 'FULL');
    });

    test('COMPLETED of the same trip does not double-count', () async {
      final r = await repo(
        mysql: [trip('x', status: 'COMPLETED')],
        firebase: [trip('x', status: 'FULL', collectionRecord: true), trip('x', status: 'COMPLETED', collectionRecord: true)],
      ).load();
      expect(r.loads.length, 1);
      expect(LoadHistory.totals(r.loads).weightKg, 5000);
    });

    test('duplicate trip ids across sources count once', () async {
      final r = await repo(
        mysql: [trip('dup'), trip('dup')],
        firebase: [trip('dup', collectionRecord: true)],
      ).load();
      expect(r.loads.length, 1);
    });

    test('a FULL trip with zero distance is a load (not silently dropped)', () async {
      final r = await repo(mysql: [trip('zero', km: 0.0)]).load();
      expect(r.loads.length, 1);
      expect(r.loads.single.totalDistanceKm, 0.0);
      expect(LoadHistory.totals(r.loads).weightKg, 5000);
    });

    test('a legacy COMPLETED trip with no FULL event and no movement is not a load', () async {
      final r = await repo(mysql: [trip('stub', status: 'COMPLETED', km: 0.0, hasFullEvent: false)]).load();
      expect(r.loads, isEmpty);
    });

    test('mixed default and saved weights aggregate correctly', () async {
      final r = await repo(
        mysql: [trip('a'), trip('b'), trip('c', weight: 3200.0, weightType: 'MEASURED')],
        measured: [DriverTrip.fromJson({'trip_id': 'b', 'weight_kg': 4100.0, 'weight_type': 'MEASURED'})],
      ).load();
      final totals = LoadHistory.totals(r.loads);
      expect(totals.trips, 3);
      expect(totals.weightKg, 5000 + 4100 + 3200);
      expect(totals.measuredCount, 2);
      expect(totals.estimatedCount, 1);
      expect(totals.isEstimate, isTrue);
    });

    test('drivers and trucks stay attached to their own trip', () async {
      final r = await repo(mysql: [
        trip('a', driver: '7', truck: 'GT-007'),
        trip('b', driver: '9', truck: 'GT-009'),
      ]).load();
      final a = r.loads.firstWhere((t) => t.tripId == 'a');
      final b = r.loads.firstWhere((t) => t.tripId == 'b');
      expect(a.driverId.toString(), '7');
      expect(a.truckId, 'GT-007');
      expect(b.driverId.toString(), '9');
      expect(b.truckId, 'GT-009');
    });
  });

  group('Errors are never shown as zero', () {
    test('all sources failing is an ERROR state, not an empty result', () async {
      final r = await repo(mysqlFails: true, firebaseFails: true, measuredFails: true).load();
      expect(r.isError, isTrue);
      expect(r.failedSources.length, 3);
    });

    test('one source failing is a partial warning with the other data kept', () async {
      final r = await repo(mysqlFails: true, firebase: [trip('f', collectionRecord: true)]).load();
      expect(r.isError, isFalse);
      expect(r.isPartial, isTrue);
      expect(r.loads.length, 1);
      expect(r.failedSources, contains('mysql'));
    });

    test('a healthy empty result is a genuine zero', () async {
      final r = await repo().load();
      expect(r.isError, isFalse);
      expect(r.isPartial, isFalse);
      expect(r.loads, isEmpty);
      expect(LoadHistory.totals(r.loads).trips, 0);
    });
  });

  group('Android and Web process data identically', () {
    test('the same inputs always produce the same aggregate (no platform branch)', () async {
      final inputs = [for (int i = 1; i <= 4; i++) trip('t$i')];
      final a = await repo(mysql: inputs).load();
      final b = await repo(mysql: inputs.reversed.toList()).load();
      expect(a.loads.map((t) => t.tripId).toSet(), b.loads.map((t) => t.tripId).toSet());
      expect(LoadHistory.totals(a.loads).weightKg, LoadHistory.totals(b.loads).weightKg);
    });
  });
}
