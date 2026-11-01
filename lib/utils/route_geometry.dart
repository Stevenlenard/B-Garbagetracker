import 'dart:math' as math;

import 'gps_smoothing.dart';
import 'route_link.dart';

/// One rule set for turning persisted route points (`driver_routes/{trip}/route`)
/// into map lines. The Admin live map and the Resident live map both use it, so the
/// same collection always draws the same geometry.
///
/// Nothing is invented: lines follow the recorded points in time order (smoothed for display by
/// [GpsSmoothing]; the stored points are never changed). Fewer than two valid points means NO line (never a straight line
/// between arbitrary endpoints). How consecutive points connect is decided by [RouteLinkPolicy] (the same rules as the
/// saved Route History): one solid line while tracking is normal, a faint dashed link over a long recording gap, and a
/// new stretch only when the truck really was elsewhere; earlier route is never dropped.
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

  /// Property of a point that starts an [RouteLink.uncertain] / [RouteLink.broken] connection to the point before it.
  static const String linkKey = 'link';

  /// Valid points in chronological order. Unusable fixes and bad fixes that cannot be reached from the last good one are
  /// dropped (the line continues from the last good fix, so one wild fix never poisons what follows); points after a
  /// long recording gap or a real relocation carry [linkKey] = 'uncertain' / 'broken' (see [RouteLinkPolicy.link]).
  static List<Map> cleanPoints(Iterable<Map> raw) {
    final List<Map> sorted = raw.toList()..sort((a, b) => _ts(a['timestamp']).compareTo(_ts(b['timestamp'])));
    final List<Map> usable = <Map>[];
    for (final Map p in sorted) {
      final double lat = _lat(p);
      final double lng = _lng(p);
      if (lat < -90 || lat > 90 || lng < -180 || lng > 180 || (lat == 0 && lng == 0)) continue;
      if (_num(p['accuracy']) > maxAccuracyM) continue;
      usable.add(p);
    }
    final List<LinkedFix> linked = RouteLinkPolicy.link(
      <RouteFix>[for (final Map p in usable) RouteFix(_lat(p), _lng(p), _ts(p['timestamp']), _num(p['accuracy']))],
      exempt: (int i) => usable[i]['live_tail'] == true, // the live position is already filtered by the driver app
    );
    return <Map>[
      for (final LinkedFix l in linked)
        if (l.link == RouteLink.solid) usable[l.index] else <dynamic, dynamic>{...usable[l.index], linkKey: l.link.name},
    ];
  }

  /// Data-driven opacity for a route line layer: a connection over a recording gap is drawn fainter than the route.
  static List<Object> opacityExpr(double base) => <Object>[
        'case',
        <Object>['==', <Object>['get', linkKey], 'uncertain'],
        base * 0.4,
        base,
      ];

  /// The recorded route with the truck's LIVE position appended as its last vertex, so the drawn line always
  /// reaches the marker instead of trailing behind it until the next route point is saved. Nothing is added when the
  /// live position is missing, within GPS noise of the last point, or implausibly far from it.
  ///
  /// A parked truck's live fix wanders a few metres every update; drawing a tail to it made the line end
  /// zigzag and flicker. The tail is only drawn once the truck is clearly away from the last point:
  /// [liveTailMinM], or the live fix's [accuracyM] when that is larger (capped at [liveTailMaxNoiseM]).
  static const double liveTailMinM = 10.0;
  static const double liveTailMaxNoiseM = 30.0;

  static List<Map> withLiveTail(List<Map> points, double? lat, double? lng, {double? accuracyM}) {
    if (points.isEmpty || lat == null || lng == null || (lat == 0 && lng == 0)) return points;
    final Map last = points.reduce((a, b) => _ts(a['timestamp']) >= _ts(b['timestamp']) ? a : b);
    final double d = distanceM(_lat(last), _lng(last), lat, lng);
    final double noise = math.min(liveTailMaxNoiseM, math.max(liveTailMinM, accuracyM ?? 0));
    if (d < noise || d > 2000) return points;
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
  /// Normal tracking is one continuous line, also across a short GPS delay, a rejected fix or a reconnection. Over a long
  /// recording gap the earlier route stays and a 2-point connector feature (property `link` = 'uncertain') joins the two
  /// known points, no coordinate in between is made up; after a real relocation a new stretch starts with no connector.
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
      final Object? link = curr[linkKey];

      if (link == 'uncertain' || link == 'broken') {
        flush(current, currentColor);
        if (link == 'uncertain') {
          final Map prev = pts[i - 1];
          features.add(<String, dynamic>{
            'type': 'Feature',
            'geometry': <String, dynamic>{
              'type': 'LineString',
              'coordinates': <List<double>>[<double>[_lng(prev), _lat(prev)], <double>[lng, lat]],
            },
            'properties': <String, dynamic>{'color': currentColor, linkKey: 'uncertain'},
          });
        }
        currentColor = color;
        current = <List<double>>[<double>[lng, lat]];
        continue;
      }

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
    bool linked(Map p) => p['live_tail'] == true || p[linkKey] != null;
    final List<int> real = GpsSmoothing.withoutSpikes(_samples(input), keep: (int i) => linked(input[i]));
    final List<Map> pts = <Map>[for (final int i in real) input[i]];
    if (pts.length < 3) return pts;
    final List<GpsSample> samples = _samples(pts);
    final List<List<double>> smooth = GpsSmoothing.kalman(samples);
    String colorOf(int i) => (pts[i]['color'] ?? 'GREEN').toString().toUpperCase();
    final List<int> keep = GpsSmoothing.movingIndexes(samples, smooth,
        keep: (int i) => linked(pts[i]) || colorOf(i) != colorOf(i - 1));
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
