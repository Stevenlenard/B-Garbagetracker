import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/analytics_pdf_builder.dart';
import 'package:garbage_tracking_app/utils/analytics_report_data.dart';

// SAMPLE DATA ONLY: generated for layout checks, never written anywhere but the local test dir.
ReportMeta meta({String area = 'All Areas'}) => ReportMeta(
      start: DateTime(2026, 10, 1),
      end: DateTime(2026, 10, 13),
      area: area,
      generatedAtManila: DateTime.utc(2026, 10, 13, 9, 30),
    );

ReportWaste waste(int n, {int measured = 0}) => ReportWaste.available(
      rows: List<ReportLoadRow>.generate(
        n,
        (int i) => ReportLoadRow(
          tripId: 'trip_2026_${1000 + i}_a_very_long_identifier_$i',
          driver: i % 3 == 0 ? 'Juan Dela Cruz Santos' : 'Maria Clara',
          truck: 'GT-00${i % 4}',
          fullAtManila: DateTime.utc(2026, 10, 1 + (i % 13), 8 + (i % 8), 5 * (i % 12)),
          kg: i < measured ? 4200 : 5000,
          measured: i < measured,
          status: 'FULL',
        ),
      ),
      partial: false,
      ongoingUnfinished: 1,
      staleUnfinished: 3,
    );

ReportEta eta(int n) => ReportEta.available(
      rows: List<ReportEtaRow>.generate(
        n,
        (int i) => ReportEtaRow(
          area: 'Central (Purok 1)',
          truck: 'GT-00${i % 3}',
          tripId: 'trip_${2000 + i}_session_identifier',
          sentAt: DateTime.utc(2026, 10, 12, 7, i % 60),
          etaMinutes: 10,
          predictedAt: DateTime.utc(2026, 10, 12, 7, (i + 10) % 60),
          actualAt: i % 4 == 0 ? null : DateTime.utc(2026, 10, 12, 8, i % 60),
          signedErrorMin: i % 4 == 0 ? null : (i % 9) - 3.0,
          status: i % 4 == 0 ? 'Awaiting arrival' : 'Evaluated',
        ),
      ),
      evaluated: n - (n ~/ 4),
      awaiting: n ~/ 4,
      noArrival: 0,
      withdrawn: 0,
      noEstimate: 0,
      avgAbsErrorMin: 2.8,
      within5Pct: 83,
      totalVisits: n,
    );

AnalyticsReportData full({int loads = 120, int etaRows = 80}) => AnalyticsReportData(
      meta: meta(),
      fleet: const ReportFleet.available(
          <String, int>{'Active': 2, 'Paused': 1, 'Full': 1, 'Completed': 1, 'Offline': 3}),
      waste: waste(loads, measured: 5),
      coverage: ReportCoverage.available(
        rows: const <ReportCoverageRow>[
          ReportCoverageRow(area: 'Central (Purok 1)', visits: 12),
          ReportCoverageRow(area: 'Purok 2', visits: 6, unconfirmed: 2),
          ReportCoverageRow(area: 'Purok Paraiso', visits: 0),
        ],
        areasVisited: 2,
        expectedAreas: 3,
        tripsWithoutEvidence: 1,
      ),
      eta: eta(etaRows),
      complaints: const ReportComplaints.available(
        counts: <String, int>{'Pending': 4, 'In Progress': 2, 'Resolved': 9},
        byArea: <String, int>{'Purok 2': 7, 'Central (Purok 1)': 8},
      ),
      forecast: const ReportForecast.available(tomorrowKg: 15000, weeklyKg: 90000, samples: 12),
      aiNarrative: 'Analyzing fleet...',
    );

int pageCount(List<int> bytes) =>
    RegExp(r'/Type\s*/Page(?!s)').allMatches(String.fromCharCodes(bytes)).length;

void main() {
  group('report data', () {
    test('totals, tons and per-date counts come from the same rows', () {
      final ReportWaste w = waste(10, measured: 2);
      expect(w.trips, 10);
      expect(w.totalKg, 2 * 4200 + 8 * 5000);
      expect(w.measuredCount, 2);
      expect(w.estimatedCount, 8);
      expect(w.byDate.values.fold(0, (int a, int b) => a + b), 10);
      expect(w.byDriver.values.fold(0, (int a, int b) => a + b), 10);
    });

    test('hypothetical estimate is labelled in the key indicators', () {
      final AnalyticsReportData d = full(loads: 4);
      final List<String> row =
          d.keyIndicators.firstWhere((List<String> r) => r[0] == 'Estimated waste volume');
      expect(row[2], contains('hypothetical'));
    });

    test('unavailable sources say "Unavailable", never 0', () {
      final AnalyticsReportData d = AnalyticsReportData(
        meta: meta(),
        fleet: const ReportFleet.unavailable('registry not loaded'),
        waste: const ReportWaste.unavailable('collection data could not be loaded'),
        coverage: const ReportCoverage.unavailable('no expected collections'),
        eta: const ReportEta.unavailable('not loaded'),
        complaints: const ReportComplaints.unavailable('not loaded'),
        forecast: const ReportForecast.unavailable('no recorded weights'),
      );
      final String all = d.keyIndicators.map((List<String> r) => r.join(' ')).join('\n');
      expect(all, contains('Unavailable'));
      expect(all, isNot(contains('0 tons')));
      expect(d.conclusion, contains('unavailable'));
    });

    test('AI placeholders are never exported', () {
      expect(AnalyticsReportData.isPlaceholder('Analyzing fleet...'), isTrue);
      expect(AnalyticsReportData.isPlaceholder('Evaluating resident feedback trends...'), isTrue);
      expect(AnalyticsReportData.isPlaceholder('Unable to generate real-time AI insights.'), isTrue);
      expect(AnalyticsReportData.isPlaceholder('Collections were steady this week.'), isFalse);
      expect(full().usableNarrative, isNull);
    });

    test('stale/unfinished and measured basis appear in insights/recommendations', () {
      final AnalyticsReportData d = full(loads: 8);
      expect(d.insights.join(' '), contains('3 unfinished'));
      expect(d.recommendations.join(' '), contains('measured weights'));
    });

    test('ETA indicator uses only evaluated visits', () {
      final AnalyticsReportData d = full();
      final List<String> row = d.keyIndicators.firstWhere((List<String> r) => r[0] == 'ETA accuracy');
      expect(row[1], contains('2.8'));
      expect(row[2], contains('83%'));
    });
  });

  group('PDF layout (sample data)', () {
    test('long tables flow onto several A4 pages without layout errors', () async {
      final List<int> bytes = await AnalyticsPdfBuilder.build(full()).save();
      expect(bytes.length, greaterThan(5000));
      expect(pageCount(bytes), greaterThan(3));
      final Directory out = Directory('build/test_reports')..createSync(recursive: true);
      File('${out.path}/SAMPLE_analytics_report.pdf').writeAsBytesSync(bytes);
    });

    test('empty and unavailable report still renders', () async {
      final AnalyticsReportData d = AnalyticsReportData(
        meta: meta(area: 'Purok 2'),
        fleet: const ReportFleet.available(
            <String, int>{'Active': 0, 'Paused': 0, 'Full': 0, 'Completed': 0, 'Offline': 0}),
        waste: waste(0),
        coverage: const ReportCoverage.unavailable('no expected collections'),
        eta: const ReportEta.unavailable('not loaded'),
        complaints: const ReportComplaints.available(counts: <String, int>{'Pending': 0, 'In Progress': 0, 'Resolved': 0}, byArea: <String, int>{}),
        forecast: const ReportForecast.unavailable('no recorded weights'),
      );
      final List<int> bytes = await AnalyticsPdfBuilder.build(d).save();
      expect(pageCount(bytes), greaterThanOrEqualTo(1));
    });

    test('same data -> same page structure (platform independent)', () async {
      final int a = pageCount(await AnalyticsPdfBuilder.build(full(loads: 40, etaRows: 10)).save());
      final int b = pageCount(await AnalyticsPdfBuilder.build(full(loads: 40, etaRows: 10)).save());
      expect(a, b);
    });
  });
}
