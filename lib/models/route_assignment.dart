/// Route assignment as returned by backend/get_assignments.php.
///
/// Status is computed by the server (assignment_lib.php) and is never derived on the device:
///   PENDING, IN_PROGRESS (FULL stays here), COMPLETED (trip(s) COMPLETED), MISSED, CANCELLED.
library;

import '../services/service_area_service.dart';

enum AssignmentStatus { pending, inProgress, completed, missed, cancelled, unknown }

AssignmentStatus assignmentStatusFrom(String? raw) {
  switch ((raw ?? '').toUpperCase()) {
    case 'PENDING':
      return AssignmentStatus.pending;
    case 'IN_PROGRESS':
      return AssignmentStatus.inProgress;
    case 'COMPLETED':
      return AssignmentStatus.completed;
    case 'MISSED':
      return AssignmentStatus.missed;
    case 'CANCELLED':
      return AssignmentStatus.cancelled;
    default:
      return AssignmentStatus.unknown;
  }
}

String assignmentStatusLabel(AssignmentStatus s) {
  switch (s) {
    case AssignmentStatus.pending:
      return 'Pending';
    case AssignmentStatus.inProgress:
      return 'In Progress';
    case AssignmentStatus.completed:
      return 'Completed';
    case AssignmentStatus.missed:
      return 'Missed';
    case AssignmentStatus.cancelled:
      return 'Cancelled';
    case AssignmentStatus.unknown:
      return 'Unknown';
  }
}

class AssignmentArea {
  const AssignmentArea({required this.key, required this.name});
  final String key;
  final String name;

  Map<String, String> toJson() => <String, String>{'key': key, 'name': name};
}

class AssignmentTrip {
  const AssignmentTrip({required this.tripId, required this.status});
  final String tripId;
  final String status;
}

class RouteAssignment {
  const RouteAssignment({
    required this.id,
    required this.date,
    required this.driverId,
    required this.truckId,
    required this.status,
    required this.areas,
    required this.trips,
    this.notes,
    this.tripsInterrupted = 0,
  });

  final int id;
  final String date; // yyyy-MM-dd, Asia/Manila
  final int driverId;
  final String truckId;
  final AssignmentStatus status;
  final List<AssignmentArea> areas;
  final List<AssignmentTrip> trips;
  final String? notes;
  final int tripsInterrupted;

  /// The server allows edit/cancel only while PENDING.
  bool get isEditable => status == AssignmentStatus.pending;

  static int _int(Object? v) => v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;

  factory RouteAssignment.fromJson(Map<dynamic, dynamic> j) => RouteAssignment(
        id: _int(j['assignment_id']),
        date: (j['assignment_date'] ?? '').toString(),
        driverId: _int(j['driver_id']),
        truckId: (j['truck_id'] ?? '').toString(),
        status: assignmentStatusFrom(j['status']?.toString()),
        notes: j['notes']?.toString(),
        tripsInterrupted: _int(j['trips_interrupted']),
        areas: <AssignmentArea>[
          for (final Object? a in (j['areas'] is List ? j['areas'] as List : const <Object?>[]))
            if (a is Map) AssignmentArea(key: (a['key'] ?? '').toString(), name: (a['name'] ?? '').toString()),
        ],
        trips: <AssignmentTrip>[
          for (final Object? t in (j['trips'] is List ? j['trips'] as List : const <Object?>[]))
            if (t is Map) AssignmentTrip(tripId: (t['trip_id'] ?? '').toString(), status: (t['status'] ?? '').toString()),
        ],
      );
}

class AssignmentSummary {
  const AssignmentSummary({
    required this.total,
    required this.due,
    required this.completed,
    required this.inProgress,
    required this.pending,
    required this.missed,
    required this.cancelled,
    required this.completionRate,
  });

  final int total;
  final int due;
  final int completed;
  final int inProgress;
  final int pending;
  final int missed;
  final int cancelled;

  /// Completed due ÷ due (server). null = nothing due ("Not available").
  final double? completionRate;

  static const AssignmentSummary empty =
      AssignmentSummary(total: 0, due: 0, completed: 0, inProgress: 0, pending: 0, missed: 0, cancelled: 0, completionRate: null);

  /// Same rules as the server (assignment_lib.php gt_assignment_summary): due = not cancelled
  /// and dated [today] or earlier; rate = completed due ÷ due, null when nothing is due.
  /// Used when the list is narrowed on the device (e.g. to one area).
  factory AssignmentSummary.fromItems(List<RouteAssignment> items, String today) {
    int count(AssignmentStatus s) => items.where((RouteAssignment a) => a.status == s).length;
    final List<RouteAssignment> due =
        items.where((RouteAssignment a) => a.status != AssignmentStatus.cancelled && a.date.compareTo(today) <= 0).toList();
    final int dueCompleted = due.where((RouteAssignment a) => a.status == AssignmentStatus.completed).length;
    return AssignmentSummary(
      total: items.length,
      due: due.length,
      completed: count(AssignmentStatus.completed),
      inProgress: count(AssignmentStatus.inProgress),
      pending: count(AssignmentStatus.pending),
      missed: count(AssignmentStatus.missed),
      cancelled: count(AssignmentStatus.cancelled),
      completionRate: due.isEmpty ? null : (dueCompleted * 1000 / due.length).round() / 10,
    );
  }

  factory AssignmentSummary.fromJson(Map<dynamic, dynamic>? j) {
    if (j == null) return empty;
    int n(String k) => RouteAssignment._int(j[k]);
    final Object? r = j['completion_rate'];
    return AssignmentSummary(
      total: n('total'),
      due: n('due'),
      completed: n('completed'),
      inProgress: n('in_progress'),
      pending: n('pending'),
      missed: n('missed'),
      cancelled: n('cancelled'),
      completionRate: r is num ? r.toDouble() : double.tryParse(r?.toString() ?? ''),
    );
  }
}

/// Assigned-area coverage, kept SEPARATE from operational completion: of the areas assigned in
/// COMPLETED and IN_PROGRESS assignments, how many have a verified collection visit by one of
/// that assignment's own linked trips. [visitedByTrip] = trip id -> canonical area names with a
/// verified visit (utils/collection_visits.dart). Area names are compared canonically.
class AssignedAreaCoverage {
  const AssignedAreaCoverage({required this.assignedAreas, required this.verifiedAreas, required this.assignments});
  final int assignedAreas;
  final int verifiedAreas;
  final int assignments;

  double? get percent => assignedAreas == 0 ? null : verifiedAreas * 100.0 / assignedAreas;

  static String _canon(String name) => ServiceAreaService.canonicalizeAreaName(name) ?? name.trim();

  /// [areaFilter] null / "All Areas" = every assigned area; otherwise only that area.
  static bool includesArea(RouteAssignment a, String? areaFilter) =>
      areaFilter == null || areaFilter == 'All Areas' || a.areas.any((AssignmentArea x) => _canon(x.name) == areaFilter);

  static AssignedAreaCoverage compute(List<RouteAssignment> items, Map<String, Set<String>> visitedByTrip, {String? areaFilter}) {
    final bool all = areaFilter == null || areaFilter == 'All Areas';
    int assigned = 0;
    int verified = 0;
    int count = 0;
    for (final RouteAssignment a in items) {
      if (a.status != AssignmentStatus.completed && a.status != AssignmentStatus.inProgress) continue;
      if (!includesArea(a, areaFilter)) continue;
      count++;
      final Set<String> visited = <String>{
        for (final AssignmentTrip t in a.trips) ...?visitedByTrip[t.tripId],
      };
      for (final String area in a.areas.map((AssignmentArea x) => _canon(x.name)).where((String n) => all || n == areaFilter).toSet()) {
        assigned++;
        if (visited.contains(area)) verified++;
      }
    }
    return AssignedAreaCoverage(assignedAreas: assigned, verifiedAreas: verified, assignments: count);
  }
}
