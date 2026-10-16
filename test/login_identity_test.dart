import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/session_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> driver(int id, String username, String truck, {String? token}) => <String, dynamic>{
      'user_id': id,
      'username': username,
      'name': '$username Driver',
      'email': '${username.toLowerCase()}@example.com',
      'role': 'driver',
      'preferred_truck': truck,
      if (token != null) 'auth_token': token,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('session identity after logout / new login', () {
    test('logout clears the session; a different driver then gets ONLY their own identity', () async {
      await SessionManager.saveUser(driver(15, 'Steven', 'GT-007', token: 'tokA.sigA'));
      expect((await SessionManager.getUser())!.username, 'Steven');
      expect(await SessionManager.getAuthToken(), 'tokA.sigA');

      await SessionManager.logout();
      expect(await SessionManager.isLoggedIn(), isFalse);
      expect(await SessionManager.getUser(), isNull);
      expect(await SessionManager.getAuthToken(), isNull);

      await SessionManager.saveUser(driver(16, 'Maria', 'GT-009', token: 'tokB.sigB'));
      final u = (await SessionManager.getUser())!;
      expect(u.userId, 16);
      expect(u.username, 'Maria');
      expect(u.preferredTruck, 'GT-009', reason: 'no GPS/truck identity inherited from the previous driver');
      expect(await SessionManager.getAuthToken(), 'tokB.sigB');
    });

    test('a login without a token never keeps the previous account\'s token', () async {
      await SessionManager.saveUser(driver(15, 'Steven', 'GT-007', token: 'tokA.sigA'));
      await SessionManager.saveUser(driver(16, 'Maria', 'GT-009'));
      expect(await SessionManager.getAuthToken(), isNull);
      expect((await SessionManager.getUser())!.userId, 16);
    });

    test('the last-user markers follow the new login', () async {
      await SessionManager.saveUser(driver(15, 'Steven', 'GT-007'));
      await SessionManager.saveUser(driver(16, 'Maria', 'GT-009'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SessionManager.keyLastUserId), '16');
      expect(prefs.getString(SessionManager.keyLastUserRole), 'driver');
    });

    test('two different drivers keep two separate saved profiles', () async {
      await SessionManager.saveUser(driver(15, 'Steven', 'GT-007'));
      await SessionManager.saveUser(driver(16, 'Maria', 'GT-009'));
      final profiles = await SessionManager.getSavedProfiles();
      expect(profiles.length, 2);
      expect(profiles.map((p) => p['user_id'].toString()).toSet(), {'15', '16'});
      // each saved profile carries only its own identifier (never the session payload)
      final steven = profiles.firstWhere((p) => p['user_id'].toString() == '15');
      expect(steven['username'], 'Steven');
      expect(steven.containsKey('user_data'), isFalse);
      expect(steven.containsKey('preferred_truck'), isFalse);
    });
  });

  group('saved profile quick login (no password) - documented behaviour', () {
    test('the saved profile stores NO password material', () async {
      await SessionManager.saveUser(<String, dynamic>{
        ...driver(15, 'Steven', 'GT-007'),
        'password': 'should-never-be-stored',
        'password_hash': 'should-never-be-stored',
      });
      final profiles = await SessionManager.getSavedProfiles();
      final String encoded = profiles.toString();
      // the remembered profile is limited to identity fields; the session payload is not kept
      for (final String k in ['user_id', 'name', 'username', 'email', 'role', 'saved_at']) {
        expect(profiles.single.containsKey(k), isTrue);
      }
      expect(profiles.single.containsKey('user_data'), isFalse);
      expect(profiles.single.containsKey('password'), isFalse);
      expect(encoded, isNot(contains('should-never-be-stored')));
      expect(encoded.isNotEmpty, isTrue);
    });

    test('KNOWN DEFECT: a driver and a resident with the same numeric id collide in saved profiles', () async {
      // login.php returns users.user_id for drivers and residents.resident_id for
      // residents; the two tables number independently, so ids can repeat.
      await SessionManager.saveUser(driver(15, 'Steven', 'GT-007'));
      await SessionManager.saveUser(<String, dynamic>{
        'user_id': 15,
        'username': 'Pedro',
        'name': 'Pedro Cruz',
        'email': 'pedro@example.com',
        'role': 'resident',
        'purok': 'Purok 1',
      });
      final profiles = await SessionManager.getSavedProfiles();
      // Today only ONE of the two accounts survives because the key is user_id alone.
      expect(profiles.length, 1, reason: 'saved-profile key does not include the role');
      expect(profiles.single['role'], 'resident');
      // Fix direction: key the saved profile by "role:user_id" so both are kept and
      // "Continue as ..." can never open the other account.
    });
  });
}
