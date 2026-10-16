/// Historical path comparison for Collection Route Optimization.
///
/// Objective: among RECORDED trips that served the SAME set of areas, find the one with the
/// shortest recorded travel distance, and offer its area order as a suggested stop sequence.
///
///  * Data source: `driver_routes/{trip}/route` GPS fixes, validated exactly like the verified
///    collection visits (`CollectionVisits.activeFixesOf`: ACTIVE only, no simulation, accuracy
///    <= 40 m, nothing after the collection was finalized).
///  * Coverage: the areas with a verified visit in the trip (`CollectionVisits.detect`), in the
///    order the truck first stayed there. Trips are comparable only with an identical area set.
///  * Measured segment: from entering the first served area to leaving the last one, so travel
///    to/from the depot does not distort the comparison.
///  * Metrics: recorded distance = sum of great-circle distances between consecutive fixes of
///    the segment (the length of the recorded trace; NOT a road-network distance, and not a
///    guarantee the roads are passable today); duration = segment time; time inside served areas
///    (verified stays) is reported separately from the remaining travel time.
///  * Quality checks (a failing trip is excluded and the reason counted): at least
///    [PathQuality.minFixes] fixes in the segment, no gap above [PathQuality.maxGapMs], no jump
///    implying more than [PathQuality.maxSpeedKmh], at least 2 served areas.
///  * Baseline: the median recorded distance of the comparable valid trips. A comparison needs at
///    least [PathQuality.minComparableTrips] valid trips; otherwise it is reported as
///    insufficient history - no recommendation is produced.
///  * Algorithm: selection of the minimum over observed trips. It is not a solver and claims no
///    optimality beyond "shortest among the recorded trips compared".
library;

import 'dart:math' as math;

import 'collection_visits.dart';

class PathQuality {
  const PathQuality({
    this.minFixes = 30,
    this.maxGapMs = 3 * 60 * 1000,
    this.maxSpeedKmh = 80.0,
    this.minComparableTrips = 2,
  });

  final int minFixes;
  final int maxGapMs;
  final double maxSpeedKmh;
  final int minComparableTrips;
}

class RecordedPath {
  const RecordedPath({
    required this.tripId,
    required this.areaOrder,
    required this.startMs,
    required this.endMs,
    required this.distanceKm,
    required this.inAreaMs,
    required this.coordinates,
    this.truckId,
  });

  final String tripId;
  final List<String> areaOrder;
  final int startMs;
  final int endMs;
  final double distanceKm;
  final int inAreaMs;

  /// [lng, lat] pairs of the measured segment (for drawing the recorded path).
  final List<List<double>> coordinates;
  final String? truckId;

  int get durationMs => endMs - startMs;
  int get travelMs => math.max(0, durationMs - inAreaMs);
  String get coverageKey => (List<String>.from(areaOrder)..sort()).join(' | ');
}

class PathComparison {
  const PathComparison({
    required this.coverage,
    required this.paths,
    required this.medianKm,
  });

  /// Areas served by every path of this group (sorted).
  final List<String> coverage;

  /// Valid paths, shortest recorded distance first.
  final List<RecordedPath> paths;
  final double medianKm;

  RecordedPath get shortest => paths.first;
  double get savingVsMedianKm => medianKm - shortest.distanceKm;

  String get basis =>
      'Shortest recorded distance among ${paths.length} valid trips that served the same '
      '${coverage.length} areas (median ${medianKm.toStringAsFixed(1)} km). Recorded GPS paths; '
      'check current road access before use.';
}

class PathAnalysis {
  const PathAnalysis({
    required this.comparisons,
    required this.validPaths,
    required this.rejected,
    required this.tripsExamined,
  });

  /// Groups with enough comparable valid trips, most trips first.
  final List<PathComparison> comparisons;

  /// Every valid path (including those without a comparable partner).
  final List<RecordedPath> validPaths;

  /// Reason -> number of trips excluded.
  final Map<String, int> rejected;
  final int tripsExamined;

  bool get hasComparison => comparisons.isNotEmpty;

  /// Comparisons whose coverage includes [area].
  List<PathComparison> including(String area) =>
      comparisons.where((PathComparison c) => c.coverage.contains(area)).toList();
}

class PathComparisonEngine {
  PathComparisonEngine._();

  static double distanceKm(double lat1, double lng1, double lat2, double lng2) {
    const double r = 6371.0;
    final double dLat = (lat2 - lat1) * math.pi / 180;
    final double dLng = (lng2 - lng1) * math.pi / 180;
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
  }

  static PathAnalysis analyze({
    required Map trips,
    required List<AreaGeofence> areas,
    required DateTime start,
    required DateTime end,
    PathQuality quality = const PathQuality(),
  }) {
    final Map<String, int> rejected = <String, int>{};
    void reject(String reason) => rejected[reason] = (rejected[reason] ?? 0) + 1;
    final List<RecordedPath> valid = <RecordedPath>[];
    int examined = 0;

    trips.forEach((Object? key, Object? trip) {
      if (trip is! Map || trip['is_simulation'] == true) return;
      final VisitSummary visits = CollectionVisits.detect(
        trips: <Object?, Object?>{key: trip},
        areas: areas,
        start: start,
        end: end,
      );
      if (visits.tripsConsidered == 0) return; // outside the period
      examined++;
      final List<CollectionVisit> v = List<CollectionVisit>.from(visits.visits)
        ..sort((CollectionVisit a, CollectionVisit b) => a.firstFixMs.compareTo(b.firstFixMs));
      if (v.length < 2) {
        reject('fewer than 2 verified area visits');
        return;
      }
      final int segStart = v.first.firstFixMs;
      final int segEnd = v.map((CollectionVisit x) => x.lastFixMs).reduce(math.max);
      final List<({int ms, double lat, double lng})> fixes = CollectionVisits.activeFixesOf(trip)
          .where((({int ms, double lat, double lng}) f) => f.ms >= segStart && f.ms <= segEnd)
          .toList();
      if (fixes.length < quality.minFixes) {
        reject('too few GPS points (< ${quality.minFixes})');
        return;
      }
      double km = 0;
      String? problem;
      for (int i = 1; i < fixes.length; i++) {
        final int dt = fixes[i].ms - fixes[i - 1].ms;
        final double d = distanceKm(fixes[i - 1].lat, fixes[i - 1].lng, fixes[i].lat, fixes[i].lng);
        if (dt > quality.maxGapMs) {
          problem = 'GPS gap longer than ${quality.maxGapMs ~/ 60000} min';
          break;
        }
        if (dt > 0 && d / (dt / 3600000.0) > quality.maxSpeedKmh) {
          problem = 'GPS jump (implied speed > ${quality.maxSpeedKmh.toStringAsFixed(0)} km/h)';
          break;
        }
        km += d;
      }
      if (problem != null) {
        reject(problem);
        return;
      }
      valid.add(RecordedPath(
        tripId: key.toString(),
        areaOrder: v.map((CollectionVisit x) => x.area).toList(),
        startMs: segStart,
        endMs: segEnd,
        distanceKm: km,
        inAreaMs: v.fold(0, (int s, CollectionVisit x) => s + x.dwellMs),
        coordinates: fixes.map((({int ms, double lat, double lng}) f) => <double>[f.lng, f.lat]).toList(),
        truckId: (trip['truck_id'] ?? trip['truckId'])?.toString(),
      ));
    });

    final Map<String, List<RecordedPath>> groups = <String, List<RecordedPath>>{};
    for (final RecordedPath p in valid) {
      groups.putIfAbsent(p.coverageKey, () => <RecordedPath>[]).add(p);
    }
    final List<PathComparison> comparisons = <PathComparison>[];
    groups.forEach((String k, List<RecordedPath> ps) {
      if (ps.length < quality.minComparableTrips) return;
      ps.sort((RecordedPath a, RecordedPath b) => a.distanceKm.compareTo(b.distanceKm));
      final List<double> d = ps.map((RecordedPath p) => p.distanceKm).toList();
      final double median = d.length.isOdd ? d[d.length ~/ 2] : (d[d.length ~/ 2 - 1] + d[d.length ~/ 2]) / 2;
      comparisons.add(PathComparison(coverage: k.split(' | '), paths: ps, medianKm: median));
    });
    comparisons.sort((PathComparison a, PathComparison b) => b.paths.length.compareTo(a.paths.length));
    return PathAnalysis(comparisons: comparisons, validPaths: valid, rejected: rejected, tripsExamined: examined);
  }
}
