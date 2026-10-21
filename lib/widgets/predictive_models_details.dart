import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../utils/predictive_models.dart';

/// Details of the predictive models. Every number, label, chart and sentence below is computed from the recorded data
/// each time it opens; only the explanations of the methods are fixed text.
class PredictiveModelsDetails extends StatelessWidget {
  const PredictiveModelsDetails({super.key, required this.regression, required this.forecast, required this.live});

  final ArrivalRegressionReport regression;
  final MovingAverageReport forecast;
  final ErrorMetrics live;

  static const Color ink = Color(0xFF0F172A);
  static const Color muted = Color(0xFF64748B);
  static const Color teal = Color(0xFF0F766E);
  static const Color violet = Color(0xFF6D28D9);
  static const Color amber = Color(0xFFD97706);

  static String minutes(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)} min';
  static String kg(double? v) => v == null ? '—' : '${NumberFormat('#,##0').format(v.round())} kg';
  static String r2Text(double? v) => v == null ? '—' : v.toStringAsFixed(2);

  /// Plain verdict of a model from its R² and sample size.
  static (String, Color) verdict(ErrorMetrics m, {int minSamples = 20}) {
    if (m.n == 0 || m.r2 == null) return ('No data yet', const Color(0xFF94A3B8));
    if (m.n < minSamples) return ('Early data (n = ${m.n})', const Color(0xFF64748B));
    final double r = m.r2!;
    if (r >= 0.7) return ('Strong fit', const Color(0xFF15803D));
    if (r >= 0.4) return ('Moderate fit', const Color(0xFF0E7490));
    if (r >= 0) return ('Weak fit', amber);
    return ('Below the average baseline', const Color(0xFFB91C1C));
  }

  String _regressionSentence() {
    final ErrorMetrics m = regression.regression;
    if (m.n == 0 || m.mae == null) {
      return 'There are not enough recorded approaches to collection areas yet. The model is fitted as soon as trucks record trips that enter the areas.';
    }
    final ErrorMetrics b = regression.baseline;
    final String compare = (b.mae == null)
        ? ''
        : (m.mae! < b.mae! - 0.05
            ? ' It is ${(b.mae! - m.mae!).toStringAsFixed(1)} minutes closer on average than the live rule (distance ÷ speed).'
            : (m.mae! > b.mae! + 0.05
                ? ' The live rule (distance ÷ speed) is still ${(m.mae! - b.mae!).toStringAsFixed(1)} minutes closer on average.'
                : ' It performs about the same as the live rule (distance ÷ speed).'));
    final String fit = m.r2 == null
        ? ''
        : (m.r2! >= 0
            ? ' It explains ${(m.r2! * 100).round()} percent of the variation of the actual arrival times.'
            : ' On these test trips it does not yet beat simply predicting the average arrival time.');
    return 'On ${regression.trips - _trainTrips()} test trip(s) the prediction is off by ${minutes(m.mae)} on average (RMSE ${minutes(m.rmse)}).$fit$compare';
  }

  int _trainTrips() {
    final RegExpMatch? mm = RegExp(r'earliest (\d+) of').firstMatch(regression.method);
    return mm == null ? 0 : int.parse(mm.group(1)!);
  }

  String _forecastSentence() {
    final ErrorMetrics m = forecast.metrics;
    if (m.n == 0 || m.mae == null) {
      return 'The selected period is shorter than ${forecast.window + 1} days, so no forecast can be checked yet.';
    }
    final int loadDays = forecast.series.where((double v) => v > 0).length;
    final String fit = m.r2 == null
        ? ''
        : (m.r2! >= 0
            ? ' It explains ${(m.r2! * 100).round()} percent of the day-to-day variation.'
            : ' It does not yet beat predicting the average day.');
    return 'Over ${m.n} checked days the forecast was off by ${kg(m.mae)} on average (RMSE ${kg(m.rmse)}).$fit '
        'Loads were recorded on $loadDays of ${forecast.series.length} days.';
  }

  @override
  Widget build(BuildContext context) {
    final bool wide = MediaQuery.sizeOf(context).width >= 720;
    final LinearFit? fit = regression.fit;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: const Color(0xFFF8FAFC),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(wide ? 28 : 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: const Color(0xFFEDE9FE), borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.insights_rounded, color: violet, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  const Text('Predictive Models', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: ink)),
                  const SizedBox(height: 2),
                  Text(
                    'Computed from ${regression.trips} recorded trip(s) and ${forecast.series.length} day(s) of loads. Updates as trips are recorded.',
                    style: const TextStyle(fontSize: 12.5, color: muted),
                  ),
                ]),
              ),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
            ]),
            const SizedBox(height: 20),

            // ------------------------------------------------ 1. arrival time
            _Section(
              icon: Icons.schedule_rounded,
              color: teal,
              title: 'Arrival time',
              method: 'Linear regression',
              badge: verdict(regression.regression),
              children: <Widget>[
                if (fit != null)
                  _Formula('minutes = ${fit.intercept.toStringAsFixed(2)} + ${fit.slope.toStringAsFixed(2)} × distance (km)'),
                const SizedBox(height: 12),
                _MetricRow(<(String, String)>[
                  ('MAE', minutes(regression.regression.mae)),
                  ('RMSE', minutes(regression.regression.rmse)),
                  ('R²', r2Text(regression.regression.r2)),
                  ('Test samples', '${regression.regression.n}'),
                ]),
                const SizedBox(height: 12),
                _Insight(_regressionSentence()),
                const SizedBox(height: 16),
                _Comparison(rows: <(String, ErrorMetrics, Color)>[
                  ('Linear regression', regression.regression, teal),
                  ('Live rule (distance ÷ speed)', regression.baseline, const Color(0xFF0EA5E9)),
                  ('Estimates sent to residents', live, amber),
                ]),
                if (regression.testActual.length >= 2) ...<Widget>[
                  const SizedBox(height: 18),
                  const _SubTitle('Predicted vs actual minutes (test samples)'),
                  const SizedBox(height: 6),
                  SizedBox(height: 220, child: _PredActChart(actual: regression.testActual, predicted: regression.testPredicted)),
                  const _Legend(<(String, Color)>[('Test sample', teal), ('Perfect prediction', Color(0xFFCBD5E1))]),
                ],
                const SizedBox(height: 10),
                _Method(
                  'Samples are GPS fixes of moving, collecting trucks in the 30 minutes before they entered a collection area '
                  '(100 m circle), one every 2 minutes; simulations are excluded. ${regression.method} '
                  'The estimates sent to residents were saved before the truck arrived and are compared with the GPS-confirmed arrival.',
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ------------------------------------------------ 2. collected load
            _Section(
              icon: Icons.local_shipping_rounded,
              color: violet,
              title: 'Collected load',
              method: '${forecast.window}-day moving average',
              badge: verdict(forecast.metrics),
              children: <Widget>[
                _MetricRow(<(String, String)>[
                  ('Next-day forecast', kg(forecast.nextForecast)),
                  ('MAE', kg(forecast.metrics.mae)),
                  ('RMSE', kg(forecast.metrics.rmse)),
                  ('R²', r2Text(forecast.metrics.r2)),
                ]),
                const SizedBox(height: 12),
                _Insight(_forecastSentence()),
                if (forecast.backtestActual.length >= 2) ...<Widget>[
                  const SizedBox(height: 18),
                  const _SubTitle('Daily load: actual vs forecast'),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 220,
                    child: _SeriesChart(
                      days: forecast.days.sublist(forecast.window),
                      actual: forecast.backtestActual,
                      forecast: forecast.backtestForecast,
                    ),
                  ),
                  const _Legend(<(String, Color)>[('Actual', violet), ('Forecast', amber)]),
                ],
                const SizedBox(height: 10),
                _Method(
                  'The daily load is the sum of the recorded weights of the collections finalized with FULL on that day (Asia/Manila), '
                  'zero on days without one, in the selected period. Each day is forecast as the mean of the ${forecast.window} days before it.',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: Material(
                color: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFFE2E8F0))),
                clipBehavior: Clip.antiAlias,
                child: const ExpansionTile(
                  leading: Icon(Icons.menu_book_rounded, color: muted),
                  title: Text('How to read the figures', style: TextStyle(fontWeight: FontWeight.w800, color: ink, fontSize: 15)),
                  childrenPadding: EdgeInsets.fromLTRB(20, 0, 20, 16),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _Bullet('MAE', 'the average size of the error, in minutes or kilograms.'),
                    _Bullet('RMSE', 'like MAE, but large errors weigh more; RMSE much larger than MAE means a few big misses.'),
                    _Bullet('R²', 'how much of the variation of the actual values the predictions explain: 1 is perfect, 0 is no better than always predicting the average, below 0 is worse. It is not a percentage of accuracy.'),
                    _Bullet('n', 'the number of compared predictions. Below 20 the figures are only a first indication.'),
                  ],
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.color, required this.title, required this.method, required this.badge, required this.children});
  final IconData icon;
  final Color color;
  final String title;
  final String method;
  final (String, Color) badge;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: <BoxShadow>[BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: PredictiveModelsDetails.ink)),
              Text(method, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
            ]),
          ),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: badge.$2.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
              child: Text(badge.$1, textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: badge.$2)),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        ...children,
      ]),
    );
  }
}

class _Formula extends StatelessWidget {
  const _Formula(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(12)),
        child: Text(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 13.5, fontWeight: FontWeight.w700, color: PredictiveModelsDetails.ink)),
      );
}

class _MetricRow extends StatelessWidget {
  const _MetricRow(this.items);
  final List<(String, String)> items;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
        final int perRow = c.maxWidth < 420 ? 2 : items.length;
        final double w = (c.maxWidth - (perRow - 1) * 10) / perRow;
        return Wrap(spacing: 10, runSpacing: 10, children: <Widget>[
          for (final (String, String) it in items)
            Container(
              width: w,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFEEF2F7))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(it.$1, style: const TextStyle(fontSize: 11.5, color: PredictiveModelsDetails.muted, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(it.$2, style: const TextStyle(fontSize: 16, color: PredictiveModelsDetails.ink, fontWeight: FontWeight.w900)),
              ]),
            ),
        ]);
      });
}

class _Insight extends StatelessWidget {
  const _Insight(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: const Color(0xFFF0FDFA), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFCCFBF1))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const Icon(Icons.lightbulb_outline_rounded, size: 18, color: PredictiveModelsDetails.teal),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.45, color: Color(0xFF134E4A)))),
        ]),
      );
}

class _Comparison extends StatelessWidget {
  const _Comparison({required this.rows});
  final List<(String, ErrorMetrics, Color)> rows;
  @override
  Widget build(BuildContext context) {
    final double maxMae = rows.map((r) => r.$2.mae ?? 0).fold(0.0, math.max);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      const _SubTitle('Average error (MAE) by method'),
      const SizedBox(height: 8),
      for (final (String, ErrorMetrics, Color) r in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
              Text(r.$1, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PredictiveModelsDetails.ink)),
              Text(
                r.$2.mae == null
                    ? 'no data'
                    : '${PredictiveModelsDetails.minutes(r.$2.mae)}  ·  R² ${PredictiveModelsDetails.r2Text(r.$2.r2)}  ·  n ${r.$2.n}',
                style: const TextStyle(fontSize: 12, color: PredictiveModelsDetails.muted),
              ),
            ]),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: (r.$2.mae == null || maxMae == 0) ? 0 : (r.$2.mae! / maxMae).clamp(0.02, 1.0),
                minHeight: 9,
                backgroundColor: const Color(0xFFF1F5F9),
                valueColor: AlwaysStoppedAnimation<Color>(r.$3),
              ),
            ),
          ]),
        ),
      const Text('Shorter bars are better.', style: TextStyle(fontSize: 11.5, color: PredictiveModelsDetails.muted)),
    ]);
  }
}

class _PredActChart extends StatelessWidget {
  const _PredActChart({required this.actual, required this.predicted});
  final List<double> actual;
  final List<double> predicted;
  @override
  Widget build(BuildContext context) {
    final double top = (<double>[...actual, ...predicted].fold(0.0, math.max) * 1.1).ceilToDouble().clamp(5, 1e9).toDouble();
    final List<ScatterSpot> spots = <ScatterSpot>[
      for (int i = 0; i < actual.length; i++)
        ScatterSpot(predicted[i], actual[i], dotPainter: FlDotCirclePainter(radius: 4.5, color: PredictiveModelsDetails.teal.withValues(alpha: 0.75), strokeWidth: 0)),
      for (int i = 0; i <= 20; i++)
        ScatterSpot(top * i / 20, top * i / 20, dotPainter: FlDotCirclePainter(radius: 1.3, color: const Color(0xFFCBD5E1), strokeWidth: 0)),
    ];
    return ScatterChart(ScatterChartData(
      minX: 0,
      maxX: top,
      minY: 0,
      maxY: top,
      scatterSpots: spots,
      gridData: const FlGridData(drawVerticalLine: true),
      borderData: FlBorderData(show: false),
      scatterTouchData: ScatterTouchData(enabled: false),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
            axisNameWidget: const Text('Predicted (min)', style: TextStyle(fontSize: 11, color: PredictiveModelsDetails.muted)),
            sideTitles: SideTitles(showTitles: true, reservedSize: 22, getTitlesWidget: (double v, TitleMeta m) => Text(v.toStringAsFixed(0), style: const TextStyle(fontSize: 10)))),
        leftTitles: AxisTitles(
            axisNameWidget: const Text('Actual (min)', style: TextStyle(fontSize: 11, color: PredictiveModelsDetails.muted)),
            sideTitles: SideTitles(showTitles: true, reservedSize: 30, getTitlesWidget: (double v, TitleMeta m) => Text(v.toStringAsFixed(0), style: const TextStyle(fontSize: 10)))),
      ),
    ));
  }
}

class _SeriesChart extends StatelessWidget {
  const _SeriesChart({required this.days, required this.actual, required this.forecast});
  final List<DateTime> days;
  final List<double> actual;
  final List<double> forecast;
  @override
  Widget build(BuildContext context) {
    final double top = (<double>[...actual, ...forecast].fold(0.0, math.max) * 1.15).clamp(1000, 1e12).toDouble();
    LineChartBarData line(List<double> v, Color c, {bool dashed = false}) => LineChartBarData(
          spots: <FlSpot>[for (int i = 0; i < v.length; i++) FlSpot(i.toDouble(), v[i])],
          isCurved: false,
          color: c,
          barWidth: dashed ? 2 : 2.5,
          dashArray: dashed ? <int>[6, 4] : null,
          dotData: FlDotData(show: !dashed, getDotPainter: (FlSpot s, double p, LineChartBarData b, int i) => FlDotCirclePainter(radius: 2.5, color: c, strokeWidth: 0)),
          belowBarData: BarAreaData(show: !dashed, color: c.withValues(alpha: 0.08)),
        );
    final int step = math.max(1, (days.length / 6).ceil());
    return LineChart(LineChartData(
      minY: 0,
      maxY: top,
      lineBarsData: <LineChartBarData>[line(actual, PredictiveModelsDetails.violet), line(forecast, PredictiveModelsDetails.amber, dashed: true)],
      gridData: const FlGridData(drawVerticalLine: false),
      borderData: FlBorderData(show: false),
      lineTouchData: const LineTouchData(enabled: false),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
            sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 22,
                interval: step.toDouble(),
                getTitlesWidget: (double v, TitleMeta m) {
                  final int i = v.round();
                  if (i < 0 || i >= days.length) return const SizedBox.shrink();
                  return Text(DateFormat('MMM d').format(days[i]), style: const TextStyle(fontSize: 10));
                })),
        leftTitles: AxisTitles(
            sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                getTitlesWidget: (double v, TitleMeta m) => Text('${(v / 1000).toStringAsFixed(0)}t', style: const TextStyle(fontSize: 10)))),
      ),
    ));
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.items);
  final List<(String, Color)> items;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(spacing: 16, children: <Widget>[
          for (final (String, Color) it in items)
            Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
              Container(width: 10, height: 10, decoration: BoxDecoration(color: it.$2, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(it.$1, style: const TextStyle(fontSize: 11.5, color: PredictiveModelsDetails.muted)),
            ]),
        ]),
      );
}

class _SubTitle extends StatelessWidget {
  const _SubTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: PredictiveModelsDetails.ink));
}

class _Method extends StatelessWidget {
  const _Method(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.info_outline_rounded, size: 15, color: PredictiveModelsDetails.muted)),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 12, height: 1.45, color: PredictiveModelsDetails.muted))),
      ]);
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.term, this.text);
  final String term;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: RichText(
          text: TextSpan(style: const TextStyle(fontSize: 13, height: 1.45, color: PredictiveModelsDetails.muted), children: <TextSpan>[
            TextSpan(text: '$term: ', style: const TextStyle(fontWeight: FontWeight.w800, color: PredictiveModelsDetails.ink)),
            TextSpan(text: text),
          ]),
        ),
      );
}
