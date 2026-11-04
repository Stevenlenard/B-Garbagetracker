import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../utils/app_localizations.dart';
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

/// Number and date formatting of the working (the same figures in English and in Tagalog).
class _F {
  static String minutes(double? v) => PredictiveModelsDetails.minutes(v);
  static String kg(double? v) => PredictiveModelsDetails.kg(v);
  static String r2(double? v) => PredictiveModelsDetails.r2Text(v);
  static String n(double v, [int d = 2]) => v.toStringAsFixed(d);
  static String kgn(double v) => NumberFormat('#,##0').format(v.round());
  static String signed(double v, [int d = 1]) => '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(d)}';
  static String signedKg(double v) => '${v >= 0 ? '+' : '−'}${NumberFormat('#,##0').format(v.abs().round())}';
  static String million(double v, bool tl) => '${(v / 1e6).toStringAsFixed(1)} ${tl ? 'milyong' : 'million'} kg²';
  static String day(DateTime d) => DateFormat('MMM d').format(d);
  static String stamp(int ms) => DateFormat('MMM d, h:mm a').format(DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).add(const Duration(hours: 8)));
  static String tail(String id) => id.length <= 6 ? id : '…${id.substring(id.length - 6)}';
}

/// "How these numbers were computed": the working behind every figure of the dialog, done on the recorded data itself, with
/// where each piece of data comes from and where it can be checked in the system. Nothing here is typed in; it is all derived
/// from the same reports the figures above come from, so it always matches them. Each step is a dropdown, so the reader opens
/// only the part that is being asked about, and the whole section can be read in English or in Tagalog (the figures,
/// formulas and screen names stay the same; only the sentences are translated).
class _Workings extends StatefulWidget {
  const _Workings({required this.regression, required this.forecast});

  final ArrivalRegressionReport regression;
  final MovingAverageReport forecast;

  @override
  State<_Workings> createState() => _WorkingsState();
}

class _WorkingsState extends State<_Workings> {
  /// Starts in the language the app is set to.
  bool _tl = AppLocalizations.currentLanguage.value == AppLanguage.fil;

  ArrivalRegressionReport get regression => widget.regression;
  MovingAverageReport get forecast => widget.forecast;

  /// The sentence in the language chosen.
  String _t(String en, String tl) => _tl ? tl : en;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      _LangToggle(tl: _tl, onChanged: (bool v) => setState(() => _tl = v)),
      const SizedBox(height: 10),
      _Section(
        icon: Icons.calculate_rounded,
        color: PredictiveModelsDetails.teal,
        title: _t('How the arrival-time figures were computed', 'Paano nakuha ang mga numero ng arrival time'),
        method: _t('Worked from the recorded trips', 'Kinuwenta mula sa mga naitalang trip'),
        badge: (_t('Real data', 'Totoong datos'), PredictiveModelsDetails.teal),
        children: _arrival(),
      ),
      const SizedBox(height: 16),
      _Section(
        icon: Icons.calculate_rounded,
        color: PredictiveModelsDetails.violet,
        title: _t('How the collected-load figures were computed', 'Paano nakuha ang mga numero ng collected load'),
        method: _t('Worked from the recorded loads', 'Kinuwenta mula sa mga naitalang load'),
        badge: (_t('Real data', 'Totoong datos'), PredictiveModelsDetails.violet),
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
      return <Widget>[
        _Method(_t(
          'There are not enough recorded approaches to a collection area yet to show the working. It appears here as soon as trucks record trips that enter the areas.',
          'Wala pang sapat na naitalang pagpasok sa collection area para maipakita ang kuwenta. Lalabas ito dito kapag may mga trip nang pumasok sa mga area.',
        )),
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
    final String a = _F.n(fit.intercept), b = _F.n(fit.slope);

    final String method = regression.trainFit == null
        ? _t(regression.method, 'Leave-one-trip-out: bawat isa sa ${regression.trips} trip ay hinuhulaan ng linyang hinubog sa ibang mga trip.')
        : _t(regression.method,
            'Hinubog sa pinakamaagang ${regression.trainTrips} sa ${regression.trips} trip at sinubok sa natirang ${regression.trips - regression.trainTrips}.');

    return <Widget>[
      _Step(
        n: 1,
        color: c,
        title: _t('Where the data comes from', 'Saan galing ang data'),
        summary: _t('$n samples from ${regression.trips} trips', '$n sample mula sa ${regression.trips} trip'),
        children: <Widget>[
          _Fact(
              Icons.storage_rounded,
              _t('Source', 'Pinagmulan'),
              _t('Each sample is one GPS fix that the driver app saved for a trip (Firebase: driver_routes / trip / route).',
                  'Ang bawat sample ay isang GPS fix na na-save ng driver app para sa isang trip (Firebase: driver_routes / trip / route).')),
          _Fact(
              Icons.travel_explore_rounded,
              _t('Check it in the system', 'Paano i-check sa system'),
              _t('Admin > Route History (past tracking): choose the date, open the trip and replay it. The fixes inside the 100 m circle of the area are the arrival.',
                  'Admin > Route History (past tracking): piliin ang petsa, buksan ang trip at i-replay. Ang mga fix sa loob ng 100 m na bilog ng area ang dating ng truck.')),
          _Fact(
              Icons.straighten_rounded,
              _t('Distance and actual minutes', 'Layo at totoong minuto'),
              _t('Distance = straight line from the fix to the edge of the area (a 100 m circle around the area\'s verified point). Actual minutes = time from the fix until the first fix of the same trip inside the circle.',
                  'Layo = tuwid na linya mula sa fix hanggang sa gilid ng area (100 m na bilog sa paligid ng verified point ng area). Totoong minuto = oras mula sa fix hanggang sa unang fix ng parehong trip na nasa loob ng bilog.')),
          _Fact(
              Icons.filter_alt_rounded,
              _t('What counts as a sample', 'Ano ang binibilang na sample'),
              _t('A collecting truck that was moving (3 km/h or more in the last 90 seconds), fix accuracy 50 m or better, up to 5 km and 30 minutes before the arrival, one sample every 2 minutes. Simulated trips are left out.',
                  'Truck na nangongolekta at gumagalaw (3 km/h o higit sa huling 90 segundo), accuracy ng fix na 50 m o mas maganda, hanggang 5 km at 30 minuto bago dumating, isang sample bawat 2 minuto. Hindi kasama ang mga simulation.')),
          _Fact(
              Icons.event_rounded,
              _t('Right now', 'Ngayon'),
              _t('$n samples from ${regression.trips} trips, ${_F.stamp(all.first.fixMs)} to ${_F.stamp(all.last.fixMs)} (Manila time).',
                  '$n sample mula sa ${regression.trips} trip, ${_F.stamp(all.first.fixMs)} hanggang ${_F.stamp(all.last.fixMs)} (oras sa Maynila).')),
          const SizedBox(height: 6),
          _SubTitle(_t('A few of the $n samples', 'Ilan sa $n sample')),
          const SizedBox(height: 6),
          _Grid(
            <String>[
              _t('Fix time', 'Oras ng fix'),
              _t('Area', 'Area'),
              _t('Trip', 'Trip'),
              _t('Distance (km)', 'Layo (km)'),
              _t('Speed (km/h)', 'Bilis (km/h)'),
              _t('Actual (min)', 'Totoo (min)'),
            ],
            <List<String>>[
              for (final ArrivalSample s in pick)
                <String>[_F.stamp(s.fixMs), s.area, _F.tail(s.tripId), _F.n(s.distanceKm), s.speedKmh == null ? '—' : _F.n(s.speedKmh!, 1), _F.n(s.actualMin, 1)],
            ],
            color: c,
          ),
        ],
      ),
      _Step(
        n: 2,
        color: c,
        open: true,
        title: _t('Where $a and $b come from', 'Saan galing ang $a at $b'),
        summary: _t('minutes = $a + $b × distance (km)', 'minuto = $a + $b × layo (km)'),
        children: <Widget>[
          _Method(_t(
            'The line is the straight line that passes closest to all the samples (least squares). First the averages and sums of the samples:',
            'Ang linya ay ang tuwid na linyang pinakamalapit sa lahat ng sample (least squares). Una, ang mga average at kabuuan ng mga sample:',
          )),
          const SizedBox(height: 8),
          _CalcRows(<(String, String)>[
            (_t('Number of samples', 'Bilang ng sample'), '$n'),
            (_t('Average distance', 'Average na layo'), '${_F.n(mx, 3)} km'),
            (_t('Average actual minutes', 'Average na totoong minuto'), '${_F.n(my)} min'),
            (
              _t('Spread of the distances: sum of (distance − average distance)²', 'Lawak ng mga layo: kabuuan ng (layo − average na layo)²'),
              _F.n(sxx)
            ),
            (
              _t('Distance and minutes moving together: sum of (distance − average distance) × (minutes − average minutes)',
                  'Layo at minuto na sabay gumagalaw: kabuuan ng (layo − average na layo) × (minuto − average na minuto)'),
              _F.n(sxy)
            ),
          ]),
          const SizedBox(height: 10),
          _Eq(
              title: 'Slope',
              general: _t('slope = moving together ÷ spread of the distances', 'slope = sabay na paggalaw ÷ lawak ng mga layo'),
              numbers: '${_F.n(sxy)} ÷ ${_F.n(sxx)}',
              result: _t('$b min per km', '$b min kada km'),
              color: c),
          const SizedBox(height: 8),
          _Eq(
              title: 'Intercept',
              general: _t('intercept = average minutes − slope × average distance', 'intercept = average na minuto − slope × average na layo'),
              numbers: '${_F.n(my)} − $b × ${_F.n(mx, 3)}',
              result: '$a min',
              color: c),
          const SizedBox(height: 10),
          _Banner(_t('minutes = $a + $b × distance (km)', 'minuto = $a + $b × layo (km)'), c),
          const SizedBox(height: 8),
          _Method(_t(
            'Slope $b: each extra kilometre adds about ${_F.n(fit.slope, 1)} minutes. Intercept $a: the time a collecting truck loses on the way (stops, streets served, detours) even when it is close. '
                'The line changes as trips are recorded. Figures are rounded for display.',
            'Slope $b: bawat dagdag na kilometro ay nagdadagdag ng mga ${_F.n(fit.slope, 1)} minuto. Intercept $a: ang oras na nawawala sa nangongolektang truck sa daan (paghinto, mga kalyeng dinadaanan, paglihis) kahit malapit na ito. '
                'Nagbabago ang linya habang may naitatalang trip. Ni-round ang mga numero para sa display.',
          )),
        ],
      ),
      _Step(
        n: 3,
        color: c,
        title: _t('Example with a real sample', 'Halimbawa gamit ang totoong sample'),
        summary: _t('${ex.area} · model ${_F.n(exModel, 1)} min · actual ${_F.n(ex.actualMin, 1)} min',
            '${ex.area} · model ${_F.n(exModel, 1)} min · totoo ${_F.n(ex.actualMin, 1)} min'),
        children: <Widget>[
          _CalcRows(<(String, String)>[
            (_t('Area', 'Area'), ex.area),
            (_t('Fix time', 'Oras ng fix'), _F.stamp(ex.fixMs)),
            (_t('Trip', 'Trip'), _F.tail(ex.tripId)),
            (_t('Distance to the area', 'Layo sa area'), '${_F.n(ex.distanceKm)} km'),
            if (ex.speedKmh != null) (_t('Truck speed', 'Bilis ng truck'), '${_F.n(ex.speedKmh!, 1)} km/h'),
          ]),
          const SizedBox(height: 10),
          _Eq(
              title: 'Model',
              general: _t('minutes = intercept + slope × distance', 'minuto = intercept + slope × layo'),
              numbers: '$a + $b × ${_F.n(ex.distanceKm)}',
              result: '${_F.n(exModel, 1)} min',
              color: c),
          if (exLive != null) ...<Widget>[
            const SizedBox(height: 8),
            _Eq(
                title: 'Live rule',
                general: _t('Time = Distance ÷ Speed × 60', 'Oras = Layo ÷ Bilis × 60'),
                numbers: '${_F.n(ex.distanceKm)} ÷ ${_F.n(ex.speedKmh!, 1)} × 60',
                result: '${_F.n(exLive, 1)} min',
                color: const Color(0xFF0EA5E9)),
          ],
          const SizedBox(height: 10),
          _MetricRow(<(String, String)>[
            (_t('Model said', 'Sabi ng model'), '${_F.n(exModel, 1)} min'),
            if (exLive != null) (_t('Live rule said', 'Sabi ng live rule'), '${_F.n(exLive, 1)} min'),
            (_t('Really took', 'Totoong inabot'), '${_F.n(ex.actualMin, 1)} min'),
          ]),
        ],
      ),
      _Step(
        n: 4,
        color: c,
        title: _t('How MAE, RMSE and R² were measured', 'Paano nasukat ang MAE, RMSE at R²'),
        summary: 'MAE ${_F.minutes(m.mae)} · RMSE ${_F.minutes(m.rmse)} · R² ${_F.r2(m.r2)}',
        children: <Widget>[
          _Method(_t(
            '$method The error is measured only on trips that were not used to fit the line, so it shows how the model does on trips it has not seen.'
                '${regression.trainFit == null ? '' : ' The line used for the test is fitted on the first ${regression.trainTrips} trips only: minutes = ${_F.n(regression.trainFit!.intercept)} + ${_F.n(regression.trainFit!.slope)} × distance, so it differs a little from the line above, which uses all samples.'}',
            '$method Sinusukat lang ang error sa mga trip na hindi ginamit sa paghubog ng linya, kaya ipinapakita nito kung paano ang model sa mga trip na hindi pa nito nakita.'
                '${regression.trainFit == null ? '' : ' Ang linyang ginamit sa test ay hinubog sa unang ${regression.trainTrips} trip lang: minuto = ${_F.n(regression.trainFit!.intercept)} + ${_F.n(regression.trainFit!.slope)} × layo, kaya bahagyang naiiba ito sa linya sa itaas na gumagamit ng lahat ng sample.'}',
          )),
          if (tn > 0) ...<Widget>[
            const SizedBox(height: 10),
            _SubTitle(_t(
              '${tn > testShown ? 'First $testShown of the $tn test samples' : 'The $tn test samples'} (error = actual − predicted)',
              '${tn > testShown ? 'Unang $testShown sa $tn test sample' : 'Ang $tn test sample'} (error = totoo − hula)',
            )),
            const SizedBox(height: 6),
            _Grid(
              <String>[
                _t('Area', 'Area'),
                _t('Distance (km)', 'Layo (km)'),
                _t('Predicted (min)', 'Hula (min)'),
                _t('Actual (min)', 'Totoo (min)'),
                _t('Error (min)', 'Error (min)'),
              ],
              <List<String>>[
                for (int i = 0; i < testShown; i++)
                  <String>[
                    i < tested.length ? tested[i].area : '—',
                    i < tested.length ? _F.n(tested[i].distanceKm) : '—',
                    _F.n(pred[i], 1),
                    _F.n(act[i], 1),
                    _F.signed(act[i] - pred[i]),
                  ],
              ],
              color: c,
            ),
            const SizedBox(height: 10),
            _Eq(
                title: 'MAE',
                general: _t('MAE = sum of |actual − predicted| ÷ number of test samples', 'MAE = kabuuan ng |totoo − hula| ÷ bilang ng test sample'),
                numbers: '${_F.n(sumAbs, 1)} ÷ $tn',
                result: _F.minutes(m.mae),
                color: c),
            const SizedBox(height: 8),
            _Eq(
                title: 'RMSE',
                general: _t('RMSE = square root of (sum of (actual − predicted)² ÷ number of test samples)',
                    'RMSE = square root ng (kabuuan ng (totoo − hula)² ÷ bilang ng test sample)'),
                numbers: '√( ${_F.n(ssRes, 1)} ÷ $tn )',
                result: _F.minutes(m.rmse),
                color: c),
            const SizedBox(height: 8),
            _CalcRows(<(String, String)>[
              (
                _t('Total squared error (SSres): sum of (actual − predicted)²', 'Kabuuang squared error (SSres): kabuuan ng (totoo − hula)²'),
                _F.n(ssRes, 1)
              ),
              (
                _t('Total variation (SStot): sum of (actual − average actual)²', 'Kabuuang pagkakaiba sa average (SStot): kabuuan ng (totoo − average na totoo)²'),
                _F.n(ssTot, 1)
              ),
              (_t('Average actual', 'Average na totoo'), '${_F.n(meanAct, 1)} min'),
            ]),
            const SizedBox(height: 8),
            _Eq(
                title: 'R²',
                general: _t('R² = 1 − total squared error ÷ total variation', 'R² = 1 − kabuuang squared error ÷ kabuuang pagkakaiba'),
                numbers: '1 − ${_F.n(ssRes, 1)} ÷ ${_F.n(ssTot, 1)}',
                result: _F.r2(m.r2),
                color: c),
            const SizedBox(height: 8),
            _Insight(
              m.r2 == null
                  ? _t('R² needs at least two test samples that are not all the same.', 'Kailangan ng R² ng hindi bababa sa dalawang test sample na hindi pare-pareho.')
                  : (m.r2! >= 0
                      ? _t(
                          'R² ${_F.r2(m.r2)} means the distance explains ${(m.r2! * 100).round()} percent of the differences between the real arrival times; the rest is what distance cannot see (stops, route, traffic).',
                          'Ang R² ${_F.r2(m.r2)} ay nangangahulugang ang layo ay nagpapaliwanag ng ${(m.r2! * 100).round()} porsiyento ng pagkakaiba ng mga totoong oras ng dating; ang natitira ay hindi nakikita ng layo (paghinto, ruta, trapiko).')
                      : _t(
                          'R² ${_F.r2(m.r2)} is below 0: on these test trips the line is worse than always predicting the average arrival time (${_F.n(meanAct, 1)} min).',
                          'Ang R² ${_F.r2(m.r2)} ay mas mababa sa 0: sa mga test trip na ito, mas masama ang linya kaysa basta hulaan ang average na oras ng dating (${_F.n(meanAct, 1)} min).')),
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
      return <Widget>[
        _Method(_t('The selected period is shorter than $w days, so there is no load figure to work out yet.',
            'Mas maikli sa $w araw ang piniling panahon, kaya wala pang numero ng load na maikukuwenta.')),
      ];
    }
    final List<int> last = <int>[for (int i = s.length - w; i < s.length; i++) i];
    final double sum = last.fold<double>(0, (double acc, int i) => acc + s[i]);

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
      _Step(
        n: 1,
        color: c,
        title: _t('Where the data comes from', 'Saan galing ang data'),
        summary: _t('Load History · 5,000 kg per FULL trip', 'Load History · 5,000 kg bawat FULL na trip'),
        children: <Widget>[
          _Fact(Icons.local_shipping_rounded, _t('Source', 'Pinagmulan'),
              _t('Each load is a trip that was finalized FULL.', 'Ang bawat load ay isang trip na natapos bilang FULL.')),
          _Fact(
              Icons.travel_explore_rounded,
              _t('Check it in the system', 'Paano i-check sa system'),
              _t('Analytics > Waste Collection Summary > View Load History lists every trip under its date. It is the same list the Waste Collection Summary card counts.',
                  'Ang Analytics > Waste Collection Summary > View Load History ay naglilista ng bawat trip sa ilalim ng petsa nito. Ito rin ang listahang binibilang ng Waste Collection Summary card.')),
          _Fact(
              Icons.scale_rounded,
              _t('Weight', 'Timbang'),
              _t('Every FULL counts as 5,000 kg unless an admin entered a measured weight, because there is no weighing scale yet. So the daily load is mostly the number of FULL trips of the day × 5,000 kg.',
                  'Ang bawat FULL ay binibilang na 5,000 kg maliban kung may sinukat na timbang na inilagay ng admin, dahil wala pang timbangan. Kaya ang daily load ay halos bilang ng FULL na trip sa araw × 5,000 kg.')),
          _Fact(
              Icons.event_rounded,
              _t('Days', 'Mga araw'),
              _t('A day with no FULL is 0 kg. Days are Asia/Manila calendar days.',
                  'Ang araw na walang FULL ay 0 kg. Ang mga araw ay ayon sa kalendaryo ng Asia/Manila.')),
        ],
      ),
      _Step(
        n: 2,
        color: c,
        open: true,
        title: _t('The next-day forecast', 'Ang forecast para bukas'),
        summary: _t('last $w days ÷ $w = ${_F.kg(forecast.nextForecast)}', 'huling $w araw ÷ $w = ${_F.kg(forecast.nextForecast)}'),
        children: <Widget>[
          _SubTitle(_t('The last $w days', 'Ang huling $w araw')),
          const SizedBox(height: 6),
          _Chips(<(String, String)>[for (final int i in last) (_F.day(forecast.days[i]), '${_F.kgn(s[i])} kg')], c),
          const SizedBox(height: 10),
          _Eq(
              title: 'Forecast',
              general: _t('Forecast = (sum of the last $w days) ÷ $w', 'Forecast = (kabuuan ng huling $w araw) ÷ $w'),
              numbers: '(${last.map((int i) => _F.kgn(s[i])).join(' + ')}) ÷ $w',
              result: _F.kg(forecast.nextForecast),
              color: c),
          const SizedBox(height: 6),
          _Method(_t(
            'The sum of the $w days is ${_F.kgn(sum)} kg, so ${_F.kgn(sum)} ÷ $w = ${_F.kg(forecast.nextForecast)}.',
            'Ang kabuuan ng $w araw ay ${_F.kgn(sum)} kg, kaya ${_F.kgn(sum)} ÷ $w = ${_F.kg(forecast.nextForecast)}.',
          )),
        ],
      ),
      _Step(
        n: 3,
        color: c,
        title: _t('How it was checked against what really happened', 'Paano ito sinuri laban sa totoong nangyari'),
        summary: 'MAE ${_F.kg(m.mae)} · RMSE ${_F.kg(m.rmse)} · R² ${_F.r2(m.r2)}',
        children: <Widget>[
          _Method(_t(
            'Every day from day ${w + 1} on was forecast from the $w days before it and then compared with the real load of that day ($bn checked days).',
            'Bawat araw mula sa araw na ${w + 1} ay hinulaan mula sa $w araw bago nito, at inihambing sa totoong load ng araw na iyon ($bn araw na sinuri).',
          )),
          if (bn > 0) ...<Widget>[
            const SizedBox(height: 10),
            _SubTitle(_t('The latest $shown checked days (error = actual − forecast)', 'Ang pinakabagong $shown araw na sinuri (error = totoo − forecast)')),
            const SizedBox(height: 6),
            _Grid(
              <String>[
                _t('Day', 'Araw'),
                _t('Previous $w days (kg)', 'Nakaraang $w araw (kg)'),
                _t('Forecast (kg)', 'Forecast (kg)'),
                _t('Actual (kg)', 'Totoo (kg)'),
                _t('Error (kg)', 'Error (kg)'),
              ],
              <List<String>>[
                for (int i = bn - shown; i < bn; i++)
                  <String>[
                    _F.day(forecast.days[w + i]),
                    _F.kgn(forecast.backtestForecast[i] * w),
                    _F.kgn(forecast.backtestForecast[i]),
                    _F.kgn(forecast.backtestActual[i]),
                    _F.signedKg(forecast.backtestActual[i] - forecast.backtestForecast[i]),
                  ],
              ],
              color: c,
            ),
            const SizedBox(height: 10),
            _Eq(
                title: 'MAE',
                general: _t('MAE = sum of |actual − forecast| ÷ number of checked days', 'MAE = kabuuan ng |totoo − forecast| ÷ bilang ng araw na sinuri'),
                numbers: '${_F.kgn(sumAbs)} ÷ $bn',
                result: _F.kg(m.mae),
                color: c),
            const SizedBox(height: 8),
            _Eq(
                title: 'RMSE',
                general: _t('RMSE = square root of (sum of (actual − forecast)² ÷ number of checked days)',
                    'RMSE = square root ng (kabuuan ng (totoo − forecast)² ÷ bilang ng araw na sinuri)'),
                numbers: '√( ${_F.million(ssRes, _tl)} ÷ $bn )',
                result: _F.kg(m.rmse),
                color: c),
            const SizedBox(height: 8),
            _CalcRows(<(String, String)>[
              (
                _t('Total squared error (SSres): sum of (actual − forecast)²', 'Kabuuang squared error (SSres): kabuuan ng (totoo − forecast)²'),
                _F.million(ssRes, _tl)
              ),
              (
                _t('Total variation (SStot): sum of (actual − average actual)²', 'Kabuuang pagkakaiba sa average (SStot): kabuuan ng (totoo − average na totoo)²'),
                _F.million(ssTot, _tl)
              ),
              (_t('Average actual', 'Average na totoo'), '${_F.kgn(meanAct)} kg'),
            ]),
            const SizedBox(height: 8),
            _Eq(
                title: 'R²',
                general: _t('R² = 1 − total squared error ÷ total variation', 'R² = 1 − kabuuang squared error ÷ kabuuang pagkakaiba'),
                numbers: '1 − ${_F.n(ssRes / 1e6, 1)} ÷ ${_F.n(ssTot / 1e6, 1)}',
                result: _F.r2(m.r2),
                color: c),
            const SizedBox(height: 8),
            _Insight(
              m.r2 == null
                  ? _t('R² needs at least two checked days that are not all the same.', 'Kailangan ng R² ng hindi bababa sa dalawang araw na sinuri na hindi pare-pareho.')
                  : (m.r2! >= 0
                      ? _t('R² ${_F.r2(m.r2)}: the forecast explains ${(m.r2! * 100).round()} percent of the day-to-day differences.',
                          'R² ${_F.r2(m.r2)}: ipinapaliwanag ng forecast ang ${(m.r2! * 100).round()} porsiyento ng pagkakaiba kada araw.')
                      : _t(
                          'R² ${_F.r2(m.r2)} is below 0: always forecasting the average day (${_F.kgn(meanAct)} kg) would have been closer, because collection days alternate between 0 and many loads and an average of the past week cannot follow that.',
                          'Ang R² ${_F.r2(m.r2)} ay mas mababa sa 0: mas malapit sana kung ang average na araw (${_F.kgn(meanAct)} kg) ang palaging hinulaan, dahil paiba-iba ang mga araw ng koleksyon sa pagitan ng 0 at maraming load, at hindi iyon masusundan ng average ng nakaraang linggo.')),
            ),
          ],
        ],
      ),
    ];
  }
}

/// English / Tagalog switch of the working.
class _LangToggle extends StatelessWidget {
  const _LangToggle({required this.tl, required this.onChanged});
  final bool tl;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget chip(String label, bool selected, bool value) => ChoiceChip(
          label: Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: selected ? Colors.white : PredictiveModelsDetails.ink)),
          selected: selected,
          showCheckmark: false,
          selectedColor: PredictiveModelsDetails.violet,
          backgroundColor: Colors.white,
          side: const BorderSide(color: Color(0xFFE2E8F0)),
          visualDensity: VisualDensity.compact,
          onSelected: (_) => onChanged(value),
        );
    return Row(children: <Widget>[
      const Icon(Icons.translate_rounded, size: 18, color: PredictiveModelsDetails.muted),
      const SizedBox(width: 8),
      Expanded(
        child: Text(tl ? 'Wika ng kuwenta' : 'Language of the working',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: PredictiveModelsDetails.muted)),
      ),
      chip('English', !tl, false),
      const SizedBox(width: 6),
      chip('Tagalog', tl, true),
    ]);
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
