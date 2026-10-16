import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/models/driver_trip.dart';
import 'package:garbage_tracking_app/utils/history_playback.dart';

GpsPoint _p(DateTime t, [double lat = 13.95, double lng = 121.16]) =>
    GpsPoint(latitude: lat, longitude: lng, speedKmh: 0, heading: 0, accuracyM: 5, status: 'ACTIVE', timestamp: t);

void main() {
  group('Manila dates (History default = today)', () {
    test('today follows Asia/Manila, not UTC or the device zone', () {
      // 2026-10-12 16:30 UTC is already Oct 13, 00:30 in Manila.
      final DateTime now = DateTime.utc(2026, 10, 12, 16, 30);
      final DateTime today = HistoryDates.manilaToday(now);
      expect([today.year, today.month, today.day], [2026, 10, 13]);
      expect(HistoryDates.isToday(DateTime(2026, 10, 13), now), isTrue);
      expect(HistoryDates.isToday(DateTime(2026, 10, 12), now), isFalse);
    });

    test('a trip just after Manila midnight belongs to the new day only', () {
      final DateTime day13 = DateTime(2026, 10, 13);
      final DateTime day12 = DateTime(2026, 10, 12);
      final DateTime justAfter = DateTime.utc(2026, 10, 12, 16, 0, 1); // 00:00:01 Manila, Oct 13
      final DateTime justBefore = DateTime.utc(2026, 10, 12, 15, 59, 59); // 23:59:59 Manila, Oct 12
      expect(HistoryDates.inRange(justAfter, day13, day13), isTrue);
      expect(HistoryDates.inRange(justAfter, day12, day12), isFalse);
      expect(HistoryDates.inRange(justBefore, day12, day12), isTrue);
      expect(HistoryDates.inRange(justBefore, day13, day13), isFalse);
      expect(HistoryDates.inRange(justBefore, day12, day13), isTrue, reason: 'ranges are inclusive days');
    });

    test('a stored yyyy-MM-dd date is a Manila calendar day', () {
      final DateTime? d = HistoryDates.parseRecordedDate('2026-10-13');
      expect(d, DateTime.utc(2026, 10, 12, 16));
      expect(HistoryDates.inRange(d!, DateTime(2026, 10, 13), DateTime(2026, 10, 13)), isTrue);
      expect(HistoryDates.parseRecordedDate('not a date'), isNull);
      expect(HistoryDates.ymd(DateTime(2026, 1, 5)), '2026-01-05');
    });
  });

  group('date-scoped Firebase query (push-key range)', () {
    test('push key time prefix matches the Firebase alphabet and sorts by time', () {
      expect(HistoryDates.pushKeyPrefix(0), '--------');
      expect(HistoryDates.pushKeyPrefix(1), '-------0');
      expect(HistoryDates.pushKeyPrefix(64), '------0-');
      final List<int> times = <int>[1600000000000, 1700000000000, 1760000000000, 1760000000001, 1800000000000];
      final List<String> keys = times.map(HistoryDates.pushKeyPrefix).toList();
      expect(List<String>.from(keys)..sort(), keys, reason: 'lexical order = chronological order');
    });

    test('bounds cover the selected days plus the lookback, and nothing after', () {
      final DateTime day = DateTime(2026, 10, 13);
      final (String from, String to) = HistoryDates.firebaseKeyBounds(day, day);
      final int dayStart = HistoryDates.startOf(day).millisecondsSinceEpoch;
      final int dayEnd = HistoryDates.endOf(day).millisecondsSinceEpoch;
      String keyAt(int ms) => '${HistoryDates.pushKeyPrefix(ms)}AbCdEfGhIjKl';

      bool inBounds(String k) => k.compareTo(from) >= 0 && k.compareTo(to) <= 0;
      expect(inBounds(keyAt(dayStart + 3600 * 1000)), isTrue, reason: 'trip created that morning');
      expect(inBounds(keyAt(dayStart - 3600 * 1000)), isTrue, reason: 'opened the evening before (lookback)');
      expect(inBounds(keyAt(dayEnd + 1000)), isFalse, reason: 'created the next day');
      expect(inBounds(keyAt(dayStart - const Duration(days: 4).inMilliseconds)), isFalse,
          reason: 'older trips are not downloaded for today');
    });
  });

  group('playback uses the recorded points and timestamps', () {
    final DateTime t0 = DateTime.utc(2026, 10, 13, 0, 0);
    // Uneven recording: 3 fixes in the first minute, then one 9 minutes later.
    final List<GpsPoint> pts = <GpsPoint>[
      _p(t0, 13.950, 121.160),
      _p(t0.add(const Duration(seconds: 20)), 13.951, 121.161),
      _p(t0.add(const Duration(seconds: 40)), 13.952, 121.162),
      _p(t0.add(const Duration(minutes: 10)), 13.960, 121.170),
    ];

    test('the slider position maps to the point recorded at that moment', () {
      expect(HistoryPlayback.indexAt(pts, 0), 0);
      expect(HistoryPlayback.indexAt(pts, 1), 3);
      // Halfway in TIME (5 min) the truck was still at its 40 s fix, not at point #2 by count.
      expect(HistoryPlayback.indexAt(pts, 0.5), 2);
      expect(HistoryPlayback.indexAt(pts, 0.04), 1); // 24 s
      expect(HistoryPlayback.span(pts), const Duration(minutes: 10));
    });

    test('every replay position is a real recorded coordinate (nothing interpolated)', () {
      final Set<String> recorded = pts.map((GpsPoint p) => '${p.latitude},${p.longitude}').toSet();
      for (int i = 0; i <= 100; i++) {
        final GpsPoint p = pts[HistoryPlayback.indexAt(pts, i / 100)];
        expect(recorded.contains('${p.latitude},${p.longitude}'), isTrue);
      }
    });

    test('fewer than 2 points cannot be replayed', () {
      expect(HistoryPlayback.canPlay(const <GpsPoint>[]), isFalse);
      expect(HistoryPlayback.canPlay(<GpsPoint>[_p(t0)]), isFalse);
      expect(HistoryPlayback.canPlay(pts), isTrue);
      expect(HistoryPlayback.indexAt(const <GpsPoint>[], 0.5), -1);
    });

    test('points sharing one timestamp still step through by order', () {
      final List<GpsPoint> same = <GpsPoint>[_p(t0, 1, 1), _p(t0, 2, 2), _p(t0, 3, 3)];
      expect(HistoryPlayback.indexAt(same, 0), 0);
      expect(HistoryPlayback.indexAt(same, 1), 2);
    });

    test('a 1x replay keeps the previous ~20 s duration', () {
      expect(HistoryPlayback.stepPerTick(tickMs: 100), closeTo(0.005, 1e-12));
    });
  });
}
