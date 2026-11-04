import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../utils/predictive_models.dart';
import 'ai_model_explanation.dart';

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

  /// The arrival-time figures shown in this dialog, as sent to the AI explanation (numbers only; missing ones left out).
  Map<String, num> _arrivalNumbers() {
    final ErrorMetrics m = regression.regression, b = regression.baseline;
    return <String, num>{
      'recorded_trips': regression.trips,
      'samples': regression.samples,
      'test_samples': m.n,
      if (m.mae != null) 'mae_min': m.mae!,
      if (m.rmse != null) 'rmse_min': m.rmse!,
      if (m.r2 != null) 'r2': m.r2!,
      if (regression.fit != null) 'intercept_min': regression.fit!.intercept,
      if (regression.fit != null) 'slope_min_per_km': regression.fit!.slope,
      if (b.mae != null) 'live_rule_mae_min': b.mae!,
      if (b.rmse != null) 'live_rule_rmse_min': b.rmse!,
      if (b.r2 != null) 'live_rule_r2': b.r2!,
      'resident_estimates_checked': live.n,
      if (live.mae != null) 'resident_estimates_mae_min': live.mae!,
    };
  }

  /// The collected-load figures shown in this dialog, as sent to the AI explanation.
  Map<String, num> _loadNumbers() {
    final ErrorMetrics m = forecast.metrics;
    return <String, num>{
      'window_days': forecast.window,
      'days_in_period': forecast.series.length,
      'days_with_loads': forecast.series.where((double v) => v > 0).length,
      'checked_days': m.n,
      if (m.mae != null) 'mae_kg': m.mae!,
      if (m.rmse != null) 'rmse_kg': m.rmse!,
      if (m.r2 != null) 'r2': m.r2!,
      if (forecast.nextForecast != null) 'next_day_forecast_kg': forecast.nextForecast!,
    };
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
            AiModelExplanation(arrival: _arrivalNumbers(), load: _loadNumbers()),
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
            _Workings(regression: regression, forecast: forecast),
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

/// "How these numbers were computed": the working behind every figure of the dialog, done on the recorded data itself, with
/// where each piece of data comes from and where it can be checked in the system. Nothing here is typed in; it is all derived
/// from the same reports the figures above come from, so it always matches them. Each step is a dropdown, so the reader opens
/// only the part that is being asked about.
class _Workings extends StatelessWidget {
  const _Workings({required this.regression, required this.forecast});

  final ArrivalRegressionReport regression;
  final MovingAverageReport forecast;

  static String minutes(double? v) => PredictiveModelsDetails.minutes(v);
  static String kg(double? v) => PredictiveModelsDetails.kg(v);
  static String r2Text(double? v) => PredictiveModelsDetails.r2Text(v);
  static String _n(double v, [int d = 2]) => v.toStringAsFixed(d);
  static String _kg(double v) => NumberFormat('#,##0').format(v.round());
  static String _signed(double v, [int d = 1]) => '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(d)}';
  static String _signedKg(double v) => '${v >= 0 ? '+' : '−'}${NumberFormat('#,##0').format(v.abs().round())}';
  static String _million(double v) => '${(v / 1e6).toStringAsFixed(1)} million kg²';
  static String _day(DateTime d) => DateFormat('MMM d').format(d);
  static String _stamp(int ms) => DateFormat('MMM d, h:mm a').format(DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).add(const Duration(hours: 8)));
  static String _tail(String id) => id.length <= 6 ? id : '…${id.substring(id.length - 6)}';

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      _Section(
        icon: Icons.calculate_rounded,
        color: PredictiveModelsDetails.teal,
        title: 'How the arrival-time figures were computed',
        method: 'Worked from the recorded trips',
        badge: ('Real data', PredictiveModelsDetails.teal),
        children: _arrival(),
      ),
      const SizedBox(height: 16),
      _Section(
        icon: Icons.calculate_rounded,
        color: PredictiveModelsDetails.violet,
        title: 'How the collected-load figures were computed',
        method: 'Worked from the recorded loads',
        badge: ('Real data', PredictiveModelsDetails.violet),
        children: _load(),
      ),
    ]);
  }

  // ------------------------------------------------------------------ arrival time
  List<Widget> _arrival() {
    const Color c = PredictiveModelsDetails.teal;
    final List<ArrivalSample> all = regression.allSamples;
    final LinearFit? fit = regression.fit;
    if (all.length < 2 || fit == null) {
      return const <Widget>[
        _Method('There are not enough recorded approaches to a collection area yet to show the working. It appears here as soon as trucks record trips that enter the areas.'),
      ];
    }
    final int n = all.length;
    double mx = 0, my = 0;
    for (final ArrivalSample s in all) {
      mx += s.distanceKm;
      my += s.actualMin;
    }
    mx /= n;
    my /= n;
    double sxx = 0, sxy = 0;
    for (final ArrivalSample s in all) {
      sxx += (s.distanceKm - mx) * (s.distanceKm - mx);
      sxy += (s.distanceKm - mx) * (s.actualMin - my);
    }

    // a handful of samples spread over the whole period, so the table is not just the oldest trip
    final int shown = math.min(6, n);
    final List<ArrivalSample> pick = <ArrivalSample>[for (int i = 0; i < shown; i++) all[(i * (n - 1) / math.max(1, shown - 1)).round()]];
    final ArrivalSample ex = pick.firstWhere((ArrivalSample s) => s.baselineMin != null, orElse: () => pick.first);
    final double exModel = fit.predict(ex.distanceKm);
    final double? exLive = ex.baselineMin;

    final ErrorMetrics m = regression.regression;
    final List<double> act = regression.testActual, pred = regression.testPredicted;
    double sumAbs = 0, ssRes = 0, meanAct = 0;
    for (int i = 0; i < act.length; i++) {
      final double e = act[i] - pred[i];
      sumAbs += e.abs();
      ssRes += e * e;
      meanAct += act[i];
    }
    if (act.isNotEmpty) meanAct /= act.length;
    double ssTot = 0;
    for (final double a in act) {
      ssTot += (a - meanAct) * (a - meanAct);
    }
    final int tn = act.length;
    final List<ArrivalSample> tested = regression.testSamples;
    final int testShown = math.min(8, tn);

    return <Widget>[
      _Step(
        n: 1,
        color: c,
        title: 'Where the data comes from',
        summary: '$n samples from ${regression.trips} trips',
        children: <Widget>[
          const _Fact(Icons.storage_rounded, 'Source', 'Each sample is one GPS fix that the driver app saved for a trip (Firebase: driver_routes / trip / route).'),
          const _Fact(Icons.travel_explore_rounded, 'Check it in the system',
              'Admin > Route History (past tracking): choose the date, open the trip and replay it. The fixes inside the 100 m circle of the area are the arrival.'),
          const _Fact(Icons.straighten_rounded, 'Distance and actual minutes',
              'Distance = straight line from the fix to the edge of the area (a 100 m circle around the area\'s verified point). Actual minutes = time from the fix until the first fix of the same trip inside the circle.'),
          const _Fact(Icons.filter_alt_rounded, 'What counts as a sample',
              'A collecting truck that was moving (3 km/h or more in the last 90 seconds), fix accuracy 50 m or better, up to 5 km and 30 minutes before the arrival, one sample every 2 minutes. Simulated trips are left out.'),
          _Fact(Icons.event_rounded, 'Right now', '$n samples from ${regression.trips} trips, ${_stamp(all.first.fixMs)} to ${_stamp(all.last.fixMs)} (Manila time).'),
          const SizedBox(height: 6),
          _SubTitle('A few of the $n samples'),
          const SizedBox(height: 6),
          _Grid(
            const <String>['Fix time', 'Area', 'Trip', 'Distance (km)', 'Speed (km/h)', 'Actual (min)'],
            <List<String>>[
              for (final ArrivalSample s in pick)
                <String>[_stamp(s.fixMs), s.area, _tail(s.tripId), _n(s.distanceKm), s.speedKmh == null ? '—' : _n(s.speedKmh!, 1), _n(s.actualMin, 1)],
            ],
            color: c,
          ),
        ],
      ),
      _Step(
        n: 2,
        color: c,
        open: true,
        title: 'Where ${_n(fit.intercept)} and ${_n(fit.slope)} come from',
        summary: 'minutes = ${_n(fit.intercept)} + ${_n(fit.slope)} × distance (km)',
        children: <Widget>[
          const _Method('The line is the straight line that passes closest to all the samples (least squares). First the averages and sums of the samples:'),
          const SizedBox(height: 8),
          _CalcRows(<(String, String)>[
            ('Number of samples', '$n'),
            ('Average distance', '${_n(mx, 3)} km'),
            ('Average actual minutes', '${_n(my)} min'),
            ('Spread of the distances: sum of (distance − average distance)²', _n(sxx)),
            ('Distance and minutes moving together: sum of (distance − average distance) × (minutes − average minutes)', _n(sxy)),
          ]),
          const SizedBox(height: 10),
          _Eq(title: 'Slope', general: 'slope = moving together ÷ spread of the distances', numbers: '${_n(sxy)} ÷ ${_n(sxx)}', result: '${_n(fit.slope)} min per km', color: c),
          const SizedBox(height: 8),
          _Eq(title: 'Intercept', general: 'intercept = average minutes − slope × average distance', numbers: '${_n(my)} − ${_n(fit.slope)} × ${_n(mx, 3)}', result: '${_n(fit.intercept)} min', color: c),
          const SizedBox(height: 10),
          _Banner('minutes = ${_n(fit.intercept)} + ${_n(fit.slope)} × distance (km)', c),
          const SizedBox(height: 8),
          _Method(
            'Slope ${_n(fit.slope)}: each extra kilometre adds about ${_n(fit.slope, 1)} minutes. Intercept ${_n(fit.intercept)}: the time a collecting truck loses on the way (stops, streets served, detours) even when it is close. '
            'The line changes as trips are recorded. Figures are rounded for display.',
          ),
        ],
      ),
      _Step(
        n: 3,
        color: c,
        title: 'Example with a real sample',
        summary: '${ex.area} · model ${_n(exModel, 1)} min · actual ${_n(ex.actualMin, 1)} min',
        children: <Widget>[
          _CalcRows(<(String, String)>[
            ('Area', ex.area),
            ('Fix time', _stamp(ex.fixMs)),
            ('Trip', _tail(ex.tripId)),
            ('Distance to the area', '${_n(ex.distanceKm)} km'),
            if (ex.speedKmh != null) ('Truck speed', '${_n(ex.speedKmh!, 1)} km/h'),
          ]),
          const SizedBox(height: 10),
          _Eq(title: 'Model', general: 'minutes = intercept + slope × distance', numbers: '${_n(fit.intercept)} + ${_n(fit.slope)} × ${_n(ex.distanceKm)}', result: '${_n(exModel, 1)} min', color: c),
          if (exLive != null) ...<Widget>[
            const SizedBox(height: 8),
            _Eq(
                title: 'Live rule',
                general: 'Time = Distance ÷ Speed × 60',
                numbers: '${_n(ex.distanceKm)} ÷ ${_n(ex.speedKmh!, 1)} × 60',
                result: '${_n(exLive, 1)} min',
                color: const Color(0xFF0EA5E9)),
          ],
          const SizedBox(height: 10),
          _MetricRow(<(String, String)>[
            ('Model said', '${_n(exModel, 1)} min'),
            if (exLive != null) ('Live rule said', '${_n(exLive, 1)} min'),
            ('Really took', '${_n(ex.actualMin, 1)} min'),
          ]),
        ],
      ),
      _Step(
        n: 4,
        color: c,
        title: 'How MAE, RMSE and R² were measured',
        summary: 'MAE ${minutes(m.mae)} · RMSE ${minutes(m.rmse)} · R² ${r2Text(m.r2)}',
        children: <Widget>[
          _Method(
            '${regression.method} The error is measured only on trips that were not used to fit the line, so it shows how the model does on trips it has not seen.'
            '${regression.trainFit == null ? '' : ' The line used for the test is fitted on the first ${regression.trainTrips} trips only: minutes = ${_n(regression.trainFit!.intercept)} + ${_n(regression.trainFit!.slope)} × distance, so it differs a little from the line above, which uses all samples.'}',
          ),
          if (tn > 0) ...<Widget>[
            const SizedBox(height: 10),
            _SubTitle('${tn > testShown ? 'First $testShown of the $tn test samples' : 'The $tn test samples'} (error = actual − predicted)'),
            const SizedBox(height: 6),
            _Grid(
              const <String>['Area', 'Distance (km)', 'Predicted (min)', 'Actual (min)', 'Error (min)'],
              <List<String>>[
                for (int i = 0; i < testShown; i++)
                  <String>[
                    i < tested.length ? tested[i].area : '—',
                    i < tested.length ? _n(tested[i].distanceKm) : '—',
                    _n(pred[i], 1),
                    _n(act[i], 1),
                    _signed(act[i] - pred[i]),
                  ],
              ],
              color: c,
            ),
            const SizedBox(height: 10),
            _Eq(title: 'MAE', general: 'MAE = sum of |actual − predicted| ÷ number of test samples', numbers: '${_n(sumAbs, 1)} ÷ $tn', result: minutes(m.mae), color: c),
            const SizedBox(height: 8),
            _Eq(title: 'RMSE', general: 'RMSE = square root of (sum of (actual − predicted)² ÷ number of test samples)', numbers: '√( ${_n(ssRes, 1)} ÷ $tn )', result: minutes(m.rmse), color: c),
            const SizedBox(height: 8),
            _CalcRows(<(String, String)>[
              ('Total squared error (SSres): sum of (actual − predicted)²', _n(ssRes, 1)),
              ('Total variation (SStot): sum of (actual − average actual)²', _n(ssTot, 1)),
              ('Average actual', '${_n(meanAct, 1)} min'),
            ]),
            const SizedBox(height: 8),
            _Eq(title: 'R²', general: 'R² = 1 − total squared error ÷ total variation', numbers: '1 − ${_n(ssRes, 1)} ÷ ${_n(ssTot, 1)}', result: r2Text(m.r2), color: c),
            const SizedBox(height: 8),
            _Insight(
              m.r2 == null
                  ? 'R² needs at least two test samples that are not all the same.'
                  : (m.r2! >= 0
                      ? 'R² ${r2Text(m.r2)} means the distance explains ${(m.r2! * 100).round()} percent of the differences between the real arrival times; the rest is what distance cannot see (stops, route, traffic).'
                      : 'R² ${r2Text(m.r2)} is below 0: on these test trips the line is worse than always predicting the average arrival time (${_n(meanAct, 1)} min).'),
            ),
          ],
        ],
      ),
    ];
  }

  // ------------------------------------------------------------------ collected load
  List<Widget> _load() {
    const Color c = PredictiveModelsDetails.violet;
    final int w = forecast.window;
    final List<double> s = forecast.series;
    final ErrorMetrics m = forecast.metrics;
    if (s.length < w || forecast.nextForecast == null) {
      return <Widget>[_Method('The selected period is shorter than $w days, so there is no load figure to work out yet.')];
    }
    final List<int> last = <int>[for (int i = s.length - w; i < s.length; i++) i];
    final double sum = last.fold<double>(0, (double a, int i) => a + s[i]);

    final int bn = forecast.backtestActual.length;
    double sumAbs = 0, ssRes = 0, meanAct = 0;
    for (int i = 0; i < bn; i++) {
      final double e = forecast.backtestActual[i] - forecast.backtestForecast[i];
      sumAbs += e.abs();
      ssRes += e * e;
      meanAct += forecast.backtestActual[i];
    }
    if (bn > 0) meanAct /= bn;
    double ssTot = 0;
    for (final double a in forecast.backtestActual) {
      ssTot += (a - meanAct) * (a - meanAct);
    }
    final int shown = math.min(7, bn);

    return <Widget>[
      const _Step(
        n: 1,
        color: c,
        title: 'Where the data comes from',
        summary: 'Load History · 5,000 kg per FULL trip',
        children: <Widget>[
          _Fact(Icons.local_shipping_rounded, 'Source', 'Each load is a trip that was finalized FULL.'),
          _Fact(Icons.travel_explore_rounded, 'Check it in the system',
              'Analytics > Waste Collection Summary > View Load History lists every trip under its date. It is the same list the Waste Collection Summary card counts.'),
          _Fact(Icons.scale_rounded, 'Weight', 'Every FULL counts as 5,000 kg unless an admin entered a measured weight, because there is no weighing scale yet. So the daily load is mostly the number of FULL trips of the day × 5,000 kg.'),
          _Fact(Icons.event_rounded, 'Days', 'A day with no FULL is 0 kg. Days are Asia/Manila calendar days.'),
        ],
      ),
      _Step(
        n: 2,
        color: c,
        open: true,
        title: 'The next-day forecast',
        summary: 'last $w days ÷ $w = ${kg(forecast.nextForecast)}',
        children: <Widget>[
          _SubTitle('The last $w days'),
          const SizedBox(height: 6),
          _Chips(<(String, String)>[for (final int i in last) (_day(forecast.days[i]), '${_kg(s[i])} kg')], c),
          const SizedBox(height: 10),
          _Eq(
              title: 'Forecast',
              general: 'Forecast = (sum of the last $w days) ÷ $w',
              numbers: '(${last.map((int i) => _kg(s[i])).join(' + ')}) ÷ $w',
              result: kg(forecast.nextForecast),
              color: c),
          const SizedBox(height: 6),
          _Method('The sum of the $w days is ${_kg(sum)} kg, so ${_kg(sum)} ÷ $w = ${kg(forecast.nextForecast)}.'),
        ],
      ),
      _Step(
        n: 3,
        color: c,
        title: 'How it was checked against what really happened',
        summary: 'MAE ${kg(m.mae)} · RMSE ${kg(m.rmse)} · R² ${r2Text(m.r2)}',
        children: <Widget>[
          _Method('Every day from day ${w + 1} on was forecast from the $w days before it and then compared with the real load of that day ($bn checked days).'),
          if (bn > 0) ...<Widget>[
            const SizedBox(height: 10),
            _SubTitle('The latest $shown checked days (error = actual − forecast)'),
            const SizedBox(height: 6),
            _Grid(
              <String>['Day', 'Previous $w days (kg)', 'Forecast (kg)', 'Actual (kg)', 'Error (kg)'],
              <List<String>>[
                for (int i = bn - shown; i < bn; i++)
                  <String>[
                    _day(forecast.days[w + i]),
                    _kg(forecast.backtestForecast[i] * w),
                    _kg(forecast.backtestForecast[i]),
                    _kg(forecast.backtestActual[i]),
                    _signedKg(forecast.backtestActual[i] - forecast.backtestForecast[i]),
                  ],
              ],
              color: c,
            ),
            const SizedBox(height: 10),
            _Eq(title: 'MAE', general: 'MAE = sum of |actual − forecast| ÷ number of checked days', numbers: '${_kg(sumAbs)} ÷ $bn', result: kg(m.mae), color: c),
            const SizedBox(height: 8),
            _Eq(title: 'RMSE', general: 'RMSE = square root of (sum of (actual − forecast)² ÷ number of checked days)', numbers: '√( ${_million(ssRes)} ÷ $bn )', result: kg(m.rmse), color: c),
            const SizedBox(height: 8),
            _CalcRows(<(String, String)>[
              ('Total squared error (SSres): sum of (actual − forecast)²', _million(ssRes)),
              ('Total variation (SStot): sum of (actual − average actual)²', _million(ssTot)),
              ('Average actual', '${_kg(meanAct)} kg'),
            ]),
            const SizedBox(height: 8),
            _Eq(title: 'R²', general: 'R² = 1 − total squared error ÷ total variation', numbers: '1 − ${_n(ssRes / 1e6, 1)} ÷ ${_n(ssTot / 1e6, 1)}', result: r2Text(m.r2), color: c),
            const SizedBox(height: 8),
            _Insight(
              m.r2 == null
                  ? 'R² needs at least two checked days that are not all the same.'
                  : (m.r2! >= 0
                      ? 'R² ${r2Text(m.r2)}: the forecast explains ${(m.r2! * 100).round()} percent of the day-to-day differences.'
                      : 'R² ${r2Text(m.r2)} is below 0: always forecasting the average day (${_kg(meanAct)} kg) would have been closer, because collection days alternate between 0 and many loads and an average of the past week cannot follow that.'),
            ),
          ],
        ],
      ),
    ];
  }
}

/// One dropdown step of the working: a numbered badge, the question it answers and its result at a glance.
class _Step extends StatelessWidget {
  const _Step({required this.n, required this.color, required this.title, required this.summary, required this.children, this.open = false});
  final int n;
  final Color color;
  final String title;
  final String summary;
  final List<Widget> children;
  final bool open;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE2E8F0))),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: open,
          maintainState: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(14, 2, 14, 14),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          collapsedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          leading: Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.13), shape: BoxShape.circle),
            child: Text('$n', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: color)),
          ),
          title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: PredictiveModelsDetails.ink)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(summary, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: color)),
          ),
          children: children,
        ),
      ),
    );
  }
}

/// An icon, a bold heading and a sentence: one fact about where the data comes from.
class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.title, this.text);
  final IconData icon;
  final String title;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(9), border: Border.all(color: const Color(0xFFE2E8F0))),
            child: Icon(icon, size: 16, color: PredictiveModelsDetails.muted),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: PredictiveModelsDetails.ink)),
              const SizedBox(height: 1),
              Text(text, style: const TextStyle(fontSize: 12.5, height: 1.45, color: Color(0xFF475569))),
            ]),
          ),
        ]),
      );
}

/// Label and value rows of one working, like a receipt.
class _CalcRows extends StatelessWidget {
  const _CalcRows(this.rows);
  final List<(String, String)> rows;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE2E8F0))),
        child: Column(children: <Widget>[
          for (int i = 0; i < rows.length; i++) ...<Widget>[
            if (i > 0) const Divider(height: 1, color: Color(0xFFEEF2F7)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Expanded(child: Text(rows[i].$1, style: const TextStyle(fontSize: 12.5, color: PredictiveModelsDetails.muted))),
                const SizedBox(width: 12),
                Flexible(child: Text(rows[i].$2, textAlign: TextAlign.right, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: PredictiveModelsDetails.ink))),
              ]),
            ),
          ],
        ]),
      );
}

/// One calculation: its name, the general formula, the same formula with the real numbers, and the result as a pill.
class _Eq extends StatelessWidget {
  const _Eq({required this.title, required this.general, required this.numbers, required this.result, required this.color});
  final String title;
  final String general;
  final String numbers;
  final String result;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(14), border: Border.all(color: color.withValues(alpha: 0.2))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(title.toUpperCase(), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 0.6, color: color)),
          const SizedBox(height: 4),
          Text(general, style: const TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: PredictiveModelsDetails.muted)),
          const SizedBox(height: 8),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 10, runSpacing: 6, children: <Widget>[
            Text(numbers, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: PredictiveModelsDetails.ink)),
            const Text('=', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: PredictiveModelsDetails.muted)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
              child: Text(result, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Colors.white)),
            ),
          ]),
        ]),
      );
}

/// The finished equation, large.
class _Banner extends StatelessWidget {
  const _Banner(this.text, this.color);
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Colors.white)),
      );
}

/// Small day and value cards (the days a forecast is made from).
class _Chips extends StatelessWidget {
  const _Chips(this.items, this.color);
  final List<(String, String)> items;
  final Color color;
  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
        for (final (String, String) it in items)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withValues(alpha: 0.25))),
            child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
              Text(it.$1, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: PredictiveModelsDetails.muted)),
              const SizedBox(height: 1),
              Text(it.$2, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: PredictiveModelsDetails.ink)),
            ]),
          ),
      ]);
}

/// A small table that scrolls sideways on a narrow screen instead of squeezing its columns.
class _Grid extends StatelessWidget {
  const _Grid(this.headers, this.rows, {required this.color});
  final List<String> headers;
  final List<List<String>> rows;
  final Color color;

  Widget _cell(String t, {bool head = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(t, style: TextStyle(fontSize: 12.5, fontWeight: head ? FontWeight.w800 : FontWeight.w500, color: head ? color : PredictiveModelsDetails.ink)),
      );

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(border: Border.all(color: const Color(0xFFE2E8F0)), borderRadius: BorderRadius.circular(12), color: Colors.white),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              children: <TableRow>[
                TableRow(decoration: BoxDecoration(color: color.withValues(alpha: 0.08)), children: <Widget>[for (final String h in headers) _cell(h, head: true)]),
                for (int i = 0; i < rows.length; i++)
                  TableRow(
                    decoration: BoxDecoration(color: i.isOdd ? const Color(0xFFF8FAFC) : Colors.white),
                    children: <Widget>[for (final String v in rows[i]) _cell(v)],
                  ),
              ],
            ),
          ),
        ),
      );
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
