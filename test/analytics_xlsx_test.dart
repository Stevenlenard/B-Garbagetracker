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
          ReportLoadRow(
              tripId: 'GT-001_2026-07-22', driver: 'Driver', truck: 'GT-001', fullAtManila: DateTime.utc(2026, 10, 22, 11, 47), kg: 5000, measured: false, status: 'FULL', timeRecorded: false),
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

  Archive open(List<int> bytes) => ZipDecoder().decodeBytes(bytes);
  String part(Archive zip, String name) => utf8.decode(zip.findFile(name)!.content as List<int>);
  List<String> sheetNames(Archive zip) =>
      RegExp(r'<sheet name="([^"]+)"').allMatches(part(zip, 'xl/workbook.xml')).map((Match m) => m[1]!.replaceAll('&amp;', '&')).toList();

  test('each category exports its own sheets, and the file name says what it is', () {
    final AnalyticsReportData d = _sample();
    expect(sheetNames(open(AnalyticsXlsxBuilder.build(d, ReportCategory.fullSystem))),
        <String>['Overview', 'Fleet', 'Collection Trips', 'Trucks & Drivers', 'Purok Coverage', 'Complaints', 'ETA Accuracy', 'About']);
    expect(sheetNames(open(AnalyticsXlsxBuilder.build(d, ReportCategory.truckPerformance))),
        <String>['Overview', 'Fleet', 'Collection Trips', 'Trucks & Drivers', 'ETA Accuracy', 'About']);
    expect(sheetNames(open(AnalyticsXlsxBuilder.build(d, ReportCategory.areaCoverage))),
        <String>['Overview', 'Purok Coverage', 'Complaints', 'ETA Accuracy', 'About']);
    expect(AnalyticsXlsxBuilder.fileName(d, ReportCategory.areaCoverage), 'Area_Coverage_All_Areas_2026-09-22_to_2026-10-22.xlsx');
    expect(ReportCategoryLabel.parse('Truck Performance'), ReportCategory.truckPerformance);
    expect(ReportCategoryLabel.parse('Area Coverage'), ReportCategory.areaCoverage);
    expect(ReportCategoryLabel.parse('Full System Report'), ReportCategory.fullSystem);
  });

  test('the full workbook is a valid .xlsx with the dashboard figures, formulas and real dates', () {
    final AnalyticsReportData d = _sample();
    final List<int> bytes = AnalyticsXlsxBuilder.build(d, ReportCategory.fullSystem);
    expect(bytes.sublist(0, 2), <int>[0x50, 0x4B]); // a zip ("PK")
    final Archive zip = open(bytes);
    for (final String p in <String>['[Content_Types].xml', '_rels/.rels', 'xl/workbook.xml', 'xl/_rels/workbook.xml.rels', 'xl/styles.xml', 'docProps/core.xml']) {
      expect(zip.findFile(p), isNotNull, reason: p);
    }
    final String overview = part(zip, 'xl/worksheets/sheet1.xml');
    expect(overview, contains('FULL SYSTEM REPORT')); // banner names the report
    expect(overview, contains('All Areas  ·  Sep 22, 2026 to Oct 22, 2026'));
    expect(overview, contains('Oct 22, 2026 11:47 AM (Asia/Manila)')); // Manila time, not UTC
    expect(overview, contains('2 of 3')); // areas with a verified visit, as on the dashboard
    expect(overview, contains('The forecast is unavailable')); // never reported as 0 kg
    expect(overview, contains('location="\'Fleet\'!A1"')); // contents link to the sheets

    final String trips = part(zip, 'xl/worksheets/sheet3.xml');
    expect(trips, contains('Not recorded')); // empty driver name / untimed legacy trip
    expect(trips, contains('carry no time at all')); // explained, not shown with the download time
    expect(part(zip, 'xl/worksheets/sheet4.xml'), contains('Time not recorded'));
    expect(trips, contains('<f>SUM(F')); // total kg is a formula
    expect(trips, contains('<autoFilter ref="A')); // filter buttons
    expect(trips, contains('state="frozen"')); // header stays visible
    // the FULL time is a real Excel date: 2026-10-21 08:05 = 46316.336805...
    expect(RegExp(r'<v>46316\.33680').hasMatch(trips), isTrue);

    final String coverage = part(zip, 'xl/worksheets/sheet5.xml');
    expect(coverage, contains('Brixton Homes &amp; &lt;Annex&gt;')); // escaped
    expect(coverage, contains('COUNTIF(B'));
    expect(part(zip, 'xl/worksheets/sheet7.xml'), contains('ETA data is unavailable'));
    expect(part(zip, 'xl/styles.xml'), contains('FF00796B')); // app teal

    for (int i = 1; i <= 8; i++) {
      final String x = part(zip, 'xl/worksheets/sheet$i.xml');
      expect(RegExp('<row ').allMatches(x).length, RegExp('</row>').allMatches(x).length);
    }

    // Kept for opening in a real spreadsheet application during manual checks.
    final Directory out = Directory('build/test_output')..createSync(recursive: true);
    for (final ReportCategory c in ReportCategory.values) {
      File('${out.path}/${AnalyticsXlsxBuilder.fileName(d, c)}').writeAsBytesSync(AnalyticsXlsxBuilder.build(d, c));
    }
  });
}
