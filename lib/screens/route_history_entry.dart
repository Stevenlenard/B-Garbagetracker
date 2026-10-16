import 'package:flutter/material.dart';

import '../utils/admin_quick_actions.dart';
import '../utils/session_manager.dart';
import 'admin_dashboard.dart';
import 'route_history_screen.dart';

/// Target of the `/route_history` route (e.g. a direct web link or refresh).
///
/// An Admin lands INSIDE the dashboard shell (sidebar visible) on Route History; every
/// other role keeps the existing standalone screen. The Route History screen itself is
/// reused, not duplicated.
class RouteHistoryEntry extends StatelessWidget {
  const RouteHistoryEntry({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: SessionManager.getUser(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final String role = (snapshot.data?.role ?? '').toLowerCase();
        if (role == 'admin') {
          return const AdminDashboard(initialIndex: AdminDestinations.routeHistory);
        }
        return const RouteHistoryScreen();
      },
    );
  }
}
