import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/predictive_models.dart';
import 'package:garbage_tracking_app/widgets/predictive_models_details.dart';

void main() {
  final reg = ArrivalRegressionReport(
    samples: 68,
    trips: 12,
    fit: const LinearFit(6.18, 1.99),
    method: 'Fitted on the earliest 8 of 12 trips and tested on the other 4.',
    regression: ErrorMetrics.of(<double>[5, 9, 3, 12], <double>[6, 8, 7, 10]),
    baseline: ErrorMetrics.of(<double>[5, 9, 3, 12], <double>[4, 11, 2, 15]),
    testActual: <double>[5, 9, 3, 12],
    testPredicted: <double>[6, 8, 7, 10],
  );
  final days = List<DateTime>.generate(12, (i) => DateTime.utc(2026, 10, i + 1));
  final ma = MovingAverageForecast.evaluate(days, <double>[0, 5000, 0, 10000, 5000, 0, 0, 5000, 5000, 0, 10000, 5000]);

  for (final Size size in <Size>[const Size(1400, 1000), const Size(400, 900)]) {
    testWidgets('details render without layout errors at ${size.width.toInt()} px and adapt their sentences to the data', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: PredictiveModelsDetails(regression: reg, forecast: ma, live: ErrorMetrics.of(<double>[30], <double>[5])))));
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.textContaining('minutes = 6.18 + 1.99'), findsOneWidget);
      expect(find.textContaining('On 4 test trip(s)'), findsOneWidget);
      expect(find.textContaining('Early data'), findsWidgets); // n below 20
    });
  }
}
