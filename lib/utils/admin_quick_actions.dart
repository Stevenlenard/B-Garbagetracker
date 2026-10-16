import 'package:flutter/material.dart';

/// Admin dashboard destinations (indexes of the dashboard's IndexedStack).
class AdminDestinations {
  AdminDestinations._();

  static const int dashboard = 0;
  static const int liveMap = 1;
  static const int analytics = 2;
  static const int incidents = 3;
  static const int users = 4;
  static const int database = 5;
  static const int settings = 6;

  /// The existing, standalone Route History screen (not part of the live map).
  static const int routeHistory = 7;

  /// Route Assignments (driver + truck + service areas per collection day).
  static const int routeAssignments = 8;

  /// Collection Route Optimization (collection status + recorded-path comparison).
  static const int collectionRouteOptimization = 9;
}

class AdminQuickAction {
  const AdminQuickAction({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.targetIndex,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final int targetIndex;
}

/// The permanent Quick Actions of the Admin dashboard (same list on Android and Web,
/// both layouts).
const List<AdminQuickAction> kAdminQuickActions = <AdminQuickAction>[
  AdminQuickAction(
    title: 'Analytics',
    subtitle: 'View system performance',
    icon: Icons.bar_chart_rounded,
    color: Color(0xFF1E88E5),
    targetIndex: AdminDestinations.analytics,
  ),
  AdminQuickAction(
    title: 'Users',
    subtitle: 'Manage account access',
    icon: Icons.people_outline_rounded,
    color: Color(0xFF8E24AA),
    targetIndex: AdminDestinations.users,
  ),
  AdminQuickAction(
    title: 'Database Center',
    subtitle: 'System record management',
    icon: Icons.storage_rounded,
    color: Color(0xFF009688),
    targetIndex: AdminDestinations.database,
  ),
  AdminQuickAction(
    title: 'Incidents',
    subtitle: 'Review resident reports',
    icon: Icons.chat_bubble_rounded,
    color: Color(0xFFE53935),
    targetIndex: AdminDestinations.incidents,
  ),
  AdminQuickAction(
    title: 'Driver Route History',
    subtitle: 'View recorded collection routes, trip details, and associated load history.',
    icon: Icons.route_rounded,
    color: Color(0xFFFB8C00),
    targetIndex: AdminDestinations.routeHistory,
  ),
  AdminQuickAction(
    title: 'Route Assignments',
    subtitle: 'Assign drivers, trucks and service areas to collection days',
    icon: Icons.assignment_ind_rounded,
    color: Color(0xFF3949AB),
    targetIndex: AdminDestinations.routeAssignments,
  ),
];
