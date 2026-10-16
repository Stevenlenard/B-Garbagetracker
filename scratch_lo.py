import re

def rd(p):
    raw = open(p, 'rb').read().decode('utf-8')
    return ('\r\n' in raw), raw.replace('\r\n', '\n')

def wr(p, s, crlf):
    open(p, 'wb').write((s.replace('\n', '\r\n') if crlf else s).encode('utf-8'))

def rep(s, old, new, label):
    assert s.count(old) == 1, label
    return s.replace(old, new, 1)

def method_span(s, header):
    a = s.index(header)
    i = s.index('{', a)
    depth = 0
    j = i
    while True:
        c = s[j]
        if c == '{': depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return a, j + 1
        j += 1

IMPORT = "import '../widgets/logout_choice_dialog.dart';\n"

def add_import(s):
    if IMPORT in s: return s
    first = s.index('import ')
    return s[:first] + IMPORT + s[first:]

# ---------- session_manager ----------
p = 'lib/utils/session_manager.dart'
crlf, s = rd(p)
s = rep(s, """    // Safe Profile Map - NEVER STORE PLAINTEXT PASSWORDS!
    final Map<String, dynamic> profileMap = {
      'user_id': uid,
      'name': name,
      'email': email,
      'role': role,
      'profile_picture': profilePicture,
      'saved_at': DateTime.now().millisecondsSinceEpoch,
      'user_data': userMap,
    };
""", """    // A remembered account is an IDENTIFIER ONLY (to pre-fill the login form): never a
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
""", 'saveProfile')

s = rep(s, """    final String? raw = prefs.getString(keySavedProfiles);
    if (raw != null && raw.isNotEmpty) {
      try {
        final List list = jsonDecode(raw) as List;
        return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } catch (e) {""", """    final String? raw = prefs.getString(keySavedProfiles);
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
          return m;
        }).toList();
        if (changed) await prefs.setString(keySavedProfiles, jsonEncode(out));
        return out;
      } catch (e) {""", 'getSavedProfiles')

s = rep(s, """  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(keyUserData);
    await prefs.remove(keyLoginTimestamp);
    await prefs.remove(keyAuthToken);
    await prefs.setBool(keyIsLoggedIn, false);
    debugPrint("[AUTH DEBUG] Logout executed. Active session cleared.");
  }
""", """  /// Ends the authenticated session. The session, its token and timestamp are ALWAYS removed.
  ///
  /// [forgetLogin] false (default): the remembered account identifier stays so the login form
  /// can be pre-filled (the password is still required). true: the identifier of the account
  /// that is signing out is removed from this device as well.
  static Future<void> logout({bool forgetLogin = false}) async {
    final prefs = await SharedPreferences.getInstance();

    String? uid;
    if (forgetLogin) {
      try {
        final String? raw = prefs.getString(keyUserData);
        if (raw != null) {
          final Map<String, dynamic> m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
          uid = (m['user_id'] ?? m['id'] ?? m['resident_id'])?.toString();
        }
      } catch (_) {}
      uid ??= prefs.getString(keyLastUserId);
    }

    await prefs.remove(keyUserData);
    await prefs.remove(keyLoginTimestamp);
    await prefs.remove(keyAuthToken);
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
""", 'logout')
wr(p, s, crlf)

# ---------- login_screen: remembered account pre-fills, never signs in ----------
p = 'lib/screens/login_screen.dart'
crlf, s = rd(p)
a, b = method_span(s, "  void _handleSavedProfileLogin() async {")
s = s[:a] + """  /// A remembered account only pre-fills the form. It never restores a session: signing in
  /// always goes through the password check on the server.
  void _handleSavedProfileLogin() {
    final Map<String, dynamic>? p = _selectedProfile;
    if (p == null) return;
    final String ident = (p['username'] ?? p['email'] ?? p['name'] ?? '').toString();
    setState(() {
      _usernameController.text = ident;
      _passwordController.clear();
      _showSavedProfileCard = false;
    });
  }
""" + s[b:]
wr(p, s, crlf)

# ---------- admin_settings_screen ----------
p = 'lib/screens/admin_settings_screen.dart'
crlf, s = rd(p)
a, b = method_span(s, "  void _showLogoutDialog(BuildContext context) {")
s = s[:a] + """  Future<void> _showLogoutDialog(BuildContext context) async {
    final LogoutChoice choice = await showLogoutChoiceDialog(context);
    if (choice == LogoutChoice.cancel || !mounted) return;
    await SystemLogger.logEvent("LOGOUT", "Admin session ended");
    NotificationService.stopListening();
    await SessionManager.logout(forgetLogin: choice == LogoutChoice.forget);
    if (mounted) {
      CustomNotification.showTopNotification(context, "Logout successful", false);
      Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
    }
  }
""" + s[b:]
s = add_import(s)
wr(p, s, crlf)

# ---------- admin_dashboard ----------
p = 'lib/screens/admin_dashboard.dart'
crlf, s = rd(p)
a, b = method_span(s, "  void _showLogoutDialog(BuildContext context) {")
s = s[:a] + """  Future<void> _showLogoutDialog(BuildContext context) async {
    final LogoutChoice choice = await showLogoutChoiceDialog(context);
    if (choice == LogoutChoice.cancel || !mounted) return;
    await SystemLogger.logEvent("LOGOUT", "Admin session ended");
    NotificationService.stopListening();
    await SessionManager.logout(forgetLogin: choice == LogoutChoice.forget);
    await RoutePersistenceManager.clearLastRoute();
    if (mounted) {
      CustomNotification.showTopNotification(context, "Logout successful", false);
      Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
    }
  }
""" + s[b:]
s = add_import(s)
wr(p, s, crlf)

# ---------- resident_dashboard ----------
p = 'lib/screens/resident_dashboard.dart'
crlf, s = rd(p)
a, b = method_span(s, "  void _handleLogout() {")
s = s[:a] + """  Future<void> _handleLogout() async {
    final LogoutChoice choice = await showLogoutChoiceDialog(context);
    if (choice == LogoutChoice.cancel || !mounted) return;
    NotificationService.stopListening();
    await SessionManager.logout(forgetLogin: choice == LogoutChoice.forget);
    await RoutePersistenceManager.clearLastRoute();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }
""" + s[b:]
s = add_import(s)
wr(p, s, crlf)

# ---------- resident_settings_screen ----------
p = 'lib/screens/resident_settings_screen.dart'
crlf, s = rd(p)
a, b = method_span(s, "  void _showLogoutDialog(BuildContext context) async {")
s = s[:a] + """  void _showLogoutDialog(BuildContext context) async {
    final LogoutChoice choice = await showLogoutChoiceDialog(context);
    if (choice == LogoutChoice.cancel || !mounted) return;
    setState(() => _isLoggingOut = true);
    await SessionManager.logout(forgetLogin: choice == LogoutChoice.forget);
    if (mounted) {
      CustomNotification.showTopNotification(context, "Logout successful.", false);
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
    }
  }
""" + s[b:]
s = add_import(s)
wr(p, s, crlf)

# ---------- driver_settings_screen ----------
p = 'lib/screens/driver_settings_screen.dart'
crlf, s = rd(p)
s = rep(s, """    final bool isDesktop = Responsive.isDesktop(context);
    final Color themeColor = isDesktop ? Colors.red : AppColors.tealText;

    bool confirmed = await _showConfirmActionDialog(
      title: "Logout?",
      message: "Are you sure you want to end your current session?",
      confirmText: "Logout",
      cancelText: "CANCEL",
      isDestructive: false,
      icon: Icons.logout_rounded,
      iconColor: themeColor,
    );
    if (confirmed) {
      if (!mounted) return;
""", """    final LogoutChoice choice = await showLogoutChoiceDialog(context);
    final bool forget = choice == LogoutChoice.forget;
    if (choice != LogoutChoice.cancel) {
      if (!mounted) return;
""", 'driver settings confirm')
# only the two logout calls inside _showLogoutDialog
a, b = method_span(s, "  void _showLogoutDialog(BuildContext context) async {")
body = s[a:b]
assert body.count("SessionManager.logout()") == 2
body = body.replace("SessionManager.logout()", "SessionManager.logout(forgetLogin: forget)")
s = s[:a] + body + s[b:]
s = add_import(s)
wr(p, s, crlf)

# ---------- driver_dashboard ----------
p = 'lib/screens/driver_dashboard.dart'
crlf, s = rd(p)
a, b = method_span(s, "  void _showLogoutDialog(BuildContext context) {")
s = s[:a] + """  Future<void> _showLogoutDialog(BuildContext context) async {
    final LogoutChoice choice = await showLogoutChoiceDialog(context);
    if (choice == LogoutChoice.cancel || !mounted) return;
    await _handleLogout(forgetLogin: choice == LogoutChoice.forget);
  }
""" + s[b:]
s = rep(s, "  Future<void> _handleLogout() async {", "  Future<void> _handleLogout({bool forgetLogin = false}) async {", 'handleLogout sig')
a, b = method_span(s, "  Future<void> _handleLogout({bool forgetLogin = false}) async {")
body = s[a:b]
assert body.count("SessionManager.logout()") == 2
body = body.replace("SessionManager.logout()", "SessionManager.logout(forgetLogin: forgetLogin)")
s = s[:a] + body + s[b:]
s = add_import(s)
wr(p, s, crlf)
print('ok')
