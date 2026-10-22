import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/models/route_assignment.dart';
import 'package:garbage_tracking_app/screens/route_assignments_screen.dart';
import 'package:garbage_tracking_app/services/route_assignment_service.dart';
import 'package:intl/intl.dart';

class _FakeService extends RouteAssignmentService {
  _FakeService(this.items);
  final List<RouteAssignment> items;

  @override
  Future<AssignmentResult<AssignmentList>> list({required String startDate, required String endDate, int? driverId}) async =>
      AssignmentResult.ok(AssignmentList(items: items, summary: AssignmentSummary.fromItems(items, startDate), today: startDate));
}

void main() {
  final String today = DateFormat('yyyy-MM-dd').format(DateTime.now());
  final String tomorrow = DateFormat('yyyy-MM-dd').format(DateTime.now().add(const Duration(days: 1)));
  RouteAssignment a(int id, String date, AssignmentStatus s, List<String> areas, {String? notes}) => RouteAssignment(
        id: id,
        date: date,
        driverId: id,
        truckId: 'GT-00$id',
        status: s,
        areas: <AssignmentArea>[for (final String n in areas) AssignmentArea(key: n, name: n)],
        trips: s == AssignmentStatus.completed ? const <AssignmentTrip>[AssignmentTrip(tripId: 't', status: 'COMPLETED')] : const <AssignmentTrip>[],
        notes: notes,
      );
  final List<RouteAssignment> items = <RouteAssignment>[
    a(1, today, AssignmentStatus.pending, <String>['Purok 2', 'Central (Purok 1)', 'Ayala Highway', 'Riverside'], notes: 'Start at the barangay hall'),
    a(2, today, AssignmentStatus.completed, <String>['Brixton Homes']),
    a(3, tomorrow, AssignmentStatus.cancelled, <String>['Purok Paraiso', 'T.M. Kalaw Street']),
  ];

  for (final Size size in <Size>[const Size(1500, 1000), const Size(900, 1000), const Size(360, 2400)]) {
    testWidgets('assignments render grouped by day without layout errors at ${size.width.toInt()} px', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: RouteAssignmentsScreen(service: _FakeService(items), onBack: () {})));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(t.takeException(), isNull);
      expect(find.textContaining('Today ·'), findsOneWidget);
      expect(find.textContaining('Tomorrow ·'), findsOneWidget);
      expect(find.text('GT-001'), findsOneWidget);
      expect(find.text('Start at the barangay hall'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget); // only the pending one is editable

      // the Completed tile filters the list
      await t.tap(find.text('Completed').first);
      await t.pump();
      expect(find.text('GT-002'), findsOneWidget);
      expect(find.text('GT-001'), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(minutes: 2));
    });
  }

  testWidgets('empty period shows the call to action', (t) async {
    t.view.physicalSize = const Size(360, 780);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: RouteAssignmentsScreen(service: _FakeService(const <RouteAssignment>[]))));
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.text('No assignments in this period'), findsOneWidget);
    expect(find.text('Create the first assignment'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(minutes: 2));
  });
}
