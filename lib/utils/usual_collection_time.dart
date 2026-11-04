/// "Usual collection time" of one area: on which days of the week, and between which times, the truck was
/// VERIFIED in the area during the last [windowDays] days (visits from `CollectionVisits.detect`).
///
/// It describes what recorded trips did; it is not a promise and not a prediction model. A weekday is shown only when
/// at least [minVisitsPerDay] verified visits fell on it, and the time is a range (earliest to latest arrival,
/// rounded outwards to [roundMin] minutes), never a single minute. With six or more visits on a day the earliest and
/// the latest one are left out, so one unusual trip does not stretch the range.
library;

import 'collection_visits.dart';
import 'resident_alert_rules.dart';

class UsualDay {
  const UsualDay({required this.weekday, required this.startMin, required this.endMin, required this.visits});

  /// DateTime.monday (1) .. DateTime.sunday (7), Asia/Manila.
  final int weekday;

  /// Minutes after midnight, Manila time.
  final int startMin;
  final int endMin;
  final int visits;
}

class UsualCollectionTimes {
  const UsualCollectionTimes({required this.days, required this.visitCount, required this.windowDays});

  const UsualCollectionTimes.none({this.windowDays = UsualCollectionTime.defaultWindowDays})
      : days = const <UsualDay>[],
        visitCount = 0;

  /// The usual weekdays, Monday first.
  final List<UsualDay> days;

  /// Verified visits in the window that the pattern is based on (all weekdays).
  final int visitCount;
  final int windowDays;

  bool get hasPattern => days.isNotEmpty;

  int get startMin => days.map((UsualDay d) => d.startMin).reduce((int a, int b) => a < b ? a : b);
  int get endMin => days.map((UsualDay d) => d.endMin).reduce((int a, int b) => a > b ? a : b);

  /// The range is wider than [UsualCollectionTime.variesAfterMin] minutes: the time of day is not steady.
  bool get varies => hasPattern && endMin - startMin > UsualCollectionTime.variesAfterMin;

  /// "Tue & Fri", "Mon, Wed & Fri".
  String get daysLabel {
    final List<String> n = days.map((UsualDay d) => UsualCollectionTime.dayShort[d.weekday - 1]).toList();
    if (n.length == 1) return n.first;
    return '${n.sublist(0, n.length - 1).join(', ')} & ${n.last}';
  }

  /// "7:00 – 8:30 AM", "11:30 AM – 1:00 PM".
  String get rangeLabel => UsualCollectionTime.formatRange(startMin, endMin);

  String get basisLabel => 'Based on $visitCount verified visit${visitCount == 1 ? '' : 's'} in the last $windowDays days'
      '${varies ? ' · time varies' : ''}';
}

class UsualCollectionTime {
  UsualCollectionTime._();

  static const int defaultWindowDays = 28;
  static const int minVisitsPerDay = 2;
  static const int roundMin = 15;

  /// A range wider than this (3 hours) is reported as varying.
  static const int variesAfterMin = 180;

  static const List<String> dayShort = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static UsualCollectionTimes compute(
    Iterable<CollectionVisit> visits, {
    String? area,
    int windowDays = defaultWindowDays,
    int minVisits = minVisitsPerDay,
  }) {
    final Map<int, List<int>> minutesByDay = <int, List<int>>{};
    int total = 0;
    for (final CollectionVisit v in visits) {
      if (v.simulated) continue;
      if (area != null && !ResidentAlertRules.samePurok(v.area, area)) continue;
      final DateTime m = DateTime.fromMillisecondsSinceEpoch(v.firstFixMs, isUtc: true).add(CollectionVisits.manilaOffset);
      (minutesByDay[m.weekday] ??= <int>[]).add(m.hour * 60 + m.minute);
      total++;
    }
    final List<UsualDay> days = <UsualDay>[];
    for (final int wd in (minutesByDay.keys.toList()..sort())) {
      final List<int> t = minutesByDay[wd]!..sort();
      if (t.length < minVisits) continue;
      final List<int> kept = t.length >= 6 ? t.sublist(1, t.length - 1) : t;
      final int start = (kept.first ~/ roundMin) * roundMin;
      final int end = ((kept.last + roundMin - 1) ~/ roundMin) * roundMin;
      days.add(UsualDay(weekday: wd, startMin: start, endMin: end > 1439 ? 1439 : end, visits: t.length));
    }
    if (days.isEmpty) return UsualCollectionTimes.none(windowDays: windowDays);
    return UsualCollectionTimes(days: days, visitCount: total, windowDays: windowDays);
  }

  static String _clock(int min, {required bool withMeridiem}) {
    final int h24 = (min ~/ 60) % 24;
    final int mm = min % 60;
    final int h12 = h24 % 12 == 0 ? 12 : h24 % 12;
    final String base = '$h12:${mm.toString().padLeft(2, '0')}';
    return withMeridiem ? '$base ${h24 < 12 ? 'AM' : 'PM'}' : base;
  }

  static String formatRange(int startMin, int endMin) {
    final bool same = (startMin ~/ 720) == (endMin ~/ 720);
    if (startMin == endMin) return _clock(startMin, withMeridiem: true);
    return '${_clock(startMin, withMeridiem: !same)} – ${_clock(endMin, withMeridiem: true)}';
  }
}
