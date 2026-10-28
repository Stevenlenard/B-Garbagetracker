import '../models/driver_trip.dart';

/// Single rule set for Load History, its yearly bar chart and the Waste Collection
/// Summary. All three are computed from the SAME list, so one finalized collection is
/// counted exactly once everywhere.
///
/// A load is a FINALIZED collection trip (FULL or COMPLETED) that really moved.
/// Unfinished trips are never loads, however far they travelled, and a finished session
/// that covered less than [minLoadKm] is not a collection at all.
class LoadHistory {
  LoadHistory._();

  /// Less than this over a whole collection is GPS wander of a parked truck, not a trip.
  static const double minLoadKm = 0.05;

  static bool isLoad(DriverTrip t) {
    if (!t.isFinalizedCollection) return false;
    // A record with no recorded date cannot be placed on any day.
    if (!t.hasKnownDate && t.fullTime == null && t.endTime == null) return false;
    return t.totalDistanceKm >= minLoadKm;
  }

  /// The time a load is reported under: when the truck became FULL.
  static DateTime eventTime(DriverTrip t) => (t.fullTime ?? t.endTime ?? t.startTime).toLocal();

  /// Wall-clock in Asia/Manila (UTC+8) as a UTC-flagged DateTime (read its fields directly).
  static DateTime manila(DateTime t) => t.toUtc().add(const Duration(hours: 8));

  static int _dayKey(DateTime d) => d.year * 10000 + d.month * 100 + d.day;

  /// Asia/Manila calendar day (yyyymmdd) the load is reported under.
  static int manilaDayKey(DateTime t) => _dayKey(manila(t));

  /// A load that carries a genuine FULL event (as opposed to a legacy finished trip that was
  /// only inferred from movement).
  static bool isGenuineFull(DriverTrip t) => t.hasFullEvent;

  /// An unfinished trip that is plausibly still running: not finalized, status still
  /// ACTIVE/PAUSED, and with recorded activity (last GPS point, else a recorded start) inside
  /// [ongoingWindow] of [now]. Anything else - no recorded start time, or old - is a stale /
  /// legacy record, not an ongoing trip.
  static const Duration ongoingWindow = Duration(hours: 12);

  static bool isOngoing(DriverTrip t, DateTime now) {
    if (t.isFinalizedCollection) return false;
    final String s = t.routeStatus.toUpperCase();
    if (s != 'ACTIVE' && s != 'PAUSED' && s != 'COLLECTING') return false;
    DateTime? last;
    for (final GpsPoint p in t.points) {
      if (last == null || p.timestamp.isAfter(last)) last = p.timestamp;
    }
    last ??= t.hasRecordedStartTime ? t.startTime : null;
    if (last == null) return false;
    final Duration age = now.difference(last);
    return age <= ongoingWindow && age >= const Duration(minutes: -10);
  }

  /// Splits unfinished trips into (ongoing, stale/legacy).
  static ({List<DriverTrip> ongoing, List<DriverTrip> stale}) splitUnfinished(
      Iterable<DriverTrip> unfinished, DateTime now) {
    final List<DriverTrip> ongoing = <DriverTrip>[];
    final List<DriverTrip> stale = <DriverTrip>[];
    for (final DriverTrip t in unfinished) {
      (isOngoing(t, now) ? ongoing : stale).add(t);
    }
    return (ongoing: ongoing, stale: stale);
  }

  /// Loads that name [area] among the areas they visited. Loads that record no area at all
  /// cannot be attributed and are reported in [unattributed] instead of being guessed.
  static ({List<DriverTrip> matched, int unattributed}) forArea(
      Iterable<DriverTrip> loads, String? area, {String? Function(String raw)? canonicalize}) {
    final String a = (area ?? '').trim().toLowerCase();
    if (a.isEmpty || a == 'all areas') {
      return (matched: loads.toList(), unattributed: 0);
    }
    String norm(String v) => ((canonicalize?.call(v) ?? v)).trim().toLowerCase();
    final List<DriverTrip> matched = <DriverTrip>[];
    int unattributed = 0;
    for (final DriverTrip t in loads) {
      if (t.visitedAreas.isEmpty) {
        unattributed++;
      } else if (t.visitedAreas.any((String v) => norm(v) == a)) {
        matched.add(t);
      }
    }
    return (matched: matched, unattributed: unattributed);
  }

  static int _richness(DriverTrip t) =>
      (t.hasFullEvent ? 4 : 0) + (t.points.length >= 2 ? 2 : 0) + (t.totalDistanceKm > 0 ? 1 : 0);

  /// Finalized loads, one per trip id. When the same trip comes from several sources
  /// (Firebase route, MySQL history, load_history node) the richest record is kept and
  /// a MEASURED weight from any of them is applied to it.
  static List<DriverTrip> uniqueLoads(Iterable<DriverTrip> trips) {
    final Map<String, DriverTrip> measured = <String, DriverTrip>{};
    for (final DriverTrip t in trips) {
      if (t.isMeasured && !measured.containsKey(t.tripId)) measured[t.tripId] = t;
    }

    final Map<String, DriverTrip> best = <String, DriverTrip>{};
    for (final DriverTrip t in trips) {
      if (!isLoad(t)) continue;
      final DriverTrip? cur = best[t.tripId];
      if (cur == null || _richness(t) > _richness(cur)) best[t.tripId] = t;
    }

    return best.values.map((DriverTrip t) {
      final DriverTrip? m = measured[t.tripId];
      if (m != null && !t.isMeasured) {
        return t.copyWith(weightKg: m.weightKg, weightType: 'MEASURED');
      }
      return t;
    }).toList();
  }

  /// Loads whose FULL time falls inside [start]..[end] (date bounds inclusive).
  /// A null bound is open.
  static List<DriverTrip> inRange(Iterable<DriverTrip> loads, DateTime? start, DateTime? end) {
    // Calendar days are compared in Asia/Manila, by the FULL time of the load.
    final int? lo = start == null ? null : _dayKey(start);
    final int? hi = end == null ? null : _dayKey(end);
    return loads.where((DriverTrip t) {
      final int day = manilaDayKey(eventTime(t));
      if (lo != null && day < lo) return false;
      if (hi != null && day > hi) return false;
      return true;
    }).toList();
  }

  static LoadTotals totals(Iterable<DriverTrip> loads) {
    double kg = 0;
    int measured = 0;
    int estimated = 0;
    int n = 0;
    for (final DriverTrip t in loads) {
      n++;
      kg += t.weightKg;
      if (t.isMeasured) {
        measured++;
      } else {
        estimated++;
      }
    }
    return LoadTotals(trips: n, weightKg: kg, measuredCount: measured, estimatedCount: estimated);
  }

  /// Jan..Dec buckets for [year] in the shape the Load History chart already consumes.
  static List<Map<String, dynamic>> monthly(Iterable<DriverTrip> loads, int year) {
    const List<String> labels = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final List<double> kg = List<double>.filled(12, 0);
    final List<int> count = List<int>.filled(12, 0);
    for (final DriverTrip t in loads) {
      final DateTime when = manila(eventTime(t));
      if (when.year != year) continue;
      kg[when.month - 1] += t.weightKg;
      count[when.month - 1]++;
    }
    return List<Map<String, dynamic>>.generate(12, (int i) {
      final bool has = count[i] > 0;
      final double tons = has ? double.parse((kg[i] / 1000.0).toStringAsFixed(2)) : 0.0;
      return <String, dynamic>{
        'month_number': i + 1,
        'month_label': labels[i],
        'has_data': has,
        'trip_count': count[i],
        'total_weight_kg': kg[i],
        'total_weight_tons': tons,
        'display_label': has ? '$tons tons' : 'No data',
      };
    });
  }
}

class LoadTotals {
  const LoadTotals({
    required this.trips,
    required this.weightKg,
    required this.measuredCount,
    required this.estimatedCount,
  });

  final int trips;
  final double weightKg;
  final int measuredCount;
  final int estimatedCount;

  double get weightTons => weightKg / 1000.0;

  /// Any estimate in the total makes the whole figure an estimate.
  bool get isEstimate => estimatedCount > 0;

  /// "25 tons", "12.5 tons" (no truncation of fractions).
  String get tonsLabel {
    final double t = weightTons;
    final String s = t == t.roundToDouble() ? t.toStringAsFixed(0) : t.toStringAsFixed(1);
    return '$s tons';
  }
}
