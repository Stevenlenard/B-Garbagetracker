import 'dart:math' as math;

/// One rule set for turning persisted route points (`driver_routes/{trip}/route`)
/// into map lines. The Admin live map and the Resident live map both use it, so the
/// same collection always draws the same geometry.
///
/// Nothing is invented: only recorded points are drawn, in time order. Fewer than two
/// valid points means NO line (never a straight line between arbitrary endpoints).
class RouteGeometry {
  RouteGeometry._();

  /// Live-map policy (points with poorer accuracy are not drawn).
  static const double maxAccuracyM = 100.0;

  /// A pause longer than this, or a hop longer than [gapDistanceM], starts a new segment
  /// instead of drawing a line across the gap.
  static const double gapSeconds = 180.0;
  static const double gapDistanceM = 800.0;

  static int _ts(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) {
      return int.tryParse(v) ?? DateTime.tryParse(v)?.millisecondsSinceEpoch ?? 0;
    }
    return 0;
  }

  static double _num(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0.0;
  }

  /// Great-circle distance in metres.
  static double distanceM(double lat1, double lng1, double lat2, double lng2) {
    const double r = 6371000.0;
    final double dLat = (lat2 - lat1) * math.pi / 180.0;
    final double dLng = (lng2 - lng1) * math.pi / 180.0;
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) * math.cos(lat2 * math.pi / 180.0) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
  }

  static double _lat(Map p) => _num(p['latitude'] ?? p['lat']);
  static double _lng(Map p) => _num(p['longitude'] ?? p['lng']);

  /// Valid points in chronological order (outliers, duplicates and impossible jumps removed).
  static List<Map> cleanPoints(Iterable<Map> raw) {
    final List<Map> sorted = raw.toList()..sort((a, b) => _ts(a['timestamp']).compareTo(_ts(b['timestamp'])));
    final List<Map> valid = <Map>[];
    for (final Map p in sorted) {
      final double lat = _lat(p);
      final double lng = _lng(p);
      final double accuracy = _num(p['accuracy']);
      final int ts = _ts(p['timestamp']);

      if (lat < -90 || lat > 90 || lng < -180 || lng > 180 || (lat == 0 && lng == 0)) continue;
      if (accuracy > maxAccuracyM) continue;

      if (valid.isNotEmpty) {
        final Map prev = valid.last;
        final double d = distanceM(_lat(prev), _lng(prev), lat, lng);
        final int prevTs = _ts(prev['timestamp']);
        final double dtSec = (ts > 0 && prevTs > 0) ? (ts - prevTs) / 1000.0 : 0.0;

        if (d < 0.5) continue; // exact duplicate fix
        if (dtSec > 0) {
          final double kmh = (d / dtSec) * 3.6;
          if (kmh > 120.0 && d > 100.0) continue; // impossible jump
          if (d > 400.0 && dtSec < 10.0) continue; // sudden jump
        }
      }
      valid.add(p);
    }
    return valid;
  }

  /// GeoJSON LineString features (one per continuous, single-colour segment).
  /// Empty when fewer than two valid points exist.
  static List<Map<String, dynamic>> lineFeatures(Iterable<Map> raw) {
    final List<Map> pts = cleanPoints(raw);
    final List<Map<String, dynamic>> features = <Map<String, dynamic>>[];
    if (pts.length < 2) return features;

    void flush(List<List<double>> coords, String color) {
      if (coords.length >= 2) {
        features.add(<String, dynamic>{
          'type': 'Feature',
          'geometry': <String, dynamic>{'type': 'LineString', 'coordinates': List<List<double>>.from(coords)},
          'properties': <String, dynamic>{'color': color},
        });
      }
    }

    String colorOf(Map p) => (p['color'] ?? 'GREEN').toString().toUpperCase();

    List<List<double>> current = <List<double>>[
      <double>[_lng(pts.first), _lat(pts.first)]
    ];
    String currentColor = colorOf(pts.first);

    for (int i = 1; i < pts.length; i++) {
      final Map curr = pts[i];
      final Map prev = pts[i - 1];
      final double lat = _lat(curr);
      final double lng = _lng(curr);
      final String color = colorOf(curr);

      final double d = distanceM(_lat(prev), _lng(prev), lat, lng);
      final int cts = _ts(curr['timestamp']);
      final int pts0 = _ts(prev['timestamp']);
      final double dtSec = (cts > 0 && pts0 > 0) ? (cts - pts0) / 1000.0 : 0.0;
      final bool gap = dtSec > gapSeconds || d > gapDistanceM;

      if (gap) {
        flush(current, currentColor);
        currentColor = color;
        current = <List<double>>[<double>[lng, lat]];
      } else if (color != currentColor) {
        current.add(<double>[lng, lat]);
        flush(current, currentColor);
        currentColor = color;
        current = <List<double>>[<double>[lng, lat]];
      } else {
        current.add(<double>[lng, lat]);
      }
    }
    flush(current, currentColor);
    return features;
  }

  /// Why a historical route cannot be shown as a complete collection path, or null
  /// when it can. Used to label routes honestly instead of drawing guesses.
  static String? incompleteReason({
    required int validPointCount,
    required bool collectionFinalized,
    required double recordedDistanceKm,
  }) {
    if (validPointCount == 0) return 'No GPS points were recorded for this trip.';
    if (validPointCount == 1) return 'Only one GPS point was recorded; no route line can be drawn.';
    if (!collectionFinalized) return 'Collection not finalized (FULL not pressed): showing the points recorded so far.';
    if (recordedDistanceKm >= 0.5 && validPointCount < 5) {
      return 'Only $validPointCount GPS points were recorded for ${recordedDistanceKm.toStringAsFixed(1)} km: the route is incomplete.';
    }
    return null;
  }
}
