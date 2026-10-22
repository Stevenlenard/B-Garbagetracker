import 'dart:typed_data';

import 'package:intl/intl.dart';

import '../utils/analytics_report_data.dart';
import '../utils/xlsx_writer.dart';

/// The report categories offered in Analytics > Export. Each one exports its own set of sheets.
enum ReportCategory { fullSystem, truckPerformance, areaCoverage }

extension ReportCategoryLabel on ReportCategory {
  String get label => switch (this) {
        ReportCategory.fullSystem => 'Full System Report',
        ReportCategory.truckPerformance => 'Truck Performance',
        ReportCategory.areaCoverage => 'Area Coverage',
      };

  /// What the exported file contains (shown in the export dialog and on the Overview sheet).
  String get contents => switch (this) {
        ReportCategory.fullSystem => 'Overview, fleet, collection trips, trucks and drivers, purok coverage, ETA accuracy and complaints',
        ReportCategory.truckPerformance => 'Overview, fleet, collection trips, trucks and drivers, and ETA accuracy',
        ReportCategory.areaCoverage => 'Overview, purok coverage, complaints by area, and ETA accuracy by area',
      };

  static ReportCategory parse(String s) {
    final String t = s.toLowerCase();
    if (t.contains('truck')) return ReportCategory.truckPerformance;
    if (t.contains('area') || t.contains('coverage')) return ReportCategory.areaCoverage;
    return ReportCategory.fullSystem;
  }
}

/// Excel version of the analytics report. Like [AnalyticsPdfBuilder] it only formats an
/// [AnalyticsReportData] snapshot, so the spreadsheet shows exactly what the dashboard shows
/// (unavailable data is written as unavailable, never as 0). The workbook is not locked: totals
/// and shares are formulas, so they follow when a value is edited, and tables can be filtered.
class AnalyticsXlsxBuilder {
  // ---------------------------------------------------------------- theme (app teal)
  static const String _tealDark = 'FF004D40';
  static const String _teal = 'FF00796B';
  static const String _tealText = 'FF00695C';
  static const String _mint = 'FFE0F2F1';
  static const String _mintSoft = 'FFF3FAF9';
  static const String _mintStrong = 'FFB2DFDB';
  static const String _ink = 'FF1F2937';
  static const String _muted = 'FF6B7280';
  static const String _white = 'FFFFFFFF';

  static const XlsxStyle _banner = XlsxStyle(bold: true, size: 18, color: _white, fill: _tealDark, border: false, indent: 1);
  static const XlsxStyle _subBanner = XlsxStyle(bold: true, size: 11, color: _white, fill: _teal, border: false, indent: 1);
  static const XlsxStyle _meta = XlsxStyle(italic: true, size: 10, color: _muted, border: false, indent: 1);
  static const XlsxStyle _section = XlsxStyle(bold: true, size: 13, color: _tealText, border: false, bottomRule: _teal);
  static const XlsxStyle _sectionFill = XlsxStyle(border: false, bottomRule: _teal);
  static const XlsxStyle _th = XlsxStyle(bold: true, color: _white, fill: _teal, align: 'center', wrap: true, borderColor: 'FF00695C');
  static const XlsxStyle _td = XlsxStyle(color: _ink);
  static const XlsxStyle _tdAlt = XlsxStyle(color: _ink, fill: _mintSoft);
  static const XlsxStyle _label = XlsxStyle(bold: true, color: _tealDark, fill: _mint);
  static const XlsxStyle _value = XlsxStyle(color: _ink);
  static const XlsxStyle _total = XlsxStyle(bold: true, color: _tealDark, fill: _mintStrong, topRule: _teal);
  static const XlsxStyle _note = XlsxStyle(italic: true, size: 10, color: _muted, border: false, wrap: true, vAlign: 'top');
  static const XlsxStyle _bullet = XlsxStyle(color: _ink, border: false, wrap: true, vAlign: 'top', indent: 1);
  static const XlsxStyle _link = XlsxStyle(color: 'FF00695C', bold: true);
  static const XlsxStyle _unavailable = XlsxStyle(italic: true, color: 'FFB45309', fill: 'FFFEF3C7', wrap: true);

  static const String _fmtInt = '#,##0';
  static const String _fmtDec = '0.0';
  static const String _fmtPct = '0%';
  static const String _fmtDateTime = 'mmm d, yyyy h:mm AM/PM';
  static const String _fmtDate = 'ddd, mmm d, yyyy';

  /// Text and fill colours for status words, so a status reads the same on every sheet.
  static const Map<String, List<String>> _statusColors = <String, List<String>>{
    'pending': <String>['FF1565C0', 'FFE3F2FD'],
    'in progress': <String>['FFB45309', 'FFFEF3C7'],
    'resolved': <String>['FF2E7D32', 'FFE8F5E9'],
    'active': <String>['FF2E7D32', 'FFE8F5E9'],
    'paused': <String>['FFB45309', 'FFFEF3C7'],
    'full': <String>['FFC62828', 'FFFDECEA'],
    'completed': <String>['FF1565C0', 'FFE3F2FD'],
    'offline': <String>['FF6B7280', 'FFF3F4F6'],
    'measured': <String>['FF2E7D32', 'FFE8F5E9'],
    'estimate': <String>['FFB45309', 'FFFEF3C7'],
    'evaluated': <String>['FF2E7D32', 'FFE8F5E9'],
    'awaiting arrival': <String>['FF1565C0', 'FFE3F2FD'],
    'no arrival recorded': <String>['FFB45309', 'FFFEF3C7'],
    'withdrawn': <String>['FF6B7280', 'FFF3F4F6'],
    'no eta stated': <String>['FF6B7280', 'FFF3F4F6'],
    'visited': <String>['FF2E7D32', 'FFE8F5E9'],
    'no verified visit': <String>['FFC62828', 'FFFDECEA'],
  };

  static XlsxStyle _status(String s) {
    final List<String>? c = _statusColors[s.trim().toLowerCase()];
    return c == null ? _td.copyWith(align: 'center') : XlsxStyle(bold: true, color: c[0], fill: c[1], align: 'center');
  }

  static final DateFormat _day = DateFormat('MMM d, yyyy');
  static final DateFormat _stamp = DateFormat('MMM d, yyyy h:mm a');

  static String _slug(String s) => s.trim().replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');

  static String fileName(AnalyticsReportData d, ReportCategory c) {
    final String area = d.meta.isAllAreas ? 'All_Areas' : _slug(d.meta.area);
    return '${_slug(c.label)}_${area}_${DateFormat('yyyy-MM-dd').format(d.meta.start)}_to_${DateFormat('yyyy-MM-dd').format(d.meta.end)}.xlsx';
  }

  static String _period(AnalyticsReportData d) => '${_day.format(d.meta.start)} to ${_day.format(d.meta.end)}';
  static String _area(AnalyticsReportData d) => d.meta.isAllAreas ? 'All Areas' : d.meta.area;

  // ---------------------------------------------------------------- workbook
  static Uint8List build(AnalyticsReportData d, [ReportCategory category = ReportCategory.fullSystem]) {
    final XlsxWorkbook wb = XlsxWorkbook(title: '${category.label} - ${_area(d)} - ${_period(d)}', author: 'Garbage Tracker');
    final List<_Part> parts = <_Part>[
      if (category != ReportCategory.areaCoverage) ...<_Part>[
        _Part('Fleet', 'Trucks by status when the file was generated', 'FF2E7D32', _fleet),
        _Part('Collection Trips', 'Every finalized FULL trip with driver, truck, time and load', 'FFF59E0B', _trips),
        _Part('Trucks & Drivers', 'FULL trips and loads per truck, per driver and per day', 'FF8E24AA', _trucksDrivers),
      ],
      if (category != ReportCategory.truckPerformance) ...<_Part>[
        _Part('Purok Coverage', 'Verified collection visits and complaints per area', 'FF1E88E5', _coverage),
        _Part('Complaints', 'Resident complaints by status and by area', 'FFC62828', _complaints),
      ],
      _Part('ETA Accuracy', category == ReportCategory.areaCoverage ? 'Arrival estimates sent to residents, by area' : 'Arrival estimates sent to residents and their error', 'FF00838F', _eta),
      _Part('About', 'Definitions, data sources and how to edit this file', 'FF6B7280', _about),
    ];
    _overview(wb.sheet('Overview', tabColor: _tealDark), d, category, parts);
    for (final _Part p in parts) {
      p.build(wb.sheet(p.name, tabColor: p.tab), d, category);
    }
    return wb.build();
  }

  // ---------------------------------------------------------------- shared pieces
  static void _header(XlsxSheet s, AnalyticsReportData d, ReportCategory c, String title, int cols) {
    // On narrow sheets the banner runs over a few more (default-width) columns so it is never cut.
    int span = cols;
    double width = 0;
    for (int i = 0; i < cols; i++) {
      width += s.columnWidths[i] ?? 9;
    }
    while (width < 84) {
      width += 9;
      span++;
    }
    s.band('GARBAGE TRACKER  ·  ${c.label.toUpperCase()}', _banner, span, height: 32);
    s.band('$title  ·  ${_area(d)}  ·  ${_period(d)}', _subBanner, span, height: 20);
    s.band('Generated ${_stamp.format(d.meta.generatedAtManila)} (Asia/Manila)  ·  Barangay Balintawak, Lipa City', _meta, span, height: 18);
    s.blank(8);
    s.showGridLines = false;
  }

  static void _sectionTitle(XlsxSheet s, String title, int cols) {
    s.blank(8);
    s.add(<Object?>[XlsxCell(title, _section), for (int i = 1; i < cols; i++) const XlsxCell(null, _sectionFill)], height: 22);
    s.blank(4);
  }

  static void _unavailableRow(XlsxSheet s, String what, String? reason, int cols) {
    s.band('$what is unavailable: ${reason ?? 'the source could not be reached'}.', _unavailable, cols, height: 30);
  }

  static void _noteRow(XlsxSheet s, String text, int cols, {double charsPerLine = 110}) {
    s.band(text, _note, cols, height: _wrapHeight(text, charsPerLine, 14));
  }

  static double _wrapHeight(String text, double charsPerLine, double lineHeight) =>
      ((text.length / charsPerLine).ceil().clamp(1, 12)) * lineHeight + 4;

  /// Writes a header row and banded data rows; returns the 1-based first and last data rows.
  static (int, int) _table(XlsxSheet s, List<String> headers, List<List<Object?>> rows,
      {Map<int, String> formats = const <int, String>{}, Set<int> statusCols = const <int>{}, Set<int> centerCols = const <int>{}}) {
    s.add(<Object?>[for (final String h in headers) XlsxCell(h, _th)], height: 30);
    final int first = s.nextRow;
    for (int r = 0; r < rows.length; r++) {
      final XlsxStyle base = r.isOdd ? _tdAlt : _td;
      s.add(<Object?>[
        for (int c = 0; c < headers.length; c++)
          () {
            final Object? v = c < rows[r].length ? rows[r][c] : null;
            if (v is XlsxCell) return v;
            if (statusCols.contains(c) && v is String) return XlsxCell(v, _status(v));
            XlsxStyle st = base;
            if (formats[c] != null) st = st.copyWith(numFmt: formats[c], align: 'right');
            if (v is num && formats[c] == null) st = st.copyWith(align: 'right');
            if (centerCols.contains(c)) st = st.copyWith(align: 'center');
            return XlsxCell(v, st);
          }(),
      ]);
    }
    return (first, s.nextRow - 1);
  }

  static XlsxCell _sum(int col, int first, int last, [String fmt = _fmtInt]) {
    final String c = XlsxWorkbook.colName(col);
    return XlsxCell(last < first ? 0 : XlsxFormula('SUM($c$first:$c$last)'), _total.copyWith(numFmt: fmt, align: 'right'));
  }

  static List<XlsxCell> _totalRow(String label, int cols, Map<int, XlsxCell> cells) => <XlsxCell>[
        XlsxCell(label, _total),
        for (int c = 1; c < cols; c++) cells[c] ?? const XlsxCell(null, _total),
      ];

  // ---------------------------------------------------------------- Overview
  static void _overview(XlsxSheet s, AnalyticsReportData d, ReportCategory c, List<_Part> parts) {
    const int cols = 3;
    s.width(0, 34);
    s.width(1, 30);
    s.width(2, 72);
    _header(s, d, c, 'Overview', cols);

    _sectionTitle(s, 'Report details', cols);
    void infoMerged(String k, Object v) {
      s.add(<Object?>[XlsxCell(k, _label), XlsxCell(v, _value.copyWith(wrap: true)), const XlsxCell(null, _value)]);
      s.merges.add('B${s.nextRow - 1}:C${s.nextRow - 1}');
    }

    infoMerged('Report', c.label);
    infoMerged('Includes', c.contents);
    infoMerged('Area', _area(d));
    infoMerged('Period', _period(d));
    s.add(<Object?>[XlsxCell('Generated', _label), XlsxCell(d.meta.generatedAtManila, _value.copyWith(numFmt: _fmtDateTime, align: 'left')), const XlsxCell('Asia/Manila time', _value)]);
    infoMerged('Source', 'Garbage Tracker admin dashboard: the same figures as the Analytics page and the PDF report.');
    infoMerged('Editing', 'This file can be edited, sorted and filtered. Totals and shares are formulas and update automatically.');

    _sectionTitle(s, 'Sheets in this file', cols);
    s.add(<Object?>[const XlsxCell('Sheet', _th), const XlsxCell('What it contains', _th), const XlsxCell(null, _th)], height: 24);
    s.merges.add('B${s.nextRow - 1}:C${s.nextRow - 1}');
    for (int i = 0; i < parts.length; i++) {
      final _Part p = parts[i];
      final XlsxStyle base = i.isOdd ? _tdAlt : _td;
      s.add(<Object?>[XlsxCell('→  ${p.name}', _link.copyWith(fill: base.fill)), XlsxCell(p.description, base), XlsxCell(null, base)]);
      s.merges.add('B${s.nextRow - 1}:C${s.nextRow - 1}');
      s.links['A${s.nextRow - 1}'] = "'${p.name}'!A1";
    }

    _sectionTitle(s, 'Key indicators', cols);
    final List<List<String>> kpis = d.keyIndicators.where((List<String> k) => _kpiFor(c, k[0])).toList();
    _table(s, const <String>['Indicator', 'Value', 'Basis'],
        <List<Object?>>[for (final List<String> k in kpis) <Object?>[XlsxCell(k[0], _label), int.tryParse(k[1]) ?? k[1], k[2]]]);
    for (int r = s.nextRow - kpis.length; r < s.nextRow; r++) {
      final List<XlsxCell?> row = s.rows[r - 1];
      row[2] = XlsxCell(row[2]!.value, row[2]!.style!.copyWith(wrap: true));
      row[1] = XlsxCell(row[1]!.value, row[1]!.style!.copyWith(bold: true, color: _tealDark, align: 'left', numFmt: row[1]!.value is num ? _fmtInt : null));
      s.rowHeights[r - 1] = _wrapHeight(row[2]!.value.toString(), 70, 15);
    }

    if (c != ReportCategory.areaCoverage) {
      _sectionTitle(s, 'Waste forecast', cols);
      if (d.forecast.available) {
        final String method = 'Projection from ${d.forecast.samples} recorded collection weight(s); not a measurement.';
        _table(s, const <String>['Forecast', 'Tons', 'Method'], <List<Object?>>[
          <Object?>[XlsxCell('Next collection day volume', _label), d.forecast.tomorrowKg / 1000.0, method],
          <Object?>[XlsxCell('Weekly volume projection', _label), d.forecast.weeklyKg / 1000.0, method],
        ], formats: const <int, String>{1: _fmtDec});
      } else {
        _unavailableRow(s, 'The forecast', d.forecast.reason, cols);
      }
    }

    final String? ai = d.usableNarrative;
    final List<String> insights = _filterText(c, d.insights);
    _sectionTitle(s, 'Insights', cols);
    if (ai != null && c == ReportCategory.fullSystem) s.band(ai, _bullet, cols, height: _wrapHeight(ai, 120, 15));
    for (final String t in insights) {
      s.band('•  $t', _bullet, cols, height: _wrapHeight(t, 120, 15));
    }
    _sectionTitle(s, 'Recommendations', cols);
    for (final String t in _filterText(c, d.recommendations)) {
      s.band('•  $t', _bullet, cols, height: _wrapHeight(t, 120, 15));
    }
  }

  static bool _kpiFor(ReportCategory c, String label) {
    final String l = label.toLowerCase();
    return switch (c) {
      ReportCategory.fullSystem => true,
      ReportCategory.truckPerformance => l.contains('trip') || l.contains('waste') || l.contains('fleet') || l.contains('eta'),
      ReportCategory.areaCoverage => l.contains('area') || l.contains('complaint') || l.contains('eta'),
    };
  }

  static List<String> _filterText(ReportCategory c, List<String> all) {
    if (c == ReportCategory.fullSystem) return all;
    final List<String> words = c == ReportCategory.truckPerformance
        ? <String>['trip', 'full', 'load', 'weight', 'truck', 'eta', 'arrival']
        : <String>['visit', 'area', 'complaint', 'gps', 'eta', 'arrival'];
    final List<String> out = all.where((String t) => words.any(t.toLowerCase().contains)).toList();
    return out.isEmpty ? <String>['No observations specific to this report for the selected period.'] : out;
  }

  // ---------------------------------------------------------------- Fleet
  static void _fleet(XlsxSheet s, AnalyticsReportData d, ReportCategory c) {
    const int cols = 3;
    s.width(0, 28);
    s.width(1, 14);
    s.width(2, 14);
    _header(s, d, c, 'Fleet status', cols);
    final ReportFleet f = d.fleet;
    if (!f.available) return _unavailableRow(s, 'The fleet snapshot', f.reason, cols);
    _sectionTitle(s, 'Trucks by status', cols);
    const List<String> order = <String>['Active', 'Paused', 'Full', 'Completed', 'Offline'];
    final int totalRow = s.nextRow + 1 + order.length; // header + rows, then total
    final (int a, int b) = _table(s, const <String>['Status', 'Trucks', 'Share'], <List<Object?>>[
      for (final String k in order) <Object?>[k, f.counts[k] ?? 0, XlsxFormula('IF(\$B\$$totalRow=0,0,B${s.nextRow + 1 + order.indexOf(k)}/\$B\$$totalRow)')],
    ], formats: const <int, String>{1: _fmtInt, 2: _fmtPct}, statusCols: const <int>{0});
    s.add(_totalRow('Total', cols, <int, XlsxCell>{1: _sum(1, a, b), 2: XlsxCell(XlsxFormula('IF(B$totalRow=0,0,1)'), _total.copyWith(numFmt: _fmtPct, align: 'right'))}));
    s.blank(6);
    _noteRow(s, 'A snapshot of the registered trucks at the moment the file was generated (connected = not offline).', cols, charsPerLine: 60);
  }

  // ---------------------------------------------------------------- Collection trips
  static void _trips(XlsxSheet s, AnalyticsReportData d, ReportCategory c) {
    const int cols = 8;
    const List<double> w = <double>[6, 26, 22, 11, 22, 13, 12, 14];
    for (int i = 0; i < w.length; i++) {
      s.width(i, w[i]);
    }
    s.landscape = true;
    _header(s, d, c, 'Finalized FULL collection trips', cols);
    final ReportWaste x = d.waste;
    if (!x.available) return _unavailableRow(s, 'Collection data', x.reason, cols);
    final int headerRow = s.nextRow;
    final (int a, int b) = _table(
      s,
      const <String>['#', 'Trip', 'Driver', 'Truck', 'FULL at (Manila)', 'Load (kg)', 'Basis', 'Status'],
      <List<Object?>>[
        for (int i = 0; i < x.rows.length; i++)
          <Object?>[
            i + 1,
            x.rows[i].tripId,
            x.rows[i].driver.trim().isEmpty ? 'Not recorded' : x.rows[i].driver.trim(),
            x.rows[i].truck,
            x.rows[i].timeRecorded ? x.rows[i].fullAtManila : XlsxCell('Not recorded', _td.copyWith(italic: true, color: _muted, align: 'center', fill: i.isOdd ? _mintSoft : null)),
            x.rows[i].kg.round(),
            x.rows[i].measured ? 'Measured' : 'Estimate',
            x.rows[i].status,
          ],
      ],
      formats: const <int, String>{4: _fmtDateTime, 5: _fmtInt},
      statusCols: const <int>{6, 7},
      centerCols: const <int>{0, 3},
    );
    s.freezeRows = headerRow;
    if (b >= a) s.autoFilter = 'A$headerRow:H$b';
    s.add(_totalRow('', cols, <int, XlsxCell>{
      1: XlsxCell(XlsxFormula('COUNTA(B$a:B${b < a ? a : b})&" trip(s)"'), _total),
      5: _sum(5, a, b),
    }));
    final int noTime = x.rows.where((ReportLoadRow r) => !r.timeRecorded).length;
    if (noTime > 0) {
      s.blank(6);
      _noteRow(
          s,
          'Not recorded = $noTime older trip record(s) carry no time at all. They are listed and counted exactly as the dashboard counts them, '
          'but they are left out of the first/last FULL times and of the per-day table.',
          cols);
    }
    if (x.isEstimate) {
      s.blank(6);
      _noteRow(
          s,
          'Estimate = no weight was recorded for that trip, so a hypothetical ${AnalyticsReportData.tons(x.perTripEstimateKg)} tons per FULL '
          'trip is used. Replace a value in "Load (kg)" with a measured weight and the total updates.',
          cols);
    }
  }

  // ---------------------------------------------------------------- Trucks & drivers
  static void _trucksDrivers(XlsxSheet s, AnalyticsReportData d, ReportCategory c) {
    const int cols = 6;
    const List<double> w = <double>[26, 13, 14, 13, 22, 22];
    for (int i = 0; i < w.length; i++) {
      s.width(i, w[i]);
    }
    s.landscape = true;
    _header(s, d, c, 'Trucks and drivers', cols);
    final ReportWaste x = d.waste;
    if (!x.available) return _unavailableRow(s, 'Collection data', x.reason, cols);

    // per truck
    final Map<String, List<ReportLoadRow>> byTruck = <String, List<ReportLoadRow>>{};
    for (final ReportLoadRow r in x.rows) {
      byTruck.putIfAbsent(r.truck.trim().isEmpty ? 'Not recorded' : r.truck.trim(), () => <ReportLoadRow>[]).add(r);
    }
    final List<String> trucks = byTruck.keys.toList()..sort();
    _sectionTitle(s, 'By truck', cols);
    final (int a, int b) = _table(s, const <String>['Truck', 'FULL trips', 'Load (kg)', 'Measured', 'First FULL', 'Last FULL'], <List<Object?>>[
      for (final String t in trucks)
        () {
          final List<ReportLoadRow> rs = byTruck[t]!;
          final List<DateTime> times = rs.where((ReportLoadRow r) => r.timeRecorded).map((ReportLoadRow r) => r.fullAtManila).toList()..sort();
          return <Object?>[
            t,
            rs.length,
            rs.fold<double>(0, (double s, ReportLoadRow r) => s + r.kg).round(),
            rs.where((ReportLoadRow r) => r.measured).length,
            times.isEmpty ? 'Not recorded' : times.first,
            times.isEmpty ? 'Not recorded' : times.last,
          ];
        }(),
    ], formats: const <int, String>{1: _fmtInt, 2: _fmtInt, 3: _fmtInt, 4: _fmtDateTime, 5: _fmtDateTime});
    s.add(_totalRow('Total', cols, <int, XlsxCell>{1: _sum(1, a, b), 2: _sum(2, a, b), 3: _sum(3, a, b)}));

    // per driver
    _sectionTitle(s, 'By driver', cols);
    final Map<String, int> drivers = x.byDriver;
    final int dTotal = s.nextRow + 1 + drivers.length;
    final (int da, int db) = _table(s, const <String>['Driver', 'FULL trips', 'Share'], <List<Object?>>[
      for (final MapEntry<String, int> e in drivers.entries)
        <Object?>[e.key, e.value, XlsxFormula('IF(\$B\$$dTotal=0,0,B${s.nextRow + 1 + drivers.keys.toList().indexOf(e.key)}/\$B\$$dTotal)')],
    ], formats: const <int, String>{1: _fmtInt, 2: _fmtPct});
    s.add(_totalRow('Total', 3, <int, XlsxCell>{1: _sum(1, da, db), 2: XlsxCell(XlsxFormula('IF(B$dTotal=0,0,1)'), _total.copyWith(numFmt: _fmtPct, align: 'right'))}));

    // per day
    _sectionTitle(s, 'By collection day', cols);
    final Map<String, List<ReportLoadRow>> byDay = <String, List<ReportLoadRow>>{};
    final List<ReportLoadRow> untimed = x.rows.where((ReportLoadRow r) => !r.timeRecorded).toList();
    for (final ReportLoadRow r in x.rows.where((ReportLoadRow r) => r.timeRecorded)) {
      byDay.putIfAbsent(DateFormat('yyyy-MM-dd').format(r.fullAtManila), () => <ReportLoadRow>[]).add(r);
    }
    final List<String> days = byDay.keys.toList()..sort();
    final (int ya, int yb) = _table(s, const <String>['Day', 'FULL trips', 'Load (kg)'], <List<Object?>>[
      for (final String k in days)
        <Object?>[DateTime.parse(k), byDay[k]!.length, byDay[k]!.fold<double>(0, (double s, ReportLoadRow r) => s + r.kg).round()],
      if (untimed.isNotEmpty)
        <Object?>['Time not recorded', untimed.length, untimed.fold<double>(0, (double s, ReportLoadRow r) => s + r.kg).round()],
    ], formats: const <int, String>{0: _fmtDate, 1: _fmtInt, 2: _fmtInt});
    for (int r = ya; r <= yb; r++) {
      final XlsxCell cell = s.rows[r - 1][0]!;
      s.rows[r - 1][0] = XlsxCell(cell.value, cell.style!.copyWith(align: 'left'));
    }
    s.add(_totalRow('Total', 3, <int, XlsxCell>{1: _sum(1, ya, yb), 2: _sum(2, ya, yb)}));
  }

  // ---------------------------------------------------------------- Coverage
  static void _coverage(XlsxSheet s, AnalyticsReportData d, ReportCategory c) {
    const int cols = 5;
    const List<double> w = <double>[34, 18, 18, 17, 20];
    for (int i = 0; i < w.length; i++) {
      s.width(i, w[i]);
    }
    _header(s, d, c, 'Purok coverage', cols);
    final ReportCoverage cv = d.coverage;
    if (!cv.available) return _unavailableRow(s, 'Coverage', cv.reason, cols);
    final Map<String, int> complaints = d.complaints.available ? d.complaints.byArea : const <String, int>{};
    _sectionTitle(s, 'Verified collection visits per area', cols);
    final int headerRow = s.nextRow;
    final (int a, int b) = _table(s, const <String>['Area', 'Verified visits', 'Entered, not verified', 'Resident complaints', 'Result'], <List<Object?>>[
      for (final ReportCoverageRow r in cv.rows)
        <Object?>[r.area, r.visits, r.unconfirmed, complaints[r.area] ?? 0, r.visits > 0 ? 'Visited' : 'No verified visit'],
    ], formats: const <int, String>{1: _fmtInt, 2: _fmtInt, 3: _fmtInt}, statusCols: const <int>{4});
    if (b >= a) s.autoFilter = 'A$headerRow:E$b';
    s.add(_totalRow('Total', cols, <int, XlsxCell>{
      1: _sum(1, a, b),
      2: _sum(2, a, b),
      3: _sum(3, a, b),
      4: XlsxCell(b < a ? '0 of 0 areas' : XlsxFormula('COUNTIF(B$a:B$b,">0")&" of "&ROWS(B$a:B$b)&" areas"'), _total.copyWith(align: 'center')),
    }));
    s.blank(6);
    if (cv.tripsWithoutEvidence > 0) {
      s.add(<Object?>[const XlsxCell('Trips without usable GPS points', _label), XlsxCell(cv.tripsWithoutEvidence, _value.copyWith(numFmt: _fmtInt, align: 'right'))]);
      s.blank(6);
    }
    _noteRow(
        s,
        'Verified visit = one trip with enough accurate GPS fixes inside the area while collecting, counted once per trip and area. '
        '"Entered, not verified" = the truck entered the area but did not meet that rule. Complaints = resident complaints filed in the period.',
        cols,
        charsPerLine: 100);
  }

  // ---------------------------------------------------------------- ETA
  static void _eta(XlsxSheet s, AnalyticsReportData d, ReportCategory c) {
    const int cols = 9;
    const List<double> w = <double>[36, 22, 10, 12, 22, 22, 13, 20, 24];
    for (int i = 0; i < w.length; i++) {
      s.width(i, w[i]);
    }
    s.landscape = true;
    _header(s, d, c, 'ETA accuracy', cols);
    final ReportEta e = d.eta;
    if (!e.available) return _unavailableRow(s, 'ETA data', e.reason, cols);

    _sectionTitle(s, 'Summary', cols);
    void kv(String k, Object? v, [String? fmt]) {
      s.add(<Object?>[XlsxCell(k, _label), XlsxCell(v ?? 'Not available', _value.copyWith(numFmt: fmt, align: 'right', bold: true, color: _tealDark))]);
    }

    kv('ETA notifications in the period', e.totalVisits, _fmtInt);
    kv('Evaluated (GPS-confirmed arrival)', e.evaluated, _fmtInt);
    kv('Average absolute error (min)', e.avgAbsErrorMin == null ? null : double.parse(e.avgAbsErrorMin!.toStringAsFixed(1)), _fmtDec);
    kv('Within ±5 minutes', e.within5Pct == null ? null : e.within5Pct! / 100.0, _fmtPct);
    kv('Awaiting arrival', e.awaiting, _fmtInt);
    kv('No arrival recorded', e.noArrival, _fmtInt);
    kv('Withdrawn', e.withdrawn, _fmtInt);
    kv('No ETA stated', e.noEstimate, _fmtInt);

    // per area
    final Map<String, List<ReportEtaRow>> byArea = <String, List<ReportEtaRow>>{};
    for (final ReportEtaRow r in e.rows) {
      byArea.putIfAbsent(r.area, () => <ReportEtaRow>[]).add(r);
    }
    final List<String> areas = byArea.keys.toList()..sort();
    _sectionTitle(s, 'By area', cols);
    final (int a, int b) = _table(s, const <String>['Area', 'ETAs sent', 'Evaluated', 'Avg error (min)'], <List<Object?>>[
      for (final String k in areas)
        () {
          final List<double> errs = byArea[k]!.where((ReportEtaRow r) => r.signedErrorMin != null).map((ReportEtaRow r) => r.signedErrorMin!.abs()).toList();
          return <Object?>[
            k,
            byArea[k]!.length,
            errs.length,
            errs.isEmpty ? null : double.parse((errs.reduce((double x, double y) => x + y) / errs.length).toStringAsFixed(1)),
          ];
        }(),
    ], formats: const <int, String>{1: _fmtInt, 2: _fmtInt, 3: _fmtDec});
    s.add(_totalRow('Total', 4, <int, XlsxCell>{1: _sum(1, a, b), 2: _sum(2, a, b)}));

    if (c != ReportCategory.areaCoverage) {
      _sectionTitle(s, 'Every ETA sent', cols);
      final int headerRow = s.nextRow;
      final (int da, int db) = _table(
        s,
        const <String>['Sent', 'Area', 'Truck', 'ETA (min)', 'Predicted arrival', 'GPS arrival', 'Error (min)', 'Status', 'Trip'],
        <List<Object?>>[
          for (final ReportEtaRow r in e.rows)
            <Object?>[
              r.sentAt,
              r.area,
              r.truck,
              r.etaMinutes,
              r.predictedAt,
              r.actualAt ?? 'Not recorded',
              r.signedErrorMin == null ? null : double.parse(r.signedErrorMin!.toStringAsFixed(1)),
              r.status,
              r.tripId,
            ],
        ],
        formats: const <int, String>{0: _fmtDateTime, 3: _fmtInt, 4: _fmtDateTime, 5: _fmtDateTime, 6: _fmtDec},
        statusCols: const <int>{7},
        centerCols: const <int>{2},
      );
      if (db >= da) s.autoFilter = 'A$headerRow:I$db';
      s.blank(6);
      _noteRow(s, 'Error = GPS-confirmed arrival minus predicted arrival (positive = the truck arrived later than stated).', cols);
    }
  }

  // ---------------------------------------------------------------- Complaints
  static void _complaints(XlsxSheet s, AnalyticsReportData d, ReportCategory c) {
    const int cols = 3;
    s.width(0, 34);
    s.width(1, 14);
    s.width(2, 12);
    _header(s, d, c, 'Resident complaints', cols);
    final ReportComplaints cm = d.complaints;
    if (!cm.available) return _unavailableRow(s, 'Complaint data', cm.reason, cols);
    _sectionTitle(s, 'By status', cols);
    const List<String> order = <String>['Pending', 'In Progress', 'Resolved'];
    final int totalRow = s.nextRow + 1 + order.length;
    final (int a, int b) = _table(s, const <String>['Status', 'Complaints', 'Share'], <List<Object?>>[
      for (int i = 0; i < order.length; i++)
        <Object?>[order[i], cm.counts[order[i]] ?? 0, XlsxFormula('IF(\$B\$$totalRow=0,0,B${s.nextRow + 1 + i}/\$B\$$totalRow)')],
    ], formats: const <int, String>{1: _fmtInt, 2: _fmtPct}, statusCols: const <int>{0});
    s.add(_totalRow('Total', cols, <int, XlsxCell>{1: _sum(1, a, b), 2: XlsxCell(XlsxFormula('IF(B$totalRow=0,0,1)'), _total.copyWith(numFmt: _fmtPct, align: 'right'))}));

    _sectionTitle(s, 'By area', cols);
    if (cm.byArea.isEmpty) {
      _noteRow(s, 'No complaint in this period named an area.', cols, charsPerLine: 60);
      return;
    }
    final List<MapEntry<String, int>> areas = cm.byArea.entries.toList()
      ..sort((MapEntry<String, int> x, MapEntry<String, int> y) => y.value.compareTo(x.value));
    final (int aa, int ab) = _table(s, const <String>['Area', 'Complaints'], <List<Object?>>[
      for (final MapEntry<String, int> e in areas) <Object?>[e.key, e.value],
    ], formats: const <int, String>{1: _fmtInt});
    s.add(_totalRow('Total', 2, <int, XlsxCell>{1: _sum(1, aa, ab)}));
  }

  // ---------------------------------------------------------------- About
  static void _about(XlsxSheet s, AnalyticsReportData d, ReportCategory c) {
    const int cols = 2;
    s.width(0, 30);
    s.width(1, 100);
    _header(s, d, c, 'About this file', cols);
    _sectionTitle(s, 'Definitions', cols);
    final List<List<String>> defs = <List<String>>[
      <String>['FULL trip', 'A collection trip that the driver finalized as FULL (truck at capacity). Counted once per trip id.'],
      <String>['Load (kg)', 'The recorded weight of a FULL trip; when none was recorded, a hypothetical ${AnalyticsReportData.tons(d.waste.perTripEstimateKg)} tons is used and marked "Estimate".'],
      <String>['Verified visit', 'One trip with enough accurate GPS fixes inside a collection area while collecting, counted once per trip and area.'],
      <String>['Entered, not verified', 'The truck entered the area but the GPS evidence did not meet the verified-visit rule.'],
      <String>['ETA', 'The estimated arrival time sent to residents in an approach alert.'],
      <String>['ETA error', 'GPS-confirmed arrival minus the predicted arrival, in minutes (positive = later than stated).'],
      <String>['Fleet status', 'Active (collecting), Paused, Full, Completed or Offline (no live connection), when the file was generated.'],
      <String>['Unavailable', 'A source that could not be reached is written as unavailable, never as 0.'],
    ];
    _table(s, const <String>['Term', 'Meaning'], <List<Object?>>[
      for (final List<String> x in defs) <Object?>[XlsxCell(x[0], _label), XlsxCell(x[1], _td.copyWith(wrap: true))],
    ]);
    _sectionTitle(s, 'Data sources', cols);
    _table(s, const <String>['Source', 'Used for'], <List<Object?>>[
      <Object?>[const XlsxCell('Live GPS and trips', _label), XlsxCell('Fleet status, FULL trips, verified visits and ETA arrivals (Firebase Realtime Database).', _td.copyWith(wrap: true))],
      <Object?>[const XlsxCell('Notifications', _label), XlsxCell('ETA values sent to residents.', _td.copyWith(wrap: true))],
      <Object?>[const XlsxCell('Complaints', _label), XlsxCell('Resident complaints filed in the period (status and area).', _td.copyWith(wrap: true))],
    ]);
    _sectionTitle(s, 'Editing this file', cols);
    for (final String t in <String>[
      'Nothing is locked: values can be corrected, rows sorted, and the filter buttons on the table headers used.',
      'Totals, shares and counts are formulas, so they recalculate when a value changes.',
      'Dates and times are real Excel dates (Asia/Manila time), so they sort and filter correctly.',
      'The figures were taken from the system at the time shown on every sheet; edits here do not change the system.',
    ]) {
      s.band('•  $t', _bullet, cols, height: 18);
    }
  }
}

class _Part {
  const _Part(this.name, this.description, this.tab, this.build);
  final String name;
  final String description;
  final String tab;
  final void Function(XlsxSheet, AnalyticsReportData, ReportCategory) build;
}
