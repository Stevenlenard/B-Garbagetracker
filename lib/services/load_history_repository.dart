import 'package:flutter/foundation.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';

import '../api/api_service.dart';
import '../models/driver_trip.dart';
import '../models/user.dart';
import '../utils/load_history.dart';
import 'driver_route_history_service.dart';

/// Outcome of one load of the finalized-collection dataset.
class LoadHistoryResult {
  const LoadHistoryResult({
    required this.loads,
    required this.unfinished,
    required this.failedSources,
    required this.allSources,
  });

  /// Finalized collections, one per trip id (what Load History and the Waste
  /// Collection Summary both count).
  final List<DriverTrip> loads;

  /// Trips that were seen but are NOT counted (collection not finalized with FULL).
  final List<DriverTrip> unfinished;

  final List<String> failedSources;
  final int allSources;

  /// Every source failed: the result says nothing about whether collections exist, so
  /// the UI must show an error, never "0 trips".
  bool get isError => failedSources.length >= allSources;

  /// Some sources failed: totals may be incomplete.
  bool get isPartial => failedSources.isNotEmpty && !isError;
}

/// Loads trips from every source ONCE and normalizes them with [LoadHistory], so the
/// Waste Collection Summary and the Load History list can never disagree about what a
/// load is. Sources are injected so the logic is testable without a network.
class LoadHistoryRepository {
  LoadHistoryRepository({
    required this.fetchMysql,
    required this.fetchFirebaseRoutes,
    required this.fetchMeasuredWeights,
  });

  /// get_load_history.php (already finalized-only on the server).
  final Future<List<DriverTrip>> Function(DateTime? start, DateTime? end) fetchMysql;

  /// Firebase driver_routes (frozen `collection` record and route points) + route history.
  final Future<List<DriverTrip>> Function() fetchFirebaseRoutes;

  /// Firebase load_history node (measured weights).
  final Future<List<DriverTrip>> Function() fetchMeasuredWeights;

  factory LoadHistoryRepository.standard() {
    final ApiService api = ApiService();
    return LoadHistoryRepository(
      fetchMysql: (DateTime? start, DateTime? end) async {
        final DateFormat f = DateFormat('yyyy-MM-dd');
        // The endpoint defaults to the last 30 days when no date is given: ask for the
        // whole range explicitly when the period is open-ended.
        final response = await api.getLoadHistory(
          startDate: start != null ? f.format(start) : '2000-01-01',
          endDate: end != null ? f.format(end) : f.format(DateTime.now().add(const Duration(days: 1))),
        );
        final Object? data = response.data;
        if (data is! Map || data['success'] != true) {
          throw StateError('load history request failed');
        }
        final List raw = data['trips'] as List? ?? <dynamic>[];
        return raw.map((Object? j) => DriverTrip.fromJson(Map<String, dynamic>.from(j as Map))).toList();
      },
      fetchFirebaseRoutes: () => DriverRouteHistoryService.fetchRouteHistory(
        currentUser: UserData(userId: 0, name: 'Admin', email: '', role: 'Admin', approvalStatus: 'APPROVED'),
        startDate: null,
        endDate: null,
        // A trip that reached FULL with no movement is still a load: do not pre-filter
        // zero-movement trips here, LoadHistory.isLoad decides.
        includeAllTrips: true,
      ),
      fetchMeasuredWeights: () async {
        final DataSnapshot snap = await FirebaseDatabase.instance.ref('load_history').get();
        final List<DriverTrip> out = <DriverTrip>[];
        if (snap.exists && snap.value is Map) {
          (snap.value as Map).forEach((Object? key, Object? val) {
            if (val is Map) {
              final Map<String, dynamic> json = Map<String, dynamic>.from(val);
              json['trip_id'] = key.toString();
              out.add(DriverTrip.fromJson(json));
            }
          });
        }
        return out;
      },
    );
  }

  Future<LoadHistoryResult> load({DateTime? start, DateTime? end}) async {
    final List<DriverTrip> all = <DriverTrip>[];
    final List<String> failed = <String>[];

    Future<void> run(String name, Future<List<DriverTrip>> Function() f) async {
      try {
        all.addAll(await f());
      } catch (e) {
        failed.add(name);
        debugPrint('[LOAD HISTORY] source "$name" failed: $e');
      }
    }

    await Future.wait(<Future<void>>[
      run('mysql', () => fetchMysql(start, end)),
      run('firebase', fetchFirebaseRoutes),
      run('measured', fetchMeasuredWeights),
    ]);

    final List<DriverTrip> loads = LoadHistory.uniqueLoads(all);
    final Set<String> loadIds = loads.map((DriverTrip t) => t.tripId).toSet();
    final Map<String, DriverTrip> unfinished = <String, DriverTrip>{};
    for (final DriverTrip t in all) {
      if (loadIds.contains(t.tripId) || t.isFinalizedCollection) continue;
      // Only genuine trips (not weight-only stubs from the load_history node).
      if (t.totalDistanceKm > 0 || t.points.isNotEmpty || t.hasRecordedStartTime) {
        unfinished.putIfAbsent(t.tripId, () => t);
      }
    }

    return LoadHistoryResult(
      loads: loads,
      unfinished: unfinished.values.toList(),
      failedSources: failed,
      allSources: 3,
    );
  }
}
