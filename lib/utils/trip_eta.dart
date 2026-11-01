import 'area_eta.dart';
import 'eta_evaluation.dart';

/// The arrival estimate a fleet card shows: the latest "on the way" alert of the truck's current
/// trip for an area the truck has not reached yet, counted down from the moment it was sent.
class TripEta {
  const TripEta({required this.area, required this.minutesLeft, required this.sentMs, required this.etaMinutes, this.live = false});

  /// true: the truck's published estimate (AreaEta), the same one the alerts, the residents and Collection Route
  /// Optimization use. false: the last alert, for a driver app that does not publish one yet.
  final bool live;

  /// "estimate updated" / "alert sent", for the line under the card's ETA.
  String get sourceText => live ? 'updated' : 'alert sent';

  /// The truck's published estimate when it has one; otherwise the latest alert of its trip.
  static TripEta? forTruck(Map truck, Object? notifications, {required int nowMs}) {
    final AreaEta? e = AreaEta.fromNode(truck, nowMs: nowMs);
    if (e != null) {
      return TripEta(area: e.area, minutesLeft: e.minutesLeft(nowMs), sentMs: e.computedAtMs, etaMinutes: e.minutes, live: true);
    }
    return latest(notifications, truck['current_session']?.toString(), nowMs: nowMs);
  }

  final String area;

  /// Minutes until the estimated arrival (0 when it is due now).
  final int minutesLeft;
  final int sentMs;

  /// Minutes the alert stated when it was sent.
  final int etaMinutes;

  /// An estimate more than this long overdue is no longer shown (the truck went elsewhere).
  static const Duration staleAfter = Duration(minutes: 10);

  String get label => minutesLeft <= 0 ? '$area: due now' : '$area: $minutesLeft min';

  /// null when the trip has no current estimate: nothing is guessed.
  static TripEta? latest(Object? notifications, String? tripId, {required int nowMs}) {
    if (notifications is! Map || tripId == null || tripId.isEmpty) return null;
    final Set<String> arrived = <String>{};
    final List<Map> approaches = <Map>[];
    notifications.forEach((Object? _, Object? v) {
      if (v is! Map || (v['trip_id'] ?? '').toString() != tripId) return;
      final String type = (v['type'] ?? '').toString();
      final String area = (v['purok'] ?? '').toString().trim();
      if (area.isEmpty) return;
      if (type == 'auto_arrival') arrived.add(area.toLowerCase());
      if (type == 'auto_approach') approaches.add(v);
    });
    TripEta? best;
    for (final Map v in approaches) {
      final String area = (v['purok'] ?? '').toString().trim();
      if (arrived.contains(area.toLowerCase())) continue;
      final int? sent = EtaEvaluation.normalizeMs(v['timestamp']);
      final Object? m = v['eta_minutes'];
      final int? minutes = m is num ? m.toInt() : int.tryParse(m?.toString() ?? '');
      if (sent == null || minutes == null || sent > nowMs) continue;
      final int due = sent + minutes * 60000;
      if (nowMs - due > staleAfter.inMilliseconds) continue;
      if (best != null && best.sentMs >= sent) continue;
      best = TripEta(area: area, minutesLeft: ((due - nowMs) / 60000).ceil().clamp(0, 999), sentMs: sent, etaMinutes: minutes);
    }
    return best;
  }
}
