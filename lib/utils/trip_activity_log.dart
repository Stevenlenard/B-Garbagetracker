import 'dart:math' as math;

import 'collection_visits.dart';

/// One line of a truck's Activity Log.
class TripActivity {
  const TripActivity(this.title, this.ms, {this.full = false});

  final String title;
  final int ms;

  /// The truck was FULL at this moment (shown in the FULL colour).
  final bool full;
}

/// The Activity Log of a live trip, built from its recorded route points (route points carry no area name):
/// when the trip started, each collection area the truck entered (within the area circle), when it was marked
/// FULL, and where its latest position is. Newest first. Nothing is invented: no points, no entries.
class TripActivityLog {
  TripActivityLog._();

  static double _m(double lat1, double lng1, double lat2, double lng2) {
    const double r = 6371000.0;
    final double dLat = (lat2 - lat1) * math.pi / 180, dLng = (lng2 - lng1) * math.pi / 180;
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
  }

  static double? _num(Object? v) => v is num ? v.toDouble() : double.tryParse(v?.toString() ?? '');

  static int? _ms(Object? v) {
    final double? n = _num(v);
    if (n == null || n <= 0) return null;
    return n < 10000000000 ? (n * 1000).toInt() : n.toInt();
  }

  /// The area whose circle contains the point (nearest first), or null.
  static String? areaAt(double lat, double lng, List<AreaGeofence> areas) {
    String? best;
    double bestM = double.infinity;
    for (final AreaGeofence a in areas) {
      if (!a.isTruckStop) continue;
      final double m = _m(lat, lng, a.lat, a.lng);
      if (m <= a.radiusM && m < bestM) {
        best = a.name;
        bestM = m;
      }
    }
    return best;
  }

  static List<TripActivity> build(List<Map> points, List<AreaGeofence> areas, {int limit = 8}) {
    final List<({int ms, double lat, double lng, String status})> fixes = <({int ms, double lat, double lng, String status})>[];
    for (final Map p in points) {
      final double? lat = _num(p['lat'] ?? p['latitude']), lng = _num(p['lng'] ?? p['longitude']);
      final int? ms = _ms(p['timestamp']);
      if (lat == null || lng == null || ms == null || (lat == 0 && lng == 0)) continue;
      fixes.add((ms: ms, lat: lat, lng: lng, status: (p['status'] ?? '').toString().toUpperCase()));
    }
    if (fixes.isEmpty) return const <TripActivity>[];
    fixes.sort((a, b) => a.ms.compareTo(b.ms));

    final List<TripActivity> out = <TripActivity>[TripActivity('Trip started', fixes.first.ms)];
    String? inArea;
    bool full = false;
    for (final f in fixes) {
      if (!full && f.status == 'FULL') {
        full = true;
        out.add(TripActivity('Marked FULL (no more collection)', f.ms, full: true));
      }
      final String? a = areaAt(f.lat, f.lng, areas);
      if (a != null && a != inArea) out.add(TripActivity('Entered $a', f.ms, full: full));
      inArea = a;
    }
    final last = fixes.last;
    final String? lastArea = areaAt(last.lat, last.lng, areas);
    out.add(TripActivity(lastArea != null ? 'Latest position: in $lastArea' : 'Latest position: between areas', last.ms, full: full));
    return out.reversed.take(limit).toList();
  }
}
