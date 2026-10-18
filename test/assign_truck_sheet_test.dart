import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/widgets/assign_truck_sheet.dart';

void main() {
  final Map<String, dynamic> registry = <String, dynamic>{
    'GT-001': <String, dynamic>{'plateNumber': 'AAA 111'},
    'GT-003': <String, dynamic>{'plateNumber': 'BBB 222'},
    'GT-002': <String, dynamic>{},
    'Unknown': <String, dynamic>{},
  };
  final List<dynamic> users = <dynamic>[
    <String, dynamic>{'user_id': 19, 'name': 'Darna', 'role': 'driver', 'preferred_truck': 'GT-003', 'is_archived': 0},
    <String, dynamic>{'user_id': 20, 'name': 'Arian Joy', 'role': 'driver', 'preferred_truck': null, 'is_archived': 0},
    <String, dynamic>{'user_id': 15, 'name': 'Old Driver', 'role': 'driver', 'preferred_truck': 'GT-001', 'is_archived': 1},
    <String, dynamic>{'user_id': 24, 'name': 'Resident', 'role': 'resident', 'preferred_truck': 'GT-002'},
  ];

  test('truck list: placeholders hidden, trucks of active drivers marked in use, free trucks first', () {
    final List<TruckChoice> c = buildTruckChoices(registry, users, forDriverId: '20');
    expect(c.map((TruckChoice t) => t.id).toList(), <String>['GT-001', 'GT-002', 'GT-003']);
    expect(c.firstWhere((TruckChoice t) => t.id == 'GT-003').usedBy, 'Darna');
    expect(c.firstWhere((TruckChoice t) => t.id == 'GT-001').usedBy, isNull); // archived driver frees it
    expect(c.firstWhere((TruckChoice t) => t.id == 'GT-002').usedBy, isNull); // residents never hold trucks
    expect(c.firstWhere((TruckChoice t) => t.id == 'GT-001').plate, 'AAA 111');
  });

  test("a driver's own truck is not shown as in use by someone else", () {
    final List<TruckChoice> c = buildTruckChoices(registry, users, forDriverId: '19');
    expect(c.firstWhere((TruckChoice t) => t.id == 'GT-003').usedBy, isNull);
  });

  testWidgets('tile shows the truck, or a clear prompt when none is assigned', (WidgetTester tester) async {
    Future<void> show(String? truck) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: AssignedTruckTile(truckId: truck, onPressed: () {}))));

    await show(null);
    expect(find.text('No truck assigned'), findsOneWidget);
    expect(find.text('Assign'), findsOneWidget);

    await show('Unknown');
    expect(find.text('No truck assigned'), findsOneWidget);

    await show('GT-007');
    expect(find.text('GT-007'), findsOneWidget);
    expect(find.text('Change'), findsOneWidget);
  });
}
