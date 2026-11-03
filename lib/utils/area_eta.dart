import 'dart:math' as math;

import 'eta_policy.dart';
import 'fleet_status.dart';
import 'resident_alert_rules.dart';

/// THE arrival estimate of a collection area: one record per truck, computed once by the driver app from the
/// truck's distance to the area's circle, and published inside the truck's live location
/// (`truck_locations/{truck}/area_eta`).
///
/// Every resident of the area gets this same estimate, wherever they live or stand; the alerts (15 / 10 / 5 min), the
/// resident countdown, the fleet cards of the Admin and the residents' map, and Collection Route Optimization all read
/// it instead of computing their own. The arrival time is an absolute server time, so every device counts down to the
/// same moment and a late or repeated read can never show a different number.
class AreaEta {
  const AreaEta({
    required this.area,
    required this.areaKey,
    required this.minutes,
    required this.arriveAtMs,
    required this.computedAtMs,
    this.tripId = '',
    this.method = EtaPolicy.method,
  });

  /// Field of the truck node that carries the estimate.
  static const String field = 'area_eta';

  /// A new estimate this close (in time) to the one already published for the same area keeps the published one,
  /// so the countdown does not twitch with every GPS fix.
  static const int keepWithinMs = 20000;

  final String area;
  final String areaKey;

  /// Whole minutes, as stated in the alerts.
  final int minutes;

  /// When the truck is expected at the area (server clock, epoch ms).
  final int arriveAtMs;

  /// When the driver app computed it (server clock, epoch ms).
  final int computedAtMs;

  /// The trip the estimate belongs to: an estimate left on the truck node by an earlier trip is never shown.
  final String tripId;
  final String method;

  Map<String, Object?> toJson() => <String, Object?>{
        'area': area,
        'area_key': areaKey,
        'minutes': minutes,
        'arrive_at_ms': arriveAtMs,
        'computed_at_ms': computedAtMs,
        'trip_id': tripId,
        'method': method,
      };

  int secondsLeft(int nowMs) => ((arriveAtMs - nowMs) / 1000).round();

  /// Minutes left, rounded up; 0 means due now.
  int minutesLeft(int nowMs) {
    final int s = secondsLeft(nowMs);
    return s <= 0 ? 0 : (s / 60).ceil();
  }

  bool isForPurok(String? purok) => ResidentAlertRules.samePurok(area, purok);

  /// The published arrival moves by at most this per second of real time (and at least [minShiftMs] per update), so a
  /// sudden swing of the raw estimate (speed sensor glitch, a stop, a new speed window) reaches the residents as a
  /// steady correction within a minute instead of a jump.
  static const double maxShiftPerSecond = 2.0;
  static const int minShiftMs = 30000;

  /// The estimate of a new fix, made steady against the one already published for the same area and trip:
  /// GPS noise (under [keepWithinMs]) keeps the published arrival, and a larger change is followed at a bounded rate.
  static AreaEta stabilize(AreaEta? previous, AreaEta next) {
    if (previous == null || previous.areaKey != next.areaKey || previous.tripId != next.tripId) return next;
    final int diff = next.arriveAtMs - previous.arriveAtMs;
    int arrive = next.arriveAtMs;
    if (diff.abs() < keepWithinMs) {
      arrive = previous.arriveAtMs;
    } else {
      final int elapsed = (next.computedAtMs - previous.computedAtMs).clamp(0, 600000).toInt();
      final int maxShift = math.max(minShiftMs, (elapsed * maxShiftPerSecond).round());
      arrive = previous.arriveAtMs + diff.clamp(-maxShift, maxShift).toInt();
    }
    return AreaEta(
      area: next.area,
      areaKey: next.areaKey,
      minutes: math.max(1, ((arrive - next.computedAtMs) / 60000).ceil()),
      arriveAtMs: arrive,
      computedAtMs: next.computedAtMs,
      tripId: next.tripId,
      method: next.method,
    );
  }

  /// Countdown text for [secondsLeft]. Reaching zero is NOT an arrival (only the GPS-confirmed visit is): it says
  /// "< 1 min" for as long as the truck keeps being due, and the estimate itself is renewed or withdrawn by the driver.
  static String countdown(int secondsLeft) {
    if (secondsLeft <= 30) return '< 1 min';
    return '${secondsLeft ~/ 60}:${(secondsLeft % 60).toString().padLeft(2, '0')}';
  }

  /// Field of the truck node with the assigned areas still to be collected, nearest first (names).
  static const String queueField = 'route_queue';

  /// The areas the truck still has to collect today (its assignment, nearest first) while it is collecting with a
  /// current position; empty otherwise. Lets every screen say where an area stands in the truck's round.
  static List<String> queueFromNode(Map node, {required int nowMs}) {
    final Object? raw = node[queueField];
    if (raw is! List) return const <String>[];
    final String status = FleetStatus.collectionState(node);
    if (status != 'ACTIVE' && status != 'COLLECTING') return const <String>[];
    final int? gpsAge = FleetStatus.gpsAgeMs(node, nowMs: nowMs);
    if (gpsAge == null || gpsAge < 0 || gpsAge > EtaPolicy.gpsFreshMs) return const <String>[];
    return <String>[for (final Object? e in raw) if (e != null && e.toString().trim().isNotEmpty) e.toString().trim()];
  }

  static int? _int(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');

  /// The estimate a truck node carries, or null when there is none to show: no estimate, the truck is not collecting,
  /// its GPS is out of date, or the estimate itself has not been renewed within the shared freshness window. Nothing
  /// is ever guessed or kept past that.
  static AreaEta? fromNode(Map node, {required int nowMs}) {
    final Object? raw = node[field];
    if (raw is! Map) return null;
    final String status = FleetStatus.collectionState(node);
    if (status != 'ACTIVE' && status != 'COLLECTING') return null;
    final int? gpsAge = FleetStatus.gpsAgeMs(node, nowMs: nowMs);
    if (gpsAge == null || gpsAge < 0 || gpsAge > EtaPolicy.gpsFreshMs) return null;
    final int? arrive = _int(raw['arrive_at_ms']);
    final int? computed = _int(raw['computed_at_ms']);
    final int? minutes = _int(raw['minutes']);
    final String area = (raw['area'] ?? '').toString().trim();
    if (arrive == null || computed == null || minutes == null || area.isEmpty) return null;
    if (nowMs - computed > EtaPolicy.gpsFreshMs) return null;
    // Another trip on the same truck: the estimate of the trip that ended is not this trip's.
    final String tripId = (raw['trip_id'] ?? '').toString();
    final String session = (node['current_session'] ?? '').toString();
    if (tripId.isNotEmpty && session.isNotEmpty && session != 'null' && tripId != session) return null;
    return AreaEta(
      area: area,
      areaKey: (raw['area_key'] ?? area).toString(),
      minutes: minutes,
      arriveAtMs: arrive,
      computedAtMs: computed,
      tripId: tripId,
      method: (raw['method'] ?? EtaPolicy.method).toString(),
    );
  }
}
