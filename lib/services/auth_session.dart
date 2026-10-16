import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/api_client.dart';

/// Where Android keeps refresh credentials of "Stay signed in" sessions.
/// Web never stores them in JavaScript-readable storage: the server keeps them in a
/// Secure, HttpOnly cookie, so the Web store is never written.
abstract class RefreshCredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Android Keystore-backed storage (EncryptedSharedPreferences).
class SecureRefreshStore implements RefreshCredentialStore {
  SecureRefreshStore([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true, resetOnError: true));
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      // e.g. keystore key lost after a backup restore: behave as "no saved sign-in".
      debugPrint('[AUTH] secure read failed: $e');
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (_) {}
  }
}

/// In-memory store (tests; and the "not persistent" case, which ends with the process).
class MemoryRefreshStore implements RefreshCredentialStore {
  final Map<String, String> values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// An account (role + id) that can hold a saved sign-in.
@immutable
class SessionAccount {
  const SessionAccount(this.role, this.userId);
  final String role; // admin | driver | resident
  final String userId;

  String get storageKey => 'gt_rt_${role}_$userId';

  static SessionAccount? fromProfile(Map<String, dynamic> m) {
    final String role = (m['role'] ?? '').toString().toLowerCase();
    final String id = (m['user_id'] ?? m['id'] ?? m['resident_id'] ?? '').toString();
    if (!const <String>['admin', 'driver', 'resident'].contains(role) || id.isEmpty) return null;
    return SessionAccount(role, id);
  }

  @override
  bool operator ==(Object other) => other is SessionAccount && other.role == role && other.userId == userId;
  @override
  int get hashCode => Object.hash(role, userId);
  @override
  String toString() => '$role:$userId';
}

enum RefreshOutcome {
  /// New access token; [RefreshResult.user] is the current profile from the server.
  ok,

  /// The saved sign-in no longer exists (logged out elsewhere, revoked, account changed,
  /// password changed...). The password is required.
  ended,

  /// The server could not be reached. Nothing was decided: keep the saved sign-in.
  network,

  /// The server does not support saved sign-in yet (not migrated / not configured).
  unavailable,
}

class RefreshResult {
  const RefreshResult(this.outcome, {this.message, this.user, this.reason});
  final RefreshOutcome outcome;
  final String? message;
  final String? reason;
  final Map<String, dynamic>? user;
  bool get isOk => outcome == RefreshOutcome.ok;
}

/// Client side of revocable sign-in sessions (see backend/auth_session_lib.php).
///
///  - The ACCESS token (15 min) is kept in memory only and renewed transparently.
///  - Android keeps the rotating refresh credential in the Keystore when "Stay signed
///    in" was chosen, otherwise only in memory (it ends with the app process).
///  - Web never sees the refresh credential: the browser sends the HttpOnly cookie.
///  - There is no client-side expiry: a saved sign-in lasts until the server ends it.
class AuthSession {
  AuthSession({Dio? dio, RefreshCredentialStore? store, bool? isWeb, DateTime Function()? clock})
      : _dio = dio,
        _store = store ?? (kIsWeb ? MemoryRefreshStore() : SecureRefreshStore()),
        _isWeb = isWeb ?? kIsWeb,
        _clock = clock ?? DateTime.now;

  /// Process-wide instance; tests replace it.
  static AuthSession instance = AuthSession();

  Dio? _dio;
  final RefreshCredentialStore _store;
  final bool _isWeb;
  final DateTime Function() _clock;

  /// A separate client WITHOUT the token interceptor (refresh must not recurse).
  Dio get _http => _dio ??= Dio(BaseOptions(
        baseUrl: ApiClient.baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: <String, dynamic>{'Accept': 'application/json', 'Content-Type': 'application/json'},
        validateStatus: (_) => true,
      ));

  SessionAccount? _account;
  bool _persistent = false;
  String? _access;
  int _accessExpMs = 0;
  final Map<String, String> _memory = <String, String>{}; // non-persistent credentials
  final Map<SessionAccount, Future<RefreshResult>> _inflight = <SessionAccount, Future<RefreshResult>>{};

  bool get isWeb => _isWeb;
  SessionAccount? get account => _account;
  bool get isPersistent => _persistent;
  bool get hasSession => _account != null;

  /// What a login request sends to opt in to sessions.
  Map<String, dynamic> loginFields({required bool staySignedIn}) => <String, dynamic>{
        'session_v': 1,
        'client': _isWeb ? 'web' : 'android',
        'stay_signed_in': staySignedIn,
      };

  static int _expOf(String token) {
    try {
      final String p = token.split('.').first;
      final String norm = base64Url.normalize(p);
      final Object? m = jsonDecode(utf8.decode(base64Url.decode(norm)));
      if (m is Map && m['exp'] is num) return (m['exp'] as num).toInt() * 1000;
    } catch (_) {}
    return 0;
  }

  void _setAccess(String? token) {
    _access = (token == null || token.isEmpty) ? null : token;
    _accessExpMs = _access == null ? 0 : _expOf(_access!);
  }

  Future<String?> _readCredential(SessionAccount a) async => _memory[a.storageKey] ?? await _store.read(a.storageKey);

  Future<void> _saveCredential(SessionAccount a, String credential, {required bool persistent}) async {
    if (_isWeb) return; // the browser holds it as an HttpOnly cookie
    if (persistent) {
      _memory.remove(a.storageKey);
      await _store.write(a.storageKey, credential);
    } else {
      _memory[a.storageKey] = credential;
      await _store.delete(a.storageKey);
    }
  }

  Future<void> _forgetCredential(SessionAccount a) async {
    _memory.remove(a.storageKey);
    await _store.delete(a.storageKey);
  }

  /// Adopts the session returned by login.php / verify_otp.php (`session` block).
  Future<void> begin(SessionAccount account, Map<String, dynamic> session) async {
    _account = account;
    _persistent = session['persistent'] == true;
    _setAccess(session['access_token']?.toString());
    final Object? rt = session['refresh_token'];
    if (rt is String && rt.isNotEmpty) await _saveCredential(account, rt, persistent: _persistent);
  }

  /// A valid access token for the current account, renewed when (nearly) expired.
  /// Null without a session or when renewal is not possible right now.
  Future<String?> validAccessToken() async {
    if (_account == null) return null;
    final int now = _clock().millisecondsSinceEpoch;
    if (_access != null && now < _accessExpMs - 60000) return _access;
    final RefreshResult r = await refresh();
    return r.isOk ? _access : null;
  }

  /// Whether this device holds a saved sign-in for [a] (Android). On Web this cannot be
  /// known without asking the server (HttpOnly cookie), so it returns null.
  Future<bool?> hasSavedSignIn(SessionAccount a) async {
    if (_isWeb) return null;
    return (await _readCredential(a)) != null;
  }

  /// Renews the access token of [account] (default: the current one) and, on success,
  /// makes it the current account. Concurrent calls for one account share one request.
  Future<RefreshResult> refresh({SessionAccount? account}) {
    final SessionAccount? a = account ?? _account;
    if (a == null) return Future<RefreshResult>.value(const RefreshResult(RefreshOutcome.ended));
    final Future<RefreshResult>? running = _inflight[a];
    if (running != null) return running;
    // Block body on purpose: returning the removed Future would make whenComplete await
    // this same future (a self-deadlock).
    final Future<RefreshResult> f = _doRefresh(a).whenComplete(() {
      _inflight.remove(a);
    });
    _inflight[a] = f;
    return f;
  }

  Future<RefreshResult> _doRefresh(SessionAccount a, {bool retried = false}) async {
    final Map<String, dynamic> body = <String, dynamic>{'role': a.role, 'user_id': a.userId, 'client': _isWeb ? 'web' : 'android'};
    if (!_isWeb) {
      final String? cred = await _readCredential(a);
      if (cred == null) return const RefreshResult(RefreshOutcome.ended, reason: 'no_credential');
      body['refresh_token'] = cred;
    }
    final Response<dynamic> res;
    try {
      res = await _http.post('session_refresh.php',
          data: body, options: Options(headers: <String, dynamic>{if (_isWeb) 'X-GT-CSRF': '1'}));
    } on DioException catch (e) {
      debugPrint('[AUTH] refresh network error: ${e.type}');
      return const RefreshResult(RefreshOutcome.network);
    }
    Object? data = res.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {}
    }
    final Map<dynamic, dynamic> m = data is Map ? data : const <dynamic, dynamic>{};
    final int status = res.statusCode ?? 0;

    if (status == 200 && m['success'] == true) {
      final bool persistent = m['persistent'] == true;
      final Object? rt = m['refresh_token'];
      // Store the rotated credential BEFORE using the new access token.
      if (rt is String && rt.isNotEmpty) await _saveCredential(a, rt, persistent: persistent);
      _account = a;
      _persistent = persistent;
      _setAccess(m['access_token']?.toString());
      final Object? user = m['user'];
      return RefreshResult(RefreshOutcome.ok, user: user is Map ? Map<String, dynamic>.from(user) : null);
    }
    if (status == 409 && !retried) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return _doRefresh(a, retried: true);
    }
    if (status == 503 && m['reason'] == 'unavailable') return const RefreshResult(RefreshOutcome.unavailable);
    if (status == 401 || status == 403) {
      await _forgetCredential(a);
      if (_account == a) {
        _account = null;
        _setAccess(null);
      }
      return RefreshResult(RefreshOutcome.ended, message: m['message']?.toString(), reason: m['reason']?.toString());
    }
    // HTML error pages, 5xx, missing endpoint (old server): nothing decided.
    if (m.isEmpty && status == 200) return const RefreshResult(RefreshOutcome.unavailable);
    return const RefreshResult(RefreshOutcome.network);
  }

  /// Ends the saved sign-in of [account] (default: current): revoked on the server when
  /// [revoke] (best effort, the local copy is removed regardless).
  Future<void> end({SessionAccount? account, bool revoke = true}) async {
    final SessionAccount? a = account ?? _account;
    if (a == null) return;
    if (revoke) {
      final Map<String, dynamic> body = <String, dynamic>{'role': a.role, 'user_id': a.userId, 'client': _isWeb ? 'web' : 'android'};
      final String? cred = _isWeb ? null : await _readCredential(a);
      if (_isWeb || cred != null) {
        if (cred != null) body['refresh_token'] = cred;
        try {
          await _http.post('session_logout.php',
              data: body,
              options: Options(
                headers: <String, dynamic>{if (_isWeb) 'X-GT-CSRF': '1'},
                sendTimeout: const Duration(seconds: 5),
                receiveTimeout: const Duration(seconds: 5),
              ));
        } catch (e) {
          debugPrint('[AUTH] logout revoke not confirmed: $e');
        }
      }
    }
    await _forgetCredential(a);
    if (_account == a) detach();
  }

  /// Sets the current account without an access token (app start while offline, or the
  /// first request after a restart): the next [validAccessToken] call renews it.
  void attach(SessionAccount account, {required bool persistent}) {
    if (_account == account) return;
    _account = account;
    _persistent = persistent;
    _setAccess(null);
  }

  /// Stops using the current account in this app WITHOUT ending its saved sign-in
  /// (account switching). The access token is dropped from memory.
  void detach() {
    _account = null;
    _persistent = false;
    _setAccess(null);
  }
}
