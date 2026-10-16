import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/models/route_assignment.dart';
import 'package:garbage_tracking_app/services/route_assignment_service.dart';

RouteAssignment a(int id, String date, String status, {List<String> areas = const <String>['Purok 2'], List<String> trips = const <String>[]}) =>
    RouteAssignment.fromJson(<String, Object?>{
      'assignment_id': id,
      'assignment_date': date,
      'driver_id': 11,
      'truck_id': 'GT-007',
      'status': status,
      'areas': <Object?>[for (final String n in areas) <String, String>{'key': n.toLowerCase(), 'name': n}],
      'trips': <Object?>[for (final String t in trips) <String, String>{'trip_id': t, 'status': 'FULL'}],
    });

void main() {
  group('parsing and status', () {
    test('server statuses map to the five labels; only PENDING is editable', () {
      expect(assignmentStatusLabel(a(1, '2026-10-13', 'PENDING').status), 'Pending');
      expect(assignmentStatusLabel(a(1, '2026-10-13', 'IN_PROGRESS').status), 'In Progress');
      expect(assignmentStatusLabel(a(1, '2026-10-13', 'COMPLETED').status), 'Completed');
      expect(assignmentStatusLabel(a(1, '2026-10-13', 'MISSED').status), 'Missed');
      expect(assignmentStatusLabel(a(1, '2026-10-13', 'CANCELLED').status), 'Cancelled');
      expect(a(1, '2026-10-13', 'PENDING').isEditable, isTrue);
      expect(a(1, '2026-10-13', 'IN_PROGRESS').isEditable, isFalse);
    });

    test('a FULL linked trip is shown as the server says (IN_PROGRESS), never derived on device', () {
      final RouteAssignment x = a(1, '2026-10-13', 'IN_PROGRESS', trips: <String>['t1']);
      expect(x.status, AssignmentStatus.inProgress);
      expect(x.trips.single.status, 'FULL');
    });
  });

  group('HTTP results', () {
    test('401 / 403 / 503 / 409 are reported, never treated as success', () {
      expect(RouteAssignmentService.interpret(401, null).failure, AssignmentFailure.unauthorized);
      expect(RouteAssignmentService.interpret(403, null).failure, AssignmentFailure.forbidden);
      expect(RouteAssignmentService.interpret(503, <String, Object?>{'success': false}).failure, AssignmentFailure.notConfigured);
      final AssignmentResult<Map<dynamic, dynamic>> c =
          RouteAssignmentService.interpret(409, <String, Object?>{'success': false, 'message': 'This driver already has an assignment on that date.'});
      expect(c.failure, AssignmentFailure.conflict);
      expect(c.message, contains('already has an assignment'));
    });

    test('tables missing and server refusals are distinct from success', () {
      expect(RouteAssignmentService.interpret(200, <String, Object?>{'success': false, 'available': false}).failure, AssignmentFailure.notSetUp);
      expect(RouteAssignmentService.interpret(200, <String, Object?>{'success': false, 'message': 'A driver is required.'}).message, 'A driver is required.');
      expect(RouteAssignmentService.interpret(200, 'not json').failure, AssignmentFailure.network);
      expect(RouteAssignmentService.interpret(200, <String, Object?>{'success': true}).isOk, isTrue);
    });
  });

  group('summary (same rules as the server)', () {
    test('due excludes cancelled and future; rate = completed due / due', () {
      final AssignmentSummary s = AssignmentSummary.fromItems(<RouteAssignment>[
        a(1, '2026-10-10', 'MISSED'),
        a(2, '2026-10-11', 'IN_PROGRESS'),
        a(3, '2026-10-12', 'COMPLETED'),
        a(4, '2026-10-12', 'CANCELLED'),
        a(5, '2026-10-15', 'PENDING'),
      ], '2026-10-13');
      expect(s.due, 3);
      expect(s.completionRate, 33.3);
      expect(s.total, 5);
    });

    test('no assignments due -> Not available (null), never 0% or 100%', () {
      expect(AssignmentSummary.fromItems(<RouteAssignment>[a(5, '2026-10-15', 'PENDING')], '2026-10-13').completionRate, isNull);
      expect(AssignmentSummary.fromItems(const <RouteAssignment>[], '2026-10-13').completionRate, isNull);
    });
  });

  group('assigned-area coverage (separate from completion)', () {
    test('only verified visits by the assignment\'s OWN trips count', () {
      final List<RouteAssignment> items = <RouteAssignment>[
        a(1, '2026-10-12', 'COMPLETED', areas: <String>['Purok 2', 'Purok 3'], trips: <String>['t1']),
      ];
      final AssignedAreaCoverage c = AssignedAreaCoverage.compute(items, <String, Set<String>>{
        't1': <String>{'Purok 2'},
        'other': <String>{'Purok 3'}, // another trip's visit does not count
      });
      expect(c.assignedAreas, 2);
      expect(c.verifiedAreas, 1);
      expect(c.percent, 50);
    });

    test('COMPLETED with no verified visits is 0% coverage (completion does not imply service)', () {
      final AssignedAreaCoverage c = AssignedAreaCoverage.compute(
          <RouteAssignment>[a(1, '2026-10-12', 'COMPLETED', trips: <String>['t1'])], const <String, Set<String>>{});
      expect(c.verifiedAreas, 0);
      expect(c.percent, 0);
    });

    test('pending, missed and cancelled assignments are not in the coverage denominator', () {
      final AssignedAreaCoverage c = AssignedAreaCoverage.compute(<RouteAssignment>[
        a(1, '2026-10-15', 'PENDING'),
        a(2, '2026-10-10', 'MISSED'),
        a(3, '2026-10-12', 'CANCELLED'),
      ], const <String, Set<String>>{});
      expect(c.assignedAreas, 0);
      expect(c.percent, isNull);
    });

    test('area filter narrows to one canonical area name', () {
      final List<RouteAssignment> items = <RouteAssignment>[
        a(1, '2026-10-12', 'IN_PROGRESS', areas: <String>['Purok 2', 'Central (Purok 1)'], trips: <String>['t1']),
      ];
      final AssignedAreaCoverage c = AssignedAreaCoverage.compute(items, <String, Set<String>>{'t1': <String>{'Central (Purok 1)'}},
          areaFilter: 'Central (Purok 1)');
      expect(c.assignedAreas, 1);
      expect(c.verifiedAreas, 1);
      expect(AssignedAreaCoverage.includesArea(items.first, 'Purok 3'), isFalse);
    });
  });
}
