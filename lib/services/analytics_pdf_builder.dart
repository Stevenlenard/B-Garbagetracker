import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../utils/analytics_report_data.dart';

/// Formats an [AnalyticsReportData] snapshot as an A4 portrait, multi-page report.
///
/// Pure (no Firebase/UI/platform code): the same bytes are produced on Android and Web.
/// Charts are drawn from exactly the numbers shown in the adjacent legend/table. Text is
/// ASCII only because the built-in Helvetica font has no Unicode glyphs.
class AnalyticsPdfBuilder {
  AnalyticsPdfBuilder._();

  static final PdfColor navy = PdfColor.fromHex('#12304A');
  static final PdfColor teal = PdfColor.fromHex('#00897B');
  static final PdfColor tealLight = PdfColor.fromHex('#E0F2F1');
  static final PdfColor ink = PdfColor.fromHex('#1F2937');
  static final PdfColor muted = PdfColor.fromHex('#64748B');
  static final PdfColor line = PdfColor.fromHex('#CBD5E1');
  static final PdfColor zebra = PdfColor.fromHex('#F8FAFC');
  static final PdfColor amber = PdfColor.fromHex('#B45309');

  static const int maxLoadRows = 200;
  static const int maxEtaRows = 100;

  /// Rows shown inside a section; the complete lists are in the appendix.
  static const int latestRows = 10;

  static final List<PdfColor> _palette = <PdfColor>[
    PdfColor.fromHex('#00897B'),
    PdfColor.fromHex('#F59E0B'),
    PdfColor.fromHex('#3B82F6'),
    PdfColor.fromHex('#10B981'),
    PdfColor.fromHex('#94A3B8'),
    PdfColor.fromHex('#EF4444'),
  ];

  static String _date(DateTime d) => DateFormat('MMM d, yyyy').format(d);
  // ICU may emit U+202F (narrow no-break space) before AM/PM; Helvetica cannot draw it.
  static String _ascii(String s) => s.replaceAll('\u202f', ' ').replaceAll('\u00a0', ' ');
  static String _dateTime(DateTime d) => _ascii(DateFormat('MMM d, yyyy h:mm a').format(d));
  static String _time(DateTime d) => _ascii(DateFormat('MMM d, h:mm a').format(d));

  static String period(ReportMeta m) {
    final bool same = m.start.year == m.end.year && m.start.month == m.end.month && m.start.day == m.end.day;
    return same ? _date(m.start) : '${_date(m.start)} to ${_date(m.end)}';
  }

  static pw.Document build(AnalyticsReportData d) {
    final pw.Document doc = pw.Document(
      title: 'Analytics and Performance Report',
      subject: 'Mobile-Based GIS Garbage Truck Tracking and Monitoring System - Barangay Balintawak',
      author: 'Garbage Tracking System',
    );
    final String periodText = period(d.meta);
    final String areaText = d.meta.isAllAreas ? 'All areas' : d.meta.area;

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(36, 36, 36, 40),
        footer: (pw.Context c) => pw.Container(
          padding: const pw.EdgeInsets.only(top: 6),
          decoration: pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: line, width: 0.5))),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: <pw.Widget>[
              pw.Text('Garbage Tracking System  |  $periodText  |  $areaText',
                  style: pw.TextStyle(fontSize: 7.5, color: muted)),
              pw.Text('Page ${c.pageNumber} of ${c.pagesCount}', style: pw.TextStyle(fontSize: 7.5, color: muted)),
            ],
          ),
        ),
        build: (pw.Context c) => <pw.Widget>[
          ..._header(d, periodText, areaText),
          ..._structure(),
          ..._executiveSummary(d),
          // Objective 1: GPS-based tracking and notifications
          pw.NewPage(),
          _part('A', 'Objective 1', 'GPS-Based Tracking and Notifications',
              'Real-time location of the trucks, collection route monitoring with verified visits, and geofence-based notifications.'),
          ..._fleet(d),
          ..._coverage(d),
          ..._assignments(d),
          ..._geofencing(d),
          // Objective 2: analytics module
          pw.NewPage(),
          _part('B', 'Objective 2', 'Analytics Module',
              'Descriptive analytics of the collection, arrival-time and waste volume estimates, and automated summaries and recommendations.'),
          ..._descriptive(d),
          ..._waste(d),
          ..._operations(d),
          ..._complaints(d),
          ..._loadHistory(d),
          ..._estimates(d),
          ..._eta(d),
          ..._forecast(d),
          ..._insights(d),
          // Objective 3: data modeling and predictive performance
          pw.NewPage(),
          _part('C', 'Objective 3', 'Data Modeling and Predictive Performance',
              'Linear regression for arrival time and moving average for the daily load, evaluated with MAE, RMSE and R-squared.'),
          ..._models(d),
          ..._modelEvaluation(d),
          ..._conclusion(d),
          ..._notes(d),
          ..._appendix(d),
        ],
      ),
    );
    return doc;
  }

  // ---------------------------------------------------------------- building blocks

  static pw.Widget _p(String text, {double size = 9, PdfColor? color, bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 5),
        child: pw.Text(
          text,
          style: pw.TextStyle(
            fontSize: size,
            color: color ?? ink,
            lineSpacing: 2,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          ),
        ),
      );

  static pw.Widget _note(String text, {bool warning = false}) => pw.Container(
        width: double.infinity,
        margin: const pw.EdgeInsets.only(bottom: 6),
        padding: const pw.EdgeInsets.all(7),
        decoration: pw.BoxDecoration(
          color: warning ? PdfColor.fromHex('#FEF3C7') : zebra,
          border: pw.Border.all(color: warning ? PdfColor.fromHex('#F59E0B') : line, width: 0.5),
          borderRadius: pw.BorderRadius.circular(4),
        ),
        child: pw.Text(text, style: pw.TextStyle(fontSize: 8.5, color: warning ? amber : muted, lineSpacing: 1.5)),
      );

  static pw.Widget _unavailable(String what, String? reason) =>
      _note('$what is unavailable${reason == null || reason.isEmpty ? '.' : ': $reason'}', warning: true);

  /// Atomic block: a single-row table cannot be split by the page layout, so a heading and its
  /// chart stay together and move to the next page as one piece.
  static pw.Widget _keep(List<pw.Widget> parts) => pw.Table(
        columnWidths: <int, pw.TableColumnWidth>{0: const pw.FlexColumnWidth(1)},
        children: <pw.TableRow>[
          pw.TableRow(children: <pw.Widget>[
            pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: parts),
          ]),
        ],
      );

  /// Table with a repeating header row and wrapped cells.
  static pw.Widget _table(
    List<String> headers,
    List<List<String>> rows, {
    required List<double> widths, // relative flex widths
    Set<int> rightAligned = const <int>{},
  }) {
    final Map<int, pw.TableColumnWidth> cols = <int, pw.TableColumnWidth>{
      for (int i = 0; i < widths.length; i++) i: pw.FlexColumnWidth(widths[i]),
    };
    pw.Widget cell(String t, int col, {bool head = false}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3.5),
          child: pw.Text(
            t,
            textAlign: rightAligned.contains(col) ? pw.TextAlign.right : pw.TextAlign.left,
            style: pw.TextStyle(
              fontSize: 7.8,
              fontWeight: head ? pw.FontWeight.bold : pw.FontWeight.normal,
              color: head ? PdfColors.white : ink,
            ),
          ),
        );
    return pw.Table(
      columnWidths: cols,
      border: pw.TableBorder(
        horizontalInside: pw.BorderSide(color: line, width: 0.4),
        bottom: pw.BorderSide(color: line, width: 0.6),
      ),
      children: <pw.TableRow>[
        pw.TableRow(
          repeat: true,
          decoration: pw.BoxDecoration(color: navy),
          children: <pw.Widget>[for (int i = 0; i < headers.length; i++) cell(headers[i], i, head: true)],
        ),
        for (int r = 0; r < rows.length; r++)
          pw.TableRow(
            decoration: r.isOdd ? pw.BoxDecoration(color: zebra) : null,
            children: <pw.Widget>[for (int i = 0; i < rows[r].length; i++) cell(rows[r][i], i)],
          ),
      ],
    );
  }

  /// Doughnut chart + legend table built from the same entries (zero entries listed, not drawn).
  static pw.Widget _pie(String title, Map<String, int> data) {
    final int total = data.values.fold(0, (int a, int b) => a + b);
    final List<MapEntry<String, int>> entries = data.entries.toList();
    pw.Widget legendRow(int i) {
      final MapEntry<String, int> e = entries[i];
      final String pct = total == 0 ? '-' : '${(e.value * 100 / total).toStringAsFixed(0)}%';
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
        child: pw.Row(children: <pw.Widget>[
          pw.Container(width: 8, height: 8, color: _palette[i % _palette.length]),
          pw.SizedBox(width: 6),
          pw.Expanded(child: pw.Text(e.key, style: pw.TextStyle(fontSize: 8.5, color: ink))),
          pw.Text('${e.value}  ($pct)', style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: ink)),
        ]),
      );
    }

    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 8),
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: zebra,
        border: pw.Border.all(color: line, width: 0.5),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
        pw.Text(title, style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold, color: navy)),
        pw.SizedBox(height: 8),
        if (total == 0)
          pw.Text('No records in this snapshot (total 0).', style: pw.TextStyle(fontSize: 8.5, color: muted))
        else
          pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: <pw.Widget>[
            pw.SizedBox(
              width: 110,
              height: 110,
              child: pw.Chart(
                grid: pw.PieGrid(),
                datasets: <pw.Dataset>[
                  for (int i = 0; i < entries.length; i++)
                    if (entries[i].value > 0)
                      pw.PieDataSet(
                        value: entries[i].value.toDouble(),
                        color: _palette[i % _palette.length],
                        drawSurface: true,
                        innerRadius: 28,
                      ),
                ],
              ),
            ),
            pw.SizedBox(width: 16),
            pw.Expanded(
              child: pw.Column(children: <pw.Widget>[
                for (int i = 0; i < entries.length; i++) legendRow(i),
                pw.Divider(color: line, thickness: 0.5),
                pw.Row(children: <pw.Widget>[
                  pw.Expanded(child: pw.Text('Total', style: pw.TextStyle(fontSize: 8.5, color: muted))),
                  pw.Text('$total', style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: ink)),
                ]),
              ]),
            ),
          ]),
      ]),
    );
  }

  /// Horizontal bar chart: label | bar | value. Wraps long labels, never overlaps.
  static pw.Widget _bars(
    String title,
    List<MapEntry<String, double>> data, {
    required String unit,
    double? max,
    int decimals = 0,
  }) {
    double top = max ?? 0;
    if (max == null) {
      for (final MapEntry<String, double> e in data) {
        if (e.value > top) top = e.value;
      }
    }
    if (top <= 0) top = 1;
    const double barWidth = 250;
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 8),
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        border: pw.Border.all(color: line, width: 0.5),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
        pw.Text(title, style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold, color: navy)),
        pw.SizedBox(height: 6),
        for (final MapEntry<String, double> e in data)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 2),
            child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: <pw.Widget>[
              pw.SizedBox(width: 110, child: pw.Text(e.key, style: pw.TextStyle(fontSize: 8, color: ink))),
              pw.Container(
                width: barWidth,
                height: 9,
                color: zebra,
                alignment: pw.Alignment.centerLeft,
                child: pw.Container(
                  width: (e.value / top).clamp(0.0, 1.0) * barWidth,
                  height: 9,
                  color: teal,
                ),
              ),
              pw.SizedBox(width: 6),
              pw.Text('${e.value.toStringAsFixed(decimals)}$unit',
                  style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: ink)),
            ]),
          ),
      ]),
    );
  }

  // ---------------------------------------------------------------- report frame

  /// Part divider: which specific objective of the study the following sections answer.
  static pw.Widget _part(String letter, String objective, String title, String scope) => pw.Container(
        width: double.infinity,
        margin: const pw.EdgeInsets.only(top: 18, bottom: 4),
        padding: const pw.EdgeInsets.fromLTRB(12, 9, 12, 9),
        decoration: pw.BoxDecoration(color: teal, borderRadius: pw.BorderRadius.circular(6)),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
          pw.Text('PART $letter  |  ${objective.toUpperCase()}',
              style: pw.TextStyle(fontSize: 7.5, color: PdfColor.fromHex('#C8F1EC'), letterSpacing: 1)),
          pw.SizedBox(height: 2),
          pw.Text(title, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
          pw.SizedBox(height: 3),
          pw.Text(scope, style: pw.TextStyle(fontSize: 8.5, color: PdfColors.white, lineSpacing: 1.5)),
        ]),
      );

  /// Section heading with the specific objective it reports on.
  static pw.Widget _sec(String number, String title, {String? objective}) => pw.Container(
        margin: const pw.EdgeInsets.only(top: 14, bottom: 6),
        padding: const pw.EdgeInsets.only(bottom: 4),
        decoration: pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: teal, width: 1.2))),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.end, children: <pw.Widget>[
          pw.Expanded(
            child: pw.Text(number.isEmpty ? title : '$number  $title',
                style: pw.TextStyle(fontSize: 12.5, fontWeight: pw.FontWeight.bold, color: navy)),
          ),
          if (objective != null)
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: pw.BoxDecoration(color: tealLight, borderRadius: pw.BorderRadius.circular(3)),
              child: pw.Text('Objective $objective', style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, color: teal)),
            ),
        ]),
      );

  static pw.Widget _sub(String title) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 6, bottom: 4),
        child: pw.Text(title, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: navy)),
      );

  /// Row of figure tiles (label, value, note).
  static pw.Widget _tiles(List<List<String>> items) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 8),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
          for (int i = 0; i < items.length; i++) ...<pw.Widget>[
            if (i > 0) pw.SizedBox(width: 6),
            pw.Expanded(
              child: pw.Container(
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(
                  color: zebra,
                  border: pw.Border(left: pw.BorderSide(color: teal, width: 2.5)),
                ),
                child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
                  pw.Text(items[i][0].toUpperCase(), style: pw.TextStyle(fontSize: 6.5, color: muted, letterSpacing: 0.4)),
                  pw.SizedBox(height: 3),
                  pw.Text(items[i][1], style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: navy)),
                  // Always present (blank when there is no note) so the tiles of a row line up.
                  pw.SizedBox(height: 2),
                  pw.Text(items[i].length > 2 && items[i][2].isNotEmpty ? items[i][2] : ' ',
                      style: pw.TextStyle(fontSize: 7, color: muted, lineSpacing: 1)),
                ]),
              ),
            ),
          ],
        ]),
      );

  static String _n(double? v, {int decimals = 1}) => v == null ? 'n/a' : v.toStringAsFixed(decimals);
  static String _kg(double? v) => v == null ? 'n/a' : '${NumberFormat('#,##0').format(v.round())} kg';

  static List<pw.Widget> _header(AnalyticsReportData d, String periodText, String areaText) {
    return <pw.Widget>[
      pw.Container(
        padding: const pw.EdgeInsets.all(14),
        decoration: pw.BoxDecoration(color: navy, borderRadius: pw.BorderRadius.circular(8)),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
          pw.Text('GARBAGE TRACKING SYSTEM  |  BARANGAY BALINTAWAK, LIPA CITY',
              style: pw.TextStyle(fontSize: 8.5, color: PdfColor.fromHex('#9FB3C8'), letterSpacing: 1)),
          pw.SizedBox(height: 4),
          pw.Text('Analytics and Performance Report',
              style: pw.TextStyle(fontSize: 19, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
          pw.SizedBox(height: 2),
          pw.Text('Mobile-Based GIS Garbage Truck Tracking and Monitoring System with Notification and Analytics',
              style: pw.TextStyle(fontSize: 8.5, color: PdfColor.fromHex('#C8F1EC'))),
          pw.SizedBox(height: 10),
          pw.Row(children: <pw.Widget>[
            _meta('Period', periodText),
            _meta('Area', areaText),
            _meta('Generated', _dateTime(d.meta.generatedAtManila)),
            _meta('Timezone', 'Asia/Manila (UTC+8)'),
          ]),
        ]),
      ),
      pw.SizedBox(height: 6),
    ];
  }

  static pw.Widget _meta(String k, String v) => pw.Expanded(
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
          pw.Text(k.toUpperCase(), style: pw.TextStyle(fontSize: 6.5, color: PdfColor.fromHex('#9FB3C8'))),
          pw.SizedBox(height: 2),
          pw.Text(v, style: pw.TextStyle(fontSize: 8.5, color: PdfColors.white, fontWeight: pw.FontWeight.bold)),
        ]),
      );

  /// How the report follows the specific objectives of the study.
  static List<pw.Widget> _structure() => <pw.Widget>[
        _sec('', 'Report Structure'),
        _table(
          <String>['Part', 'Specific objective', 'Sections in this report'],
          <List<String>>[
            <String>['-', 'Overview', '1  Executive summary'],
            <String>['A', '1.1  Real-time location of the trucks', 'A.1  Real-time fleet status'],
            <String>['A', '1.2  Collection route monitoring', 'A.2  Verified collection visits per area;  A.3  Scheduled routes'],
            <String>['A', '1.3  Geofencing and notifications', 'A.4  Approach alerts and collection completion'],
            <String>['B', '2.1  Descriptive analytics', 'B.1 to B.5  Collection trips and frequency, operations, complaints, load history'],
            <String>['B', '2.2  Arrival-time and waste volume estimates', 'B.6  ETA performance;  B.7  Waste volume estimate'],
            <String>['B', '2.3  Automated summaries and recommendations', 'B.8  Insights and recommendations'],
            <String>['C', '3.1  Data modeling techniques', 'C.1  Linear regression and moving average'],
            <String>['C', '3.2  Predictive performance (MAE, RMSE, R-squared)', 'C.2  Model evaluation'],
            <String>['-', 'Detailed records', 'Appendix A  All collection trips;  Appendix B  All ETA notifications'],
          ],
          widths: <double>[0.6, 4.2, 5.2],
        ),
      ];

  static List<pw.Widget> _executiveSummary(AnalyticsReportData d) {
    final ReportModelMetric? reg = d.predictive.available && d.predictive.metrics.isNotEmpty ? d.predictive.metrics.first : null;
    return <pw.Widget>[
      _sec('1', 'Executive Summary'),
      _table(
        <String>['Indicator', 'Value', 'Basis'],
        <List<String>>[
          ...d.keyIndicators,
          if (d.operations.missedPickups != null)
            <String>['Missed pickups reported', '${d.operations.missedPickups}', 'Resident reports of uncollected garbage in the period'],
          if (reg != null && reg.n > 0)
            <String>[
              'Arrival-time model (regression)',
              'MAE ${_n(reg.mae)} min',
              'R-squared ${_n(reg.r2, decimals: 2)} on ${reg.n} test sample(s)',
            ],
        ],
        widths: <double>[2.4, 2.2, 4.4],
      ),
      pw.SizedBox(height: 6),
      _note('Measured data comes from recorded GPS, trips and complaints. Waste tonnage is a hypothetical '
          'estimate (a configured ${AnalyticsReportData.tons(d.waste.perTripEstimateKg)} tons per FULL trip) '
          'unless a weight was measured. Anything marked unavailable had no reachable source.'),
    ];
  }

  // ---------------------------------------------------------------- Part A (Objective 1)

  static List<pw.Widget> _fleet(AnalyticsReportData d) {
    final pw.Widget head = _sec('A.1', 'Real-Time Fleet Status', objective: '1.1');
    if (!d.fleet.available) return <pw.Widget>[head, _unavailable('Fleet status', d.fleet.reason)];
    return <pw.Widget>[
      _keep(<pw.Widget>[
        head,
        _tiles(<List<String>>[
          <String>['Registered trucks', '${d.fleet.total}', ''],
          <String>['Connected now', '${d.fleet.connected}', 'live GPS position'],
          <String>['Collecting (active)', '${d.fleet.counts['Active'] ?? 0}', ''],
          <String>['Offline', '${d.fleet.counts['Offline'] ?? 0}', 'no fresh position'],
        ]),
        _pie('Fleet status distribution (current snapshot)', d.fleet.counts),
      ]),
      _note('The location of each truck comes from the GPS of the driver\'s smartphone and is shown live on the admin, '
          'resident and public maps. This is the fleet at the moment the report was generated, not a history of the '
          'period. A driver can be online while PAUSED, FULL or COMPLETED; only ACTIVE trucks are collecting.'),
    ];
  }

  static List<pw.Widget> _coverage(AnalyticsReportData d) {
    final ReportCoverage c = d.coverage;
    final pw.Widget head = _sec('A.2', 'Verified Collection Visits per Area', objective: '1.2');
    if (!c.available) return <pw.Widget>[head, _unavailable('Collection visits', c.reason)];
    const String policy = 'A verified visit is one trip that recorded at least 2 accurate GPS fixes inside the area, '
        'at least 1 minute apart, while collecting (ACTIVE). Paused, full and completed travel is excluded, and each trip '
        'counts at most once per area. A visit does not prove that every household was serviced.';
    return <pw.Widget>[
      if (c.rows.isEmpty) ...<pw.Widget>[
        head,
        _note('No collection areas are defined for this selection.'),
      ] else ...<pw.Widget>[
        _keep(<pw.Widget>[
          head,
          _tiles(<List<String>>[
            <String>['Areas with a verified visit', '${c.areasVisited} of ${c.expectedAreas}', ''],
            <String>['Verified visits', '${c.totalVisits}', 'one per trip and area'],
            <String>['Trips without GPS evidence', '${c.tripsWithoutEvidence}', 'cannot be verified'],
          ]),
          _bars(
            'Verified visits per area',
            c.rows.map((ReportCoverageRow r) => MapEntry<String, double>(r.area, r.visits.toDouble())).toList(),
            unit: '',
          ),
        ]),
        _table(
          <String>['Area', 'Verified visits', 'Entered, not verified', 'Result'],
          c.rows
              .map((ReportCoverageRow r) =>
                  <String>[r.area, '${r.visits}', '${r.unconfirmed}', r.visits > 0 ? 'Visited' : 'No verified visit'])
              .toList(),
          widths: <double>[4, 2, 2.2, 2],
          rightAligned: <int>{1, 2},
        ),
        pw.SizedBox(height: 4),
        _p(policy, size: 8, color: muted),
        _p('Every trip is also kept in Route History with its full GPS route, so collection routes can be replayed and compared.',
            size: 8, color: muted),
      ],
    ];
  }

  static List<pw.Widget> _assignments(AnalyticsReportData d) {
    final ReportAssignments a = d.assignments;
    final pw.Widget head = _sec('A.3', 'Scheduled Routes (Route Assignments)', objective: '1.2');
    if (!a.available) return <pw.Widget>[head, _unavailable('Scheduled routes', a.reason)];
    if (a.total == 0) {
      return <pw.Widget>[head, _note('No route assignment was scheduled for this period and area.')];
    }
    return <pw.Widget>[
      _keep(<pw.Widget>[
        head,
        _tiles(<List<String>>[
          <String>[
            'Scheduled route completion',
            a.completionRate == null ? 'n/a' : '${a.completionRate!.toStringAsFixed(0)}%',
            a.due == 0 ? 'no assignment due yet' : '${a.completed} of ${a.due} due completed',
          ],
          <String>[
            'Assigned-area coverage',
            a.coveragePercent == null ? 'n/a' : '${a.coveragePercent!.toStringAsFixed(0)}%',
            a.assignedAreas == 0 ? 'no started assignment' : '${a.verifiedAreas} of ${a.assignedAreas} assigned areas verified',
          ],
          <String>['Assignments', '${a.total}', 'in the period'],
        ]),
        _table(
          <String>['Pending', 'In progress', 'Completed', 'Missed', 'Cancelled'],
          <List<String>>[
            <String>['${a.pending}', '${a.inProgress}', '${a.completed}', '${a.missed}', '${a.cancelled}'],
          ],
          widths: <double>[1, 1, 1, 1, 1],
          rightAligned: <int>{0, 1, 2, 3, 4},
        ),
      ]),
      pw.SizedBox(height: 4),
      _p('Completion is operational: an assignment is completed when its trip is COMPLETED (a FULL trip stays in progress). '
          'Coverage counts only assigned areas with a verified GPS visit by the assignment\'s own trips.', size: 8, color: muted),
    ];
  }

  static List<pw.Widget> _geofencing(AnalyticsReportData d) {
    final ReportEta e = d.eta;
    final ReportCoverage c = d.coverage;
    final pw.Widget head = _sec('A.4', 'Approach Alerts and Collection Completion', objective: '1.3');
    final List<String> visited =
        c.available ? c.rows.where((ReportCoverageRow r) => r.visits > 0).map((ReportCoverageRow r) => r.area).toList() : <String>[];
    final List<String> notVisited =
        c.available ? c.rows.where((ReportCoverageRow r) => r.visits == 0).map((ReportCoverageRow r) => r.area).toList() : <String>[];
    return <pw.Widget>[
      _keep(<pw.Widget>[
        head,
        _tiles(<List<String>>[
          <String>['Approach alerts sent', e.available ? '${e.totalVisits}' : 'n/a', 'in-app notifications to residents'],
          <String>['With GPS-confirmed arrival', e.available ? '${e.evaluated}' : 'n/a', 'truck entered the area'],
          <String>['Areas logged as collected', c.available ? '${c.areasVisited} of ${c.expectedAreas}' : 'n/a', 'automatic, from GPS'],
        ]),
        if (c.available && c.rows.isNotEmpty)
          _table(
            <String>['Collection status logged automatically', 'Areas'],
            <List<String>>[
              <String>['Collected (verified visit)', visited.isEmpty ? 'None' : visited.join(', ')],
              <String>['No verified visit', notVisited.isEmpty ? 'None' : notVisited.join(', ')],
            ],
            widths: <double>[3, 7],
          ),
      ]),
      pw.SizedBox(height: 4),
      _p('Each collection area has a geofence (about 100 m around its point). When an ACTIVE truck approaches, residents of '
          'that area receive an in-app alert with the estimated arrival time; when the truck stays inside the geofence long '
          'enough, the visit and the weekly collection status are logged without any action by the driver.', size: 8, color: muted),
    ];
  }

  // ---------------------------------------------------------------- Part B (Objective 2)

  static List<pw.Widget> _descriptive(AnalyticsReportData d) => <pw.Widget>[
        _p('Sections B.1 to B.5 summarize the recorded collection for the selected period (descriptive analytics). '
            'The same figures are shown on the Analytics page and can be exported to PDF and Excel.', size: 8.5, color: muted),
      ];

  static List<pw.Widget> _waste(AnalyticsReportData d) {
    final ReportWaste w = d.waste;
    final pw.Widget head = _sec('B.1', 'Collection Trips and Waste Collected', objective: '2.1');
    if (!w.available) return <pw.Widget>[head, _unavailable('Waste collection data', w.reason)];
    final Map<String, int> byDate = w.byDate;
    return <pw.Widget>[
      _keep(<pw.Widget>[
        head,
        if (w.partial) _note('Some collection sources could not be reached; totals may be incomplete.', warning: true),
        _tiles(<List<String>>[
          <String>['Finalized FULL trips', '${w.trips}', 'counted once per trip id'],
          <String>[
            'Waste collected',
            '${AnalyticsReportData.tons(w.totalKg)} t',
            w.measuredCount == 0 ? 'hypothetical estimate' : '${w.measuredCount} measured',
          ],
          <String>['Collection days', '${byDate.length}', w.untimedCount > 0 ? '${w.untimedCount} trip(s) without a time' : ''],
          <String>[
            'Unfinished (not counted)',
            '${w.ongoingUnfinished + w.staleUnfinished}',
            '${w.ongoingUnfinished} ongoing, ${w.staleUnfinished} stale',
          ],
        ]),
      ]),
      if (w.trips == 0)
        _note('No FULL collection trips were finalized in this period for the selected area.')
      else ...<pw.Widget>[
        if (byDate.length >= 2 && byDate.length <= 31)
          _keep(<pw.Widget>[
            _sec('B.2', 'Collection Frequency', objective: '2.1'),
            _bars(
              'FULL trips per collection day (Asia/Manila)',
              byDate.entries.map((MapEntry<String, int> e) => MapEntry<String, double>(e.key, e.value.toDouble())).toList(),
              unit: ' trip(s)',
            ),
          ])
        else ...<pw.Widget>[
          _sec('B.2', 'Collection Frequency', objective: '2.1'),
          _table(
            <String>['Date', 'FULL trips'],
            byDate.entries.map((MapEntry<String, int> e) => <String>[e.key, '${e.value}']).toList(),
            widths: <double>[3, 2],
            rightAligned: <int>{1},
          ),
        ],
        if (w.untimedCount > 0)
          _p('${w.untimedCount} older trip record(s) carry no time, so they are not placed on a day above; they are still '
              'counted in the totals, as on the dashboard.', size: 8, color: muted),
        if (w.byDriver.isNotEmpty)
          _keep(<pw.Widget>[
            _bars(
              'FULL trips per driver',
              w.byDriver.entries
                  .take(12)
                  .map((MapEntry<String, int> e) => MapEntry<String, double>(e.key, e.value.toDouble()))
                  .toList(),
              unit: ' trip(s)',
            ),
          ]),
      ],
    ];
  }

  static List<pw.Widget> _operations(AnalyticsReportData d) {
    final ReportOperations o = d.operations;
    return <pw.Widget>[
      _keep(<pw.Widget>[
        _sec('B.3', 'Operations and Missed Pickups', objective: '2.1'),
        _tiles(<List<String>>[
          <String>['Distance covered', o.distanceKm == null ? 'n/a' : '${o.distanceKm!.toStringAsFixed(1)} km', 'from recorded GPS routes'],
          <String>['Stops per route', o.stopsPerRoute == null ? 'n/a' : '${o.stopsPerRoute}', 'collection areas per route'],
          <String>[
            'Average collection time',
            o.avgCollectionHours == null ? 'n/a' : '${o.avgCollectionHours!.toStringAsFixed(1)} h',
            'per trip',
          ],
          <String>[
            'Missed pickups',
            o.missedPickups == null ? 'n/a' : '${o.missedPickups}',
            o.missedPickups == null ? '' : '${o.missedPending ?? 0} pending, ${o.missedResolved ?? 0} resolved',
          ],
        ]),
      ]),
      _p('Missed pickups are resident reports of uncollected garbage in the period. n/a = not enough recorded data for the figure.',
          size: 8, color: muted),
    ];
  }

  static List<pw.Widget> _complaints(AnalyticsReportData d) {
    final ReportComplaints c = d.complaints;
    final pw.Widget head = _sec('B.4', 'Resident Complaints', objective: '2.1');
    if (!c.available) return <pw.Widget>[head, _unavailable('Complaint data', c.reason)];
    return <pw.Widget>[
      if (c.total == 0) ...<pw.Widget>[
        head,
        _note('No complaints were recorded for this period and area.'),
      ] else ...<pw.Widget>[
        _keep(<pw.Widget>[head, _pie('Complaint status distribution', c.counts)]),
        if (c.byArea.isNotEmpty)
          _keep(<pw.Widget>[
            _bars(
              'Complaints by area',
              (c.byArea.entries.toList()
                    ..sort((MapEntry<String, int> a, MapEntry<String, int> b) => b.value.compareTo(a.value)))
                  .take(12)
                  .map((MapEntry<String, int> e) => MapEntry<String, double>(e.key, e.value.toDouble()))
                  .toList(),
              unit: '',
            ),
          ]),
      ],
    ];
  }

  static List<pw.Widget> _loadHistory(AnalyticsReportData d) {
    final ReportWaste w = d.waste;
    final pw.Widget head = _sec('B.5', 'Load History', objective: '2.1');
    if (!w.available || w.trips == 0) {
      return <pw.Widget>[
        head,
        if (!w.available) _unavailable('Load history', w.reason) else _note('No finalized loads in this period.'),
      ];
    }
    final bool more = w.rows.length > latestRows;
    return <pw.Widget>[
      head,
      _p('${more ? 'The $latestRows newest of ${w.rows.length}' : 'All ${w.rows.length}'} collection trip(s), newest first by the '
          'time the truck became FULL.${more ? ' Every trip is listed in Appendix A.' : ''}', color: muted, size: 8.5),
      _loadTable(w.rows.take(latestRows).toList()),
    ];
  }

  static pw.Widget _loadTable(List<ReportLoadRow> rows) => _table(
        <String>['FULL time', 'Trip', 'Driver', 'Truck', 'Load', 'Basis', 'Status'],
        rows
            .map((ReportLoadRow r) => <String>[
                  r.timeRecorded ? _time(r.fullAtManila) : 'Not recorded',
                  r.tripId,
                  r.driver.isEmpty ? '-' : r.driver,
                  r.truck.isEmpty ? '-' : r.truck,
                  '${AnalyticsReportData.tons(r.kg)} t',
                  r.measured ? 'Measured' : 'Estimate',
                  r.status,
                ])
            .toList(),
        widths: <double>[2.2, 2.6, 1.8, 1.2, 1.0, 1.2, 1.4],
      );

  static List<pw.Widget> _estimates(AnalyticsReportData d) => <pw.Widget>[
        pw.SizedBox(height: 4),
        _p('Sections B.6 and B.7 report the estimates the system gives: the arrival time sent to residents (from the distance '
            'to the area and the recent speed of the truck) and the waste volume.', size: 8.5, color: muted),
      ];

  static List<pw.Widget> _eta(AnalyticsReportData d) {
    final ReportEta e = d.eta;
    final pw.Widget head = _sec('B.6', 'Arrival-Time Estimates (ETA Performance)', objective: '2.2');
    if (!e.available) return <pw.Widget>[head, _unavailable('ETA performance', e.reason)];
    final List<ReportEtaRow> shown = e.rows.take(latestRows).toList();
    return <pw.Widget>[
      _keep(<pw.Widget>[
        head,
        _tiles(<List<String>>[
          <String>['ETAs sent', '${e.totalVisits}', 'one per trip and area'],
          <String>['Evaluated', '${e.evaluated}', 'GPS-confirmed arrival'],
          <String>['Average error', e.avgAbsErrorMin == null ? 'n/a' : '${e.avgAbsErrorMin!.toStringAsFixed(1)} min', 'absolute'],
          <String>['Within +/-5 min', e.within5Pct == null ? 'n/a' : '${e.within5Pct}%', 'of evaluated'],
        ]),
        _table(
          <String>['Awaiting arrival', 'No arrival recorded', 'Withdrawn', 'Without an ETA'],
          <List<String>>[
            <String>['${e.awaiting}', '${e.noArrival}', '${e.withdrawn}', '${e.noEstimate}'],
          ],
          widths: <double>[1, 1, 1, 1],
          rightAligned: <int>{0, 1, 2, 3},
        ),
      ]),
      pw.SizedBox(height: 6),
      if (shown.isEmpty)
        _note('No ETA notifications were sent for this area and period.')
      else ...<pw.Widget>[
        _sub('Latest notifications'),
        _etaTable(shown),
        _p('${e.rows.length > shown.length ? 'The $latestRows newest of ${e.rows.length} visits; every visit is listed in Appendix B. ' : ''}'
            'Each visit is judged on its first notified ETA against the GPS-confirmed arrival of the same trip and area. '
            'Diff = actual - predicted (+ is late).', size: 8, color: muted),
      ],
    ];
  }

  static pw.Widget _etaTable(List<ReportEtaRow> rows) => _table(
        <String>['Area', 'Truck / Trip', 'Sent', 'ETA', 'Predicted', 'Actual (GPS)', 'Diff', 'Status'],
        rows
            .map((ReportEtaRow r) => <String>[
                  r.area,
                  '${r.truck.isEmpty ? '-' : r.truck}\n${r.tripId}',
                  _time(r.sentAt),
                  r.etaMinutes == null ? '-' : '${r.etaMinutes} min',
                  r.predictedAt == null ? '-' : _time(r.predictedAt!),
                  r.actualAt == null ? 'Not recorded' : _time(r.actualAt!),
                  r.signedErrorMin == null
                      ? '-'
                      : '${r.signedErrorMin! > 0 ? '+' : ''}${r.signedErrorMin!.toStringAsFixed(1)} min',
                  r.status,
                ])
            .toList(),
        widths: <double>[1.7, 2.6, 1.5, 0.8, 1.5, 1.7, 1.0, 1.4],
      );

  static List<pw.Widget> _forecast(AnalyticsReportData d) {
    final ReportForecast f = d.forecast;
    final pw.Widget head = _sec('B.7', 'Waste Volume Estimate', objective: '2.2');
    if (!f.available) {
      return <pw.Widget>[
        head,
        _note('The waste volume estimate is unavailable: ${f.reason ?? 'there is not enough recorded data.'} '
            'No volume figure is reported.'),
      ];
    }
    return <pw.Widget>[
      _keep(<pw.Widget>[
        head,
        _tiles(<List<String>>[
          <String>['Next collection day', '${AnalyticsReportData.tons(f.tomorrowKg)} t', 'projection'],
          <String>['Next 7 days', '${AnalyticsReportData.tons(f.weeklyKg)} t', 'projection'],
          <String>['Based on', '${f.samples}', 'recorded weight(s)'],
        ]),
      ]),
      _p('Method: a baseline from the recorded collection weights combined with the number of stops per route. '
          'It is a projection, not a measurement.', size: 8, color: muted),
    ];
  }

  static List<pw.Widget> _insights(AnalyticsReportData d) {
    final String? ai = d.usableNarrative;
    return <pw.Widget>[
      _sec('B.8', 'Automated Summaries and Recommendations', objective: '2.3'),
      _sub('Observations (rule-based, always available)'),
      for (final String s in d.insights) _bullet(s),
      pw.SizedBox(height: 4),
      _sub('Recommendations'),
      for (final String s in d.recommendations) _bullet(s),
      pw.SizedBox(height: 6),
      if (ai != null)
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
              color: zebra, border: pw.Border.all(color: line, width: 0.5), borderRadius: pw.BorderRadius.circular(4)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
            pw.Text('AI-written summary (Google Gemini Flash, generated on the server)',
                style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: navy)),
            pw.SizedBox(height: 4),
            pw.Text(ai, style: pw.TextStyle(fontSize: 8.5, color: ink, lineSpacing: 2)),
          ]),
        )
      else
        _p('The optional AI-written summary (Google Gemini Flash) was not available for this report; the rule-based '
            'observations above are used.', size: 8, color: muted),
    ];
  }

  // ---------------------------------------------------------------- Part C (Objective 3)

  static List<pw.Widget> _models(AnalyticsReportData d) {
    final ReportPredictive p = d.predictive;
    final pw.Widget head = _sec('C.1', 'Data Modeling Techniques', objective: '3.1');
    if (!p.available) return <pw.Widget>[head, _unavailable('The predictive models', p.reason)];
    final String equation = p.intercept == null || p.slope == null
        ? 'Not enough samples to fit the line yet.'
        : 'minutes to arrival = ${p.intercept!.toStringAsFixed(2)} + ${p.slope!.toStringAsFixed(2)} x distance (km)';
    return <pw.Widget>[
      _keep(<pw.Widget>[
        head,
        _sub('Linear regression: arrival time'),
        _table(
          <String>['Item', 'Value'],
          <List<String>>[
            <String>['Fitted model', equation],
            <String>['Explanatory variable', 'Straight-line distance from the truck to the collection area (km)'],
            <String>['Outcome', 'Minutes until the truck entered the area (GPS-confirmed)'],
            <String>[
              'Samples',
              '${p.samples} sample(s) from ${p.trips} recorded trip(s): moving, collecting fixes in the 30 minutes before '
                  'entry, one every 2 minutes; simulations excluded',
            ],
            <String>['Training and testing', p.method],
          ],
          widths: <double>[2.2, 7.8],
        ),
      ]),
      _keep(<pw.Widget>[
        _sub('Moving average: daily collected load'),
        _table(
          <String>['Item', 'Value'],
          <List<String>>[
            <String>['Model', '${p.maWindow}-day simple moving average of the daily collected load'],
            <String>[
              'Series',
              '${p.maDays} day(s) in the period; the load of a day is the sum of the recorded weights of the trips '
                  'finalized FULL that day',
            ],
            <String>[
              'Evaluation',
              'Each day is forecast from the ${p.maWindow} days before it and compared with what was collected (one-step backtest)',
            ],
            <String>['Forecast for the next day', _kg(p.maNextKg)],
          ],
          widths: <double>[2.2, 7.8],
        ),
      ]),
    ];
  }

  static String _fit(ReportModelMetric m) {
    if (m.n == 0) return 'No sample yet';
    final String early = m.n < 20 ? ' (early data)' : '';
    final double? r2 = m.r2;
    if (r2 == null) return 'R-squared not defined$early';
    if (r2 < 0) return 'Below the average baseline$early';
    if (r2 < 0.3) return 'Weak fit$early';
    if (r2 < 0.7) return 'Moderate fit$early';
    return 'Strong fit$early';
  }

  static List<pw.Widget> _modelEvaluation(AnalyticsReportData d) {
    final ReportPredictive p = d.predictive;
    final pw.Widget head = _sec('C.2', 'Predictive Performance', objective: '3.2');
    if (!p.available) return <pw.Widget>[head, _unavailable('Model evaluation', p.reason)];
    String unitVal(double? v, String unit) => v == null ? 'n/a' : (unit == 'kg' ? _kg(v) : '${v.toStringAsFixed(1)} min');
    final List<String> reading = <String>[];
    if (p.metrics.length >= 2 && p.metrics[0].mae != null && p.metrics[1].mae != null) {
      final double a = p.metrics[0].mae!, b = p.metrics[1].mae!;
      reading.add(a < b
          ? 'The regression had a smaller average error than the live rule on the same test samples '
              '(${a.toStringAsFixed(1)} vs ${b.toStringAsFixed(1)} min).'
          : 'The live rule had a smaller or equal average error than the regression on the same test samples '
              '(${b.toStringAsFixed(1)} vs ${a.toStringAsFixed(1)} min).');
    }
    final List<String> negative = <String>[
      for (final ReportModelMetric m in p.metrics)
        if (m.r2 != null && m.r2! < 0) m.label.replaceFirst('Arrival time: ', '').replaceFirst('Daily collected load: ', ''),
    ];
    if (negative.isNotEmpty) {
      reading.add('R-squared is negative for ${negative.join('; ')}: on these data the predictions explained less of the '
          'variation than simply predicting the average would.');
    }
    if (p.metrics.any((ReportModelMetric m) => m.n > 0 && m.n < 20)) {
      reading.add('Some figures rest on fewer than 20 samples; they are a first indication and are recomputed automatically '
          'as more trips are recorded.');
    }
    return <pw.Widget>[
      _keep(<pw.Widget>[
        head,
        _table(
          <String>['Model', 'n', 'MAE', 'RMSE', 'R-squared', 'Reading'],
          p.metrics
              .map((ReportModelMetric m) => <String>[
                    m.label,
                    '${m.n}',
                    unitVal(m.mae, m.unit),
                    unitVal(m.rmse, m.unit),
                    m.r2 == null ? 'n/a' : m.r2!.toStringAsFixed(2),
                    _fit(m),
                  ])
              .toList(),
          widths: <double>[3.6, 0.6, 1.3, 1.3, 1.0, 2.2],
          rightAligned: <int>{1, 2, 3, 4},
        ),
      ]),
      pw.SizedBox(height: 6),
      if (p.metrics.where((ReportModelMetric m) => m.unit == 'min' && m.mae != null).length >= 2)
        _keep(<pw.Widget>[
          _bars(
            'Average arrival-time error (MAE) by method - lower is better',
            <MapEntry<String, double>>[
              for (final ReportModelMetric m in p.metrics)
                if (m.unit == 'min' && m.mae != null)
                  MapEntry<String, double>(
                      m.label.contains('regression')
                          ? 'Linear regression'
                          : (m.label.contains('live rule') ? 'Live rule (distance / speed)' : 'ETAs sent to residents'),
                      m.mae!),
            ],
            unit: ' min',
            decimals: 1,
          ),
        ]),
      for (final String r in reading) _bullet(r),
      if (p.recent.isNotEmpty)
        _keep(<pw.Widget>[
          _sub('Moving average backtest (latest days)'),
          _table(
            <String>['Day', 'Collected', 'Forecast', 'Error'],
            p.recent
                .map(((DateTime, double, double) x) => <String>[
                      DateFormat('EEE, MMM d').format(x.$1),
                      _kg(x.$2),
                      _kg(x.$3),
                      '${x.$2 - x.$3 >= 0 ? '+' : '-'}${_kg((x.$2 - x.$3).abs())}',
                    ])
                .toList(),
            widths: <double>[2.4, 2, 2, 2],
            rightAligned: <int>{1, 2, 3},
          ),
        ]),
      pw.SizedBox(height: 6),
      _note('MAE (mean absolute error) is the average size of the errors. RMSE (root mean square error) weighs large errors '
          'more. R-squared shows how much of the variation the model explains compared with always predicting the average: '
          '1 is perfect, 0 is no better than the average, and below 0 is worse than the average. The models are tested on data '
          'that was not used to fit them, and the estimates actually sent to residents are evaluated separately.'),
    ];
  }

  // ---------------------------------------------------------------- closing

  static List<pw.Widget> _conclusion(AnalyticsReportData d) => <pw.Widget>[
        pw.SizedBox(height: 12),
        _keep(<pw.Widget>[
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(color: tealLight, borderRadius: pw.BorderRadius.circular(6)),
            child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
              pw.Text('Conclusion', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: navy)),
              pw.SizedBox(height: 4),
              pw.Text(_conclusionText(d), style: pw.TextStyle(fontSize: 9, color: ink, lineSpacing: 2)),
            ]),
          ),
        ]),
      ];

  /// The data conclusion, completed with the scheduled routes (Objective 1.2) and the models (Objective 3).
  static String _conclusionText(AnalyticsReportData d) {
    final StringBuffer b = StringBuffer(d.conclusion.trim());
    final ReportAssignments a = d.assignments;
    if (a.available && a.due > 0 && a.completionRate != null) {
      b.write(' ${a.completed} of ${a.due} scheduled route assignment(s) due were completed '
          '(${a.completionRate!.toStringAsFixed(0)}%).');
    }
    final ReportPredictive p = d.predictive;
    if (p.available) {
      final List<ReportModelMetric> m = p.metrics;
      final ReportModelMetric? reg = m.isNotEmpty && m.first.n > 0 ? m.first : null;
      final ReportModelMetric? ma = m.length > 3 && m[3].n > 0 ? m[3] : null;
      if (reg != null) {
        b.write(' The arrival-time linear regression had an MAE of ${_n(reg.mae)} min and an R-squared of '
            '${_n(reg.r2, decimals: 2)} on ${reg.n} test sample(s)');
        b.write(ma == null ? '.' : ', and the ${p.maWindow}-day moving average of the daily load had an MAE of ${_kg(ma.mae)} '
            'and an R-squared of ${_n(ma.r2, decimals: 2)}.');
      }
    }
    return b.toString();
  }

  static List<pw.Widget> _notes(AnalyticsReportData d) => <pw.Widget>[
        _sec('', 'Notes and Definitions'),
        _table(
          <String>['Term', 'Meaning in this report'],
          <List<String>>[
            <String>['FULL trip', 'A collection trip the driver finalized as FULL (truck at capacity); counted once per trip id.'],
            <String>[
              'Waste collected',
              'Recorded weight of FULL trips; a hypothetical ${AnalyticsReportData.tons(d.waste.perTripEstimateKg)} tons per '
                  'trip when none was recorded.',
            ],
            <String>['Verified visit', 'At least 2 accurate GPS fixes inside the area, 1 minute apart, while collecting; once per trip and area.'],
            <String>['Approach alert', 'In-app notification to residents of an area when an ACTIVE truck is approaching, with the ETA.'],
            <String>['ETA', 'Estimated arrival time from the distance to the area and the recent speed of the truck.'],
            <String>['Unavailable / n/a', 'The source could not be reached or there is not enough recorded data; never reported as 0.'],
          ],
          widths: <double>[2, 8],
        ),
      ];

  /// Detailed records kept out of the narrative so the sections stay readable.
  static List<pw.Widget> _appendix(AnalyticsReportData d) {
    final ReportWaste w = d.waste;
    final ReportEta e = d.eta;
    final bool loads = w.available && w.rows.length > latestRows;
    final bool etas = e.available && e.rows.length > latestRows;
    if (!loads && !etas) return const <pw.Widget>[];
    final int untimed = w.available ? w.rows.where((ReportLoadRow r) => !r.timeRecorded).length : 0;
    final List<ReportLoadRow> allLoads = w.available ? w.rows.take(maxLoadRows).toList() : const <ReportLoadRow>[];
    final List<ReportEtaRow> allEtas = e.available ? e.rows.take(maxEtaRows).toList() : const <ReportEtaRow>[];
    return <pw.Widget>[
      pw.NewPage(),
      if (loads) ...<pw.Widget>[
        _sec('Appendix A', 'All Collection Trips in the Period', objective: '2.1'),
        _p('${allLoads.length < w.rows.length ? 'The newest ${allLoads.length} of ${w.rows.length}' : 'All ${w.rows.length}'} '
            'finalized FULL trip(s), newest first.'
            '${untimed > 0 ? ' Not recorded = $untimed older trip record(s) carry no time; they are counted as on the dashboard.' : ''}',
            size: 8.5, color: muted),
        _loadTable(allLoads),
      ],
      if (etas) ...<pw.Widget>[
        _sec('Appendix B', 'All ETA Notifications in the Period', objective: '2.2'),
        _p('${allEtas.length < e.rows.length ? 'The newest ${allEtas.length} of ${e.rows.length}' : 'All ${e.rows.length}'} '
            'visit(s), newest first. Diff = actual - predicted (+ is late).', size: 8.5, color: muted),
        _etaTable(allEtas),
      ],
    ];
  }

  static pw.Widget _bullet(String text) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 3),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
          pw.Container(
            width: 4,
            height: 4,
            margin: const pw.EdgeInsets.only(top: 4, right: 6),
            decoration: pw.BoxDecoration(color: teal, shape: pw.BoxShape.circle),
          ),
          pw.Expanded(child: pw.Text(text, style: pw.TextStyle(fontSize: 9, color: ink, lineSpacing: 2))),
        ]),
      );
}
