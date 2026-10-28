import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/models/driver_trip.dart';
import 'package:garbage_tracking_app/utils/load_history.dart';

/// Older Firebase trips store start_time/end_time as a time of day only, next to a
/// `date`. They used to be dated "now", so they reappeared as today's loads every day.
void main() {
  final DateTime today = DateTime(2026, 10, 28); // calendar day bound

  test('time-only start is placed on the stored date, not today', () {
    final DriverTrip t = DriverTrip.fromJson(<String, dynamic>{
      'trip_id': '-OabcSulb_wic',
      'route_status': 'FULL',
      'date': '2026-08-05',
      'start_time': '8:05 PM',
    });
    expect(LoadHistory.manilaDayKey(t.startTime), 20260805);
    expect(LoadHistory.manilaDayKey(LoadHistory.eventTime(t)), 20260805);
    expect(t.hasRecordedStartTime, isTrue);
    expect(t.hasKnownDate, isTrue);
  });

  test('time-only end before the start finished after midnight', () {
    final DriverTrip t = DriverTrip.fromJson(<String, dynamic>{
      'trip_id': '-OabclJbvpZlA',
      'route_status': 'COMPLETED',
      'date': '2026-08-13',
      'start_time': '11:23 PM',
      'end_time': '3:45 AM',
    });
    expect(t.endTime!.isAfter(t.startTime), isTrue);
    expect(LoadHistory.manilaDayKey(t.endTime!), 20260814);
  });

  test('date-only legacy FULL record keeps its own day', () {
    final DriverTrip t = DriverTrip.fromJson(<String, dynamic>{
      'trip_id': '2026-07-22',
      'route_status': 'FULL',
      'date': '2026-07-22',
    });
    expect(LoadHistory.manilaDayKey(LoadHistory.eventTime(t)), 20260722);
    expect(t.hasRecordedStartTime, isFalse);
    expect(LoadHistory.inRange(<DriverTrip>[t], today, today), isEmpty);
  });

  test('a finalized record with no date at all is never a load', () {
    final DriverTrip t = DriverTrip.fromJson(<String, dynamic>{
      'trip_id': '-Oabcnodate',
      'route_status': 'FULL',
      'start_time': '8:05 PM',
    });
    expect(t.hasKnownDate, isFalse);
    expect(LoadHistory.isLoad(t), isFalse);
  });

  test('full_time_ms is the FULL time', () {
    final int ms = DateTime.utc(2026, 10, 12, 1, 30).millisecondsSinceEpoch;
    final DriverTrip t = DriverTrip.fromJson(<String, dynamic>{
      'trip_id': '-Oabcfullms',
      'route_status': 'FULL',
      'date': '2026-10-12',
      'start_time': '8:00 AM',
      'full_time_ms': ms,
    });
    expect(t.fullTime!.millisecondsSinceEpoch, ms);
  });

  test('full ISO start times are unchanged', () {
    final DriverTrip t = DriverTrip.fromJson(<String, dynamic>{
      'trip_id': 'h1',
      'route_status': 'FULL',
      'start_time': '2026-10-12 08:00:00',
      'raw_full_time': '2026-10-12 09:00:00',
    });
    expect(t.startTime, DateTime.parse('2026-10-12 08:00:00'));
    expect(t.fullTime, DateTime.parse('2026-10-12 09:00:00'));
  });
}
