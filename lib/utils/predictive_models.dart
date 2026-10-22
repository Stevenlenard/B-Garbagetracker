import 'dart:math' as math;

import 'collection_visits.dart';
import 'trip_archive.dart';

/// Objective 3 of the study: data modeling and the evaluation of its predictive performance.
///
/// * Arrival time: a linear regression of the minutes until a truck enters a collection area on its distance to the
///   area, fitted on recorded trips and evaluated on trips that were not used to fit it.
/// * Waste volume: a moving average forecast of the daily collected load.
///
/// Both are evaluated with MAE, RMSE and R². All inputs are recorded data; nothing is invented, and every figure
/// states how many samples it rests on.

/// MAE, RMSE and R² of [predicted] against [actual].
class ErrorMetrics {
  const ErrorMetrics({required this.n, required this.mae, required this.rmse, required this.r2});

  final int n;
  final double? mae;
  final double? rmse;

  /// 1 - SSres / SStot. null with fewer than 2 samples or when the actual values do not vary. It can be negative:
  /// the predictions are then worse than always predicting the mean.
  final double? r2;

  static ErrorMetrics of(List<double> actual, List<double> predicted) {
    final int n = math.min(actual.length, predicted.length);
    if (n == 0) return const ErrorMetrics(n: 0, mae: null, rmse: null, r2: null);
    double abs = 0, sq = 0, mean = 0;
    for (int i = 0; i < n; i++) {
      final double e = actual[i] - predicted[i];
      abs += e.abs();
      sq += e * e;
      mean += actual[i];
    }
    mean /= n;
    double tot = 0;
    for (int i = 0; i < n; i++) {
      tot += (actual[i] - mean) * (actual[i] - mean);
    }
    return ErrorMetrics(
      n: n,
      mae: abs / n,
      rmse: math.sqrt(sq / n),
      r2: (n < 2 || tot == 0) ? null : 1 - sq / tot,
    );
  }
}

/// Ordinary least squares y = intercept + slope * x.
class LinearFit {
  const LinearFit(this.intercept, this.slope);

  final double intercept;
  final double slope;

  double predict(double x) => intercept + slope * x;

  static LinearFit? fit(List<double> xs, List<double> ys) {
    final int n = math.min(xs.length, ys.length);
    if (n < 2) return null;
    double mx = 0, my = 0;
    for (int i = 0; i < n; i++) {
      mx += xs[i];
      my += ys[i];
    }
    mx /= n;
    my /= n;
    double sxy = 0, sxx = 0;
    for (int i = 0; i < n; i++) {
      sxy += (xs[i] - mx) * (ys[i] - my);
      sxx += (xs[i] - mx) * (xs[i] - mx);
    }
    if (sxx == 0) return null;
    final double slope = sxy / sxx;
    return LinearFit(my - slope * mx, slope);
  }
}

/// One observation: a GPS fix of a collecting truck before it entered an area.
class ArrivalSample {
  const ArrivalSample({
    required this.tripId,
    required this.area,
    required this.fixMs,
    required this.distanceKm,
    required this.speedKmh,
    required this.actualMin,
  });

  final String tripId;
  final String area;
  final int fixMs;

  /// Straight-line distance from the truck to the edge of the area.
  final double distanceKm;

  /// Median recorded speed of the moving fixes in the 90 seconds before the fix (samples are taken only while moving).
  final double? speedKmh;

  /// Minutes from the fix until the truck entered the area.
  final double actualMin;

  /// The rule the system uses live: distance divided by recent speed (null when the truck is not moving).
  double? get baselineMin => (speedKmh == null || speedKmh! < 3) ? null : distanceKm / speedKmh! * 60;
}

class ArrivalRegressionReport {
  const ArrivalRegressionReport({
    required this.samples,
    required this.trips,
    required this.fit,
    required this.method,
    required this.regression,
    required this.baseline,
    required this.testActual,
    required this.testPredicted,
  });

  final int samples;
  final int trips;

  /// Fitted on all samples (shown as the model equation).
  final LinearFit? fit;

  /// How the error was measured (train/test split by trip, or leave-one-trip-out with few trips).
  final String method;
  final ErrorMetrics regression;

  /// The live rule (distance / recent speed) on the same evaluation samples, for comparison.
  final ErrorMetrics baseline;
  final List<double> testActual;
  final List<double> testPredicted;

  bool get hasModel => fit != null && regression.n > 0;
}

class ArrivalRegression {
  ArrivalRegression._();

  static const double areaRadiusM = AreaGeofence.areaRadiusM;
  static const int lookBackMinutes = 30;
  static const int sampleEverySeconds = 120;
  static const double maxDistanceKm = 5;

  static int? _ms(Object? v) {
    final num? n = v is num ? v : num.tryParse(v?.toString() ?? '');
    if (n == null || n <= 0) return null;
    return n < 10000000000 ? (n * 1000).toInt() : n.toInt();
  }

  static double? _num(Object? v) => v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');

  static double _dist(double lat1, double lng1, double lat2, double lng2) {
    const double r = 6371000.0;
    final double dLat = (lat2 - lat1) * math.pi / 180, dLng = (lng2 - lng1) * math.pi / 180;
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
  }

  /// Samples from recorded trips (simulations excluded): for every first entry of a collecting truck into an area,
  /// one moving fix every 2 minutes during the 30 minutes before the entry.
  static List<ArrivalSample> extract(Map trips, List<AreaGeofence> areas) {
    final List<ArrivalSample> out = <ArrivalSample>[];
    trips.forEach((Object? key, Object? value) {
      if (value is! Map || value['is_simulation'] == true || TripArchive.isArchived(value)) return;
      final Object? route = value['route'];
      final Iterable<Object?> raw = route is Map ? route.values : (route is List ? route : const <Object?>[]);
      final List<({int ms, double lat, double lng, double spd})> fixes = <({int ms, double lat, double lng, double spd})>[];
      for (final Object? p in raw) {
        if (p is! Map || p['is_simulation'] == true) continue;
        final String st = (p['status'] ?? '').toString().toUpperCase();
        if (st != 'ACTIVE' && st != 'COLLECTING') continue;
        final double? lat = _num(p['lat'] ?? p['latitude']), lng = _num(p['lng'] ?? p['longitude']);
        final int? ms = _ms(p['timestamp']);
        final double acc = _num(p['accuracy']) ?? 0;
        if (lat == null || lng == null || ms == null || lat == 0 || acc > 50) continue;
        fixes.add((ms: ms, lat: lat, lng: lng, spd: _num(p['speed']) ?? 0));
      }
      if (fixes.length < 3) return;
      fixes.sort((a, b) => a.ms.compareTo(b.ms));
      for (final AreaGeofence area in areas) {
        if (!area.isTruckStop) continue;
        final int entry = fixes.indexWhere((f) => _dist(f.lat, f.lng, area.lat, area.lng) <= areaRadiusM);
        if (entry <= 0) continue; // never entered, or the trip started inside the area
        final int arrival = fixes[entry].ms;
        int lastSampled = -1 << 62;
        for (int j = 0; j < entry; j++) {
          final f = fixes[j];
          final double mins = (arrival - f.ms) / 60000.0;
          if (mins > lookBackMinutes || mins < 0.5) continue;
          if (f.ms - lastSampled < sampleEverySeconds * 1000) continue;
          final double dKm = (_dist(f.lat, f.lng, area.lat, area.lng) - areaRadiusM) / 1000.0;
          if (dKm <= 0 || dKm > maxDistanceKm) continue;
          final List<double> recent = <double>[
            for (int k = j; k >= 0 && f.ms - fixes[k].ms <= 90000; k--)
              if (fixes[k].spd >= 3) fixes[k].spd
          ]..sort();
          final double? speed = recent.isEmpty ? null : recent[recent.length ~/ 2];
          if (speed == null) continue; // a standing truck (loading, waiting) has no travel time to predict
          lastSampled = f.ms;
          out.add(ArrivalSample(
              tripId: key.toString(), area: area.name, fixMs: f.ms, distanceKm: dKm, speedKmh: speed, actualMin: mins));
        }
      }
    });
    out.sort((a, b) => a.fixMs.compareTo(b.fixMs));
    return out;
  }

  /// Fits and evaluates the model. With 5 or more trips: fitted on the earliest 70 percent of the trips and tested
  /// on the rest. With fewer trips: leave-one-trip-out (each trip is predicted by a model fitted on the others).
  static ArrivalRegressionReport evaluate(List<ArrivalSample> samples) {
    final List<String> tripOrder = <String>[];
    for (final ArrivalSample s in samples) {
      if (!tripOrder.contains(s.tripId)) tripOrder.add(s.tripId);
    }
    final LinearFit? all = LinearFit.fit(samples.map((s) => s.distanceKm).toList(), samples.map((s) => s.actualMin).toList());
    final List<double> act = <double>[], pred = <double>[], bAct = <double>[], bPred = <double>[];
    String method;

    void score(List<ArrivalSample> test, LinearFit f) {
      for (final ArrivalSample s in test) {
        act.add(s.actualMin);
        pred.add(math.max(0, f.predict(s.distanceKm)));
        final double? b = s.baselineMin;
        if (b != null) {
          bAct.add(s.actualMin);
          bPred.add(b);
        }
      }
    }

    if (tripOrder.length >= 5) {
      final int cut = (tripOrder.length * 0.7).floor().clamp(1, tripOrder.length - 1);
      final Set<String> train = tripOrder.take(cut).toSet();
      final List<ArrivalSample> tr = samples.where((s) => train.contains(s.tripId)).toList();
      final LinearFit? f = LinearFit.fit(tr.map((s) => s.distanceKm).toList(), tr.map((s) => s.actualMin).toList());
      if (f != null) score(samples.where((s) => !train.contains(s.tripId)).toList(), f);
      method = 'Fitted on the earliest $cut of ${tripOrder.length} trips and tested on the other ${tripOrder.length - cut}.';
    } else {
      for (final String t in tripOrder) {
        final List<ArrivalSample> tr = samples.where((s) => s.tripId != t).toList();
        final LinearFit? f = LinearFit.fit(tr.map((s) => s.distanceKm).toList(), tr.map((s) => s.actualMin).toList());
        if (f != null) score(samples.where((s) => s.tripId == t).toList(), f);
      }
      method = 'Leave-one-trip-out: each of the ${tripOrder.length} trips is predicted by a model fitted on the other trips.';
    }
    return ArrivalRegressionReport(
      samples: samples.length,
      trips: tripOrder.length,
      fit: all,
      method: method,
      regression: ErrorMetrics.of(act, pred),
      baseline: ErrorMetrics.of(bAct, bPred),
      testActual: act,
      testPredicted: pred,
    );
  }
}

/// Daily collected load and its moving average forecast.
class MovingAverageReport {
  const MovingAverageReport({
    required this.window,
    required this.days,
    required this.series,
    required this.metrics,
    required this.nextForecast,
    required this.backtestActual,
    required this.backtestForecast,
  });

  final int window;
  final List<DateTime> days;

  /// Collected load (kg) per day, zero on days without a finalized collection.
  final List<double> series;
  final ErrorMetrics metrics;

  /// Forecast for the day after the last day of the series.
  final double? nextForecast;
  final List<double> backtestActual;
  final List<double> backtestForecast;
}

class MovingAverageForecast {
  MovingAverageForecast._();

  static const Duration manila = Duration(hours: 8);

  /// Daily load (kg) from finalized collections (FULL) of real trips, Asia/Manila calendar days, zero-filled.
  static ({List<DateTime> days, List<double> kg}) dailyLoads(Map trips, {required DateTime from, required DateTime to}) {
    DateTime day(int ms) {
      final DateTime m = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).add(manila);
      return DateTime.utc(m.year, m.month, m.day);
    }

    final DateTime start = DateTime.utc(from.year, from.month, from.day), end = DateTime.utc(to.year, to.month, to.day);
    final Map<DateTime, double> kg = <DateTime, double>{};
    trips.forEach((Object? _, Object? v) {
      if (v is! Map || v['is_simulation'] == true || TripArchive.isArchived(v)) return;
      final Object? c = v['collection'];
      if (c is! Map) return;
      final Object? at = c['finalized_at_ms'];
      final Object? w = c['weight_kg'] ?? v['weight_kg'];
      if (at is! num || w is! num) return;
      final DateTime d = day(at.toInt());
      if (d.isBefore(start) || d.isAfter(end)) return;
      kg[d] = (kg[d] ?? 0) + w.toDouble();
    });
    final List<DateTime> days = <DateTime>[];
    final List<double> values = <double>[];
    for (DateTime d = start; !d.isAfter(end); d = d.add(const Duration(days: 1))) {
      days.add(d);
      values.add(kg[d] ?? 0);
    }
    return (days: days, kg: values);
  }

  /// One-step-ahead simple moving average: the forecast for each day is the mean of the [window] days before it.
  static MovingAverageReport evaluate(List<DateTime> days, List<double> series, {int window = 7}) {
    final List<double> act = <double>[], fc = <double>[];
    for (int i = window; i < series.length; i++) {
      double s = 0;
      for (int k = i - window; k < i; k++) {
        s += series[k];
      }
      act.add(series[i]);
      fc.add(s / window);
    }
    double? next;
    if (series.length >= window) {
      double s = 0;
      for (int k = series.length - window; k < series.length; k++) {
        s += series[k];
      }
      next = s / window;
    }
    return MovingAverageReport(
      window: window,
      days: days,
      series: series,
      metrics: ErrorMetrics.of(act, fc),
      nextForecast: next,
      backtestActual: act,
      backtestForecast: fc,
    );
  }
}
