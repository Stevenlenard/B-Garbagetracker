import 'fleet_status.dart';

/// One live truck in a [FleetSnapshot].
class LiveTruck {
  const LiveTruck({required this.nodeKey, required this.driverKey, required this.node});
  final String nodeKey;
  final String driverKey;
  final Map node;

  bool get isCompleted {
    final String s = FleetStatus.normalizeStatus(node['status']);
    return s == 'COMPLETED' || s == 'FINISHED';
  }
}

/// Why nodes were left out of a snapshot (diagnostics and tests only).
enum FleetRejection { nonDriver, excluded, offline, inactiveStatus, stale, sessionExpired, noCoords, noPresence, duplicate }

/// The single, deduplicated, freshness-filtered fleet view that Admin cards,
/// Resident cards and the live maps are all built from.
///
/// Concepts kept apart (see [FleetStatus]):
///  * connectivity  - owner-aware `isOnline` flag AND a fresh heartbeat/GPS `lastSeen`
///  * collection    - ACTIVE / IDLE(PAUSED) / FULL / COMPLETED (never implies offline)
///  * trip          - `trip_active` + `current_session` (a COMPLETED trip is never active)
///
/// Active Fleets == Online Drivers == [count]: both are "live drivers, one per driver".
/// FULL and IDLE (paused) trucks stay in the snapshot; COMPLETED/FINISHED/OFFLINE do not.
class FleetSnapshot {
  FleetSnapshot._(this.trucks, this.rejections);

  final List<LiveTruck> trucks;
  final Map<FleetRejection, int> rejections;

  int get count => trucks.length;

  /// Connected drivers, one per driver. With `includeCompleted` this also covers a
  /// driver who confirmed COMPLETED but is still logged in (connectivity is not a
  /// collection status).
  int get onlineDrivers => count;

  /// Trucks in the collection fleet: connected and not COMPLETED/FINISHED. ACTIVE,
  /// PAUSED (IDLE) and FULL all stay in it; COMPLETED leaves it.
  int get activeFleets => trucks.where((LiveTruck t) => !t.isCompleted).length;

  /// Trucks that are collecting right now (status ACTIVE).
  int get collecting => trucks
      .where((LiveTruck t) => FleetStatus.normalizeStatus(t.node['status']) == 'ACTIVE')
      .length;

  /// The fleet list (cards, lists): connected trucks that are not COMPLETED.
  List<LiveTruck> get fleetTrucks => trucks.where((LiveTruck t) => !t.isCompleted).toList(growable: false);

  /// Live trucks per normalized collection status (ACTIVE / IDLE / FULL / ...).
  Map<String, int> get byStatus {
    final Map<String, int> out = <String, int>{};
    for (final LiveTruck t in trucks) {
      final String s = FleetStatus.normalizeStatus(t.node['status']);
      out[s] = (out[s] ?? 0) + 1;
    }
    return out;
  }

  Iterable<String> get nodeKeys => trucks.map((LiveTruck t) => t.nodeKey);

  /// Change signature of EVERYTHING the counts are derived from (every live truck, COMPLETED
  /// included, plus the counts). A UI that only re-renders when this changes can therefore
  /// never keep a stale Online Drivers / Active Fleets figure.
  String get signature {
    final List<String> parts = trucks
        .map((LiveTruck t) =>
            '${t.nodeKey}|${t.driverKey}|${FleetStatus.normalizeStatus(t.node['status'])}|${t.node['lastSeen'] ?? t.node['last_seen']}')
        .toList()
      ..sort();
    return 'online=$onlineDrivers;active=$activeFleets;${parts.join(';')}';
  }

  /// Nodes that are never drivers: residents/admins, archived accounts and the
  /// reserved system/test truck ids.
  static bool isNonDriverNode(Map node, String nodeKey) {
    final String role = (node['role'] ?? '').toString().toLowerCase();
    if (role == 'resident' || role == 'admin' || role == 'administrator') return true;

    final String accountStatus = (node['account_status'] ?? node['status'] ?? '').toString().toLowerCase();
    final dynamic archived = node['is_archived'] ?? node['isArchived'];
    if (accountStatus == 'archived' ||
        archived == 1 ||
        archived == '1' ||
        archived == true ||
        archived == 'true') {
      return true;
    }

    final String tid = (node['truck_id'] ?? nodeKey).toString().toUpperCase();
    return tid.contains('ADMIN') || tid.contains('SYSTEM') || tid.contains('USER');
  }

  /// Builds the snapshot from the raw `truck_locations` map.
  ///
  /// [exclude] adds caller-specific eligibility (for example Admin's account
  /// validity from `users`); [requirePresence] adds an optional second presence
  /// source. Everything else - freshness window, status rules, session limit,
  /// per-driver dedupe - is shared and not configurable here.
  static FleetSnapshot derive(
    Object? raw, {
    int? nowMs,
    bool requireCoords = false,
    bool includeCompleted = false,
    bool Function(String nodeKey, Map node)? exclude,
    bool Function(String driverKey, Map node)? requirePresence,
  }) {
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final Map<FleetRejection, int> rejections = <FleetRejection, int>{};
    void reject(FleetRejection r) => rejections[r] = (rejections[r] ?? 0) + 1;

    final List<MapEntry<String, MapEntry<String, Map>>> candidates = [];
    if (raw is Map) {
      raw.forEach((dynamic key, dynamic value) {
        if (value is! Map) return;
        final String nodeKey = key.toString();
        if (isNonDriverNode(value, nodeKey)) {
          reject(FleetRejection.nonDriver);
          return;
        }
        if (exclude != null && exclude(nodeKey, value)) {
          reject(FleetRejection.excluded);
          return;
        }
        if (!FleetStatus.hasOnlineFlag(value)) {
          reject(FleetRejection.offline);
          return;
        }
        final String normalized = FleetStatus.normalizeStatus(value['status']);
        final bool completed = normalized == 'COMPLETED' || normalized == 'FINISHED';
        if (normalized == 'OFFLINE' || (completed && !includeCompleted)) {
          reject(FleetRejection.inactiveStatus);
          return;
        }
        final int lastSeen = FleetStatus.parseTimestampMs(value['lastSeen'] ?? value['last_seen']);
        if (!FleetStatus.isFresh(lastSeen, now)) {
          reject(FleetRejection.stale);
          return;
        }
        final int login = FleetStatus.parseTimestampMs(value['login_time'] ?? value['loginTime']);
        if (!FleetStatus.isSessionValid(login, now)) {
          reject(FleetRejection.sessionExpired);
          return;
        }
        if (requireCoords && !FleetStatus.hasValidCoords(value)) {
          reject(FleetRejection.noCoords);
          return;
        }
        final String driverKey = FleetStatus.driverKey(value);
        if (requirePresence != null && !requirePresence(driverKey, value)) {
          reject(FleetRejection.noPresence);
          return;
        }
        candidates.add(MapEntry(driverKey, MapEntry(nodeKey, value)));
      });
    }

    // One entry per driver: the newest `lastSeen` wins (later wins ties), exactly
    // like FleetStatus.latestPerKey, but the winning node key is kept too.
    final Map<String, MapEntry<String, Map>> winners = <String, MapEntry<String, Map>>{};
    for (final MapEntry<String, MapEntry<String, Map>> c in candidates) {
      final MapEntry<String, Map>? existing = winners[c.key];
      if (existing == null) {
        winners[c.key] = c.value;
        continue;
      }
      final int a = FleetStatus.parseTimestampMs(c.value.value['lastSeen'] ?? c.value.value['last_seen']);
      final int b = FleetStatus.parseTimestampMs(existing.value['lastSeen'] ?? existing.value['last_seen']);
      reject(FleetRejection.duplicate);
      if (a >= b) winners[c.key] = c.value;
    }

    final List<LiveTruck> trucks = winners.entries
        .map((MapEntry<String, MapEntry<String, Map>> e) =>
            LiveTruck(nodeKey: e.value.key, driverKey: e.key, node: e.value.value))
        .toList(growable: false);
    return FleetSnapshot._(trucks, rejections);
  }
}
