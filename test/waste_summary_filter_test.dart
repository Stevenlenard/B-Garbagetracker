import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/models/driver_trip.dart';
import 'package:garbage_tracking_app/utils/load_history.dart';

DriverTrip full(String id, DateTime fullUtc, {List<String> areas = const <String>['Purok 2']}) {
  return DriverTrip.fromJson(<String, dynamic>{
    'trip_id': id,
    'driver_id': '7',
    'driver_name': 'D',
    'truck_id': 'GT-1',
    'route_status': 'FULL',
    'start_time': fullUtc.subtract(const Duration(hours: 1)).toIso8601String(),
    'total_distance_km': 1.0,
    'has_full_event': true,
    'collection': <String, dynamic>{
      'finalized_at_ms': fullUtc.millisecondsSinceEpoch,
      'distance_km': 1.0,
      'duration_s': 3600,
      'weight_kg': 5000,
      'weight_type': 'ESTIMATED',
    },
  }).copyWith(visitedAreas: areas);
}

DriverTrip active(String id, DateTime start) => DriverTrip.fromJson(<String, dynamic>{
      'trip_id': id,
      'driver_id': '7',
      'driver_name': 'D',
      'truck_id': 'GT-1',
      'route_status': 'ACTIVE',
      'start_time': start.toIso8601String(),
      'total_distance_km': 0.4,
    });

void main() {
  test('FULL day is the Asia/Manila day (UTC boundary)', () {
    final DriverTrip a = full('a', DateTime.utc(2026, 10, 12, 16, 30)); // 00:30 Oct 13 Manila
    final DriverTrip b = full('b', DateTime.utc(2026, 10, 12, 15, 30)); // 23:30 Oct 12 Manila
    final DateTime d13 = DateTime(2026, 10, 13);
    final DateTime d12 = DateTime(2026, 10, 12);
    expect(LoadHistory.inRange([a, b], d13, d13).map((t) => t.tripId), ['a']);
    expect(LoadHistory.inRange([a, b], d12, d12).map((t) => t.tripId), ['b']);
  });

  test('duplicate trip ids across sources count once', () {
    final DriverTrip a = full('dup', DateTime.utc(2026, 10, 13, 2));
    expect(LoadHistory.uniqueLoads([a, a, a]).length, 1);
  });

  test('unfinished: recent ACTIVE is ongoing, old ACTIVE is stale/legacy', () {
    final DateTime now = DateTime.utc(2026, 10, 13, 6);
    final split = LoadHistory.splitUnfinished([
      active('recent', now.subtract(const Duration(hours: 2))),
      active('old', now.subtract(const Duration(days: 9))),
    ], now);
    expect(split.ongoing.map((t) => t.tripId), ['recent']);
    expect(split.stale.map((t) => t.tripId), ['old']);
  });

  test('area filter matches visited areas and reports unattributed trips', () {
    final DriverTrip p2 = full('p2', DateTime.utc(2026, 10, 13, 2));
    final DriverTrip p3 = full('p3', DateTime.utc(2026, 10, 13, 3), areas: const ['Purok 3']);
    final DriverTrip none = full('none', DateTime.utc(2026, 10, 13, 4), areas: const []);
    final r = LoadHistory.forArea([p2, p3, none], 'Purok 2');
    expect(r.matched.map((t) => t.tripId), ['p2']);
    expect(r.unattributed, 1);
    expect(LoadHistory.forArea([p2, p3, none], 'All Areas').matched.length, 3);
  });
}
