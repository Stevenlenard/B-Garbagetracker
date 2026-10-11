import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/driver_trip.dart';

// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

class RouteExportManager {
  /// Triggers a direct browser file download for Web builds.
  static void _downloadWebFile(List<int> bytes, String fileName, String mimeType) {
    if (kIsWeb) {
      try {
        final blob = html.Blob([bytes], mimeType);
        final url = html.Url.createObjectUrlFromBlob(blob);
        final anchor = html.AnchorElement(href: url)
          ..setAttribute("download", fileName)
          ..style.display = 'none';
        html.document.body?.children.add(anchor);
        anchor.click();
        html.document.body?.children.remove(anchor);
        html.Url.revokeObjectUrl(url);
      } catch (e) {
        debugPrint("[EXPORT MANAGER] Web Blob Download Error: $e");
      }
    }
  }

  /// Builds PDF Uint8List document bytes.
  static Future<Uint8List> _buildPdfDocument({
    required DriverTrip trip,
    required bool includeGpsLogAppendix,
  }) async {
    final pdf = pw.Document();

    final DateFormat dateFmt = DateFormat('MMM d, yyyy');
    final DateFormat timeFmt = DateFormat('h:mm:ss a');
    final DateFormat timeShortFmt = DateFormat('h:mm a');

    final DateTime reportGenTime = DateTime.now();

    // Deriving start and end times directly from GPS bounds if points are available
    final DateTime tripStartTime = trip.points.isNotEmpty ? trip.points.first.timestamp : trip.startTime;
    final DateTime tripEndTime = trip.points.isNotEmpty ? trip.points.last.timestamp : (trip.endTime ?? trip.startTime);

    final String tripTimeRangeStr = trip.endTime != null || trip.points.isNotEmpty
        ? "${timeFmt.format(tripStartTime)} - ${timeFmt.format(tripEndTime)}"
        : "${timeShortFmt.format(tripStartTime)} - In Progress";

    final String reportGenStr = "${dateFmt.format(reportGenTime)} ${timeShortFmt.format(reportGenTime)} (Asia/Manila)";

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (pw.Context context) {
          return [
            // Header
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      "GIS ROUTE HISTORY REPORT",
                      style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold, color: PdfColors.teal800),
                    ),
                    pw.Text(
                      "Gbage Tracker | Waste Collection Telemetry Log",
                      style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
                    ),
                  ],
                ),
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: pw.BoxDecoration(
                    color: trip.routeStatus == 'COMPLETED' ? PdfColors.green100 : PdfColors.orange100,
                    borderRadius: pw.BorderRadius.circular(6),
                  ),
                  child: pw.Text(
                    trip.routeStatus,
                    style: pw.TextStyle(
                      fontSize: 10,
                      fontWeight: pw.FontWeight.bold,
                      color: trip.routeStatus == 'COMPLETED' ? PdfColors.green900 : PdfColors.orange900,
                    ),
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 12),
            pw.Divider(thickness: 1, color: PdfColors.grey300),
            pw.SizedBox(height: 8),

            // Driver & Trip Metadata Box
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                borderRadius: pw.BorderRadius.circular(8),
              ),
              child: pw.Column(
                children: [
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text("Driver: ${trip.driverName}", style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
                          pw.SizedBox(height: 3),
                          pw.Text("Truck ID: ${trip.truckId}", style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey800)),
                          pw.SizedBox(height: 3),
                          pw.Text("Visited Areas: ${trip.visitedAreas.isNotEmpty ? trip.visitedAreas.join(', ') : trip.routeName}", style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey800)),
                        ],
                      ),
                      pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.end,
                        children: [
                          pw.Text("Trip ID: ${trip.tripNumber}", style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: PdfColors.teal800)),
                          pw.SizedBox(height: 3),
                          pw.Text("Trip Date: ${dateFmt.format(tripStartTime)}", style: const pw.TextStyle(fontSize: 9.5, color: PdfColors.grey800)),
                          pw.SizedBox(height: 3),
                          pw.Text("Trip Recorded Bounds: $tripTimeRangeStr", style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold, color: PdfColors.grey900)),
                        ],
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 8),
                  pw.Divider(thickness: 0.5, color: PdfColors.grey300),
                  pw.SizedBox(height: 4),
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text("Report Generated: $reportGenStr", style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700)),
                      pw.Text("Timezone: Asia/Manila (UTC+8)", style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700)),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 14),

            // Summary Metrics Grid
            pw.Text("Trip Performance Summary", style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.grey900)),
            pw.SizedBox(height: 6),
            pw.Row(
              children: [
                _buildPdfMetricTile("Distance Traveled", "${trip.totalDistanceKm.toStringAsFixed(1)} km"),
                pw.SizedBox(width: 8),
                _buildPdfMetricTile("Moving Time", "${(trip.movingTimeSeconds / 60).toStringAsFixed(0)} min"),
                pw.SizedBox(width: 8),
                _buildPdfMetricTile("Stationary Time", "${(trip.stoppedTimeSeconds / 60).toStringAsFixed(0)} min"),
                pw.SizedBox(width: 8),
                _buildPdfMetricTile("Possible Stops", "${trip.detectedStopsCount}"),
              ],
            ),
            pw.SizedBox(height: 16),

            // Activity Timeline Section
            pw.Text("Activity Timeline Events", style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.grey900)),
            pw.SizedBox(height: 6),
            pw.Table.fromTextArray(
              headers: ["Time (Asia/Manila)", "Event / Operational State", "Location Coordinates"],
              data: trip.events.map((evt) {
                final String cleanDesc = evt.description.replaceAll('•', '-').replaceAll('–', '-');
                final String coords = (evt.latitude != null && evt.longitude != null)
                    ? "${evt.latitude!.toStringAsFixed(5)}, ${evt.longitude!.toStringAsFixed(5)}"
                    : "Recorded";
                return [timeFmt.format(evt.timestamp), cleanDesc, coords];
              }).toList(),
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 8.5),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.teal800),
              rowDecoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5))),
              cellStyle: const pw.TextStyle(fontSize: 8),
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            ),
            pw.SizedBox(height: 12),

            // Disclaimer Notice
            pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                color: PdfColors.amber50,
                border: pw.Border.all(color: PdfColors.amber300),
                borderRadius: pw.BorderRadius.circular(6),
              ),
              child: pw.Text(
                "Note: GPS-detected stops indicate stationary vehicle duration and location tracking, but do not independently confirm waste collection without operator log confirmation.",
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey800),
              ),
            ),

            // Appendix Section (If Checked)
            if (includeGpsLogAppendix && trip.points.isNotEmpty) ...[
              pw.NewPage(),
              pw.Text("GPS Observation Log Appendix", style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColors.teal800)),
              pw.SizedBox(height: 4),
              pw.Text(
                "Chronological recorded GPS observations for Trip ${trip.tripNumber} (${dateFmt.format(tripStartTime)}). Timezone: Asia/Manila.",
                style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700),
              ),
              pw.SizedBox(height: 10),
              pw.Table.fromTextArray(
                headerCount: 1,
                columnWidths: {
                  0: const pw.FixedColumnWidth(25),
                  1: const pw.FixedColumnWidth(85),
                  2: const pw.FixedColumnWidth(75),
                  3: const pw.FixedColumnWidth(75),
                  4: const pw.FixedColumnWidth(55),
                  5: const pw.FixedColumnWidth(65),
                  6: const pw.FixedColumnWidth(50),
                },
                headers: ["#", "Timestamp", "Latitude", "Longitude", "Accuracy", "Speed", "Status"],
                data: trip.points.asMap().entries.map((entry) {
                  final idx = entry.key + 1;
                  final p = entry.value;
                  return [
                    "$idx",
                    timeFmt.format(p.timestamp),
                    p.latitude.toStringAsFixed(6),
                    p.longitude.toStringAsFixed(6),
                    p.accuracyM > 0 ? "${p.accuracyM.toStringAsFixed(1)} m" : "Not recorded",
                    "${p.speedKmh.toStringAsFixed(1)} km/h",
                    p.status,
                  ];
                }).toList(),
                headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 8),
                headerDecoration: const pw.BoxDecoration(color: PdfColors.teal900),
                rowDecoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey200, width: 0.5))),
                cellStyle: const pw.TextStyle(fontSize: 7.5),
                cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
              ),
            ],
          ];
        },
      ),
    );

    return pdf.save();
  }

  /// Directly downloads PDF file to user's Downloads folder without opening printer dialog.
  static Future<void> downloadPdfReport({
    required DriverTrip trip,
    required bool includeGpsLogAppendix,
  }) async {
    try {
      final pdfBytes = await _buildPdfDocument(trip: trip, includeGpsLogAppendix: includeGpsLogAppendix);
      final String safeDate = DateFormat('yyyyMMdd').format(trip.startTime);
      final String fileName = "GIS_Route_Report_${trip.truckId.replaceAll(' ', '_')}_$safeDate.pdf";

      if (kIsWeb) {
        _downloadWebFile(pdfBytes, fileName, "application/pdf");
      } else {
        await Printing.sharePdf(bytes: pdfBytes, filename: fileName);
      }
    } catch (e) {
      debugPrint("[EXPORT MANAGER] PDF Direct Download error: $e");
    }
  }

  /// Opens the system print dialog.
  static Future<void> printPdfReport({
    required DriverTrip trip,
    required bool includeGpsLogAppendix,
  }) async {
    try {
      final pdfBytes = await _buildPdfDocument(trip: trip, includeGpsLogAppendix: includeGpsLogAppendix);
      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => pdfBytes,
        name: 'GIS_Route_Report_${trip.truckId}',
      );
    } catch (e) {
      debugPrint("[EXPORT MANAGER] PDF Print error: $e");
    }
  }

  static pw.Widget _buildPdfMetricTile(String title, String value) {
    return pw.Expanded(
      child: pw.Container(
        padding: const pw.EdgeInsets.all(8),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey300),
          borderRadius: pw.BorderRadius.circular(6),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(value, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.teal800)),
            pw.SizedBox(height: 2),
            pw.Text(title, style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700)),
          ],
        ),
      ),
    );
  }

  /// Exports animated HTML5 Canvas route replay file with real CartoDB Voyager map tiles rendered behind the vehicle polyline.
  static Future<void> exportTripAnimatedGif(DriverTrip trip) async {
    final htmlBuffer = StringBuffer();
    final String safeDate = DateFormat('yyyy-MM-dd').format(trip.startTime);

    htmlBuffer.writeln('<!DOCTYPE html><html><head><meta charset="utf-8"/><title>GIS Animated Route Replay - ${trip.truckId}</title>');
    htmlBuffer.writeln('<style>');
    htmlBuffer.writeln('body{margin:0;padding:24px;background:#0d1117;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;color:#c9d1d9;font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;}');
    htmlBuffer.writeln('.card{background:#161b22;border:1px solid #30363d;border-radius:20px;padding:24px;box-shadow:0 20px 40px rgba(0,0,0,0.6);width:100%;max-width:860px;}');
    htmlBuffer.writeln('h2{margin:0 0 4px 0;color:#238636;font-size:22px;display:flex;align-items:center;gap:10px;}');
    htmlBuffer.writeln('.sub{color:#8b949e;font-size:13px;margin-bottom:18px;}');
    htmlBuffer.writeln('.metrics{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-bottom:18px;}');
    htmlBuffer.writeln('.tile{background:#21262d;padding:12px;border-radius:12px;border:1px solid #30363d;}');
    htmlBuffer.writeln('.tile-val{font-size:16px;font-weight:800;color:#58a6ff;}');
    htmlBuffer.writeln('.tile-lbl{font-size:11px;color:#8b949e;margin-top:2px;}');
    htmlBuffer.writeln('canvas{width:100%;height:460px;background:#1e293b;border-radius:14px;border:1px solid #30363d;}');
    htmlBuffer.writeln('</style></head><body>');
    htmlBuffer.writeln('<div class="card">');
    htmlBuffer.writeln('<h2>🚚 GIS Animated Route Replay — ${trip.truckId}</h2>');
    htmlBuffer.writeln('<div class="sub">Driver: <b>${trip.driverName}</b> | Date: <b>$safeDate</b> | Status: <b style="color:#3fb950;">${trip.routeStatus}</b></div>');
    htmlBuffer.writeln('<div class="metrics">');
    htmlBuffer.writeln('<div class="tile"><div class="tile-val">${trip.totalDistanceKm.toStringAsFixed(1)} km</div><div class="tile-lbl">Distance</div></div>');
    htmlBuffer.writeln('<div class="tile"><div class="tile-val">${(trip.movingTimeSeconds/60).toStringAsFixed(0)} min</div><div class="tile-lbl">Moving Time</div></div>');
    htmlBuffer.writeln('<div class="tile"><div class="tile-val">${(trip.stoppedTimeSeconds/60).toStringAsFixed(0)} min</div><div class="tile-lbl">Stationary Time</div></div>');
    htmlBuffer.writeln('<div class="tile"><div class="tile-val">${trip.detectedStopsCount}</div><div class="tile-lbl">Possible Stops</div></div>');
    htmlBuffer.writeln('</div>');
    htmlBuffer.writeln('<canvas id="canvas" width="820" height="460"></canvas>');
    htmlBuffer.writeln('<script>');
    htmlBuffer.writeln('const points = ${jsonEncode(trip.points.map((p) => [p.longitude, p.latitude, DateFormat('h:mm:ss a').format(p.timestamp)]).toList())};');
    htmlBuffer.writeln('const canvas = document.getElementById("canvas"); const ctx = canvas.getContext("2d");');
    htmlBuffer.writeln('let idx = 0;');
    htmlBuffer.writeln('let minX=180, maxX=-180, minY=90, maxY=-90;');
    htmlBuffer.writeln('points.forEach(p => { minX=Math.min(minX,p[0]); maxX=Math.max(maxX,p[0]); minY=Math.min(minY,p[1]); maxY=Math.max(maxY,p[1]); });');

    // Mercator tile calculations for map background
    htmlBuffer.writeln('function lng2tile(lon, zoom) { return (lon + 180) / 360 * Math.pow(2, zoom); }');
    htmlBuffer.writeln('function lat2tile(lat, zoom) { return (1 - Math.log(Math.tan(lat * Math.PI / 180) + 1 / Math.cos(lat * Math.PI / 180)) / Math.PI) / 2 * Math.pow(2, zoom); }');
    htmlBuffer.writeln('const zoom = 14;');
    htmlBuffer.writeln('const minTx = Math.floor(lng2tile(minX, zoom));');
    htmlBuffer.writeln('const maxTx = Math.floor(lng2tile(maxX, zoom));');
    htmlBuffer.writeln('const minTy = Math.floor(lat2tile(maxY, zoom));');
    htmlBuffer.writeln('const maxTy = Math.floor(lat2tile(minY, zoom));');

    // Tile preloader
    htmlBuffer.writeln('const tiles = [];');
    htmlBuffer.writeln('for (let tx = minTx - 1; tx <= maxTx + 1; tx++) {');
    htmlBuffer.writeln('  for (let ty = minTy - 1; ty <= maxTy + 1; ty++) {');
    htmlBuffer.writeln('    const img = new Image();');
    htmlBuffer.writeln('    img.crossOrigin = "anonymous";');
    htmlBuffer.writeln('    img.src = "https://basemaps.cartocdn.com/rastertiles/voyager/" + zoom + "/" + tx + "/" + ty + ".png";');
    htmlBuffer.writeln('    tiles.push({ img, tx, ty });');
    htmlBuffer.writeln('  }');
    htmlBuffer.writeln('}');

    htmlBuffer.writeln('function toX(lng) { return 50 + (lng - minX) / (maxX - minX || 0.001) * 720; }');
    htmlBuffer.writeln('function toY(lat) { return 410 - (lat - minY) / (maxY - minY || 0.001) * 360; }');

    htmlBuffer.writeln('function draw() {');
    htmlBuffer.writeln('  ctx.clearRect(0, 0, 820, 460);');
    htmlBuffer.writeln('  ctx.fillStyle = "#1e293b"; ctx.fillRect(0, 0, 820, 460);');

    // Draw Map Tiles
    htmlBuffer.writeln('  tiles.forEach(t => {');
    htmlBuffer.writeln('    if (t.img.complete && t.img.naturalWidth !== 0) {');
    htmlBuffer.writeln('      const n = Math.pow(2, zoom);');
    htmlBuffer.writeln('      const lon1 = t.tx / n * 360 - 180;');
    htmlBuffer.writeln('      const lat1Rad = Math.atan(Math.sinh(Math.PI * (1 - 2 * t.ty / n)));');
    htmlBuffer.writeln('      const lat1 = lat1Rad * 180 / Math.PI;');
    htmlBuffer.writeln('      const lon2 = (t.tx + 1) / n * 360 - 180;');
    htmlBuffer.writeln('      const lat2Rad = Math.atan(Math.sinh(Math.PI * (1 - 2 * (t.ty + 1) / n)));');
    htmlBuffer.writeln('      const lat2 = lat2Rad * 180 / Math.PI;');
    htmlBuffer.writeln('      const x1 = toX(lon1), y1 = toY(lat1);');
    htmlBuffer.writeln('      const x2 = toX(lon2), y2 = toY(lat2);');
    htmlBuffer.writeln('      ctx.drawImage(t.img, x1, y1, x2 - x1, y2 - y1);');
    htmlBuffer.writeln('    }');
    htmlBuffer.writeln('  });');

    // Dark Map Overlay
    htmlBuffer.writeln('  ctx.fillStyle = "rgba(15, 23, 42, 0.22)";');
    htmlBuffer.writeln('  ctx.fillRect(0, 0, 820, 460);');

    htmlBuffer.writeln('  if (points.length < 2) {');
    htmlBuffer.writeln('    ctx.fillStyle = "#8b949e"; ctx.font = "14px system-ui"; ctx.fillText("Insufficient GPS points to animate route", 280, 230); return;');
    htmlBuffer.writeln('  }');

    // Full Planned Route Line
    htmlBuffer.writeln('  ctx.beginPath(); ctx.strokeStyle = "rgba(255, 255, 255, 0.4)"; ctx.lineWidth = 6; ctx.lineCap = "round";');
    htmlBuffer.writeln('  points.forEach((p, i) => { const x = toX(p[0]), y = toY(p[1]); if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y); }); ctx.stroke();');

    // Active Replay Segment
    htmlBuffer.writeln('  ctx.beginPath(); ctx.strokeStyle = "#10b981"; ctx.lineWidth = 7;');
    htmlBuffer.writeln('  for (let i = 0; i <= idx; i++) {');
    htmlBuffer.writeln('    const x = toX(points[i][0]), y = toY(points[i][1]);');
    htmlBuffer.writeln('    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);');
    htmlBuffer.writeln('  }');
    htmlBuffer.writeln('  ctx.stroke();');

    // Current Vehicle Marker
    htmlBuffer.writeln('  const cur = points[idx]; const cx = toX(cur[0]), cy = toY(cur[1]);');
    htmlBuffer.writeln('  ctx.beginPath(); ctx.arc(cx, cy, 11, 0, 2 * Math.PI); ctx.fillStyle = "#10b981"; ctx.fill(); ctx.lineWidth = 3; ctx.strokeStyle = "#ffffff"; ctx.stroke();');

    // Live HUD Banner
    htmlBuffer.writeln('  ctx.fillStyle = "rgba(15, 23, 42, 0.85)"; ctx.fillRect(12, 12, 340, 32);');
    htmlBuffer.writeln('  ctx.fillStyle = "#38bdf8"; ctx.font = "bold 13px system-ui";');
    htmlBuffer.writeln('  ctx.fillText("⏱ Time: " + cur[2] + " (" + (idx + 1) + "/" + points.length + " pts)", 20, 33);');

    htmlBuffer.writeln('  idx = (idx + 1) % points.length;');
    htmlBuffer.writeln('}');
    htmlBuffer.writeln('setInterval(draw, 100);');
    htmlBuffer.writeln('</script></div></body></html>');

    final String fileName = "GIS_Animated_Replay_${trip.truckId.replaceAll(' ', '_')}_${safeDate.replaceAll('-', '')}.html";
    final List<int> bytes = utf8.encode(htmlBuffer.toString());

    if (kIsWeb) {
      _downloadWebFile(bytes, fileName, "text/html");
    } else {
      final Uri uri = Uri.parse("data:text/html;charset=utf-8,${Uri.encodeComponent(htmlBuffer.toString())}");
      await launchUrl(uri);
    }
  }

  static Future<void> exportTripMp4Video(DriverTrip trip) async {
    await exportTripAnimatedGif(trip);
  }
}
