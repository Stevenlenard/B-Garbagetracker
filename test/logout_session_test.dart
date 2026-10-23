import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/session_manager.dart';
import 'package:garbage_tracking_app/widgets/logout_choice_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> account(String role, int id) => <String, dynamic>{
      'user_id': id,
      'username': '${role}_user',
      'name': '$role Name',
      'email': '$role@example.com',
      'role': role,
      'auth_token': 'SECRET.TOKEN.$id',
      'password': 'must-never-be-stored',
    };

Future<String> allPrefsText() async {
  final SharedPreferences p = await SharedPreferences.getInstance();
  return p.getKeys().map((String k) => '$k=${p.get(k)}').join('\n');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('remembered login holds an identifier only', () {
    for (final String role in <String>['admin', 'driver', 'resident']) {
      test('$role: no token, password or session payload in the saved profile', () async {
        await SessionManager.saveUser(account(role, 7), rememberMe: true);
        final List<Map<String, dynamic>> profiles = await SessionManager.getSavedProfiles();
        expect(profiles.length, 1);
        expect(profiles.first['role'], role);
        expect(profiles.first['username'], '${role}_user');
        expect(profiles.first.containsKey('user_data'), isFalse);
        final String saved = jsonEncode(profiles);
        expect(saved, isNot(contains('SECRET.TOKEN')));
        expect(saved, isNot(contains('must-never-be-stored')));
      });
    }

    test('profiles written by older versions (with the token) are scrubbed on read', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        SessionManager.keySavedProfiles: jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'user_id': '3',
            'name': 'Old',
            'email': 'old@example.com',
            'role': 'resident',
            'user_data': <String, dynamic>{'username': 'old_user', 'auth_token': 'LEAKED.TOKEN'},
          }
        ]),
      });
      final List<Map<String, dynamic>> p = await SessionManager.getSavedProfiles();
      expect(p.single.containsKey('user_data'), isFalse);
      expect(p.single['username'], 'old_user');
      expect(await allPrefsText(), isNot(contains('LEAKED.TOKEN')));
    });
  });

  group('logout', () {
    test('Logout and Remember: session and token are gone, identifier stays', () async {
      await SessionManager.saveUser(account('resident', 5), rememberMe: true);
      expect(await SessionManager.isLoggedIn(), isTrue);
      expect(await SessionManager.getAuthToken(), isNotNull);

      await SessionManager.logout(forgetLogin: false);

      expect(await SessionManager.isLoggedIn(), isFalse);
      expect(await SessionManager.getUser(), isNull);
      expect(await SessionManager.getAuthToken(), isNull);
      expect(await allPrefsText(), isNot(contains('SECRET.TOKEN')));
      final List<Map<String, dynamic>> p = await SessionManager.getSavedProfiles();
      expect(p.single['username'], 'resident_user');
    });

    test('Logout and Forget: session gone and the remembered account removed', () async {
      await SessionManager.saveUser(account('driver', 9), rememberMe: true);
      await SessionManager.logout(forgetLogin: true);

      expect(await SessionManager.isLoggedIn(), isFalse);
      expect(await SessionManager.getUser(), isNull);
      expect(await SessionManager.getAuthToken(), isNull);
      expect(await SessionManager.getSavedProfiles(), isEmpty);
      expect(await SessionManager.isRememberMeEnabled(), isFalse);
    });

    test('forget removes only the account that signed out', () async {
      await SessionManager.saveUser(account('resident', 5), rememberMe: true);
      await SessionManager.saveUser(account('admin', 1), rememberMe: true);
      await SessionManager.logout(forgetLogin: true); // admin (current session) signs out
      final List<Map<String, dynamic>> p = await SessionManager.getSavedProfiles();
      expect(p.map((Map<String, dynamic> e) => e['role']), <String>['resident']);
    });

    test('a refresh / back navigation finds no session after logout', () async {
      await SessionManager.saveUser(account('admin', 1), rememberMe: true);
      await SessionManager.logout();
      // What the splash screen reads on a browser refresh or app restart.
      expect(await SessionManager.isLoggedIn(), isFalse);
      expect(await SessionManager.getUser(), isNull);
    });
  });

  group('logout dialog', () {
    Future<LogoutChoice?> choose(WidgetTester tester, String buttonText) async {
      LogoutChoice? result;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async => result = await showLogoutChoiceDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(buttonText));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('Cancel keeps the user logged in (no choice to log out)', (WidgetTester tester) async {
      expect(await choose(tester, 'Cancel'), LogoutChoice.cancel);
    });

    testWidgets('Log out keeps what Remember me saved at sign-in (no second question)', (WidgetTester tester) async {
      expect(await choose(tester, 'Log out'), LogoutChoice.remember);
      expect(find.text('Logout and Forget Login'), findsNothing);
    });
  });
}
