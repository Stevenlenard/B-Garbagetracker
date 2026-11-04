import 'dart:async';

import 'package:flutter/foundation.dart';

import '../screens/collection_route_optimization_screen.dart';
import '../utils/collection_visits.dart';
import '../utils/history_playback.dart';
import '../utils/resident_alert_rules.dart';
import '../utils/usual_collection_time.dart';
import 'server_clock.dart';

/// Reads the last 28 days of recorded trips once (the same records Collection Status uses) and derives the usual
/// collection days and time range of the resident's area. Nothing is written; the result is kept for [ttl].
class UsualCollectionTimeService {
  UsualCollectionTimeService({CollectionDataSource? source, int Function()? nowMs})
      : _source = source ?? FirebaseCollectionDataSource(),
        _nowMs = nowMs ?? (() => ServerClock.instance.nowMs());

  final CollectionDataSource _source;
  final int Function() _nowMs;

  static const Duration ttl = Duration(hours: 6);
  static const Duration timeout = Duration(seconds: 30);

  static final Map<String, ({int atMs, UsualCollectionTimes result})> _cache = <String, ({int atMs, UsualCollectionTimes result})>{};

  @visibleForTesting
  static void clearCache() => _cache.clear();

  /// Pure derivation from already loaded records.
  static UsualCollectionTimes fromData(CollectionData d, String? purok, DateTime manilaToday, {int windowDays = UsualCollectionTime.defaultWindowDays}) {
    if (purok == null || purok.trim().isEmpty) return UsualCollectionTimes.none(windowDays: windowDays);
    final List<AreaGeofence> mine = d.areas.where((AreaGeofence a) => a.isTruckStop && ResidentAlertRules.samePurok(a.name, purok)).toList();
    if (mine.isEmpty) return UsualCollectionTimes.none(windowDays: windowDays);
    final DateTime start = manilaToday.subtract(Duration(days: windowDays - 1));
    final VisitSummary v = CollectionVisits.detect(trips: d.trips, areas: mine, start: start, end: manilaToday);
    return UsualCollectionTime.compute(v.visits, area: purok, windowDays: windowDays);
  }

  /// null when the records could not be read (the card then keeps its plain wording).
  Future<UsualCollectionTimes?> load(String? purok) async {
    if (purok == null || purok.trim().isEmpty) return null;
    final int now = _nowMs();
    final String key = purok.trim().toLowerCase();
    final cached = _cache[key];
    if (cached != null && now - cached.atMs < ttl.inMilliseconds) return cached.result;
    try {
      final DateTime today = HistoryDates.manilaToday(DateTime.fromMillisecondsSinceEpoch(now));
      final DateTime start = today.subtract(const Duration(days: UsualCollectionTime.defaultWindowDays - 1));
      final CollectionData d = await _source.watch(start: start, end: today).first.timeout(timeout);
      final UsualCollectionTimes r = fromData(d, purok, today);
      _cache[key] = (atMs: now, result: r);
      return r;
    } catch (e) {
      debugPrint('[USUAL TIME] could not be derived: $e');
      return null;
    }
  }
}
