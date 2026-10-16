/// Decides whether a GPS fix may replace the last accepted one.
///
/// A fix is rejected when it is older than the fix already accepted (out-of-order
/// delivery, e.g. a queued platform event) or older than [maxAgeMs] relative to
/// the moment it is processed (a cached/stale fix). Fixes without a plausible
/// timestamp are accepted: some platforms report 0 or a future clock.
///
/// A DEGRADED fix (reported accuracy worse than [goodAccuracyM]) is rejected only while a
/// recent GOOD fix exists: that is the "position jumps onto a nearby building" case, where
/// the receiver briefly reports a poor fix between good ones. When no good fix is available
/// (urban canyon, cold start) degraded fixes are still accepted, so tracking never freezes.
/// Nothing is smoothed, snapped or throttled: accepted fixes are used as reported.
class GpsFixPolicy {
  GpsFixPolicy._();

  static const int maxAgeMs = 30000;
  static const int maxFutureSkewMs = 60000;
  static const double goodAccuracyM = 50.0;
  static const int goodFixValidMs = 20000;

  static GpsFixVerdict evaluate({
    required DateTime fixTime,
    required DateTime nowTime,
    DateTime? lastAcceptedFixTime,
    int maxAgeMillis = maxAgeMs,
    double? accuracyM,
    double? lastAcceptedAccuracyM,
    int? lastAcceptedAgeMs,
  }) {
    final int fixMs = fixTime.millisecondsSinceEpoch;
    if (fixMs <= 0) return GpsFixVerdict.accept; // no usable timestamp
    final int skew = nowTime.millisecondsSinceEpoch - fixMs;
    if (skew < -maxFutureSkewMs) return GpsFixVerdict.accept; // device clock disagreement
    if (lastAcceptedFixTime != null &&
        fixMs < lastAcceptedFixTime.millisecondsSinceEpoch) {
      return GpsFixVerdict.outOfOrder;
    }
    if (skew > maxAgeMillis) return GpsFixVerdict.stale;
    if (accuracyM != null &&
        accuracyM > goodAccuracyM &&
        lastAcceptedAccuracyM != null &&
        lastAcceptedAccuracyM <= goodAccuracyM &&
        lastAcceptedAgeMs != null &&
        lastAcceptedAgeMs >= 0 &&
        lastAcceptedAgeMs <= goodFixValidMs) {
      return GpsFixVerdict.degraded;
    }
    return GpsFixVerdict.accept;
  }
}

enum GpsFixVerdict { accept, stale, outOfOrder, degraded }
