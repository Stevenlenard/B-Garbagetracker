import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../services/auth_session.dart';
import 'browser_session_stub.dart'
    if (dart.library.html) 'browser_session_web.dart';

/// Result of restoring the signed-in state when the app starts.
enum LaunchSession { proceed, needLogin }

class LaunchResult {
  const LaunchResult(this.state, {this.message});
  final LaunchSession state;
  final String? message;
}

// Session manager for handling user persistent data & saved profiles
class SessionManager {
  static const String keyUserData = "user_data";
  static const String keyIsLoggedIn = "is_logged_in";
  static const String keyRememberMe = "remember_me_enabled";
  static const String keySavedProfiles = "saved_user_profiles";
  static const String keyPrimarySavedUserId = "primary_saved_user_id";

  static const String keyAppNotifications = "app_notifications_enabled";
  static const String keyLastAutoDownload = "last_auto_download_date";

  static const String keyLastUserRole = "last_user_role";
  static const String keyLastUserId = "last_user_id";
  static const String keyLastUserPurok = "last_user_purok";
  static const String keyNotifPermissionRequested = "notif_permission_requested";
  static const String keyLoginTimestamp = "login_timestamp";
  static const String keyCompletedLogin = "completed_login_timestamp";
  static const String keyAuthToken = "auth_token";
  /// "session" = revocable server session (access token in memory only);
  /// "legacy" = older server: the login token is kept as before.
  static const String keySessionMode = "session_mode";
  /// The user's "Stay signed in" choice for the current sign-in (distinct from Remember account).
  static const String keyStaySignedIn = "stay_signed_in";

  static Future<void> saveLoginTimestamp(int timestamp) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(keyLoginTimestamp, timestamp);
  }

  static Future<void> saveUser(Map<String, dynamic> userMap, {bool rememberMe = true}) async {
    final prefs = await SharedPreferences.getInstance();
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (userMap['login_time'] == null && userMap['loginTime'] == null) {
      userMap['login_time'] = now;
    }
    await prefs.setInt(keyLoginTimestamp, (userMap['login_time'] ?? userMap['loginTime'] ?? now) as int);
    // The request token is kept apart from the profile (profile saves/refreshes
    // rewrite the profile JSON). Saving ANOTHER account without a token clears the
    // previous one, so one account's token can never be sent for another account;
    // a profile update of the same account keeps its token.
    final Object? token = userMap['auth_token'];
    final Map<String, dynamic> profile = Map<String, dynamic>.from(userMap)..remove('auth_token');
    if (token is String && token.isNotEmpty) {
      await prefs.setString(keyAuthToken, token);
    } else if (!_sameAccount(prefs.getString(keyUserData), profile)) {
      await prefs.remove(keyAuthToken);
      await prefs.remove(keySessionMode);
      final SessionAccount? current = AuthSession.instance.account;
      if (current != null && current != SessionAccount.fromProfile(profile)) AuthSession.instance.detach();
    }
    await prefs.setString(keyUserData, jsonEncode(profile));
    await prefs.setBool(keyIsLoggedIn, true);
    await prefs.setBool(keyRememberMe, rememberMe);

    final String? uid = (userMap['user_id'] ?? userMap['id'] ?? userMap['resident_id'])?.toString();
    final String? role = userMap['role']?.toString();
    
    // Save last user info for persistent notifications
    if (role != null) await prefs.setString(keyLastUserRole, role);
    if (uid != null) await prefs.setString(keyLastUserId, uid);
    if (userMap['purok'] != null) await prefs.setString(keyLastUserPurok, userMap['purok'].toString());

    if (rememberMe) {
      await saveProfile(userMap);
    }

    debugPrint("[AUTH DEBUG] Firebase currentUser exists: true");
    debugPrint("[AUTH DEBUG] Saved profile exists: true");
    debugPrint("[AUTH DEBUG] User ID: ${uid ?? 'unknown'}");
    debugPrint("[AUTH DEBUG] Role: ${role ?? 'unknown'}");
    debugPrint("[AUTH DEBUG] Auto-login result: SUCCESS");
  }

  static bool _sameAccount(String? storedJson, Map<String, dynamic> next) {
    if (storedJson == null) return false;
    try {
      final SessionAccount? a = SessionAccount.fromProfile(Map<String, dynamic>.from(jsonDecode(storedJson) as Map));
      return a != null && a == SessionAccount.fromProfile(next);
    } catch (_) {
      return false;
    }
  }

  /// Signs an account in after a password (or 2FA) login.
  ///
  /// [session] is the server's `session` block (revocable session); without it the server
  /// is an older one and the legacy token in [user] is kept as before.
  /// [rememberAccount] keeps the account in Saved Logins; with a revocable server session it
  /// can then be resumed with ONE TAP (no password) until it is forgotten or ended on the
  /// server. [staySignedIn] additionally continues automatically when the app starts.
  /// The login request asks for a persistent session when either is chosen
  /// ([AuthSession.loginFields] with `staySignedIn || rememberAccount`).
  static Future<void> startSession(
    Map<String, dynamic> user, {
    required bool rememberAccount,
    required bool staySignedIn,
    Map<String, dynamic>? session,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(keyAuthToken); // never carry a previous account's token over
    await prefs.remove(keyUserData); // a fresh sign-in, even for the same account
    final SessionAccount? account = SessionAccount.fromProfile(user);
    if (session != null && account != null && session['access_token'] != null) {
      final Map<String, dynamic> profile = Map<String, dynamic>.from(user)..remove('auth_token');
      await saveUser(profile, rememberMe: rememberAccount);
      await AuthSession.instance.begin(account, session);
      await prefs.setString(keySessionMode, 'session');
      await _setOneTap(account, session['persistent'] == true && rememberAccount);
      markBrowserSession();
    } else {
      AuthSession.instance.detach();
      await saveUser(Map<String, dynamic>.from(user), rememberMe: rememberAccount);
      await prefs.setString(keySessionMode, 'legacy');
      if (account != null) await _setOneTap(account, false);
    }
    await prefs.setBool(keyStaySignedIn, staySignedIn);
    if (account != null) await prefs.setBool(_keyStayByAccount(account), staySignedIn);
  }

  /// The "Stay signed in" choice last made on the password form for [account] (reused by a
  /// one-tap sign-in of that account).
  static String _keyStayByAccount(SessionAccount account) => 'stay_signed_in_${account.storageKey}';

  static Future<bool> isSessionMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(keySessionMode) == 'session';
  }

  /// Whether the current sign-in should survive an app restart. Sign-ins from before this
  /// setting existed keep their previous behaviour (stay signed in).
  static Future<bool> isStaySignedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyStaySignedIn) ?? true;
  }

  /// Whether logging out can keep this account's saved sign-in for one-tap sign-in: a
  /// persistent revocable session that is also remembered in Saved Logins.
  static Future<bool> canSwitchAccount() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(keySessionMode) != 'session') return false;
    final String? raw = prefs.getString(keyUserData);
    try {
      final SessionAccount? a = raw == null ? null : SessionAccount.fromProfile(Map<String, dynamic>.from(jsonDecode(raw) as Map));
      if (a == null) return false;
      return await _isOneTap(a);
    } catch (_) {
      return false;
    }
  }

  /// One-tap sign-in from Saved Logins ("Logout and Remember Login" keeps a revocable
  /// server session). Visitors from the public page and Truck Buddy are sent to a fresh
  /// sign-in page that never lists saved accounts (`/login_new`).
  static const bool oneTapEnabled = true;

  static Future<bool> _isOneTap(SessionAccount account) async {
    if (!oneTapEnabled) return false;
    return (await getSavedProfiles()).any((Map<String, dynamic> p) => SessionAccount.fromProfile(p) == account && p['one_tap'] == true);
  }

  /// Marks a remembered account as resumable with one tap (non-secret flag; the
  /// credential itself is in the Keystore or an HttpOnly cookie).
  static Future<void> _setOneTap(SessionAccount account, bool value) async {
    if (!oneTapEnabled) value = false;
    final prefs = await SharedPreferences.getInstance();
    final List<Map<String, dynamic>> profiles = await getSavedProfiles();
    bool changed = false;
    for (final Map<String, dynamic> p in profiles) {
      if (SessionAccount.fromProfile(p) == account && (p['one_tap'] == true) != value) {
        if (value) {
          p['one_tap'] = true;
        } else {
          p.remove('one_tap');
        }
        changed = true;
      }
    }
    if (changed) await prefs.setString(keySavedProfiles, jsonEncode(profiles));
  }

  /// Restores the signed-in state on app start.
  ///  - Revocable session: renewed with the saved credential. Ended on the server =>
  ///    password required. Server unreachable => continue with the cached profile (it is
  ///    renewed on the next request), so a driver offline at start-up keeps working.
  ///  - Without "Stay signed in": a new app start requires the password (Android), or
  ///    whatever the browser session still holds (Web).
  ///  - Legacy server: unchanged behaviour.
  static Future<LaunchResult> restoreOnLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(keyIsLoggedIn) ?? false)) return const LaunchResult(LaunchSession.needLogin);
    final String? raw = prefs.getString(keyUserData);
    Map<String, dynamic>? stored;
    try {
      stored = raw == null ? null : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {}
    final SessionAccount? account = stored == null ? null : SessionAccount.fromProfile(stored);
    if (stored == null || account == null) return const LaunchResult(LaunchSession.needLogin);

    final bool stay = prefs.getBool(keyStaySignedIn) ?? true;
    final bool sessionMode = prefs.getString(keySessionMode) == 'session';

    if (!sessionMode) {
      if (stay) return const LaunchResult(LaunchSession.proceed);
      await logout(); // keeps the remembered name
      return const LaunchResult(LaunchSession.needLogin);
    }
    if (!stay) {
      final bool web = AuthSession.instance.isWeb;
      // Web: a reload of the same tab continues; a new browser session does not.
      if (!web || !browserSessionMarked()) {
        if (await _isOneTap(account)) {
          // Remembered with a saved sign-in: no automatic sign-in, but the account stays
          // available for one tap on the sign-in screen.
          await logout(keepSignedIn: true);
          return const LaunchResult(LaunchSession.needLogin);
        }
        if (!web) {
          // The non-persistent credential lived in memory only.
          await logout(revoke: false);
          return const LaunchResult(LaunchSession.needLogin);
        }
      }
    }
    final RefreshResult r = await AuthSession.instance.refresh(account: account);
    switch (r.outcome) {
      case RefreshOutcome.ok:
        if (r.user != null) {
          await saveUser(<String, dynamic>{...stored, ...r.user!}, rememberMe: prefs.getBool(keyRememberMe) ?? false);
        }
        markBrowserSession();
        return const LaunchResult(LaunchSession.proceed);
      case RefreshOutcome.ended:
        await logout(revoke: false);
        return LaunchResult(LaunchSession.needLogin, message: r.message ?? 'Your saved sign-in has ended. Please enter your password.');
      case RefreshOutcome.network:
      case RefreshOutcome.unavailable:
        if (!stay) return const LaunchResult(LaunchSession.needLogin);
        AuthSession.instance.attach(account, persistent: true);
        return const LaunchResult(LaunchSession.proceed);
    }
  }

  /// One-tap sign-in from Saved Logins (only for accounts marked `one_tap`).
  /// Returns null on success, otherwise the message to show (the password is then needed).
  static Future<String?> resumeSavedAccount(Map<String, dynamic> profile) async {
    final SessionAccount? account = SessionAccount.fromProfile(profile);
    if (account == null || !oneTapEnabled) return 'Please enter your password.';
    final RefreshResult r = await AuthSession.instance.refresh(account: account);
    if (r.outcome == RefreshOutcome.network) {
      return 'Could not reach the server. Check your connection and try again.';
    }
    if (!r.isOk || r.user == null) {
      await _setOneTap(account, false);
      return r.message ?? 'Your saved sign-in has ended. Please enter your password.';
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(keyAuthToken);
    await prefs.remove(keyUserData);
    final Map<String, dynamic> user = Map<String, dynamic>.from(r.user!)..remove('login_time');
    await saveUser(user, rememberMe: true); // a new app sign-in: new login time
    await prefs.setString(keySessionMode, 'session');
    // A one-tap sign-in does not switch on automatic sign-in at app start; "Stay signed in"
    // is chosen on the password form.
    await prefs.setBool(keyStaySignedIn, prefs.getBool(_keyStayByAccount(account)) ?? false);
    await _setOneTap(account, AuthSession.instance.isPersistent);
    markBrowserSession();
    return null;
  }

  static Future<void> saveProfile(Map<String, dynamic> userMap) async {
    final prefs = await SharedPreferences.getInstance();
    final String? uid = (userMap['user_id'] ?? userMap['id'] ?? userMap['resident_id'])?.toString();
    if (uid == null || uid.isEmpty) return;

    final String name = (userMap['name'] ?? userMap['username'] ?? 'User').toString();
    final String email = (userMap['email'] ?? userMap['username'] ?? '').toString();
    final String role = (userMap['role'] ?? 'resident').toString();
    final String? profilePicture = userMap['profile_picture']?.toString() ?? userMap['profilePicture']?.toString();

    // A remembered account is an IDENTIFIER ONLY (to pre-fill the login form): never a
    // password, an auth token, or the session payload.
    final Map<String, dynamic> profileMap = {
      'user_id': uid,
      'name': name,
      'username': (userMap['username'] ?? email).toString(),
      'email': email,
      'role': role,
      'profile_picture': profilePicture,
      'saved_at': DateTime.now().millisecondsSinceEpoch,
    };

    List<Map<String, dynamic>> profiles = await getSavedProfiles();
    // A profile refresh of the same account keeps its one-tap flag (it is set and cleared
    // only by sign-in / logout through _setOneTap).
    final SessionAccount? acct = SessionAccount.fromProfile(profileMap);
    if (acct != null && profiles.any((p) => SessionAccount.fromProfile(p) == acct && p['one_tap'] == true)) {
      profileMap['one_tap'] = true;
    }
    profiles.removeWhere((p) => (p['user_id'] ?? p['id']).toString() == uid || (p['email'] ?? '').toString().toLowerCase() == email.toLowerCase());
    profiles.insert(0, profileMap); // Put latest saved profile at top

    await prefs.setString(keySavedProfiles, jsonEncode(profiles));
    await prefs.setString(keyPrimarySavedUserId, uid);
  }

  static Future<List<Map<String, dynamic>>> getSavedProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(keySavedProfiles);
    if (raw != null && raw.isNotEmpty) {
      try {
        final List list = jsonDecode(raw) as List;
        bool changed = false;
        final List<Map<String, dynamic>> out = list.map((e) {
          final Map<String, dynamic> m = Map<String, dynamic>.from(e as Map);
          // Older versions stored the whole session (including the auth token) here.
          final Object? ud = m['user_data'];
          if (ud is Map) {
            m['username'] ??= (ud['username'] ?? m['email'] ?? '').toString();
            changed = true;
          }
          if (m.remove('user_data') != null) changed = true;
          if (m.remove('auth_token') != null) changed = true;
          if (!oneTapEnabled && m.remove('one_tap') != null) changed = true; // no passwordless resume
          return m;
        }).toList();
        if (changed) await prefs.setString(keySavedProfiles, jsonEncode(out));
        return out;
      } catch (e) {
        debugPrint("[AUTH DEBUG] Error parsing saved profiles: $e");
      }
    }
    return [];
  }

  static Future<Map<String, dynamic>?> getPrimarySavedProfile() async {
    final profiles = await getSavedProfiles();
    if (profiles.isNotEmpty) {
      return profiles.first;
    }
    return null;
  }

  static Future<void> removeSavedProfile(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    List<Map<String, dynamic>> profiles = await getSavedProfiles();
    profiles.removeWhere((p) => (p['user_id'] ?? p['id']).toString() == userId);
    
    await prefs.setString(keySavedProfiles, jsonEncode(profiles));
    if (profiles.isEmpty) {
      await prefs.remove(keyPrimarySavedUserId);
      await prefs.setBool(keyRememberMe, false);
      debugPrint("[AUTH DEBUG] Saved profile exists: false");
    } else {
      await prefs.setString(keyPrimarySavedUserId, (profiles.first['user_id'] ?? profiles.first['id']).toString());
    }
  }

  static Future<bool> isRememberMeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyRememberMe) ?? false;
  }

  static Future<void> setRememberMeEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyRememberMe, enabled);
  }

  static Future<UserData?> getUser() async {
    final prefs = await SharedPreferences.getInstance();
    final userStr = prefs.getString(keyUserData);
    if (userStr != null) {
      try {
        return UserData.fromJson(jsonDecode(userStr));
      } catch (e) {
        debugPrint("Error parsing user data: $e");
      }
    }
    return null;
  }

  static Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyIsLoggedIn) ?? false;
  }

  /// Login session (its login timestamp) in which the driver already confirmed
  /// COMPLETED. A restart of the app in that session must not open a new trip.
  static Future<void> saveCompletedLoginTimestamp(int loginTimestamp) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(keyCompletedLogin, loginTimestamp);
  }

  static Future<int?> getCompletedLoginTimestamp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(keyCompletedLogin);
  }

  /// Token for API requests: the short-lived access token of a revocable session
  /// (renewed transparently), or the legacy login token of an older server.
  static Future<String?> getAuthToken() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(keySessionMode) == 'session') {
      if (!AuthSession.instance.hasSession && (prefs.getBool(keyIsLoggedIn) ?? false)) {
        final String? raw = prefs.getString(keyUserData);
        try {
          final SessionAccount? a = raw == null ? null : SessionAccount.fromProfile(Map<String, dynamic>.from(jsonDecode(raw) as Map));
          if (a != null) AuthSession.instance.attach(a, persistent: prefs.getBool(keyStaySignedIn) ?? true);
        } catch (_) {}
      }
      return AuthSession.instance.validAccessToken();
    }
    final String? t = prefs.getString(keyAuthToken);
    return (t == null || t.isEmpty) ? null : t;
  }

  /// Token issued by the 2FA verification step (the profile is saved separately).
  static Future<void> saveAuthToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyAuthToken, token);
  }

  static Future<int?> getLoginTimestamp() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(keyLoginTimestamp);
  }

  /// Ends the authenticated session in this app. The session, its tokens and timestamp are
  /// ALWAYS removed from the app.
  ///
  /// [forgetLogin] false (default): the remembered account name stays so the login form can
  /// be pre-filled. true: the account is removed from this device as well.
  /// [keepSignedIn] ("Logout and Remember Login"): for an account remembered with a saved
  /// sign-in (one-tap), the saved sign-in is NOT ended, so the account can be resumed with one
  /// tap from Saved Logins. Without one, it behaves like a normal logout.
  /// Otherwise the saved sign-in is revoked on the server ([revoke]) and deleted locally.
  static Future<void> logout({bool forgetLogin = false, bool keepSignedIn = false, bool revoke = true}) async {
    final prefs = await SharedPreferences.getInstance();

    String? uid;
    SessionAccount? account;
    try {
      final String? raw = prefs.getString(keyUserData);
      if (raw != null) {
        final Map<String, dynamic> m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        uid = (m['user_id'] ?? m['id'] ?? m['resident_id'])?.toString();
        account = SessionAccount.fromProfile(m);
      }
    } catch (_) {}
    if (forgetLogin) uid ??= prefs.getString(keyLastUserId);

    final bool sessionMode = prefs.getString(keySessionMode) == 'session';
    if (account != null && sessionMode) {
      if (keepSignedIn && !forgetLogin && await _isOneTap(account)) {
        AuthSession.instance.detach();
      } else {
        await AuthSession.instance.end(account: account, revoke: revoke);
        await _setOneTap(account, false);
      }
    } else {
      AuthSession.instance.detach();
    }
    clearBrowserSessionMark();
    if (forgetLogin && account != null) await prefs.remove(_keyStayByAccount(account));

    await prefs.remove(keyUserData);
    await prefs.remove(keyLoginTimestamp);
    await prefs.remove(keyAuthToken);
    await prefs.remove(keySessionMode);
    await prefs.remove(keyStaySignedIn);
    await prefs.setBool(keyIsLoggedIn, false);

    if (forgetLogin) {
      if (uid != null && uid.isNotEmpty) await removeSavedProfile(uid);
      await prefs.remove(keyLastUserRole);
      await prefs.remove(keyLastUserId);
      await prefs.remove(keyLastUserPurok);
      await prefs.setBool(keyRememberMe, false);
    }
    debugPrint("[AUTH DEBUG] Logout executed. Active session cleared (forget: $forgetLogin).");
  }

  static Future<void> setAppNotificationsEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyAppNotifications, enabled);
  }

  static Future<bool> isAppNotificationsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(keyNotifPermissionRequested)) return false;
    return prefs.getBool(keyAppNotifications) ?? true;
  }

  static Future<void> setNotifPermissionRequested(bool requested) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyNotifPermissionRequested, requested);
  }

  static Future<bool> isNotifPermissionRequested() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyNotifPermissionRequested) ?? false;
  }

  static Future<Map<String, String?>> getLastUserInfo() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'role': prefs.getString(keyLastUserRole),
      'userId': prefs.getString(keyLastUserId),
      'purok': prefs.getString(keyLastUserPurok),
    };
  }

  static Future<void> setLastAutoDownloadDate(String date) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyLastAutoDownload, date);
  }

  static Future<String?> getLastAutoDownloadDate() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(keyLastAutoDownload);
  }
}
