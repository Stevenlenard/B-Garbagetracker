import 'package:flutter/material.dart';

import '../models/user.dart';
import '../utils/session_manager.dart';

/// Guards a role's screens when they are opened by route (e.g. a web address such as
/// `#/admin_dashboard`, a reload, or a stale tab): the signed-in account must have one of
/// [roles]. Not signed in -> the sign-in flow (`/splash`); another role -> that account's own
/// dashboard. On the web all tabs share one sign-in, so a tab left on another role's page
/// follows the account that is signed in now.
///
/// This is a client-side guard. The server checks a signed role token on endpoints that use
/// `gt_require_role`; enforcing it for every request is a separate server setting.
class RoleGate extends StatefulWidget {
  const RoleGate({super.key, required this.roles, required this.child});

  final Set<String> roles;
  final Widget child;

  static String homeRouteFor(String role) => switch (role.toLowerCase()) {
        'admin' => '/admin_dashboard',
        'driver' => '/driver_dashboard',
        'resident' => '/resident_dashboard',
        _ => '/splash',
      };

  @override
  State<RoleGate> createState() => _RoleGateState();
}

class _RoleGateState extends State<RoleGate> {
  bool _allowed = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final bool loggedIn = await SessionManager.isLoggedIn();
    final UserData? user = loggedIn ? await SessionManager.getUser() : null;
    if (!mounted) return;
    final String role = (user?.role ?? '').toLowerCase();
    if (user != null && widget.roles.contains(role)) {
      setState(() => _allowed = true);
      return;
    }
    final String target = user == null ? '/splash' : RoleGate.homeRouteFor(role);
    Navigator.of(context).pushNamedAndRemoveUntil(target, (Route<dynamic> r) => false);
  }

  @override
  Widget build(BuildContext context) {
    if (_allowed) return widget.child;
    return const Scaffold(
      backgroundColor: Colors.white,
      body: Center(child: CircularProgressIndicator(color: Color(0xFF00796B))),
    );
  }
}
