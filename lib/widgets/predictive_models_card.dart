import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/driver_trip.dart';
import '../utils/collection_visits.dart';
import '../utils/eta_evaluation.dart';
import '../utils/predictive_models.dart';
import 'predictive_models_details.dart';

/// Analytics card for the predictive models: the arrival-time linear regression and the moving average forecast of
/// the daily collected load, each evaluated with MAE, RMSE and R². The details dialog shows how every figure was made.
class PredictiveModelsCard extends StatefulWidget {
  const PredictiveModelsCard({
    super.key,
    required this.trips,
    required this.areas,
    required this.range,
    required this.etaVisits,
    required this.loads,
  });

  /// `driver_routes` snapshot (GPS routes for the arrival regression).
  final Map trips;

  /// The Load History list (same records as the Waste Collection Summary) for the load forecast.
  final List<DriverTrip> loads;
  final List<AreaGeofence> areas;
  final DateTimeRange range;

  /// Notified estimates with their GPS-confirmed arrivals (the live, prospective evaluation).
  final List<EtaVisit> etaVisits;

  @override
  State<PredictiveModelsCard> createState() => _PredictiveModelsCardState();
}

class _Models {
  _Models(this.regression, this.forecast, this.live);
  final ArrivalRegressionReport regression;
  final MovingAverageReport forecast;
  final ErrorMetrics live;
}

class _PredictiveModelsCardState extends State<PredictiveModelsCard> {
  static const Color _ink = Color(0xFF0F172A);
  static const Color _muted = Color(0xFF64748B);
  static const Color _teal = Color(0xFF0F766E);

  _Models? _cache;
  Object? _cacheKey;

  _Models _models() {
    final Object key = Object.hash(identityHashCode(widget.trips), widget.trips.length, widget.areas.length,
        widget.range.start, widget.range.end, widget.etaVisits.length, identityHashCode(widget.loads), widget.loads.length);
    if (_cache != null && _cacheKey == key) return _cache!;
    final ArrivalRegressionReport reg = ArrivalRegression.evaluate(ArrivalRegression.extract(widget.trips, widget.areas));
    final ({List<DateTime> days, List<double> kg}) daily =
        MovingAverageForecast.dailyLoadsFrom(widget.loads, from: widget.range.start, to: widget.range.end);
    final MovingAverageReport ma = MovingAverageForecast.evaluate(daily.days, daily.kg);
    final List<double> act = <double>[], pred = <double>[];
    for (final EtaVisit v in widget.etaVisits) {
      if (v.status != EtaVisitStatus.evaluated || v.predictions.isEmpty) continue;
      final EtaPrediction p = v.predictions.first;
      if (p.predictedMinutes == null || p.signedErrorMin == null) continue;
      pred.add(p.predictedMinutes!.toDouble());
      act.add(p.predictedMinutes! + p.signedErrorMin!);
    }
    _cacheKey = key;
    return _cache = _Models(reg, ma, ErrorMetrics.of(act, pred));
  }

  static String _min(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)} min';
  static String _kg(double? v) => v == null ? '—' : '${NumberFormat('#,##0').format(v.round())} kg';
  static String _r2(double? v) => v == null ? '—' : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final _Models m = _models();
    final ArrivalRegressionReport r = m.regression;
    final MovingAverageReport f = m.forecast;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 16, offset: const Offset(0, 4))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: const Color(0xFFEDE9FE), borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.insights_rounded, color: Color(0xFF6D28D9), size: 22),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Predictive Models', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: _ink)),
              SizedBox(height: 2),
              Text('Linear regression and moving average, evaluated with MAE, RMSE and R²',
                  style: TextStyle(fontSize: 12.5, color: _muted)),
            ]),
          ),
          TextButton(onPressed: () => _openDetails(context, m), child: const Text('Details')),
        ]),
        const SizedBox(height: 18),
        _modelRow(
          'Arrival time (linear regression)',
          r.fit == null
              ? 'Not enough recorded approaches yet'
              : 'minutes = ${r.fit!.intercept.toStringAsFixed(1)} + ${r.fit!.slope.toStringAsFixed(2)} × distance (km)',
          <(String, String)>[('MAE', _min(r.regression.mae)), ('RMSE', _min(r.regression.rmse)), ('R²', _r2(r.regression.r2))],
          '${r.regression.n} test samples from ${r.trips} trips',
        ),
        const Divider(height: 28),
        _modelRow(
          'Collected load (${f.window}-day moving average)',
          'Forecast for the next day: ${_kg(f.nextForecast)}',
          <(String, String)>[('MAE', _kg(f.metrics.mae)), ('RMSE', _kg(f.metrics.rmse)), ('R²', _r2(f.metrics.r2))],
          '${f.metrics.n} one-day-ahead forecasts in the selected period',
        ),
      ]),
    );
  }

  Widget _modelRow(String title, String subtitle, List<(String, String)> metrics, String footer) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _ink)),
      const SizedBox(height: 2),
      Text(subtitle, style: const TextStyle(fontSize: 12.5, color: _muted)),
      const SizedBox(height: 10),
      Row(children: [
        for (final (String, String) mm in metrics)
          Expanded(
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
              decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(mm.$1, style: const TextStyle(fontSize: 11.5, color: _muted, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(mm.$2, style: const TextStyle(fontSize: 15, color: _teal, fontWeight: FontWeight.w900)),
              ]),
            ),
          ),
      ]),
      const SizedBox(height: 6),
      Text(footer, style: const TextStyle(fontSize: 11.5, color: _muted)),
    ]);
  }

  void _openDetails(BuildContext context, _Models m) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => PredictiveModelsDetails(regression: m.regression, forecast: m.forecast, live: m.live),
    );
  }
}
