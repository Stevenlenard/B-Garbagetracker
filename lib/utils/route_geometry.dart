import 'dart:math' as math;

import 'gps_smoothing.dart';

/// One rule set for turning persisted route points (`driver_routes/{trip}/route`)
/// into map lines. The Admin live map and the Resident live map both use it, so the
/// same collection always draws the same geometry.
///
/// Nothing is invented: lines follow the recorded points in time order (smoothed for display by
/// [GpsSmoothing]; the stored points are never changed). Fewer than two
/// valid points means NO line (never a straight line between arbitrary endpoints).
class RouteGeometry {
  RouteGeometry._();

  /// Live-map policy (points with poorer accuracy are not drawn).
  static const double maxAccuracyM = 100.0;

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
        if (p['live_tail'] == true) {
          valid.add(p); // the live position is already filtered by the driver app: never treated as a jump
          continue;
        }
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

  /// The recorded route with the truck's LIVE position appended as its last vertex, so the drawn line always
  /// reaches the marker instead of trailing behind it until the next route point is saved. Nothing is added when the
  /// live position is missing, (almost) the same as the last point, or implausibly far from it.
  static List<Map> withLiveTail(List<Map> points, double? lat, double? lng) {
    if (points.isEmpty || lat == null || lng == null || (lat == 0 && lng == 0)) return points;
    final Map last = points.reduce((a, b) => _ts(a['timestamp']) >= _ts(b['timestamp']) ? a : b);
    final double d = distanceM(_lat(last), _lng(last), lat, lng);
    if (d < 3 || d > 2000) return points;
    return <Map>[
      ...points,
      <String, Object?>{
        'lat': lat,
        'lng': lng,
        'timestamp': _ts(last['timestamp']) + 1000,
        'accuracy': 0,
        'status': last['status'],
        'color': last['color'],
        'live_tail': true,
      },
    ];
  }

  /// Colour of the part of a route driven while the truck is FULL (to the disposal site): the same red on every map.
  static const String fullHex = '#E53935';

  /// True for a stretch recorded while the truck was FULL (route point colour PINK / status FULL).
  static bool isFullStretch(Map<String, dynamic> feature) =>
      ((feature['properties'] as Map?)?['color'] ?? '').toString().toUpperCase() == 'PINK';

  /// GeoJSON LineString features (one per single-colour stretch; neighbouring stretches share their joint point).
  /// The line is NEVER cut: a pause or a GPS drop is drawn as a straight connection to the next recorded point.
  /// Empty when fewer than two valid points exist.
  static List<Map<String, dynamic>> lineFeatures(Iterable<Map> raw) {
    final List<Map> pts = smoothForDisplay(cleanPoints(raw));
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
      final double lat = _lat(curr);
      final double lng = _lng(curr);
      final String color = colorOf(curr);

      if (color != currentColor) {
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

  /// [cleanPoints] smoothed for drawing ([GpsSmoothing]: short out-and-back spikes removed, Kalman filter,
  /// then standing-still jitter dropped).
  /// Returns copies with smoothed coordinates; the first and last point, every colour change and the live
  /// tail (the marker position) are always kept, so stretches and the line end stay where they were.
  static List<Map> smoothForDisplay(List<Map> input) {
    if (input.length < 3) return input;
    final List<int> real = GpsSmoothing.withoutSpikes(_samples(input), keep: (int i) => input[i]['live_tail'] == true);
    final List<Map> pts = <Map>[for (final int i in real) input[i]];
    if (pts.length < 3) return pts;
    final List<GpsSample> samples = _samples(pts);
    final List<List<double>> smooth = GpsSmoothing.kalman(samples);
    String colorOf(int i) => (pts[i]['color'] ?? 'GREEN').toString().toUpperCase();
    final List<int> keep = GpsSmoothing.movingIndexes(samples, smooth,
        keep: (int i) => pts[i]['live_tail'] == true || colorOf(i) != colorOf(i - 1));
    return keep.map((int i) {
      final Map p = pts[i];
      if (p['live_tail'] == true) return p; // already the filtered live position: the line must end at the marker
      return <String, Object?>{...p.cast<String, Object?>(), 'lat': smooth[i][0], 'lng': smooth[i][1], 'latitude': smooth[i][0], 'longitude': smooth[i][1]};
    }).toList();
  }

  static List<GpsSample> _samples(List<Map> pts) => pts
      .map((Map p) => GpsSample(
            lat: _lat(p),
            lng: _lng(p),
            accuracyM: _num(p['accuracy']),
            timestampMs: _ts(p['timestamp']),
            speedMps: _num(p['speed']),
          ))
      .toList();

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
