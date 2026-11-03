import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/prediction_engine.dart';

/// The report forecast used to multiply by 1.2 on every Saturday and Sunday and on 13 hard-coded dates, with no source
/// (it also changed the "next 7 days" total depending on the weekday the report was exported on). The reports now pass a
/// neutral multiplier and say so; the legacy behaviour of HolidayTracker is untouched for anything that does not pass one.
void main() {
  final DateTime saturday = DateTime(2026, 11, 7); // a Saturday
  final DateTime tuesday = DateTime(2026, 11, 3);

  test('legacy default is pinned: a Saturday is still x1.2 when no multiplier is given', () {
    expect(PredictionEngine.predictWasteVolume('Any', date: saturday, historicalAvgKg: 1000), closeTo(1200, 1e-9));
    expect(PredictionEngine.predictWasteVolume('Any', date: tuesday, historicalAvgKg: 1000), closeTo(1000, 1e-9));
  });

  test('a neutral multiplier gives the recorded average on any day', () {
    for (final DateTime d in <DateTime>[saturday, tuesday]) {
      expect(PredictionEngine.predictWasteVolume('Any', date: d, historicalAvgKg: 1000, multiplier: 1.0), closeTo(1000, 1e-9));
    }
  });

  test('the weekly projection with a neutral multiplier is 7 x the average, whatever day it is exported', () {
    expect(PredictionEngine.predictWeeklyVolume('Any', historicalAvgKg: 1000, multiplier: 1.0), closeTo(7000, 1e-9));
  });

  test('the Analytics reports pass the neutral multiplier and the exports state it', () {
    final String a = File('lib/screens/analytics_screen.dart').readAsStringSync();
    expect(RegExp(r'predictWasteVolume\(topArea[^;]*multiplier: 1\.0').hasMatch(a), isTrue);
    expect(RegExp(r'predictWeeklyVolume\(topArea[^;]*multiplier: 1\.0').hasMatch(a), isTrue);
    expect(File('lib/services/analytics_pdf_builder.dart').readAsStringSync().contains('No holiday or weekend adjustment is applied'), isTrue);
    expect(File('lib/services/analytics_xlsx_builder.dart').readAsStringSync().contains('no holiday or weekend adjustment applied'), isTrue);
  });
}
