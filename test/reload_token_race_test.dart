import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/auth_session.dart';
import 'package:garbage_tracking_app/utils/session_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Server implements HttpClientAdapter {
  int refreshes = 0;
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s, Future<void>? c) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    refreshes++;
    String b64(Object x) => base64Url.encode(utf8.encode(jsonEncode(x))).replaceAll('=', '');
    final int exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 900;
    return ResponseBody.fromString(
        jsonEncode(<String, dynamic>{
          'success': true,
          'access_token': '${b64(<String, Object>{'sub': '24', 'role': 'resident', 'exp': exp})}.sig',
          'persistent': true,
          'user': <String, dynamic>{'user_id': 24, 'role': 'resident', 'name': 'R'},
        }),
        200,
        headers: <String, List<String>>{Headers.contentTypeHeader: <String>['application/json']});
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('web reload straight onto a dashboard: concurrent requests all get a token', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SessionManager.keyIsLoggedIn: true,
      SessionManager.keySessionMode: 'session',
      SessionManager.keyStaySignedIn: true,
      SessionManager.keyUserData: jsonEncode(<String, dynamic>{'user_id': 24, 'role': 'resident', 'name': 'R'}),
    });
    final _Server server = _Server();
    final Dio dio = Dio(BaseOptions(baseUrl: 'https://x.test/backend/', validateStatus: (_) => true))..httpClientAdapter = server;
    AuthSession.instance = AuthSession(dio: dio, store: MemoryRefreshStore(), isWeb: true);

    final List<String?> tokens = await Future.wait(
      List<Future<String?>>.generate(6, (_) => SessionManager.getAuthToken()),
    ).timeout(const Duration(seconds: 3));
    expect(tokens.every((t) => t != null && t.isNotEmpty), isTrue, reason: '$tokens');
    expect(server.refreshes, 1);
  });
}
