import '../models/driver_trip.dart';

/// Asia/Manila (UTC+8, no DST) calendar dates for Map Tracking history.
///
/// A "Manila date" is a plain DateTime whose year/month/day fields are the calendar day
/// in Manila; only those fields are read. Instants (GPS timestamps) are converted with
/// [manilaDayOf], so the device time zone never shifts a trip onto another day.
class HistoryDates {
  HistoryDates._();

  static const Duration manilaOffset = Duration(hours: 8);

  /// Trips are opened before their first GPS fix and may be resumed later, so the
  /// Firebase key range starts a little before the selected day. Exact day filtering
  /// happens afterwards on the recorded trip date.
  static const Duration keyLookback = Duration(days: 3);

  /// Longest range one history load may cover (bounded loading).
  static const int maxRangeDays = 31;

  static DateTime manilaDayOf(DateTime instant) {
    final DateTime m = instant.toUtc().add(manilaOffset);
    return DateTime(m.year, m.month, m.day);
  }

  static DateTime manilaToday([DateTime? now]) => manilaDayOf(now ?? DateTime.now());

  static bool isToday(DateTime? manilaDate, [DateTime? now]) {
    if (manilaDate == null) return false;
    final DateTime t = manilaToday(now);
    return manilaDate.year == t.year && manilaDate.month == t.month && manilaDate.day == t.day;
  }

  /// First instant of a Manila calendar day.
  static DateTime startOf(DateTime manilaDate) =>
      DateTime.utc(manilaDate.year, manilaDate.month, manilaDate.day).subtract(manilaOffset);

  /// First instant AFTER a Manila calendar day (exclusive bound).
  static DateTime endOf(DateTime manilaDate) =>
      DateTime.utc(manilaDate.year, manilaDate.month, manilaDate.day + 1).subtract(manilaOffset);

  /// Whether [instant] falls on a Manila day within [start]..[end] (inclusive days).
  static bool inRange(DateTime instant, DateTime? start, DateTime? end) {
    if (start != null && instant.isBefore(startOf(start))) return false;
    if (end != null && !instant.isBefore(endOf(end))) return false;
    return true;
  }

  /// A stored trip date: "yyyy-MM-dd" is a Manila calendar day; anything else is parsed
  /// as an instant (null when unreadable).
  static DateTime? parseRecordedDate(String raw) {
    final String s = raw.trim();
    final RegExpMatch? m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
    if (m != null) {
      return startOf(DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)));
    }
    return DateTime.tryParse(s);
  }

  static String ymd(DateTime manilaDate) =>
      '${manilaDate.year.toString().padLeft(4, '0')}-'
      '${manilaDate.month.toString().padLeft(2, '0')}-'
      '${manilaDate.day.toString().padLeft(2, '0')}';

  static const String _pushChars = '-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz';

  /// The 8-character time prefix of a Firebase push key created at [ms]. Push keys sort by
  /// creation time, so a key range is a date range that needs no database index.
  static String pushKeyPrefix(int ms) {
    final List<String> out = List<String>.filled(8, '-');
    int t = ms;
    for (int i = 7; i >= 0; i--) {
      out[i] = _pushChars[t % 64];
      t ~/= 64;
    }
    return out.join();
  }

  /// `orderByKey().startAt(a).endAt(b)` bounds covering trips that can fall on
  /// [start]..[end] (Manila days).
  static (String, String) firebaseKeyBounds(DateTime start, DateTime end) {
    final int from = startOf(start).subtract(keyLookback).millisecondsSinceEpoch;
    final int to = endOf(end).millisecondsSinceEpoch;
    return (pushKeyPrefix(from), pushKeyPrefix(to));
  }
}

/// Replay of a saved trip: only real recorded GPS points, positioned by their timestamps.
class HistoryPlayback {
  HistoryPlayback._();

  /// Fewer points than this cannot show any movement.
  static const int minPoints = 2;

  static bool canPlay(List<GpsPoint> points) => points.length >= minPoints;

  /// Index of the recorded point shown at [progress] (0..1 of the recorded time span):
  /// the last point recorded at or before that moment.
  static int indexAt(List<GpsPoint> points, double progress) {
    if (points.isEmpty) return -1;
    final int first = points.first.timestamp.millisecondsSinceEpoch;
    final int last = points.last.timestamp.millisecondsSinceEpoch;
    if (last <= first) return ((points.length - 1) * progress.clamp(0.0, 1.0)).round();
    final int target = first + ((last - first) * progress.clamp(0.0, 1.0)).round();
    int lo = 0, hi = points.length - 1;
    while (lo < hi) {
      final int mid = (lo + hi + 1) >> 1;
      if (points[mid].timestamp.millisecondsSinceEpoch <= target) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Recorded duration of the trace.
  static Duration span(List<GpsPoint> points) =>
      points.length < 2 ? Duration.zero : points.last.timestamp.difference(points.first.timestamp);

  /// Progress added per animation tick so a replay lasts about [replaySeconds] at 1x,
  /// whatever the trip length.
  static double stepPerTick({int tickMs = 100, int replaySeconds = 20}) => tickMs / (replaySeconds * 1000);
}
