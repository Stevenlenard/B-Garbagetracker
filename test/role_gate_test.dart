import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/session_manager.dart';
import 'package:garbage_tracking_app/widgets/role_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<void> pumpAdminRoute(WidgetTester t, {Map<String, Object>? user}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      if (user != null) SessionManager.keyIsLoggedIn: true,
      if (user != null) SessionManager.keyUserData: jsonEncode(user),
    });
    await t.pumpWidget(MaterialApp(
      initialRoute: '/admin_dashboard',
      routes: <String, WidgetBuilder>{
        '/admin_dashboard': (_) => const RoleGate(roles: <String>{'admin'}, child: Text('ADMIN UI')),
        '/resident_dashboard': (_) => const Text('RESIDENT HOME'),
        '/driver_dashboard': (_) => const Text('DRIVER HOME'),
        '/splash': (_) => const Text('SIGN IN'),
      },
    ));
    await t.pumpAndSettle();
  }

  testWidgets('the admin page opens for an admin', (WidgetTester t) async {
    await pumpAdminRoute(t, user: <String, Object>{'user_id': 1, 'name': 'Admin', 'role': 'admin'});
    expect(find.text('ADMIN UI'), findsOneWidget);
  });

  testWidgets('a resident opening #/admin_dashboard lands on the resident dashboard', (WidgetTester t) async {
    await pumpAdminRoute(t, user: <String, Object>{'user_id': 24, 'name': 'Arian Joy', 'role': 'resident'});
    expect(find.text('ADMIN UI'), findsNothing);
    expect(find.text('RESIDENT HOME'), findsOneWidget);
  });

  testWidgets('a driver is sent to the driver dashboard', (WidgetTester t) async {
    await pumpAdminRoute(t, user: <String, Object>{'user_id': 7, 'name': 'Steve', 'role': 'driver'});
    expect(find.text('DRIVER HOME'), findsOneWidget);
  });

  testWidgets('nobody signed in: sign-in flow, never the admin UI', (WidgetTester t) async {
    await pumpAdminRoute(t);
    expect(find.text('ADMIN UI'), findsNothing);
    expect(find.text('SIGN IN'), findsOneWidget);
  });
}
