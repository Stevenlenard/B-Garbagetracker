import 'dart:typed_data';

import 'package:intl/intl.dart';

import '../utils/analytics_report_data.dart';
import '../utils/xlsx_writer.dart';

/// Excel version of the analytics report. Like [AnalyticsPdfBuilder] it only formats an
/// [AnalyticsReportData] snapshot, so the spreadsheet shows exactly what the dashboard and the
/// PDF show (unavailable data is written as unavailable, never as 0).
class AnalyticsXlsxBuilder {
  static final DateFormat _day = DateFormat('MMM d, yyyy');
  static final DateFormat _stamp = DateFormat('MMM d, yyyy h:mm a');

  static String fileName(AnalyticsReportData d) =>
      'Analytics_Report_${DateFormat('yyyyMMdd').format(d.meta.start)}_${DateFormat('yyyyMMdd').format(d.meta.end)}.xlsx';

  static Uint8List build(AnalyticsReportData d) {
    final XlsxWorkbook wb = XlsxWorkbook();
    _summary(wb.sheet('Summary', columnWidths: <double>[34, 30, 70]), d);
    _coverage(wb.sheet('Purok Coverage', columnWidths: <double>[34, 18, 26]), d);
    _loads(wb.sheet('Collection Trips', columnWidths: <double>[22, 24, 12, 22, 14, 14, 14]), d);
    _eta(wb.sheet('ETA Accuracy', columnWidths: <double>[24, 12, 20, 20, 12, 20, 20, 14, 22]), d);
    _complaints(wb.sheet('Complaints', columnWidths: <double>[34, 14]), d);
    return wb.build();
  }

  static void _title(XlsxSheet s, String title, AnalyticsReportData d) {
    s.add(<Object?>[title], XlsxStyle.title);
    s.merges.add('A1:C1');
    s.add(<Object?>['Garbage Truck Tracking and Monitoring System - Barangay Balintawak, Lipa City']);
    s.add(<Object?>['Period', '${_day.format(d.meta.start)} to ${_day.format(d.meta.end)}']);
    s.add(<Object?>['Area', d.meta.area]);
    s.add(<Object?>['Generated', '${_stamp.format(d.meta.generatedAtManila)} (Asia/Manila)']);
    s.blank();
  }

  static void _unavailable(XlsxSheet s, String what, String? reason) {
    s.add(<Object?>[XlsxCell('$what is unavailable: ${reason ?? 'the source could not be reached'}.', XlsxStyle.wrap)]);
  }

  static void _summary(XlsxSheet s, AnalyticsReportData d) {
    _title(s, 'Analytics Report', d);
    s.add(<Object?>['Key indicators'], XlsxStyle.subtitle);
    s.add(<Object?>['Indicator', 'Value', 'Basis'], XlsxStyle.header);
    for (final List<String> k in d.keyIndicators) {
      s.add(<Object?>[XlsxCell(k[0], XlsxStyle.bold), k[1], XlsxCell(k[2], XlsxStyle.wrap)]);
    }
    s.blank();
    s.add(<Object?>['Waste forecast'], XlsxStyle.subtitle);
    if (d.forecast.available) {
      s.add(<Object?>['Forecast', 'Value', 'Method'], XlsxStyle.header);
      final String method = 'Projection from ${d.forecast.samples} recorded collection weight(s); not a measurement.';
      s.add(<Object?>['Next collection day volume', '${AnalyticsReportData.tons(d.forecast.tomorrowKg)} tons', XlsxCell(method, XlsxStyle.wrap)]);
      s.add(<Object?>['Weekly volume projection', '${AnalyticsReportData.tons(d.forecast.weeklyKg)} tons', XlsxCell(method, XlsxStyle.wrap)]);
    } else {
      _unavailable(s, 'The forecast', d.forecast.reason);
    }
    s.blank();
    s.add(<Object?>['Insights'], XlsxStyle.subtitle);
    final String? ai = d.usableNarrative;
    if (ai != null) s.add(<Object?>[XlsxCell(ai, XlsxStyle.wrap)]);
    for (final String t in d.insights) {
      s.add(<Object?>[XlsxCell('• $t', XlsxStyle.wrap)]);
    }
    s.blank();
    s.add(<Object?>['Recommendations'], XlsxStyle.subtitle);
    for (final String t in d.recommendations) {
      s.add(<Object?>[XlsxCell('• $t', XlsxStyle.wrap)]);
    }
    // Long text rows read across all three columns.
    for (int r = 0; r < s.rows.length; r++) {
      final List<XlsxCell> row = s.rows[r];
      if (row.length == 1 && row.first.style == XlsxStyle.wrap) s.merges.add('A${r + 1}:C${r + 1}');
    }
  }

  static void _coverage(XlsxSheet s, AnalyticsReportData d) {
    _title(s, 'Purok Coverage (verified collection visits)', d);
    final ReportCoverage c = d.coverage;
    if (!c.available) return _unavailable(s, 'Coverage', c.reason);
    s.add(<Object?>['Area', 'Verified visits', 'Entered, not verified'], XlsxStyle.header);
    for (final ReportCoverageRow r in c.rows) {
      s.add(<Object?>[r.area, r.visits, r.unconfirmed]);
    }
    s.add(<Object?>[XlsxCell('Total', XlsxStyle.bold), XlsxCell(c.totalVisits, XlsxStyle.bold), null]);
    s.blank();
    s.add(<Object?>['Areas with a verified visit', '${c.areasVisited} of ${c.expectedAreas}']);
    if (c.tripsWithoutEvidence > 0) {
      s.add(<Object?>['Trips without usable GPS points', c.tripsWithoutEvidence]);
    }
    s.add(<Object?>[
      XlsxCell('A verified visit is one trip with enough accurate GPS fixes inside the area while collecting, '
          'counted once per trip and area.', XlsxStyle.wrap)
    ]);
    s.merges.add('A${s.rows.length}:C${s.rows.length}');
  }

  static void _loads(XlsxSheet s, AnalyticsReportData d) {
    _title(s, 'Finalized FULL Collection Trips', d);
    final ReportWaste w = d.waste;
    if (!w.available) return _unavailable(s, 'Collection data', w.reason);
    s.add(<Object?>['Trip', 'Driver', 'Truck', 'FULL at (Manila)', 'Load (kg)', 'Basis', 'Status'], XlsxStyle.header);
    for (final ReportLoadRow r in w.rows) {
      s.add(<Object?>[
        r.tripId,
        r.driver.trim().isEmpty ? 'Not recorded' : r.driver,
        r.truck,
        _stamp.format(r.fullAtManila),
        r.kg.round(),
        r.measured ? 'Measured' : 'Estimate',
        r.status,
      ]);
    }
    s.add(<Object?>[XlsxCell('Total', XlsxStyle.bold), '${w.trips} trip(s)', null, null, XlsxCell(w.totalKg.round(), XlsxStyle.bold), null, null]);
    if (w.isEstimate) {
      s.blank();
      s.add(<Object?>[
        XlsxCell('Estimated loads use a hypothetical ${AnalyticsReportData.tons(w.perTripEstimateKg)} tons per FULL trip '
            '(no measured weight was recorded).', XlsxStyle.wrap)
      ]);
      s.merges.add('A${s.rows.length}:G${s.rows.length}');
    }
  }

  static void _eta(XlsxSheet s, AnalyticsReportData d) {
    _title(s, 'Arrival Estimates (ETA) sent to residents', d);
    final ReportEta e = d.eta;
    if (!e.available) return _unavailable(s, 'ETA data', e.reason);
    s.add(<Object?>['Area', 'Truck', 'Sent', 'Predicted arrival', 'ETA (min)', 'GPS arrival', 'Status', 'Error (min)', 'Trip'], XlsxStyle.header);
    for (final ReportEtaRow r in e.rows) {
      s.add(<Object?>[
        r.area,
        r.truck,
        _stamp.format(r.sentAt),
        r.predictedAt == null ? '' : _stamp.format(r.predictedAt!),
        r.etaMinutes,
        r.actualAt == null ? 'Not recorded' : _stamp.format(r.actualAt!),
        r.status,
        r.signedErrorMin == null ? null : double.parse(r.signedErrorMin!.toStringAsFixed(1)),
        r.tripId,
      ]);
    }
    s.blank();
    s.add(<Object?>['Evaluated visits', e.evaluated]);
    if (e.avgAbsErrorMin != null) s.add(<Object?>['Average absolute error (min)', double.parse(e.avgAbsErrorMin!.toStringAsFixed(1))]);
    if (e.within5Pct != null) s.add(<Object?>['Within ±5 minutes', '${e.within5Pct}%']);
    s.add(<Object?>['Awaiting arrival', e.awaiting]);
    s.add(<Object?>['No arrival recorded', e.noArrival]);
  }

  static void _complaints(XlsxSheet s, AnalyticsReportData d) {
    _title(s, 'Resident Complaints', d);
    final ReportComplaints c = d.complaints;
    if (!c.available) return _unavailable(s, 'Complaint data', c.reason);
    s.add(<Object?>['Status', 'Complaints'], XlsxStyle.header);
    for (final String k in const <String>['Pending', 'In Progress', 'Resolved']) {
      s.add(<Object?>[k, c.counts[k] ?? 0]);
    }
    s.add(<Object?>[XlsxCell('Total', XlsxStyle.bold), XlsxCell(c.total, XlsxStyle.bold)]);
    if (c.byArea.isNotEmpty) {
      s.blank();
      s.add(<Object?>['Area', 'Complaints'], XlsxStyle.header);
      final List<MapEntry<String, int>> areas = c.byArea.entries.toList()
        ..sort((MapEntry<String, int> a, MapEntry<String, int> b) => b.value.compareTo(a.value));
      for (final MapEntry<String, int> e in areas) {
        s.add(<Object?>[e.key, e.value]);
      }
    }
  }
}
