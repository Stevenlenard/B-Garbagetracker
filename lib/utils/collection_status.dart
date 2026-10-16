/// Collection recency per service area, from evidence the system really has.
///
/// Evidence (strongest first):
///  * VERIFIED VISIT - a [CollectionVisit] from `CollectionVisits.detect`: GPS fixes recorded
///    while the trip was ACTIVE, at least 3 fixes and 60 s in one continuous stay inside the
///    area. It shows the truck stayed in the area to collect; it does NOT prove that every
///    household was served (no such record exists in the system).
///  * PARTIAL - a record that explicitly says the collection was partial. The current app
///    writes no such record; the rules below handle it for when one exists.
///  * ACTIVITY - weaker signals: a weekly-progress mark (`completionSource` GPS_PROXIMITY =
///    3 fixes inside the radius at < 25 km/h, no dwell; MANUAL_ALERT = an approach alert) or
///    an unconfirmed pass. Shown as "latest activity", never as a collection.
///
/// A verified visit establishes TRUCK PRESENCE while collecting, not completed collection;
/// labels therefore say "visit", never "collected".
///
/// Bands (days = Asia/Manila calendar days since the last verified visit):
///    0 .. recentDays-1      -> recent   (green, check)
///    recentDays .. staleDays-1 -> aging (red, clock, "N days")
///    staleDays ..           -> stale    (red, clock, "N days")
///    no confirmed visit in the analysed window -> partialOnly when a partial record exists,
///    otherwise unknown (gray, "?"). Unknown stays unknown: no date is assumed.
/// A newer partial record never upgrades or downgrades the band of the last confirmed visit;
/// it is shown next to it ("Partial activity on ...").
/// These are recency bands, not schedule compliance: nothing here says "missed" or "overdue".
library;

import 'collection_visits.dart';

class CollectionStatusConfig {
  const CollectionStatusConfig({this.recentDays = 7, this.staleDays = 14, this.windowDays = 90});

  final int recentDays;
  final int staleDays;

  /// How far back records are analysed; "unknown" means "no confirmed visit in this window".
  final int windowDays;
}

enum CollectionBand { recent, aging, stale, partialOnly, unknown }

enum StatusFilter { all, sevenPlus, fourteenPlus }

class AreaActivity {
  const AreaActivity({required this.ms, required this.source});
  final int ms;
  final String source;
}

class AreaCollectionStatus {
  const AreaCollectionStatus({
    required this.area,
    required this.band,
    required this.lastConfirmedMs,
    required this.daysSince,
    required this.latestPartialMs,
    required this.latestActivity,
    required this.confirmedVisits,
  });

  final String area;
  final CollectionBand band;
  final int? lastConfirmedMs;
  final int? daysSince;
  final int? latestPartialMs;
  final AreaActivity? latestActivity;
  final int confirmedVisits;

  bool get hasNewerPartial =>
      latestPartialMs != null && (lastConfirmedMs == null || latestPartialMs! > lastConfirmedMs!);

  /// Short label that does not rely on colour.
  String get label => switch (band) {
        CollectionBand.recent => daysSince == 0 ? 'Visited today' : 'Visited $daysSince day${daysSince == 1 ? '' : 's'} ago',
        CollectionBand.aging => '$daysSince days since verified visit',
        CollectionBand.stale => '$daysSince days since verified visit',
        CollectionBand.partialOnly => 'Partial collection only',
        CollectionBand.unknown => 'No verified visit record',
      };

  /// Marker symbol (text, so meaning does not depend on colour alone).
  String get symbol => switch (band) {
        CollectionBand.recent => '✓',
        CollectionBand.aging => '◷',
        CollectionBand.stale => '◷',
        CollectionBand.partialOnly => '!',
        CollectionBand.unknown => '?',
      };

  String explanation(CollectionStatusConfig c) => switch (band) {
        CollectionBand.recent =>
          'Last verified truck visit is less than ${c.recentDays} days old.',
        CollectionBand.aging =>
          'Last verified truck visit is ${c.recentDays}-${c.staleDays - 1} days old.',
        CollectionBand.stale => 'Last verified truck visit is ${c.staleDays} or more days old.',
        CollectionBand.partialOnly =>
          'Only partial collection is recorded in the last ${c.windowDays} days; no verified visit.',
        CollectionBand.unknown =>
          'No verified truck visit in the last ${c.windowDays} days. This is not proof of a missed collection.',
      };

  bool matches(StatusFilter f, CollectionStatusConfig c) => switch (f) {
        StatusFilter.all => true,
        StatusFilter.sevenPlus => daysSince != null && daysSince! >= c.recentDays,
        StatusFilter.fourteenPlus => daysSince != null && daysSince! >= c.staleDays,
      };
}

class CollectionStatus {
  CollectionStatus._();

  static const Duration manila = Duration(hours: 8); // Asia/Manila, no daylight saving

  static DateTime manilaTime(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).add(manila);

  /// Whole Asia/Manila calendar days between [ms] and [nowMs].
  static int manilaDaysBetween(int ms, int nowMs) {
    DateTime day(int v) {
      final DateTime t = manilaTime(v);
      return DateTime.utc(t.year, t.month, t.day);
    }

    return day(nowMs).difference(day(ms)).inDays;
  }

  /// Next instant at which a band can change without new data (next Manila midnight).
  static DateTime nextBoundary(DateTime now) {
    final DateTime m = manilaTime(now.millisecondsSinceEpoch);
    return DateTime.utc(m.year, m.month, m.day + 1).subtract(manila);
  }

  static const List<String> _months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  /// "Oct 12, 2026, 8:05 AM" in Asia/Manila.
  static String formatManila(int ms) {
    final DateTime t = manilaTime(ms);
    final int h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '${_months[t.month - 1]} ${t.day}, ${t.year}, $h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  static AreaCollectionStatus evaluate({
    required String area,
    required List<CollectionVisit> confirmedVisits,
    List<int> partialRecordsMs = const <int>[],
    List<AreaActivity> activity = const <AreaActivity>[],
    required int nowMs,
    CollectionStatusConfig config = const CollectionStatusConfig(),
  }) {
    final List<CollectionVisit> visits =
        confirmedVisits.where((CollectionVisit v) => v.area == area && v.firstFixMs <= nowMs).toList();
    int? last;
    for (final CollectionVisit v in visits) {
      if (last == null || v.lastFixMs > last) last = v.lastFixMs;
    }
    int? partial;
    for (final int p in partialRecordsMs) {
      if (p <= nowMs && (partial == null || p > partial)) partial = p;
    }
    AreaActivity? act;
    for (final AreaActivity a in activity) {
      if (a.ms <= nowMs && (act == null || a.ms > act.ms)) act = a;
    }

    CollectionBand band;
    int? days;
    if (last != null) {
      days = manilaDaysBetween(last, nowMs);
      band = days < config.recentDays
          ? CollectionBand.recent
          : (days < config.staleDays ? CollectionBand.aging : CollectionBand.stale);
    } else {
      band = partial != null ? CollectionBand.partialOnly : CollectionBand.unknown;
    }
    return AreaCollectionStatus(
      area: area,
      band: band,
      lastConfirmedMs: last,
      daysSince: days,
      latestPartialMs: partial,
      latestActivity: act,
      confirmedVisits: visits.length,
    );
  }

  /// Weekly-progress marks as ACTIVITY (never as a verified visit). [progress] is
  /// `weekly_collection_progress` (week -> driver -> {areas: {key: record}}); [areaOf] maps a
  /// record key (area name or id) to the canonical area name.
  static Map<String, List<AreaActivity>> activityFromWeeklyProgress(Object? progress, String? Function(String key) areaOf) {
    final Map<String, List<AreaActivity>> out = <String, List<AreaActivity>>{};
    if (progress is! Map) return out;
    for (final Object? week in progress.values) {
      if (week is! Map) continue;
      for (final Object? driver in week.values) {
        final Object? areas = driver is Map ? driver['areas'] : null;
        if (areas is! Map) continue;
        areas.forEach((Object? key, Object? rec) {
          if (rec is! Map || rec['completed'] != true) return;
          final String source = (rec['completionSource'] ?? '').toString();
          if (source == 'SIMULATION') return;
          final Object? ts = rec['timestamp'];
          if (ts is! num || ts <= 0) return;
          final String? area = areaOf(key.toString());
          if (area == null) return;
          out.putIfAbsent(area, () => <AreaActivity>[]).add(AreaActivity(
              ms: ts.toInt(),
              source: source == 'MANUAL_ALERT' ? 'Driver approach alert' : 'Weekly progress mark (GPS proximity)'));
        });
      }
    }
    return out;
  }
}
