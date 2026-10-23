import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/widgets/period_selector.dart';

void main() {
  final DateTime now = DateTime(2026, 10, 23, 15, 30);

  test('every preset covers whole days, today included', () {
    final ReportPeriod t = ReportPeriod.today(now);
    expect(t.range.start, DateTime(2026, 10, 23));
    expect(t.range.end, DateTime(2026, 10, 23, 23, 59, 59, 999));
    expect(t.days, 1);
    expect(t.label, 'Today');
    final ReportPeriod w = ReportPeriod.lastDays(7, now);
    expect(w.startDay, DateTime(2026, 10, 17));
    expect(w.days, 7);
    expect(w.label, 'Last 7 days');
    expect(ReportPeriod.lastDays(30, now).days, 30);
  });

  test('custom ranges are labelled with their dates and stay put after midnight', () {
    final ReportPeriod c = ReportPeriod.custom(DateTimeRange(start: DateTime(2026, 10, 3, 9), end: DateTime(2026, 10, 9, 8)));
    expect(c.label, 'Oct 3 – Oct 9, 2026');
    expect(c.refreshed(DateTime(2026, 10, 30)).range, c.range);
    expect(ReportPeriod.custom(DateTimeRange(start: DateTime(2026, 10, 3), end: DateTime(2026, 10, 3))).label, 'Oct 3, 2026');
    expect(ReportPeriod.today(now).refreshed(DateTime(2026, 10, 24, 1)).startDay, DateTime(2026, 10, 24));
  });

  testWidgets('tapping a preset reports it', (WidgetTester t) async {
    ReportPeriod? got;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: PeriodSelector(value: ReportPeriod.today(), onChanged: (ReportPeriod p) => got = p))),
    ));
    await t.tap(find.text('7 days'));
    expect(got?.preset, PeriodPreset.last7);
    await t.tap(find.text('30 days'));
    expect(got?.preset, PeriodPreset.last30);
    expect(find.text('Custom'), findsOneWidget);
  });
}
