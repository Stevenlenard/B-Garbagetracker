import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/api/api_client.dart';
import 'package:garbage_tracking_app/utils/session_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Captures the outgoing request headers without any network.
class _CaptureAdapter implements HttpClientAdapter {
  Map<String, dynamic>? lastHeaders;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    lastHeaders = Map<String, dynamic>.from(options.headers);
    return ResponseBody.fromString('{"success":true}', 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}
}

Future<Map<String, dynamic>?> sendWith(Future<String?> Function() provider) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid/'));
  final adapter = _CaptureAdapter();
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(AuthTokenInterceptor(tokenProvider: provider));
  await dio.post('approve_user.php', data: {'user_id': 1});
  return adapter.lastHeaders;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AuthTokenInterceptor', () {
    test('adds X-GT-Token while a token exists', () async {
      final h = await sendWith(() async => 'payload.signature');
      expect(h!['X-GT-Token'], 'payload.signature');
    });

    test('sends nothing extra when there is no token (old servers / legacy sessions)', () async {
      final h = await sendWith(() async => null);
      expect(h!.containsKey('X-GT-Token'), isFalse);
    });

    test('a token that cannot be read never blocks the request', () async {
      final h = await sendWith(() async => throw StateError('storage unavailable'));
      expect(h!.containsKey('X-GT-Token'), isFalse);
    });
  });

  group('SessionManager token handling', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('login stores the token apart from the profile', () async {
      await SessionManager.saveUser({
        'user_id': 7,
        'username': 'driver01',
        'name': 'Juan',
        'email': 'j@example.com',
        'role': 'driver',
        'auth_token': 'abc.def',
      });
      expect(await SessionManager.getAuthToken(), 'abc.def');
      final user = await SessionManager.getUser();
      expect(user!.userId, 7);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(SessionManager.keyUserData), isNot(contains('abc.def')),
          reason: 'the token must not live inside the profile JSON');
    });

    test('a profile refresh (no token in the map) keeps working and clears nothing it should not', () async {
      await SessionManager.saveUser({'user_id': 7, 'username': 'd', 'name': 'D', 'email': 'e', 'role': 'driver', 'auth_token': 'abc.def'});
      expect(await SessionManager.getAuthToken(), 'abc.def');
      // A different account without a token must not inherit the previous token.
      await SessionManager.saveUser({'user_id': 9, 'username': 'r', 'name': 'R', 'email': 'x', 'role': 'resident'});
      expect(await SessionManager.getAuthToken(), isNull);
    });

    test('the 2FA step can attach its token after the profile is saved', () async {
      await SessionManager.saveUser({'user_id': 1, 'username': 'a', 'name': 'A', 'email': 'e', 'role': 'admin'});
      expect(await SessionManager.getAuthToken(), isNull);
      await SessionManager.saveAuthToken('t.s');
      expect(await SessionManager.getAuthToken(), 't.s');
    });

    test('logout removes the token', () async {
      await SessionManager.saveUser({'user_id': 7, 'username': 'd', 'name': 'D', 'email': 'e', 'role': 'driver', 'auth_token': 'abc.def'});
      await SessionManager.logout();
      expect(await SessionManager.getAuthToken(), isNull);
    });
  });
}
