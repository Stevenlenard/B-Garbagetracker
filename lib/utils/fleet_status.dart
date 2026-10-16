/// Shared rules for deciding whether a `truck_locations` node describes a truck
/// that is currently live. Every dashboard card and map uses these rules so the
/// Active Fleets list, online-driver count and map markers always agree.
///
/// Connectivity (`isOnline`) is kept separate from collection status
/// (`ACTIVE`, `IDLE`, `FULL`, `COMPLETED`, ...). A driver being online does not
/// imply the truck is actively collecting.
class FleetStatus {
  FleetStatus._();

  /// A node that has not reported within this window is no longer live.
  /// The driver heartbeat is 30 s, so this tolerates several missed beats and
  /// moderate device clock skew.
  static const int freshnessWindowMs = 180000;

  /// Driver sessions expire 12 hours after login (mirrors the driver app).
  static const int sessionLimitMs = 43200000;

  /// Statuses that mean the truck is not in service right now.
  static const Set<String> inactiveStatuses = {'OFFLINE', 'COMPLETED', 'FINISHED'};

  /// Upper-cases a status and collapses legacy connection-loss labels such as
  /// `"IDLE (LOST)"` to `IDLE`.
  static String normalizeStatus(dynamic raw, {String fallback = 'OFFLINE'}) {
    final String s = raw?.toString().trim().toUpperCase() ?? '';
    if (s.isEmpty) return fallback;
    if (s.contains('LOST')) return 'IDLE';
    return s;
  }

  static bool isInactiveStatus(String normalizedStatus) =>
      inactiveStatuses.contains(normalizedStatus);

  /// Parses a numeric (epoch ms) or ISO-like timestamp. Returns 0 when unknown.
  static int parseTimestampMs(dynamic raw) {
    if (raw is num) return raw.toInt();
    if (raw == null) return 0;
    final DateTime? parsed = DateTime.tryParse(raw.toString().trim().replaceAll(' ', 'T'));
    return parsed?.millisecondsSinceEpoch ?? 0;
  }

  /// A missing timestamp (0) is treated as fresh, matching the long-standing
  /// dashboard behaviour for nodes that never carried a `lastSeen`.
  static bool isFresh(int lastSeenMs, [int? nowMs]) {
    if (lastSeenMs == 0) return true;
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return (now - lastSeenMs).abs() < freshnessWindowMs;
  }

  static bool isSessionValid(int loginMs, [int? nowMs]) {
    if (loginMs == 0) return true;
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return (now - loginMs) < sessionLimitMs;
  }

  /// Strict connectivity flag. A missing flag is NOT online.
  ///
  /// A runtime's disconnect handler records `offline_token` (its own token) rather
  /// than flipping `isOnline`. The node is offline only when that token is the
  /// CURRENT owner's token, so a replaced runtime disconnecting late can never
  /// mark a newer session offline.
  static bool hasOnlineFlag(Map node) {
    final bool flag = node['isOnline'] == true || node['is_online'] == true || node['is_online'] == 1;
    if (!flag) return false;
    final String off = (node['offline_token'] ?? '').toString();
    final String owner = (node['owner_token'] ?? '').toString();
    if (off.isNotEmpty && owner.isNotEmpty && off == owner) return false;
    return true;
  }

  /// Identity used to count one driver once, however many runtimes/nodes mention
  /// them: the driver id when present, otherwise the upper-cased driver name.
  static String driverKey(Map node) {
    final String id = (node['driver_id'] ?? node['driverId'] ?? '').toString();
    if (id.isNotEmpty && id != 'null') return id;
    return (node['driver_name'] ?? node['driverName'] ?? 'Driver').toString().trim().toUpperCase();
  }

  /// Keeps exactly one entry per key: the one with the newest `lastSeen`
  /// (later entries win ties). This is how Active Fleets / Online Drivers stay
  /// deduplicated when a driver has several nodes or duplicate sessions.
  static Map<String, Map> latestPerKey(Iterable<MapEntry<String, Map>> candidates) {
    final Map<String, Map> out = <String, Map>{};
    for (final MapEntry<String, Map> c in candidates) {
      final Map? existing = out[c.key];
      if (existing == null ||
          parseTimestampMs(c.value['lastSeen'] ?? c.value['last_seen']) >=
              parseTimestampMs(existing['lastSeen'] ?? existing['last_seen'])) {
        out[c.key] = c.value;
      }
    }
    return out;
  }

  static bool hasValidCoords(Map node) {
    final double lat = double.tryParse((node['latitude'] ?? node['lat'] ?? '0').toString()) ?? 0.0;
    final double lng = double.tryParse((node['longitude'] ?? node['lng'] ?? '0').toString()) ?? 0.0;
    return lat != 0.0 && lng != 0.0 && lat >= -90.0 && lat <= 90.0 && lng >= -180.0 && lng <= 180.0;
  }

  /// True when the node is online, in service (not OFFLINE/COMPLETED/FINISHED),
  /// within the freshness window and within the session limit.
  static bool isLive(Map node, {int? nowMs}) {
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    if (!hasOnlineFlag(node)) return false;
    if (isInactiveStatus(normalizeStatus(node['status']))) return false;
    final int lastSeen = parseTimestampMs(node['lastSeen'] ?? node['last_seen']);
    if (!isFresh(lastSeen, now)) return false;
    final int login = parseTimestampMs(node['login_time'] ?? node['loginTime']);
    return isSessionValid(login, now);
  }

  /// Driver connectivity: owner-aware online flag AND a fresh `lastSeen`.
  /// A stale `isOnline: true` is NOT connectivity.
  static bool isConnected(Map node, {int? nowMs}) {
    if (!hasOnlineFlag(node)) return false;
    return isFresh(parseTimestampMs(node['lastSeen'] ?? node['last_seen']), nowMs);
  }

  /// Collection status, independent of connectivity. FULL and IDLE (paused) are
  /// still collection states of a connected driver.
  static String collectionState(Map node) => normalizeStatus(node['status']);

  /// True only for a valid, unfinished trip that is currently open on the node
  /// (collecting, paused or FULL). A COMPLETED/FINISHED node never has one.
  static bool hasActiveTrip(Map node) {
    if (isInactiveStatus(collectionState(node))) return false;
    if (node['trip_active'] != true) return false;
    final String session = (node['current_session'] ?? '').toString();
    return session.isNotEmpty && session != 'null';
  }

  /// An open trip that is currently collecting (not paused, not FULL).
  static bool isCollecting(Map node) {
    if (!hasActiveTrip(node)) return false;
    final String s = collectionState(node);
    return s == 'ACTIVE' || s == 'COLLECTING';
  }

  /// Age of the last real GPS fix in ms, or null when unknown. `gps_at` is stamped
  /// only by GPS publishes; the 30 s heartbeat refreshes `lastSeen` (connectivity)
  /// and never `gps_at`. Legacy nodes without `gps_at` fall back to `lastSeen`.
  static int? gpsAgeMs(Map node, {int? nowMs}) {
    final int at = parseTimestampMs(node['gps_at'] ?? node['lastSeen'] ?? node['last_seen']);
    if (at == 0) return null;
    return (nowMs ?? DateTime.now().millisecondsSinceEpoch) - at;
  }

  /// GPS freshness uses the same canonical window as connectivity. Unknown age is
  /// treated as fresh, like [isFresh].
  static bool isGpsFresh(Map node, {int? nowMs}) {
    final int? age = gpsAgeMs(node, nowMs: nowMs);
    return age == null || age.abs() < freshnessWindowMs;
  }
}
