/// Verified collection visits, derived ONLY from GPS points the Driver app stored under
/// `driver_routes/{trip}/route`.
///
/// A VISIT is one trip spending meaningful time inside one service area while ACTIVE
/// (collecting). It is evidence that the truck was there to collect; it does NOT prove that
/// every household in the area was serviced.
///
/// Confirmation policy ([VisitPolicy]):
///  * only fixes recorded while the trip status was ACTIVE (IDLE/PAUSED, FULL, COMPLETED and
///    FINISHED travel is excluded, and so is anything after the collection was finalized);
///  * simulation points, points without coordinates and fixes with a reported accuracy worse
///    than [VisitPolicy.maxAccuracyM] (the Driver app's own proximity threshold) are rejected;
///  * at least [VisitPolicy.minFixes] in-area fixes spanning at least
///    [VisitPolicy.minDwellMs] in ONE continuous stay. A quick pass-through is reported as an
///    unconfirmed pass, never as a visit;
///  * a stay is broken by a gap longer than [VisitPolicy.maxGapMs] or by more than
///    [VisitPolicy.outsideTolerance] consecutive fixes outside the area (one stray fix across
///    the boundary is treated as jitter);
///  * at most ONE visit per trip and area, however often the truck leaves and re-enters.
///    Separate trips to the same area are separate visits.
library;

import 'dart:math' as math;
import 'trip_archive.dart';

class AreaGeofence {
  const AreaGeofence({
    required this.name,
    required this.lat,
    required this.lng,
    required this.radiusM,
    this.polygon = const <List<double>>[],
    this.isTruckStop = true,
  });

  final String name;
  final double lat;
  final double lng;
  final double radiusM;

  /// Boundary as [longitude, latitude] pairs. Used when it has at least 3 vertices,
  /// otherwise the circular geofence ([lat], [lng], [radiusM]) is used.
  final List<List<double>> polygon;

  /// false = stationary street-sweeping area (not serviced by the truck): never visited.
  final bool isTruckStop;

  /// Largest plausible boundary of one collection area. The stored boxes of about 650 x 670 m are placeholders
  /// that overlap their neighbours (a walk near Dali counted as a Brixton Homes visit), and one box lies 1.2 km away
  /// from its own area (Central). Such a polygon is ignored and the circle around the verified area point is used.
  static const double maxPolygonSideM = 400;

  /// Every collection area is the circle of this radius around its verified point (owner decision, 21 Oct 2026).
  /// Neighbouring areas closer than 200 m (Riverside and T.M. Kalaw) overlap; a stay there counts for both, which
  /// matches practice: the crew collects in both while passing.
  static const double areaRadiusM = 100;

  bool get usesPolygon {
    if (polygon.length < 3) return false;
    if (!_inPolygon(lng, lat, polygon)) return false; // the boundary must contain its own area point
    final double minLng = polygon.map((p) => p[0]).reduce(math.min), maxLng = polygon.map((p) => p[0]).reduce(math.max);
    final double minLat = polygon.map((p) => p[1]).reduce(math.min), maxLat = polygon.map((p) => p[1]).reduce(math.max);
    return _distanceM(lat, minLng, lat, maxLng) <= maxPolygonSideM && _distanceM(minLat, lng, maxLat, lng) <= maxPolygonSideM;
  }

  bool contains(double pLat, double pLng) {
    if (usesPolygon) return _inPolygon(pLng, pLat, polygon);
    return _distanceM(lat, lng, pLat, pLng) <= radiusM;
  }

  static bool _inPolygon(double x, double y, List<List<double>> poly) {
    bool inside = false;
    for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final double xi = poly[i][0], yi = poly[i][1];
      final double xj = poly[j][0], yj = poly[j][1];
      final bool crosses = (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / ((yj - yi) == 0 ? 1e-12 : (yj - yi)) + xi;
      if (crosses) inside = !inside;
    }
    return inside;
  }

  static double _distanceM(double lat1, double lng1, double lat2, double lng2) {
    const double r = 6371000.0;
    final double dLat = (lat2 - lat1) * math.pi / 180;
    final double dLng = (lng2 - lng1) * math.pi / 180;
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
  }
}

class VisitPolicy {
  const VisitPolicy({
    // with minDwellMs: two fixes at least 40 s apart. Phones on battery saving report only every ~40-50 s,
    // so a real stop gives just two fixes 45 s apart; a pass-through (one fix, or seconds apart) still never counts.
    this.minFixes = 2,
    this.minDwellMs = 40 * 1000,
    this.maxAccuracyM = 40.0,
    this.maxGapMs = 3 * 60 * 1000,
    this.outsideTolerance = 1,
  });

  final int minFixes;
  final int minDwellMs;
  final double maxAccuracyM;
  final int maxGapMs;
  final int outsideTolerance;
}

class CollectionVisit {
  const CollectionVisit({
    required this.tripId,
    required this.area,
    required this.firstFixMs,
    required this.lastFixMs,
    required this.fixes,
    this.truckId,
    this.driverId,
    this.simulated = false,
  });

  final String tripId;
  final String area;
  final int firstFixMs;
  final int lastFixMs;
  final int fixes;
  final String? truckId;
  final String? driverId;

  /// From a SIMULATION trip: shown on the collection-status screen (to test the status change) but never used by
  /// Analytics or the evaluation.
  final bool simulated;

  int get dwellMs => lastFixMs - firstFixMs;
}

class VisitSummary {
  const VisitSummary({
    required this.visits,
    required this.unconfirmedPasses,
    required this.tripsConsidered,
    required this.tripsWithoutEvidence,
  });

  /// Confirmed visits (one per trip and area), newest first.
  final List<CollectionVisit> visits;

  /// Area -> number of trips that entered the area while ACTIVE but did not meet the policy.
  final Map<String, int> unconfirmedPasses;

  /// Trips dated in the period (simulations excluded).
  final int tripsConsidered;

  /// Trips in the period with no usable ACTIVE GPS fix at all: their visits cannot be proven.
  final int tripsWithoutEvidence;

  Map<String, int> countByArea() {
    final Map<String, int> out = <String, int>{};
    for (final CollectionVisit v in visits) {
      out[v.area] = (out[v.area] ?? 0) + 1;
    }
    return out;
  }

  Set<String> get areasVisited => visits.map((CollectionVisit v) => v.area).toSet();
}

class _Fix {
  const _Fix(this.ms, this.lat, this.lng);
  final int ms;
  final double lat;
  final double lng;
}

class CollectionVisits {
  CollectionVisits._();

  static const Duration manilaOffset = Duration(hours: 8);

  /// Asia/Manila calendar day (yyyy-mm-dd) of an epoch-ms instant.
  static String manilaDay(int ms) {
    final DateTime d = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).add(manilaOffset);
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static int? _ms(Object? v) {
    if (v == null) return null;
    final num? n = v is num ? v : num.tryParse(v.toString());
    if (n == null || n <= 0) return null;
    return n < 10000000000 ? (n * 1000).toInt() : n.toInt();
  }

  static double? _num(Object? v) => v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');

  static bool _isActive(Object? status) {
    final String s = (status ?? '').toString().trim().toUpperCase();
    return s == 'ACTIVE' || s == 'COLLECTING';
  }

  /// Valid ACTIVE fixes of one trip, oldest first, de-duplicated by time.
  static List<_Fix> _activeFixes(Map trip, VisitPolicy policy, {bool includeSimulated = false}) {
    final Object? route = trip['route'];
    final Iterable<Object?> raw = route is Map ? route.values : (route is List ? route : const <Object?>[]);
    final int? finalizedAt = _ms(trip['collection'] is Map ? (trip['collection'] as Map)['finalized_at_ms'] : null);
    final Map<int, _Fix> byTime = <int, _Fix>{};
    for (final Object? p in raw) {
      if (p is! Map) continue;
      if (p['is_simulation'] == true && !includeSimulated) continue;
      if (!_isActive(p['status'])) continue;
      final double? lat = _num(p['latitude'] ?? p['lat']);
      final double? lng = _num(p['longitude'] ?? p['lng']);
      if (lat == null || lng == null || lat == 0 || lng == 0) continue;
      final double? acc = _num(p['accuracy']);
      if (acc != null && acc > policy.maxAccuracyM) continue;
      final int? ms = _ms(p['fix_time']) ?? _ms(p['timestamp']);
      if (ms == null) continue;
      if (finalizedAt != null && ms >= finalizedAt) continue;
      byTime[ms] = _Fix(ms, lat, lng);
    }
    final List<_Fix> out = byTime.values.toList()..sort((_Fix a, _Fix b) => a.ms.compareTo(b.ms));
    return out;
  }

  /// The same validated ACTIVE fixes the visit detection uses (oldest first), for other
  /// analyses of recorded paths (simulation, inaccurate, finalized and non-ACTIVE fixes removed).
  static List<({int ms, double lat, double lng})> activeFixesOf(Map trip, [VisitPolicy policy = const VisitPolicy()]) =>
      _activeFixes(trip, policy).map((_Fix f) => (ms: f.ms, lat: f.lat, lng: f.lng)).toList();

  /// Longest qualifying stay of [fixes] inside [area], or null (with [entered] reporting
  /// whether the trip entered the area at all).
  static ({int first, int last, int count})? _bestStay(
      List<_Fix> fixes, AreaGeofence area, VisitPolicy policy, void Function() entered) {
    ({int first, int last, int count})? best;
    int? first;
    int last = 0;
    int count = 0;
    int outside = 0;
    bool any = false;

    void close() {
      if (first != null && count >= policy.minFixes && last - first! >= policy.minDwellMs) {
        if (best == null || last - first! > best!.last - best!.first) best = (first: first!, last: last, count: count);
      }
      first = null;
      count = 0;
      outside = 0;
    }

    for (final _Fix f in fixes) {
      if (first != null && f.ms - last > policy.maxGapMs) close();
      if (area.contains(f.lat, f.lng)) {
        any = true;
        first ??= f.ms;
        last = f.ms;
        count++;
        outside = 0;
      } else if (first != null) {
        outside++;
        if (outside > policy.outsideTolerance) close();
      }
    }
    close();
    if (any) entered();
    return best;
  }

  static bool _hasSimulatedPoints(Map trip) {
    final Object? route = trip['route'];
    final Iterable<Object?> raw = route is Map ? route.values : (route is List ? route : const <Object?>[]);
    for (final Object? p in raw) {
      if (p is Map && p['is_simulation'] == true) return true;
    }
    return false;
  }

  static String _tripDay(Map trip, List<_Fix> fixes) {
    final String d = (trip['date'] ?? '').toString();
    if (d.length >= 10) return d.substring(0, 10);
    final int? start = _ms(trip['server_start_time'] ?? trip['timestamp']);
    if (start != null) return manilaDay(start);
    if (fixes.isNotEmpty) return manilaDay(fixes.first.ms);
    return '';
  }

  /// Detects verified visits for trips in [trips] (`driver_routes` snapshot) whose visit day
  /// (Asia/Manila, first in-area fix) lies in [start]..[end] (calendar days, inclusive).
  /// [areaFilter] null or "All Areas" keeps every area.
  static VisitSummary detect({
    required Map trips,
    required List<AreaGeofence> areas,
    required DateTime start,
    required DateTime end,
    String? areaFilter,
    VisitPolicy policy = const VisitPolicy(),
    bool includeSimulated = false,
  }) {
    final String from = _day(start);
    final String to = _day(end);
    bool inRange(String day) => day.isNotEmpty && day.compareTo(from) >= 0 && day.compareTo(to) <= 0;
    final bool allAreas = areaFilter == null || areaFilter == 'All Areas';
    final List<AreaGeofence> targets =
        areas.where((AreaGeofence a) => a.isTruckStop && (allAreas || a.name == areaFilter)).toList();

    final List<CollectionVisit> visits = <CollectionVisit>[];
    final Map<String, int> unconfirmed = <String, int>{};
    int considered = 0;
    int noEvidence = 0;

    trips.forEach((Object? key, Object? value) {
      if (value is! Map || TripArchive.isArchived(value)) return;
      final bool simTrip = value['is_simulation'] == true || _hasSimulatedPoints(value);
      if (simTrip && !includeSimulated) return;
      // a simulated drive-by counts once it has two fixes inside the area (no dwell), so the status change can be tested
      final VisitPolicy tripPolicy = simTrip
          ? VisitPolicy(minFixes: 2, minDwellMs: 0, maxAccuracyM: 1000, maxGapMs: policy.maxGapMs, outsideTolerance: policy.outsideTolerance)
          : policy;
      final List<_Fix> fixes = _activeFixes(value, tripPolicy, includeSimulated: simTrip);
      final String tripDay = _tripDay(value, fixes);
      final bool tripInRange = inRange(tripDay) || fixes.any((_Fix f) => inRange(manilaDay(f.ms)));
      if (!tripInRange) return;
      considered++;
      if (fixes.isEmpty) {
        noEvidence++;
        return;
      }
      final String tripId = key.toString();
      for (final AreaGeofence area in targets) {
        bool entered = false;
        final ({int first, int last, int count})? stay = _bestStay(fixes, area, tripPolicy, () => entered = true);
        if (stay != null) {
          if (!inRange(manilaDay(stay.first))) continue;
          visits.add(CollectionVisit(
            tripId: tripId,
            area: area.name,
            firstFixMs: stay.first,
            lastFixMs: stay.last,
            fixes: stay.count,
            truckId: (value['truck_id'] ?? value['truckId'])?.toString(),
            driverId: (value['driver_id'] ?? value['driverId'])?.toString(),
            simulated: simTrip,
          ));
        } else if (entered) {
          unconfirmed[area.name] = (unconfirmed[area.name] ?? 0) + 1;
        }
      }
    });

    visits.sort((CollectionVisit a, CollectionVisit b) => b.firstFixMs.compareTo(a.firstFixMs));
    return VisitSummary(
      visits: visits,
      unconfirmedPasses: unconfirmed,
      tripsConsidered: considered,
      tripsWithoutEvidence: noEvidence,
    );
  }
}
