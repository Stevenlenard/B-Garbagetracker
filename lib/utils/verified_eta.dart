import '../services/service_area_service.dart';
import 'collection_visits.dart';
import 'eta_evaluation.dart';
import 'trip_archive.dart';

/// The arrival-time evaluation shared by Analytics (ETA Performance) and Collection Route Optimization:
/// each "on the way" alert is compared with the VERIFIED (green) visit of the same trip and area.
class VerifiedEta {
  VerifiedEta._();

  /// Trips that have ended (FULL, COMPLETED, finished or archived).
  static Set<String> closedTripIds(Map trips) {
    final Set<String> out = <String>{};
    trips.forEach((Object? key, Object? v) {
      if (v is! Map) return;
      final String s = (v['route_status'] ?? v['status'] ?? '').toString().toUpperCase();
      if (s == 'FULL' || s == 'COMPLETED' || s == 'FINISHED' || v['collection_finalized'] == true || TripArchive.isArchived(v)) {
        out.add(key.toString());
      }
    });
    return out;
  }

  /// The notifications with their arrivals replaced by the VERIFIED (green) visits: an arrival
  /// is the first fix of a stay of at least 2 accurate GPS fixes, at least 40 seconds apart,
  /// inside the area while ACTIVE (VisitPolicy) - the same rule that turns an area green on
  /// Collection Route Optimization. Driver-app arrival alerts no longer count on their own.
  static Object? withVerifiedArrivals(Object? rawNotifications, {required Map trips, required List<AreaGeofence> areas}) {
    if (rawNotifications is! Map) return rawNotifications;
    final Map<String, Object?> out = <String, Object?>{};
    rawNotifications.forEach((Object? k, Object? v) {
      if (v is Map && (v['type'] ?? '').toString() == 'auto_arrival') return;
      out[k.toString()] = v;
    });
    if (trips.isEmpty || areas.isEmpty) return out;
    final List<CollectionVisit> visits = CollectionVisits.detect(
      trips: trips,
      areas: areas,
      start: DateTime(2000),
      end: DateTime.now().add(const Duration(days: 1)),
    ).visits;
    for (final CollectionVisit v in visits) {
      if (v.simulated) continue;
      out['verified_${v.tripId}_${v.area}'] = <String, Object?>{
        'type': 'auto_arrival',
        'purok': v.area,
        'trip_id': v.tripId,
        'timestamp': v.firstFixMs,
      };
    }
    return out;
  }

  /// Valid ETAs only: an alert counts when the truck really reached that area on that trip
  /// (verified, green visit), or while its trip is still running and it can still arrive.
  /// Alerts for areas the truck never reached are invalid and are left out.
  static List<EtaVisit> visits(
    Object? rawNotifications, {
    required Map trips,
    required List<AreaGeofence> areas,
    required int nowMs,
    Set<String>? closedTripIds,
  }) {
    return allVisits(rawNotifications, trips: trips, areas: areas, nowMs: nowMs, closedTripIds: closedTripIds)
        .where((EtaVisit v) => v.status == EtaVisitStatus.evaluated || v.status == EtaVisitStatus.awaiting)
        .toList();
  }

  /// Every "on the way" alert with its outcome, including those the truck never followed with a verified arrival
  /// (trip ended first, or no arrival recorded): the per-area history shows what residents were told.
  static List<EtaVisit> allVisits(
    Object? rawNotifications, {
    required Map trips,
    required List<AreaGeofence> areas,
    required int nowMs,
    Set<String>? closedTripIds,
  }) {
    return EtaEvaluation.build(
      withVerifiedArrivals(rawNotifications, trips: trips, areas: areas),
      nowMs: nowMs,
      canonicalize: (String raw) => ServiceAreaService.canonicalizeAreaName(raw) ?? raw,
      closedTripIds: closedTripIds ?? VerifiedEta.closedTripIds(trips),
    ).where((EtaVisit v) => v.status != EtaVisitStatus.noEstimate).toList();
  }
}
