import 'dart:math' as math;

/// Arrival-time estimate that refuses to guess.
///
/// Inputs are the facts that justify an estimate: the truck must be COLLECTING (ACTIVE),
/// its GPS must be fresh, and there must be a real speed. Anything else is "unavailable"
/// - never a made-up number, and never "0 minutes" (0 only exists as "arrived").
///
/// The distance supplied is straight-line unless [distanceIsRoute] is true; a straight
/// line is a LOWER BOUND of the road distance, so such estimates are labelled
/// approximate and never claimed more precise than that.
enum EtaKind { minutes, arrived, unavailable }

class EtaResult {
  const EtaResult.minutes(this.minutes, {this.approximate = true, this.stage, this.seconds})
      : kind = EtaKind.minutes,
        reason = null;

  const EtaResult.arrived()
      : kind = EtaKind.arrived,
        minutes = null,
        approximate = false,
        stage = null,
        seconds = null,
        reason = null;

  const EtaResult.unavailable(this.reason)
      : kind = EtaKind.unavailable,
        minutes = null,
        approximate = false,
        stage = null,
        seconds = null;

  final EtaKind kind;
  final int? minutes;

  /// Unrounded estimate in seconds (for a live countdown between updates).
  final int? seconds;
  final bool approximate;

  /// Notification stage reached (15 / 10 / 5 minutes), when it applies.
  final int? stage;
  final String? reason;

  bool get isAvailable => kind != EtaKind.unavailable;

  /// Text for cards.
  String get label {
    switch (kind) {
      case EtaKind.minutes:
        return '${approximate ? '~' : ''}$minutes min';
      case EtaKind.arrived:
        return 'Arrived';
      case EtaKind.unavailable:
        return 'ETA unavailable';
    }
  }
}

/// Minutes until arrival learned from recorded trips: minutes = intercept + slope x straight-line km to the area.
/// The intercept is the time a collecting truck loses on its way (streets served, stops, detours), which a
/// distance / speed estimate cannot see. Fitted by Analytics (Predictive Models) and shared through
/// `admin_settings/eta_model`; [defaults] is the fit of the trips recorded up to October 28, 2026.
class EtaModel {
  const EtaModel(this.intercept, this.slope, {this.samples = 0});

  final double intercept;
  final double slope;
  final int samples;

  static const EtaModel defaults = EtaModel(5.78, 1.79, samples: 20);

  /// The intercept is the time a collecting truck loses on its way (streets served, stops, detours). Applied as a
  /// constant it put a floor of 6-8 minutes under EVERY estimate, also for a truck at the edge of the area, and the
  /// 5-minute alert could never be sent. Recorded trips show why that is wrong: of the 62 samples taken closer than
  /// 500 m, half arrived within 2 minutes (and a few passed by and came back much later). The delay is therefore applied
  /// in proportion to the distance still to drive, in full from [fullOverheadKm] on; the fitted coefficients and the
  /// regression itself are unchanged.
  ///
  /// Replay of the 20 recorded trips (188 samples, each trip predicted by a fit that excludes it, estimate = the larger
  /// of this and distance / speed): mean error 7.6 -> 6.9 min overall, 6.2 -> 4.1 min closer than 500 m, unchanged
  /// farther away (8.25 min). A small sample: it is re-measured by Analytics as trips are recorded.
  static const double fullOverheadKm = 0.5;

  double minutesFor(double straightKm) =>
      intercept * (straightKm / fullOverheadKm).clamp(0.0, 1.0).toDouble() + slope * straightKm;

  /// A stored fit, or null when it is missing or not plausible (then [defaults] stays in use).
  static EtaModel? fromJson(Object? v) {
    if (v is! Map) return null;
    final num? a = v['intercept'] is num ? v['intercept'] as num : null;
    final num? b = v['slope'] is num ? v['slope'] as num : null;
    final Object? n = v['samples'];
    if (a == null || b == null || a < 0 || a > 30 || b <= 0 || b > 30) return null;
    final int samples = n is num ? n.toInt() : 0;
    if (samples < 10) return null;
    return EtaModel(a.toDouble(), b.toDouble(), samples: samples);
  }
}

class EtaPolicy {
  EtaPolicy._();

  /// The learned model in use (see EtaModel); replaced when a newer fit is read from the database.
  static EtaModel model = EtaModel.defaults;

  static const int gpsFreshMs = 180000; // the shared freshness window
  static const double minSpeedKmh = 3.0; // slower than this is "not travelling"
  static const int maxMinutes = 90; // beyond this an estimate is not meaningful
  static const List<int> stages = <int>[15, 10, 5];

  /// Roads are longer than the straight line between two points; a straight-line
  /// distance is scaled by this typical urban detour factor before it is used.
  static const double roadFactor = 1.3;

  static double roadDistanceKm(double straightKm) => straightKm * roadFactor;

  /// Stamped on every approach alert computed this way. Alerts from the earlier method
  /// (first-fix alerts, speed while moving) carry no stamp and are not evaluated.
  static const String method = 'recent_speed_or_model';

  static EtaResult evaluate({
    required String? status,
    required int? gpsAgeMs,
    required double? distanceKm,
    required double? speedKmh,
    double? averageSpeedKmh,
    double arrivalRadiusM = 60.0,
    bool distanceIsRoute = false,
    double? straightKm,
  }) {
    final String s = (status ?? '').trim().toUpperCase();
    if (s != 'ACTIVE' && s != 'COLLECTING') {
      return const EtaResult.unavailable('The truck is not collecting right now.');
    }
    if (gpsAgeMs == null || gpsAgeMs < 0 || gpsAgeMs > gpsFreshMs) {
      return const EtaResult.unavailable('The truck location is out of date.');
    }
    if (distanceKm == null || distanceKm.isNaN || distanceKm < 0) {
      return const EtaResult.unavailable('Distance is unknown.');
    }
    // Arrival is a measured fact (inside the arrival radius), not a rounded estimate.
    if (distanceKm * 1000.0 <= arrivalRadiusM) return const EtaResult.arrived();

    double? speed;
    if (speedKmh != null && speedKmh >= minSpeedKmh) {
      speed = speedKmh;
    } else if (averageSpeedKmh != null && averageSpeedKmh >= minSpeedKmh) {
      speed = averageSpeedKmh;
    }
    if (speed == null) return const EtaResult.unavailable('The truck speed is not known yet.');

    // The larger of: the road distance at the recent travel speed, and the time recorded trips actually took for
    // this straight-line distance (a truck rarely drives straight to an area; replaying the recorded trips, this
    // cut the mean alert error from 6.1 to 4.5 min).
    final double bySpeed = distanceKm / speed * 60.0;
    final double raw = straightKm == null ? bySpeed : math.max(bySpeed, model.minutesFor(straightKm));
    final int minutes = raw <= 1.0 ? 1 : raw.ceil();
    if (minutes > maxMinutes) return const EtaResult.unavailable('The truck is too far for a useful estimate.');
    return EtaResult.minutes(minutes, approximate: !distanceIsRoute, stage: stageFor(minutes), seconds: (raw * 60).round());
  }

  /// 15 / 10 / 5 minute stage for [minutes], or null while farther than 15 minutes.
  static int? stageFor(int minutes) {
    for (final int stage in <int>[5, 10, 15]) {
      if (minutes <= stage) return stage;
    }
    return null;
  }
}
