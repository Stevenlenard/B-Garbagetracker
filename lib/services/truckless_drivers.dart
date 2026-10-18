import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../utils/fleet_status.dart';

/// Drivers who are signed in on a live trip but have no truck assigned.
///
/// Such a driver publishes no `truck_locations` node (only their trip in `driver_routes`), so no map
/// could show them. The shared truck feed asks this class for a stand-in node per driver, built from
/// the account's heartbeat (`users/{id}.lastSeen`) and the trip's last GPS fix, so every map (admin,
/// resident, driver, public) lists them as "No truck". Simulated trips and ended trips never appear.
class TrucklessDrivers {
  TrucklessDrivers._();

  static const String keyPrefix = 'NO-TRUCK-';
  static const String label = 'No truck';

  static bool _blank(Object? v) {
    final String s = (v ?? '').toString().trim();
    return s.isEmpty || s == 'Unknown' || s == 'None' || s == 'null';
  }

  /// Driver ids (with their trip id) in a `users` map that are online, fresh and truck-less.
  static Map<String, String> candidates(Map<dynamic, dynamic> users, int nowMs) {
    final Map<String, String> out = <String, String>{};
    users.forEach((dynamic id, dynamic u) {
      if (u is! Map) return;
      if ((u['role'] ?? '').toString().toLowerCase() != 'driver') return;
      if (u['isOnline'] != true) return;
      final String status = FleetStatus.normalizeStatus(u['status'], fallback: 'ACTIVE');
      if (FleetStatus.isInactiveStatus(status)) return;
      final String acct = (u['account_status'] ?? '').toString().toLowerCase();
      final Object? arch = u['is_archived'];
      if (acct == 'archived' || arch == 1 || arch == '1' || arch == true) return;
      if (!_blank(u['preferred_truck']) || _blank(u['current_trip_id'])) return;
      final int seen = FleetStatus.parseTimestampMs(u['lastSeen']);
      if (seen <= 0 || !FleetStatus.isFresh(seen, nowMs)) return;
      if (!FleetStatus.isSessionValid(FleetStatus.parseTimestampMs(u['login_time']), nowMs)) return;
      out[id.toString()] = u['current_trip_id'].toString();
    });
    return out;
  }

  /// The stand-in `truck_locations` node, or null when the trip has no usable position
  /// (no fix yet, simulated, or ended).
  static Map<String, dynamic>? buildNode({
    required String driverId,
    required Map<dynamic, dynamic> user,
    required Object? lat,
    required Object? lng,
    required Object? routeStatus,
    required Object? isSimulation,
  }) {
    final double la = double.tryParse('$lat') ?? 0, lo = double.tryParse('$lng') ?? 0;
    final String rs = '$routeStatus'.toUpperCase();
    if (la == 0 || lo == 0 || isSimulation == true || FleetStatus.isInactiveStatus(rs)) return null;
    return <String, dynamic>{
      'truck_id': label,
      'driver_id': driverId,
      'driver_name': (user['name'] ?? user['username'] ?? 'Driver').toString(),
      'latitude': la,
      'longitude': lo,
      'status': rs == 'NULL' ? 'ACTIVE' : rs,
      'isOnline': true,
      'lastSeen': FleetStatus.parseTimestampMs(user['lastSeen']),
      'login_time': FleetStatus.parseTimestampMs(user['login_time']),
      'plate_number': '',
      'no_truck': true,
    };
  }

  /// Reads the trip's last fix for one driver and builds the node (null on any problem).
  static Future<Map<String, dynamic>?> load(FirebaseDatabase db, String driverId, String tripId, Map<dynamic, dynamic> user) async {
    try {
      final DatabaseReference trip = db.ref('driver_routes/$tripId');
      final List<Object?> v = (await Future.wait(
              <String>['last_lat', 'last_lng', 'route_status', 'is_simulation'].map((String k) => trip.child(k).get())))
          .map((DataSnapshot s) => s.value)
          .toList();
      return buildNode(driverId: driverId, user: user, lat: v[0], lng: v[1], routeStatus: v[2], isSimulation: v[3]);
    } catch (e) {
      debugPrint('[NO-TRUCK] trip read failed: $e');
      return null;
    }
  }
}
