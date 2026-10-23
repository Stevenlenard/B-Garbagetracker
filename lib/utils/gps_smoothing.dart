import 'dart:math' as math;

/// One GPS fix to smooth (display only; recorded data is never changed).
class GpsSample {
  const GpsSample({required this.lat, required this.lng, required this.accuracyM, required this.timestampMs, this.speedMps = 0});

  final double lat;
  final double lng;
  final double accuracyM;
  final int timestampMs;
  final double speedMps;
}

/// Display smoothing for route lines: a Kalman filter on the position, then a stationary filter.
///
/// * Kalman: each fix is weighted by its reported accuracy against the uncertainty the filter has
///   built up since the previous fix (which grows with time and travel speed). A precise fix moves
///   the line almost all the way; a poor one only a little, so single wild fixes no longer pull the
///   line onto a roof. A backward pass then removes the filter's lag.
/// * Stationary: a smoothed position closer than [stationaryMinM] (or half its accuracy) to the last
///   drawn position is not drawn, so a phone lying still does not scribble a star around itself.
///
/// Used only to DRAW lines. Distances, visits, ETA and analytics keep using the recorded fixes.
class GpsSmoothing {
  GpsSmoothing._();

  /// Expected change of position per second (m/s) when the reported speed is lower.
  static const double processNoiseMps = 3.0;

  /// Reported accuracy is never trusted beyond this (some phones report 0 or 1 m).
  static const double minAccuracyM = 3.0;

  /// Movement below this (metres) is treated as standing still.
  static const double stationaryMinM = 8.0;

  /// A first or last fix at least this precise is drawn exactly as recorded.
  static const double endAccuracyM = 25.0;

  /// After a gap this long the filter restarts from the next fix instead of dragging the old estimate along.
  static const int resetGapMs = 180000;

  /// Smoothed position of every sample (same length and order as [samples]): a forward Kalman pass,
  /// then a backward (Rauch-Tung-Striebel) pass so the line has no lag behind the truck and the last
  /// point stays the filter's best estimate of where the trip really ended.
  static List<List<double>> kalman(List<GpsSample> samples) {
    final int n = samples.length;
    final List<double> fLat = List<double>.filled(n, 0), fLng = List<double>.filled(n, 0);
    final List<double> fVar = List<double>.filled(n, 0), priorVar = List<double>.filled(n, 0);
    final List<bool> restart = List<bool>.filled(n, false);
    double lat = 0, lng = 0, variance = -1;
    int lastTs = 0;
    for (int i = 0; i < n; i++) {
      final GpsSample s = samples[i];
      final double acc = math.max(s.accuracyM, minAccuracyM);
      final int gap = s.timestampMs - lastTs;
      if (variance < 0 || gap > resetGapMs) {
        lat = s.lat;
        lng = s.lng;
        variance = acc * acc;
        restart[i] = true;
        priorVar[i] = variance;
      } else {
        final double dt = math.max(0, gap) / 1000.0;
        // Expected movement: at least walking pace, the reported speed, or the speed the raw fixes imply
        // (sparse fixes from a moving vehicle must not be dragged back towards each other).
        final GpsSample prev = samples[i - 1];
        final double implied = dt > 0 ? distanceM(prev.lat, prev.lng, s.lat, s.lng) / dt : 0;
        final double q = math.max(processNoiseMps, math.max(s.speedMps, implied));
        variance += dt * q * q;
        priorVar[i] = variance;
        final double k = variance / (variance + acc * acc);
        lat += k * (s.lat - lat);
        lng += k * (s.lng - lng);
        variance = (1 - k) * variance;
      }
      lastTs = s.timestampMs;
      fLat[i] = lat;
      fLng[i] = lng;
      fVar[i] = variance;
    }
    final List<List<double>> out = List<List<double>>.generate(n, (int i) => <double>[fLat[i], fLng[i]]);
    // The line starts and ends where the trip was recorded when those fixes are precise (the forward
    // pass alone would leave the end a few metres behind a moving truck).
    if (n > 1 && samples[n - 1].accuracyM <= endAccuracyM) out[n - 1] = <double>[samples[n - 1].lat, samples[n - 1].lng];
    for (int i = n - 2; i >= 0; i--) {
      if (restart[i + 1]) continue; // separate stretch after a long gap
      final double c = fVar[i] / priorVar[i + 1];
      out[i][0] = fLat[i] + c * (out[i + 1][0] - fLat[i]);
      out[i][1] = fLng[i] + c * (out[i + 1][1] - fLng[i]);
    }
    if (n > 1 && samples[0].accuracyM <= endAccuracyM) out[0] = <double>[samples[0].lat, samples[0].lng];
    return out;
  }

  /// A detour of at most this many fixes can be a GPS spike.
  static const int spikeMaxFixes = 3;

  /// A spike reaches at least this far (metres) from where it left...
  static const double spikeMinReachM = 50;

  /// ...comes back to within this distance of that place...
  static const double spikeReturnM = 30;

  /// ...within this time...
  static const int spikeMaxMs = 60000;

  /// ...faster (out and back) than walking pace, in m/s.
  static const double spikeMinSpeedMps = 3;

  /// Indexes of the samples that are not GPS spikes. A spike is a short out-and-back jump: up to
  /// [spikeMaxFixes] fixes that leave a place by [spikeMinReachM] or more and are back within
  /// [spikeReturnM] of it in under [spikeMaxMs], moving faster than [spikeMinSpeedMps] - the typical
  /// warm-up or reflected fix that would otherwise draw a straight line to nowhere. [keep] protects a
  /// sample (e.g. the live position) from being dropped.
  static List<int> withoutSpikes(List<GpsSample> samples, {bool Function(int i)? keep}) {
    final int n = samples.length;
    final List<bool> drop = List<bool>.filled(n, false);
    for (int i = 0; i < n - 2; i++) {
      if (drop[i]) continue;
      final GpsSample a = samples[i];
      for (int len = 1; len <= spikeMaxFixes && i + len + 1 < n; len++) {
        final GpsSample back = samples[i + len + 1];
        final int dt = back.timestampMs - a.timestampMs;
        if (dt <= 0 || dt > spikeMaxMs) break;
        if (distanceM(a.lat, a.lng, back.lat, back.lng) > math.max(spikeReturnM, back.accuracyM)) continue;
        double reach = 0;
        bool protectedFix = false;
        for (int j = i + 1; j <= i + len; j++) {
          reach = math.max(reach, distanceM(a.lat, a.lng, samples[j].lat, samples[j].lng));
          if (keep != null && keep(j)) protectedFix = true;
        }
        if (protectedFix || reach < spikeMinReachM || 2 * reach / (dt / 1000.0) < spikeMinSpeedMps) continue;
        for (int j = i + 1; j <= i + len; j++) {
          drop[j] = true;
        }
        break;
      }
    }
    return <int>[for (int i = 0; i < n; i++) if (!drop[i]) i];
  }

  /// Indexes of the samples to draw after smoothing: the first and last always, a sample whose
  /// [keep] is true always (e.g. a colour change), otherwise only real movement.
  static List<int> movingIndexes(List<GpsSample> samples, List<List<double>> smoothed, {bool Function(int i)? keep}) {
    final List<int> idx = <int>[];
    if (samples.isEmpty) return idx;
    idx.add(0);
    for (int i = 1; i < samples.length; i++) {
      final List<double> last = smoothed[idx.last];
      final double d = distanceM(last[0], last[1], smoothed[i][0], smoothed[i][1]);
      final double minMove = math.max(stationaryMinM, samples[i].accuracyM * 0.5);
      if (d >= minMove || (keep != null && keep(i))) idx.add(i);
    }
    if (idx.last != samples.length - 1) idx.add(samples.length - 1);
    return idx;
  }

  static double distanceM(double lat1, double lng1, double lat2, double lng2) {
    const double r = 6371000.0;
    final double dLat = (lat2 - lat1) * math.pi / 180.0;
    final double dLng = (lng2 - lng1) * math.pi / 180.0;
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) * math.cos(lat2 * math.pi / 180.0) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
  }
}
