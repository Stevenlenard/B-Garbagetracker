import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/analytics_xlsx_builder.dart';
import 'package:garbage_tracking_app/utils/analytics_report_data.dart';
import 'package:garbage_tracking_app/utils/xlsx_writer.dart';

AnalyticsReportData _sample() => AnalyticsReportData(
      meta: ReportMeta(
        start: DateTime(2026, 9, 22),
        end: DateTime(2026, 10, 22),
        area: 'All Areas',
        generatedAtManila: DateTime.utc(2026, 10, 22, 11, 47),
      ),
      fleet: const ReportFleet.available(<String, int>{'Active': 1, 'Paused': 0, 'Full': 0, 'Completed': 0, 'Offline': 2}),
      waste: ReportWaste.available(
        rows: <ReportLoadRow>[
          ReportLoadRow(
              tripId: 'trip_1', driver: 'Steve Espaldon', truck: 'GT-001', fullAtManila: DateTime.utc(2026, 10, 21, 8, 5), kg: 5000, measured: false, status: 'COMPLETED'),
          ReportLoadRow(
              tripId: 'trip_2', driver: '', truck: 'GT-002', fullAtManila: DateTime.utc(2026, 10, 20, 9, 30), kg: 4200, measured: true, status: 'FULL'),
        ],
        partial: false,
        ongoingUnfinished: 0,
        staleUnfinished: 1,
      ),
      coverage: const ReportCoverage.available(
        rows: <ReportCoverageRow>[
          ReportCoverageRow(area: 'Central (Purok 1)', visits: 7),
          ReportCoverageRow(area: 'Purok 2', visits: 0, unconfirmed: 1),
          ReportCoverageRow(area: 'Brixton Homes & <Annex>', visits: 1),
        ],
        areasVisited: 2,
        expectedAreas: 3,
        tripsWithoutEvidence: 4,
      ),
      eta: const ReportEta.unavailable('ETA notifications have not loaded'),
      complaints: const ReportComplaints.available(
        counts: <String, int>{'Pending': 3, 'In Progress': 0, 'Resolved': 1},
        byArea: <String, int>{'Central (Purok 1)': 2, 'Purok 2': 1},
      ),
      forecast: const ReportForecast.unavailable('no recorded collection weights exist to base a forecast on'),
    );

void main() {
  test('column names', () {
    expect(XlsxWorkbook.colName(0), 'A');
    expect(XlsxWorkbook.colName(25), 'Z');
    expect(XlsxWorkbook.colName(26), 'AA');
  });

  test('the analytics workbook is a valid .xlsx package with the dashboard figures', () {
    final AnalyticsReportData d = _sample();
    final List<int> bytes = AnalyticsXlsxBuilder.build(d);
    expect(bytes.sublist(0, 2), <int>[0x50, 0x4B]); // a zip ("PK")

    final Archive zip = ZipDecoder().decodeBytes(bytes);
    String part(String name) => utf8.decode(zip.findFile(name)!.content as List<int>);
    for (final String p in <String>['[Content_Types].xml', '_rels/.rels', 'xl/workbook.xml', 'xl/_rels/workbook.xml.rels', 'xl/styles.xml']) {
      expect(zip.findFile(p), isNotNull, reason: p);
    }
    expect(part('xl/workbook.xml'), contains('name="Purok Coverage"'));
    expect(RegExp('<sheet ').allMatches(part('xl/workbook.xml')).length, 5);

    final String summary = part('xl/worksheets/sheet1.xml');
    expect(summary, contains('Sep 22, 2026 to Oct 22, 2026'));
    expect(summary, contains('Oct 22, 2026 11:47 AM (Asia/Manila)')); // Manila time, not UTC
    expect(summary, contains('2 of 3')); // areas with a verified visit, as on the dashboard
    expect(summary, contains('The forecast is unavailable')); // never reported as 0 kg

    final String coverage = part('xl/worksheets/sheet2.xml');
    expect(coverage, contains('Brixton Homes &amp; &lt;Annex&gt;')); // escaped
    expect(coverage, contains('<v>7</v>')); // numbers are numeric cells

    final String trips = part('xl/worksheets/sheet3.xml');
    expect(trips, contains('Not recorded')); // empty driver name
    expect(trips, contains('<v>9200</v>')); // total kg

    expect(part('xl/worksheets/sheet4.xml'), contains('ETA data is unavailable'));
    expect(part('xl/worksheets/sheet5.xml'), contains('Central (Purok 1)'));

    // Every XML part is well formed enough for Excel: the same number of opening and closing rows.
    for (int i = 1; i <= 5; i++) {
      final String x = part('xl/worksheets/sheet$i.xml');
      expect(RegExp('<row ').allMatches(x).length, RegExp('</row>').allMatches(x).length);
    }

    // Kept for opening in a real spreadsheet application during manual checks.
    final Directory out = Directory('build/test_output')..createSync(recursive: true);
    File('${out.path}/${AnalyticsXlsxBuilder.fileName(d)}').writeAsBytesSync(bytes);
  });
}
