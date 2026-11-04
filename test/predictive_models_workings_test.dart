import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/predictive_models.dart';
import 'package:garbage_tracking_app/widgets/predictive_models_details.dart';

/// The "How the figures were computed" section works the recorded data out in front of the reader, so its numbers must be
/// the ones the figures above are made of.
void main() {
  // y = 2 + 3x exactly, so the working must read slope 3.00 and intercept 2.00.
  final int t0 = DateTime.utc(2026, 10, 20, 1).millisecondsSinceEpoch;
  ArrivalSample s(String trip, double d, int minutesAfter) =>
      ArrivalSample(tripId: trip, area: 'Central (Purok 1)', fixMs: t0 + minutesAfter * 60000, distanceKm: d, speedKmh: 20, actualMin: 2 + 3 * d);
  final List<ArrivalSample> all = <ArrivalSample>[
    s('-Trip00A', 1, 0),
    s('-Trip00A', 2, 2),
    s('-Trip00B', 3, 60),
    s('-Trip00B', 4, 62),
    s('-Trip00C', 5, 120),
    s('-Trip00C', 6, 122),
  ];
  final LinearFit fit = LinearFit.fit(all.map((x) => x.distanceKm).toList(), all.map((x) => x.actualMin).toList())!;
  final List<ArrivalSample> tested = all.sublist(4);
  final List<double> act = tested.map((x) => x.actualMin).toList();
  final List<double> pred = tested.map((x) => fit.predict(x.distanceKm) + 1).toList(); // every prediction 1 minute late
  final ArrivalRegressionReport reg = ArrivalRegressionReport(
    samples: all.length,
    trips: 3,
    fit: fit,
    method: 'Fitted on the earliest 2 of 3 trips and tested on the other 1.',
    regression: ErrorMetrics.of(act, pred),
    baseline: ErrorMetrics.of(act, <double>[3, 9]),
    testActual: act,
    testPredicted: pred,
    allSamples: all,
    testSamples: tested,
    trainFit: fit,
    trainTrips: 2,
  );
  final List<DateTime> days = List<DateTime>.generate(10, (i) => DateTime.utc(2026, 10, i + 1));
  final MovingAverageReport ma = MovingAverageForecast.evaluate(days, <double>[0, 5000, 0, 10000, 5000, 0, 0, 5000, 5000, 0]);

  Future<void> open(WidgetTester t, Size size, {ArrivalRegressionReport? report}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: PredictiveModelsDetails(regression: report ?? reg, forecast: ma, live: ErrorMetrics.of(<double>[30], <double>[5])))));
    await t.pump();
  }

  // the steps are dropdowns: their content is built but folded away until opened, so look at it with skipOffstage off
  Finder text(String t) => find.textContaining(t, skipOffstage: false);

  for (final Size size in <Size>[const Size(1400, 1000), const Size(400, 900)]) {
    testWidgets('the working renders at ${size.width.toInt()} px and shows where the slope and intercept come from', (WidgetTester t) async {
      await open(t, size);
      expect(t.takeException(), isNull);
      expect(find.text('How the arrival-time figures were computed'), findsOneWidget);
      expect(find.text('How the collected-load figures were computed'), findsOneWidget);
      expect(find.text('Where 2.00 and 3.00 come from'), findsOneWidget);
      // the data and where to check it
      expect(text('driver_routes / trip / route'), findsOneWidget);
      expect(text('Admin > Route History'), findsOneWidget);
      expect(text('6 samples from 3 trips'), findsWidgets);
      // the least-squares working: n, averages, sums, slope and intercept
      expect(text('3.500 km'), findsOneWidget);
      expect(find.text('52.50 ÷ 17.50'), findsOneWidget);
      expect(find.text('3.00 min per km'), findsOneWidget);
      expect(find.text('12.50 − 3.00 × 3.500'), findsOneWidget);
      expect(find.text('2.00 min', skipOffstage: false), findsWidgets);
      // the live rule and the error measures, on the recorded numbers
      expect(text('Time = Distance ÷ Speed × 60'), findsOneWidget);
      expect(find.text('2.0 ÷ 2', skipOffstage: false), findsOneWidget);
      expect(find.text('1.0 min', skipOffstage: false), findsWidgets);
      expect(text('Total squared error (SSres)'), findsWidgets);
      expect(text('Fitted on the earliest 2 of 3 trips'), findsWidgets);
    });

    testWidgets('the load working adds up the last 7 days and divides by 7 at ${size.width.toInt()} px', (WidgetTester t) async {
      await open(t, size);
      expect(t.takeException(), isNull);
      expect(text('View Load History'), findsOneWidget);
      // last 7 days of [0, 5000, 0, 10000, 5000, 0, 0, 5000, 5000, 0] = 0+10000+5000+0+0+5000+5000 = 25000 over 7 days
      expect(text('÷ 7'), findsWidgets);
      expect(text('The sum of the 7 days is 25,000 kg, so 25,000 ÷ 7 = 3,571 kg.'), findsOneWidget);
      expect(text('MAE = sum of |actual − forecast| ÷ number of checked days'), findsOneWidget);
    });
  }

  testWidgets('a folded step opens when its title is tapped', (WidgetTester t) async {
    await open(t, const Size(1000, 1400));
    expect(find.text('Admin > Route History (past tracking): choose the date, open the trip and replay it. The fixes inside the 100 m circle of the area are the arrival.'), findsNothing);
    await t.ensureVisible(find.text('Where the data comes from').first);
    await t.tap(find.text('Where the data comes from').first);
    await t.pumpAndSettle();
    expect(find.textContaining('Admin > Route History (past tracking)'), findsOneWidget);
  });

  testWidgets('without recorded approaches the working says so instead of showing empty maths', (WidgetTester t) async {
    final ArrivalRegressionReport none = ArrivalRegressionReport(
      samples: 0,
      trips: 0,
      fit: null,
      method: '',
      regression: ErrorMetrics.of(<double>[], <double>[]),
      baseline: ErrorMetrics.of(<double>[], <double>[]),
      testActual: <double>[],
      testPredicted: <double>[],
    );
    await open(t, const Size(1000, 900), report: none);
    expect(t.takeException(), isNull);
    expect(find.textContaining('not enough recorded approaches to a collection area yet to show the working'), findsOneWidget);
  });
}
