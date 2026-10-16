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
          ..._executiveSummary(d),
          ..._fleet(d),
          ..._waste(d),
          ..._loadHistory(d),
          ..._coverage(d),
          ..._eta(d),
          ..._complaints(d),
          ..._forecast(d),
          ..._insights(d),
        ],
      ),
    );
    return doc;
  }

  // ---------------------------------------------------------------- building blocks

  static pw.Widget _h1(String text) => pw.Container(
        margin: const pw.EdgeInsets.only(top: 16, bottom: 8),
        padding: const pw.EdgeInsets.only(bottom: 4),
        decoration: pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: teal, width: 1.2))),
        child: pw.Text(text, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: navy)),
      );

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

  // ---------------------------------------------------------------- sections

  static List<pw.Widget> _header(AnalyticsReportData d, String periodText, String areaText) {
    return <pw.Widget>[
      pw.Container(
        padding: const pw.EdgeInsets.all(14),
        decoration: pw.BoxDecoration(color: navy, borderRadius: pw.BorderRadius.circular(8)),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
          pw.Text('GARBAGE TRACKING SYSTEM',
              style: pw.TextStyle(fontSize: 10, color: PdfColors.white, letterSpacing: 1.2)),
          pw.SizedBox(height: 4),
          pw.Text('Official Analytics & Performance Report',
              style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
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

  static List<pw.Widget> _executiveSummary(AnalyticsReportData d) {
    return <pw.Widget>[
      _h1('1. Executive Summary'),
      _table(
        <String>['Indicator', 'Value', 'Basis'],
        d.keyIndicators,
        widths: <double>[2.4, 2.2, 4.4],
      ),
      pw.SizedBox(height: 6),
      _note('Measured data comes from recorded GPS, trips and complaints. Waste tonnage is a hypothetical '
          'estimate (a configured ${AnalyticsReportData.tons(d.waste.perTripEstimateKg)} tons per FULL trip) '
          'unless a weight was measured. Anything marked unavailable had no reachable source.'),
    ];
  }

  static List<pw.Widget> _fleet(AnalyticsReportData d) {
    return <pw.Widget>[
      if (!d.fleet.available) ...<pw.Widget>[
        _h1('2. Fleet Performance'),
        _unavailable('Fleet status', d.fleet.reason),
      ] else ...<pw.Widget>[
        _keep(<pw.Widget>[_h1('2. Fleet Performance'), _pie('Fleet status distribution (current snapshot)', d.fleet.counts)]),
        _note('This is the fleet at the moment the report was generated, not a history of the period. '
            'Connectivity and collection status are separate: a driver can be online while PAUSED, FULL '
            'or COMPLETED, and only ACTIVE trucks are collecting. Offline = registered trucks with no '
            'fresh live position.'),
      ],
    ];
  }

  static List<pw.Widget> _waste(AnalyticsReportData d) {
    final ReportWaste w = d.waste;
    if (!w.available) {
      return <pw.Widget>[_h1('3. Waste Collection Summary'), _unavailable('Waste collection data', w.reason)];
    }
    final Map<String, int> byDate = w.byDate;
    return <pw.Widget>[
      _h1('3. Waste Collection Summary'),
      if (w.partial)
        _note('Some collection sources could not be reached; totals may be incomplete.', warning: true),
      _table(
        <String>['Measure', 'Value'],
        <List<String>>[
          <String>['Finalized FULL collection trips', '${w.trips}'],
          <String>[
            w.measuredCount == 0 ? 'Estimated waste (hypothetical)' : 'Waste (measured + hypothetical)',
            '${AnalyticsReportData.tons(w.totalKg)} tons',
          ],
          <String>[
            'Basis',
            '${AnalyticsReportData.tons(w.perTripEstimateKg)} tons per FULL trip is an assumption, not a '
                'measured weight. ${w.measuredCount} trip(s) have a measured weight.'
          ],
          <String>['Unfinished trips (not counted)', '${w.ongoingUnfinished} ongoing, ${w.staleUnfinished} stale or legacy'],
        ],
        widths: <double>[3, 6],
      ),
      pw.SizedBox(height: 8),
      if (w.trips == 0)
        _note('No FULL collection trips were finalized in this period for the selected area.')
      else ...<pw.Widget>[
        if (byDate.length >= 2 && byDate.length <= 31)
          _keep(<pw.Widget>[
            _bars(
              'FULL trips per collection day (Asia/Manila)',
              byDate.entries.map((MapEntry<String, int> e) => MapEntry<String, double>(e.key, e.value.toDouble())).toList(),
              unit: ' trip(s)',
            ),
          ])
        else if (byDate.length > 31)
          _table(
            <String>['Date', 'FULL trips'],
            byDate.entries.map((MapEntry<String, int> e) => <String>[e.key, '${e.value}']).toList(),
            widths: <double>[3, 2],
            rightAligned: <int>{1},
          ),
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

  static List<pw.Widget> _loadHistory(AnalyticsReportData d) {
    final ReportWaste w = d.waste;
    if (!w.available || w.trips == 0) {
      return <pw.Widget>[
        _h1('4. Load History'),
        if (!w.available) _unavailable('Load history', w.reason) else _note('No finalized loads in this period.'),
      ];
    }
    final List<ReportLoadRow> shown = w.rows.take(maxLoadRows).toList();
    return <pw.Widget>[
      _h1('4. Load History'),
      _p('One row per collection trip (a trip id appears once). Loads are ordered newest first by the time '
          'the truck became FULL.', color: muted, size: 8.5),
      _table(
        <String>['FULL time', 'Trip', 'Driver', 'Truck', 'Estimated load', 'Basis', 'Status'],
        shown
            .map((ReportLoadRow r) => <String>[
                  _time(r.fullAtManila),
                  r.tripId,
                  r.driver.isEmpty ? '-' : r.driver,
                  r.truck.isEmpty ? '-' : r.truck,
                  '${AnalyticsReportData.tons(r.kg)} t',
                  r.measured ? 'Measured' : 'Estimate',
                  r.status,
                ])
            .toList(),
        widths: <double>[2.2, 2.6, 1.8, 1.2, 1.2, 1.2, 1.2],
      ),
      if (w.rows.length > shown.length)
        _p('Showing the newest ${shown.length} of ${w.rows.length} trips.', size: 8, color: muted),
    ];
  }

  static List<pw.Widget> _coverage(AnalyticsReportData d) {
    final ReportCoverage c = d.coverage;
    const String title = '5. Collection Visits per Area';
    if (!c.available) {
      return <pw.Widget>[_h1(title), _unavailable('Collection visits', c.reason)];
    }
    final String summary = '${c.areasVisited} of ${c.expectedAreas} collection area(s) had at least one verified '
        'visit (${c.totalVisits} visit(s) in total).';
    const String policy = 'A verified visit is one trip that recorded at least 3 accurate GPS fixes inside the area '
        'over at least 60 seconds while collecting (ACTIVE). Paused, full and completed travel is excluded, and each '
        'trip counts at most once per area. A visit does not prove that every household was serviced. There is no '
        'schedule data, so no completion rate is given.';
    return <pw.Widget>[
      if (c.rows.isEmpty) ...<pw.Widget>[
        _h1(title),
        _p(summary),
        _note('No collection areas are defined for this selection.'),
      ] else ...<pw.Widget>[
        _keep(<pw.Widget>[
          _h1(title),
          _p(summary),
          _p(policy, size: 8, color: muted),
          _bars(
            'Verified visits per area',
            c.rows.map((ReportCoverageRow r) => MapEntry<String, double>(r.area, r.visits.toDouble())).toList(),
            unit: '',
          ),
        ]),
        _table(
          <String>['Area', 'Verified visits', 'Passes not confirmed'],
          c.rows.map((ReportCoverageRow r) => <String>[r.area, '${r.visits}', '${r.unconfirmed}']).toList(),
          widths: <double>[4, 2.5, 2.5],
          rightAligned: <int>{1, 2},
        ),
        if (c.tripsWithoutEvidence > 0)
          _note('${c.tripsWithoutEvidence} trip(s) had no usable GPS points; their visits cannot be verified.'),
      ],
    ];
  }

  static List<pw.Widget> _eta(AnalyticsReportData d) {
    final ReportEta e = d.eta;
    if (!e.available) {
      return <pw.Widget>[_h1('6. ETA Performance'), _unavailable('ETA performance', e.reason)];
    }
    final List<ReportEtaRow> shown = e.rows.take(maxEtaRows).toList();
    return <pw.Widget>[
      _h1('6. ETA Performance'),
      _p('Each visit is one trip in one area. It is judged on its first notified ETA against the '
          'GPS-confirmed arrival of the same trip and area. Predicted times are never shown as actual arrivals.',
          size: 8.5, color: muted),
      _table(
        <String>['Measure', 'Value'],
        <List<String>>[
          <String>['Evaluated visits', '${e.evaluated}'],
          <String>['Average absolute error', e.avgAbsErrorMin == null ? 'Not available' : '${e.avgAbsErrorMin!.toStringAsFixed(1)} min'],
          <String>['Within +/-5 minutes', e.within5Pct == null ? 'Not available' : '${e.within5Pct}%'],
          <String>['Awaiting GPS-confirmed arrival', '${e.awaiting}'],
          <String>['No arrival recorded', '${e.noArrival}'],
          <String>['Withdrawn', '${e.withdrawn}'],
          <String>['Notification without an ETA', '${e.noEstimate}'],
        ],
        widths: <double>[4, 3],
      ),
      pw.SizedBox(height: 8),
      if (shown.isEmpty)
        _note('No ETA notifications were sent for this area and period.')
      else ...<pw.Widget>[
        _table(
          <String>['Area', 'Truck / Trip', 'Sent', 'ETA', 'Predicted', 'Actual (GPS)', 'Diff', 'Status'],
          shown
              .map((ReportEtaRow r) => <String>[
                    r.area,
                    '${r.truck.isEmpty ? '-' : r.truck}\n${r.tripId}',
                    _time(r.sentAt),
                    r.etaMinutes == null ? '-' : '${r.etaMinutes} min',
                    r.predictedAt == null ? '-' : _time(r.predictedAt!),
                    r.actualAt == null ? 'Awaiting GPS arrival' : _time(r.actualAt!),
                    r.signedErrorMin == null
                        ? '-'
                        : '${r.signedErrorMin! > 0 ? '+' : ''}${r.signedErrorMin!.toStringAsFixed(1)} min',
                    r.status,
                  ])
              .toList(),
          widths: <double>[1.7, 2.6, 1.5, 0.8, 1.5, 1.7, 1.0, 1.2],
        ),
        if (e.rows.length > shown.length)
          _p('Showing the newest ${shown.length} of ${e.rows.length} visits. Diff = actual - predicted '
              '(+ is late). "Awaiting GPS arrival" = no GPS-confirmed arrival recorded yet.', size: 8, color: muted)
        else
          _p('Diff = actual - predicted (+ is late). "Awaiting GPS arrival" = no GPS-confirmed arrival '
              'recorded yet.', size: 8, color: muted),
      ],
    ];
  }

  static List<pw.Widget> _complaints(AnalyticsReportData d) {
    final ReportComplaints c = d.complaints;
    if (!c.available) {
      return <pw.Widget>[_h1('7. Resident Complaints'), _unavailable('Complaint data', c.reason)];
    }
    return <pw.Widget>[
      if (c.total == 0) ...<pw.Widget>[
        _h1('7. Resident Complaints'),
        _note('No complaints were recorded for this period and area.'),
      ] else ...<pw.Widget>[
        _keep(<pw.Widget>[_h1('7. Resident Complaints'), _pie('Complaint status distribution', c.counts)]),
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

  static List<pw.Widget> _forecast(AnalyticsReportData d) {
    final ReportForecast f = d.forecast;
    return <pw.Widget>[
      _h1('8. Performance Forecasts'),
      if (!f.available)
        _note('Forecasting is unavailable: ${f.reason ?? 'there is not enough recorded data.'} '
            'No volume forecast or confidence figure is reported.')
      else ...<pw.Widget>[
        _table(
          <String>['Forecast', 'Value'],
          <List<String>>[
            <String>['Next collection day volume', '${AnalyticsReportData.tons(f.tomorrowKg)} tons'],
            <String>['Weekly volume projection', '${AnalyticsReportData.tons(f.weeklyKg)} tons'],
          ],
          widths: <double>[4, 3],
        ),
        _note('Method: a baseline from ${f.samples} recorded collection weight(s) combined with the number '
            'of stops per route. This is a projection, not a measurement, and no confidence percentage is '
            'claimed.'),
      ],
    ];
  }

  static List<pw.Widget> _insights(AnalyticsReportData d) {
    final String? ai = d.usableNarrative;
    return <pw.Widget>[
      _h1('9. Insights, Recommendations and Conclusion'),
      pw.Text('Observations', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: navy)),
      pw.SizedBox(height: 4),
      for (final String s in d.insights) _bullet(s),
      pw.SizedBox(height: 8),
      pw.Text('Follow-up', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: navy)),
      pw.SizedBox(height: 4),
      for (final String s in d.recommendations) _bullet(s),
      pw.SizedBox(height: 10),
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(color: tealLight, borderRadius: pw.BorderRadius.circular(6)),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: <pw.Widget>[
          pw.Text('Conclusion', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: navy)),
          pw.SizedBox(height: 4),
          pw.Text(d.conclusion, style: pw.TextStyle(fontSize: 9, color: ink, lineSpacing: 2)),
          if (ai != null) ...<pw.Widget>[
            pw.SizedBox(height: 6),
            pw.Text('AI-assisted summary: $ai', style: pw.TextStyle(fontSize: 8.5, color: muted, lineSpacing: 2)),
          ],
        ]),
      ),
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
