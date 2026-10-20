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

class EtaPolicy {
  EtaPolicy._();

  static const int gpsFreshMs = 180000; // the shared freshness window
  static const double minSpeedKmh = 3.0; // slower than this is "not travelling"
  static const int maxMinutes = 90; // beyond this an estimate is not meaningful
  static const List<int> stages = <int>[15, 10, 5];

  static EtaResult evaluate({
    required String? status,
    required int? gpsAgeMs,
    required double? distanceKm,
    required double? speedKmh,
    double? averageSpeedKmh,
    double arrivalRadiusM = 60.0,
    bool distanceIsRoute = false,
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

    final double raw = distanceKm / speed * 60.0;
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
