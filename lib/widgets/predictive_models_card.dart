import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../utils/collection_visits.dart';
import '../utils/eta_evaluation.dart';
import '../utils/predictive_models.dart';

/// Analytics card for the predictive models: the arrival-time linear regression and the moving average forecast of
/// the daily collected load, each evaluated with MAE, RMSE and R². The details dialog shows how every figure was made.
class PredictiveModelsCard extends StatefulWidget {
  const PredictiveModelsCard({
    super.key,
    required this.trips,
    required this.areas,
    required this.range,
    required this.etaVisits,
  });

  /// `driver_routes` snapshot.
  final Map trips;
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
        widget.range.start, widget.range.end, widget.etaVisits.length);
    if (_cache != null && _cacheKey == key) return _cache!;
    final ArrivalRegressionReport reg = ArrivalRegression.evaluate(ArrivalRegression.extract(widget.trips, widget.areas));
    final ({List<DateTime> days, List<double> kg}) daily =
        MovingAverageForecast.dailyLoads(widget.trips, from: widget.range.start, to: widget.range.end);
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
    final ArrivalRegressionReport r = m.regression;
    final MovingAverageReport f = m.forecast;
    Widget metricsTable(List<(String, ErrorMetrics, bool)> rows) => Table(
          columnWidths: const <int, TableColumnWidth>{0: FlexColumnWidth(3), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1.4), 3: FlexColumnWidth(1.4), 4: FlexColumnWidth(1)},
          border: TableBorder(horizontalInside: BorderSide(color: Colors.grey.shade200)),
          children: <TableRow>[
            const TableRow(children: <Widget>[
              _Cell('Model', bold: true), _Cell('n', bold: true), _Cell('MAE', bold: true), _Cell('RMSE', bold: true), _Cell('R²', bold: true)
            ]),
            for (final (String, ErrorMetrics, bool) row in rows)
              TableRow(children: <Widget>[
                _Cell(row.$1),
                _Cell('${row.$2.n}'),
                _Cell(row.$3 ? _kg(row.$2.mae) : _min(row.$2.mae)),
                _Cell(row.$3 ? _kg(row.$2.rmse) : _min(row.$2.rmse)),
                _Cell(_r2(row.$2.r2)),
              ]),
          ],
        );
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(
                    child: Text('Predictive Models', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: _ink))),
                IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close_rounded)),
              ]),
              const SizedBox(height: 6),
              const _H('1. Arrival time: linear regression'),
              Text(
                'Each sample is a GPS fix of a moving, collecting truck in the 30 minutes before it entered a collection area '
                '(100 m circle), taken every 2 minutes. The model predicts the minutes until entry from the straight-line distance '
                'to the area. ${r.method} It is compared with the rule the system uses live (distance divided by recent speed) on the '
                'same test samples, and with the estimates actually notified to residents.',
                style: const TextStyle(fontSize: 13, color: _muted, height: 1.4),
              ),
              const SizedBox(height: 8),
              Text(
                r.fit == null
                    ? 'Model: not enough recorded approaches yet.'
                    : 'Model (fitted on all ${r.samples} samples): minutes = ${r.fit!.intercept.toStringAsFixed(2)} + ${r.fit!.slope.toStringAsFixed(2)} × distance (km)',
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: _ink),
              ),
              const SizedBox(height: 10),
              metricsTable(<(String, ErrorMetrics, bool)>[
                ('Linear regression (test samples)', r.regression, false),
                ('Live rule: distance ÷ speed (same samples)', r.baseline, false),
                ('Estimates notified to residents', m.live, false),
              ]),
              const SizedBox(height: 18),
              _H('2. Collected load: ${f.window}-day moving average'),
              Text(
                'The daily load is the sum of the recorded weights of the collections finalized with FULL on that day (Asia/Manila), '
                'zero on days without one, in the selected period. Each day is forecast as the mean of the ${f.window} days before it, '
                'and the forecasts are compared with what was actually collected.',
                style: const TextStyle(fontSize: 13, color: _muted, height: 1.4),
              ),
              const SizedBox(height: 8),
              Text('Forecast for the next day: ${_kg(f.nextForecast)}',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: _ink)),
              const SizedBox(height: 10),
              metricsTable(<(String, ErrorMetrics, bool)>[('Moving average (one day ahead)', f.metrics, true)]),
              const SizedBox(height: 18),
              const _H('How to read the figures'),
              const Text(
                '• MAE: the average size of the error.\n'
                '• RMSE: like MAE, but large errors weigh more.\n'
                '• R²: how much of the variation of the actual values the predictions explain. 1 is perfect, 0 is no better '
                'than always predicting the average, and below 0 is worse than that. R² is not a percentage of accuracy.\n'
                '• n: the number of compared predictions. Small n gives only a first indication; the figures update as trips are recorded.',
                style: TextStyle(fontSize: 13, color: _muted, height: 1.5),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _H extends StatelessWidget {
  const _H(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 4),
        child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Color(0xFF0F172A))),
      );
}

class _Cell extends StatelessWidget {
  const _Cell(this.text, {this.bold = false});
  final String text;
  final bool bold;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Text(text,
            style: TextStyle(fontSize: 12.5, fontWeight: bold ? FontWeight.w800 : FontWeight.w500, color: const Color(0xFF0F172A))),
      );
}
