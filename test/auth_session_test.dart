import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/auth_session.dart';
import 'package:garbage_tracking_app/utils/session_manager.dart';
import 'package:garbage_tracking_app/utils/browser_session_stub.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Scripted backend: records requests and answers with [handler].
class FakeServer implements HttpClientAdapter {
  FakeServer(this.handler);
  (int, Map<String, dynamic>) Function(String path, Map<String, dynamic> body, Map<String, dynamic> headers) handler;
  final List<(String, Map<String, dynamic>, Map<String, dynamic>)> calls = <(String, Map<String, dynamic>, Map<String, dynamic>)>[];
  bool offline = false;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (offline) throw DioException.connectionError(requestOptions: options, reason: 'offline');
    final Map<String, dynamic> body = options.data is Map ? Map<String, dynamic>.from(options.data as Map) : <String, dynamic>{};
    calls.add((options.path, body, Map<String, dynamic>.from(options.headers)));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final (int status, Map<String, dynamic> json) = handler(options.path, body, options.headers);
    return ResponseBody.fromString(jsonEncode(json), status, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}

  int count(String path) => calls.where((c) => c.$1 == path).length;
}

String accessToken(int expSeconds, {String sid = 's1'}) {
  String b64(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${b64(<String, Object>{'sub': '7', 'role': 'driver', 'sid': sid, 'exp': expSeconds})}.sig';
}

const String sid = '0123456789abcdef0123456789abcdef';
String cred(int gen) => '$sid.$gen.${'m' * 43}';

Map<String, dynamic> driver(int id, {String name = 'Steven'}) =>
    <String, dynamic>{'user_id': id, 'username': name.toLowerCase(), 'name': name, 'email': '$name@x.test', 'role': 'driver', 'preferred_truck': 'GT-00$id'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeServer server;
  late MemoryRefreshStore store;
  late DateTime now;
  late int gen; // server-side credential generation

  AuthSession newSession({bool web = false}) {
    final Dio dio = Dio(BaseOptions(baseUrl: 'https://app.example.test/backend/', validateStatus: (_) => true));
    dio.httpClientAdapter = server;
    return AuthSession(dio: dio, store: store, isWeb: web, clock: () => now);
  }

  int nowSec() => now.millisecondsSinceEpoch ~/ 1000;

  // Default server: rotates on refresh, accepts logout.
  (int, Map<String, dynamic>) okServer(String path, Map<String, dynamic> body, Map<String, dynamic> headers) {
    if (path == 'session_refresh.php') {
      gen++;
      return (200, <String, dynamic>{
        'success': true,
        'access_token': accessToken(nowSec() + 900),
        'expires_in': 900,
        'persistent': true,
        if (body['client'] != 'web') 'refresh_token': cred(gen),
        'user': driver(int.parse(body['user_id'].toString()), name: 'Steven Updated'),
      });
    }
    if (path == 'session_logout.php') return (200, <String, dynamic>{'success': true, 'revoked': true});
    return (404, <String, dynamic>{});
  }

  Map<String, dynamic> sessionBlock({bool persistent = true, bool web = false}) => <String, dynamic>{
        'access_token': accessToken(nowSec() + 900),
        'expires_in': 900,
        'persistent': persistent,
        if (!web) 'refresh_token': cred(1),
      };

  setUp(() {
    clearBrowserSessionMark();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    store = MemoryRefreshStore();
    now = DateTime.utc(2026, 10, 13, 8);
    gen = 1;
    server = FakeServer(okServer);
    AuthSession.instance = newSession();
  });

  group('Android: Stay signed in', () {
    test('login keeps the access token in memory and the refresh credential in secure storage only', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: true, session: sessionBlock());
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(store.values['gt_rt_driver_7'], cred(1));
      expect(prefs.getString(SessionManager.keyAuthToken), isNull, reason: 'no bearer token in plain preferences');
      expect(prefs.getKeys().map((k) => prefs.get(k).toString()).any((v) => v.contains(cred(1))), isFalse);
      expect(await SessionManager.getAuthToken(), startsWith('ey'));
      expect(server.calls, isEmpty, reason: 'a valid access token needs no refresh');
      final List<Map<String, dynamic>> saved = await SessionManager.getSavedProfiles();
      expect(saved.single['one_tap'], isTrue);
      expect(saved.single.containsKey('refresh_token'), isFalse);
    });

    test('an expired access token is renewed transparently and the credential rotated', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: true, session: sessionBlock());
      now = now.add(const Duration(minutes: 20));
      final String? t = await SessionManager.getAuthToken();
      expect(t, isNotNull);
      expect(server.count('session_refresh.php'), 1);
      expect(server.calls.single.$2['refresh_token'], cred(1));
      expect(store.values['gt_rt_driver_7'], cred(2), reason: 'rotated credential stored');
    });

    test('concurrent requests share ONE refresh (no rotation race)', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: true, session: sessionBlock());
      now = now.add(const Duration(minutes: 20));
      final List<String?> tokens = await Future.wait(List<Future<String?>>.generate(5, (_) => SessionManager.getAuthToken()));
      expect(tokens.toSet().length, 1);
      expect(server.count('session_refresh.php'), 1);
    });

    test('app restart after 2 years: restored through the server, no password, no expiry', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: true, session: sessionBlock());
      final int loginTime = (await SessionManager.getLoginTimestamp())!;
      AuthSession.instance = newSession(); // process restart: memory gone, keystore kept
      now = now.add(const Duration(days: 730));
      final LaunchResult r = await SessionManager.restoreOnLaunch();
      expect(r.state, LaunchSession.proceed);
      expect(server.count('session_refresh.php'), 1);
      expect((await SessionManager.getUser())!.name, 'Steven Updated', reason: 'profile re-read from the server');
      expect(await SessionManager.getLoginTimestamp(), loginTime, reason: 'same app session: driver trip continuity');
    });

    test('revoked on the server: password required, saved credential deleted, name kept', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: true, session: sessionBlock());
      server.handler = (p, b, h) => (401, <String, dynamic>{'success': false, 'reason': 'revoked', 'message': 'This sign-in was ended. Please sign in again.'});
      AuthSession.instance = newSession();
      final LaunchResult r = await SessionManager.restoreOnLaunch();
      expect(r.state, LaunchSession.needLogin);
      expect(r.message, contains('ended'));
      expect(store.values, isEmpty);
      expect(await SessionManager.isLoggedIn(), isFalse);
      final List<Map<String, dynamic>> saved = await SessionManager.getSavedProfiles();
      expect(saved.single['username'], 'steven');
      expect(saved.single['one_tap'], isNull, reason: 'no longer offered as one-tap');
    });

    test('account archived / password changed (403/401 from refresh): same outcome', () async {
      for (final (int code, String reason) in <(int, String)>[(403, 'account_archived'), (401, 'password_changed'), (403, 'account_rejected')]) {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        store.values.clear();
        AuthSession.instance = newSession();
        await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: true, session: sessionBlock());
        server.handler = (p, b, h) => (code, <String, dynamic>{'success': false, 'reason': reason, 'message': 'msg $reason'});
        AuthSession.instance = newSession();
        final LaunchResult r = await SessionManager.restoreOnLaunch();
        expect(r.state, LaunchSession.needLogin, reason: reason);
        expect(store.values, isEmpty, reason: reason);
      }
    });

    test('server unreachable at start-up: keeps working offline with the saved sign-in', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: true, session: sessionBlock());
      AuthSession.instance = newSession();
      server.offline = true;
      final LaunchResult r = await SessionManager.restoreOnLaunch();
      expect(r.state, LaunchSession.proceed, reason: 'a network failure is not a logout');
      expect(store.values['gt_rt_driver_7'], cred(1));
      server.offline = false;
      expect(await SessionManager.getAuthToken(), isNotNull, reason: 'renewed on the next request');
    });

    test('server without session support (503 unavailable): continues as before', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: true, session: sessionBlock());
      server.handler = (p, b, h) => (503, <String, dynamic>{'success': false, 'reason': 'unavailable'});
      AuthSession.instance = newSession();
      expect((await SessionManager.restoreOnLaunch()).state, LaunchSession.proceed);
      expect(store.values, isNotEmpty);
    });

    test('a 409 (parallel rotation) is retried once', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: true, session: sessionBlock());
      int n = 0;
      server.handler = (p, b, h) => ++n == 1 ? (409, <String, dynamic>{'success': false, 'reason': 'retry'}) : okServer(p, b, h);
      now = now.add(const Duration(minutes: 20));
      expect(await SessionManager.getAuthToken(), isNotNull);
      expect(server.count('session_refresh.php'), 2);
    });
  });

  group('without Stay signed in', () {
    test('Android: a new app start requires the password (nothing in secure storage)', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: false, session: sessionBlock(persistent: false));
      expect(store.values, isEmpty, reason: 'non-persistent credential is memory-only');
      expect((await SessionManager.getSavedProfiles()).single['one_tap'], isNull, reason: 'Remember account alone never offers one-tap');
      now = now.add(const Duration(minutes: 20));
      expect(await SessionManager.getAuthToken(), isNotNull, reason: 'renews while the app keeps running');
      AuthSession.instance = newSession();
      final int before = server.calls.length;
      expect((await SessionManager.restoreOnLaunch()).state, LaunchSession.needLogin);
      expect(server.calls.length, before, reason: 'no request needed');
    });
  });

  group('Remember account (one-tap sign-in without the password)', () {
    // The login asks for a persistent session whenever "Remember account" is ticked.
    test('remembered without Stay signed in: restart needs ONE TAP, not the password', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: false, session: sessionBlock());
      expect((await SessionManager.getSavedProfiles()).single['one_tap'], isTrue);
      AuthSession.instance = newSession(); // app restart
      final LaunchResult r = await SessionManager.restoreOnLaunch();
      expect(r.state, LaunchSession.needLogin, reason: 'no automatic sign-in without Stay signed in');
      expect(server.count('session_logout.php'), 0, reason: 'the saved sign-in is kept');
      expect(store.values['gt_rt_driver_7'], cred(1));
      final Map<String, dynamic> p = (await SessionManager.getSavedProfiles()).single;
      expect(p['one_tap'], isTrue);
      expect(await SessionManager.resumeSavedAccount(p), isNull, reason: 'one tap, no password');
      expect(await SessionManager.isLoggedIn(), isTrue);
      expect(await SessionManager.isStaySignedIn(), isFalse, reason: 'one tap does not switch on automatic sign-in');
    });

    test('Logout and Remember Login keeps the saved sign-in; the next sign-in is one tap', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: false, session: sessionBlock());
      expect(await SessionManager.canSwitchAccount(), isTrue, reason: 'the dialog offers the one-tap wording');
      await SessionManager.logout(keepSignedIn: true); // what the dialog's Remember choice does
      expect(server.count('session_logout.php'), 0);
      expect(await SessionManager.isLoggedIn(), isFalse);
      expect(await SessionManager.getAuthToken(), isNull);
      final Map<String, dynamic> p = (await SessionManager.getSavedProfiles()).single;
      expect(await SessionManager.resumeSavedAccount(p), isNull);
      expect((await SessionManager.getUser())!.userId.toString(), '7');
    });

    test('Remember on an account WITHOUT a saved sign-in still ends the session on the server', () async {
      await SessionManager.startSession(driver(7), rememberAccount: false, staySignedIn: false, session: sessionBlock(persistent: false));
      expect(await SessionManager.canSwitchAccount(), isFalse);
      await SessionManager.logout(keepSignedIn: true);
      expect(server.count('session_logout.php'), 1);
      expect(store.values, isEmpty);
    });

    test('Forget Login after a one-tap sign-in removes everything', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: false, session: sessionBlock());
      await SessionManager.logout(forgetLogin: true, keepSignedIn: false);
      expect(server.count('session_logout.php'), 1);
      expect(store.values, isEmpty);
      expect(await SessionManager.getSavedProfiles(), isEmpty);
    });
  });

  group('logout, forget and account switching', () {
    test('Logout and Remember Login: revoked on the server, credential deleted, name kept', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: true, session: sessionBlock());
      await SessionManager.logout();
      expect(server.count('session_logout.php'), 1);
      expect(server.calls.last.$2['refresh_token'], cred(1));
      expect(store.values, isEmpty);
      expect(await SessionManager.getAuthToken(), isNull);
      final List<Map<String, dynamic>> saved = await SessionManager.getSavedProfiles();
      expect(saved.single['username'], 'steven');
      expect(saved.single['one_tap'], isNull);
    });

    test('Forget Account: revoked and the account removed from the device', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: true, session: sessionBlock());
      await SessionManager.logout(forgetLogin: true);
      expect(server.count('session_logout.php'), 1);
      expect(store.values, isEmpty);
      expect(await SessionManager.getSavedProfiles(), isEmpty);
    });

    test('logout while offline still removes the local credential', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: true, session: sessionBlock());
      server.offline = true;
      await SessionManager.logout();
      expect(store.values, isEmpty);
      expect(await SessionManager.isLoggedIn(), isFalse);
    });

    test('Switch account keeps A signed in; B signs in; A resumes with one tap; tokens never mix', () async {
      await SessionManager.startSession(driver(7, name: 'Steven'), rememberAccount: true, staySignedIn: true, session: sessionBlock());
      expect(await SessionManager.canSwitchAccount(), isTrue);
      await SessionManager.logout(keepSignedIn: true);
      expect(server.count('session_logout.php'), 0, reason: 'switching does not end the saved sign-in');
      expect(store.values['gt_rt_driver_7'], cred(1));

      final Map<String, dynamic> bSession = sessionBlock()..['refresh_token'] = '${'f' * 32}.1.${'b' * 43}';
      bSession['access_token'] = accessToken(nowSec() + 900, sid: 'B');
      await SessionManager.startSession(driver(9, name: 'Maria'), rememberAccount: true, staySignedIn: true, session: bSession);
      expect(await SessionManager.getAuthToken(), bSession['access_token']);
      expect(store.values.keys, containsAll(<String>['gt_rt_driver_7', 'gt_rt_driver_9']));

      await SessionManager.logout(keepSignedIn: true);
      final Map<String, dynamic> steven = (await SessionManager.getSavedProfiles()).firstWhere((p) => p['user_id'].toString() == '7');
      expect(steven['one_tap'], isTrue);
      final String? problem = await SessionManager.resumeSavedAccount(steven);
      expect(problem, isNull);
      expect(server.calls.last.$2['user_id'], '7');
      expect(server.calls.last.$2['refresh_token'], cred(1), reason: 'Steven\'s own credential, never Maria\'s');
      expect((await SessionManager.getUser())!.userId.toString(), '7');
      expect(await SessionManager.isLoggedIn(), isTrue);
    });

    test('one-tap on an ended sign-in falls back to the password', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: true, session: sessionBlock());
      await SessionManager.logout(keepSignedIn: true);
      server.handler = (p, b, h) => (401, <String, dynamic>{'success': false, 'reason': 'revoked', 'message': 'This sign-in was ended. Please sign in again.'});
      final Map<String, dynamic> p = (await SessionManager.getSavedProfiles()).single;
      final String? problem = await SessionManager.resumeSavedAccount(p);
      expect(problem, contains('ended'));
      expect(await SessionManager.isLoggedIn(), isFalse);
      expect((await SessionManager.getSavedProfiles()).single['one_tap'], isNull);
    });

    test('Switch account is not offered without Stay signed in', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: false, session: sessionBlock(persistent: false));
      expect(await SessionManager.canSwitchAccount(), isFalse);
    });
  });

  group('Web', () {
    setUp(() => AuthSession.instance = newSession(web: true));

    test('no refresh credential in app storage; refresh relies on the HttpOnly cookie + CSRF header', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: true, session: sessionBlock(web: true));
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(store.values, isEmpty);
      expect(prefs.getString(SessionManager.keyAuthToken), isNull, reason: 'no bearer token in localStorage');
      now = now.add(const Duration(minutes: 20));
      expect(await SessionManager.getAuthToken(), isNotNull);
      final (String path, Map<String, dynamic> body, Map<String, dynamic> headers) = server.calls.single;
      expect(path, 'session_refresh.php');
      expect(body.containsKey('refresh_token'), isFalse);
      expect(body['client'], 'web');
      expect(headers['X-GT-CSRF'], '1');
    });

    test('browser reopened: restored through the cookie; logout asks the server to delete it', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: true, session: sessionBlock(web: true));
      AuthSession.instance = newSession(web: true);
      expect((await SessionManager.restoreOnLaunch()).state, LaunchSession.proceed);
      await SessionManager.logout();
      expect(server.count('session_logout.php'), 1);
      expect(server.calls.last.$3['X-GT-CSRF'], '1');
    });

    test('remembered without Stay signed in: a reload continues, a new browser session needs one tap', () async {
      clearBrowserSessionMark();
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: false, session: sessionBlock(web: true));
      AuthSession.instance = newSession(web: true); // page reload: same tab session
      expect((await SessionManager.restoreOnLaunch()).state, LaunchSession.proceed);
      clearBrowserSessionMark(); // browser closed and reopened
      AuthSession.instance = newSession(web: true);
      expect((await SessionManager.restoreOnLaunch()).state, LaunchSession.needLogin);
      expect(server.count('session_logout.php'), 0, reason: 'the cookie-held saved sign-in is kept');
      final Map<String, dynamic> p = (await SessionManager.getSavedProfiles()).single;
      expect(p['one_tap'], isTrue);
      expect(await SessionManager.resumeSavedAccount(p), isNull);
    });

    test('without Stay signed in, a still-open browser session cookie may continue', () async {
      await SessionManager.startSession(driver(7), rememberAccount: true, staySignedIn: false, session: sessionBlock(persistent: false, web: true));
      AuthSession.instance = newSession(web: true);
      expect((await SessionManager.restoreOnLaunch()).state, LaunchSession.proceed);
      server.handler = (p, b, h) => (401, <String, dynamic>{'success': false, 'reason': 'no_session'});
      AuthSession.instance = newSession(web: true);
      expect((await SessionManager.restoreOnLaunch()).state, LaunchSession.needLogin, reason: 'browser closed: cookie gone');
    });
  });

  group('older server (no session support)', () {
    test('legacy token behaves exactly as before; no session requests', () async {
      await SessionManager.startSession(<String, dynamic>{...driver(7), 'auth_token': 'legacy.token'}, rememberAccount: true, staySignedIn: true);
      expect(await SessionManager.getAuthToken(), 'legacy.token');
      AuthSession.instance = newSession();
      expect((await SessionManager.restoreOnLaunch()).state, LaunchSession.proceed);
      await SessionManager.logout();
      expect(server.calls, isEmpty);
      expect(await SessionManager.getAuthToken(), isNull);
    });

    test('a profile update of the same account keeps its token; another account never inherits it', () async {
      await SessionManager.startSession(<String, dynamic>{...driver(7), 'auth_token': 'legacy.token'}, rememberAccount: true, staySignedIn: true);
      await SessionManager.saveUser(<String, dynamic>{...driver(7), 'preferred_truck': 'GT-010'});
      expect(await SessionManager.getAuthToken(), 'legacy.token');
      await SessionManager.saveUser(driver(9, name: 'Maria'));
      expect(await SessionManager.getAuthToken(), isNull);
    });
  });
}
