import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../config/mapbox_config.dart';
import '../models/driver_trip.dart';
import '../utils/gps_smoothing.dart';

/// A trip line snapped to the road network, aligned with the points it was made from.
class MatchedRoute {
  const MatchedRoute({required this.line, required this.vertexOfPoint, required this.matchedShare, required this.profiles});

  /// Line vertices as [lng, lat].
  final List<List<double>> line;

  /// For each input point (same order), the index in [line] where the truck was at that moment.
  /// Never decreases, so a replay moves forward along the road.
  final List<int> vertexOfPoint;

  /// Share of the input points that Mapbox placed on a road (0..1).
  final double matchedShare;

  /// Mapbox profiles used ("driving", and "walking" for stretches no road for cars fits).
  final Set<String> profiles;
}

/// Snaps finished trips to the roads with the Mapbox Map Matching API, for drawing only.
///
/// * The input is the smoothed display line ([DriverRouteHistoryService.smoothForDisplay]); stored
///   GPS points, distances, visits and analytics are never changed.
/// * Each 100-point chunk is matched with the `driving` profile; a chunk that mostly fails (a walk
///   on a footpath during a pilot test) is retried once with `walking`.
/// * Stretches Mapbox cannot place on a road keep their GPS positions, so nothing is hidden.
/// * A finished trip is matched once: the result is stored with the trip
///   (`driver_routes/{trip}/matched_route`) and reused by every device.
/// * Every request first takes one unit of the server's monthly budget (`backend/mapbox_quota.php`,
///   [monthlyLimit] for all devices together); when the budget is used up or cannot be checked,
///   nothing is sent and the smoothed GPS line is drawn.
class MapMatchingService {
  MapMatchingService._();

  static const int cacheVersion = 3;

  /// Mapbox Map Matching requests allowed per calendar month (UTC) for all devices together.
  /// Enforced by the server (`backend/mapbox_quota.php`); shown here for reference.
  static const int monthlyLimit = 50000;

  /// A matching Mapbox itself rates below this is not trusted (its GPS positions are drawn).
  static const double minConfidence = 0.05;

  /// A chunk with fewer of its points on accepted roads than this is retried as a walk.
  static const double retryWalkingBelow = 0.6;

  /// Below this share of matched points the whole result is discarded (smoothed GPS is drawn).
  static const double minUsefulShare = 0.3;

  /// A trip whose drawn line is shorter than this (metres) stood still: it is not matched, so GPS
  /// jitter around a house is never turned into a drive along the nearest street.
  static const double minTravelM = 150;

  static final Map<String, MatchedRoute?> _memory = <String, MatchedRoute?>{};
  static final Map<String, Future<MatchedRoute?>> _inFlight = <String, Future<MatchedRoute?>>{};
  static Dio _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 20)));

  @visibleForTesting
  static set debugDio(Dio dio) => _dio = dio;

  /// Test hook replacing the server budget check.
  @visibleForTesting
  static Future<bool> Function()? debugMonthlyBudget;

  /// True when the server granted one request from this month's shared budget.
  static Future<bool> _takeMonthlyBudget() async {
    final Future<bool> Function()? hook = debugMonthlyBudget;
    if (hook != null) return hook();
    try {
      final Response<dynamic> res = await ApiClient.instance.post<dynamic>('mapbox_quota.php',
          data: <String, dynamic>{'service': 'map_matching', 'count': 1});
      final Object? d = res.data;
      final bool allowed = d is Map && d['allowed'] == true;
      if (!allowed) debugPrint('[MAP MATCHING] monthly budget refused: ${d is Map ? (d['message'] ?? '${d['used']}/${d['limit']}') : d}');
      return allowed;
    } catch (e) {
      debugPrint('[MAP MATCHING] monthly budget check failed, not sending: $e');
      return false;
    }
  }

  @visibleForTesting
  static void debugClear() {
    _memory.clear();
    _inFlight.clear();
    debugMonthlyBudget = null;
  }

  static bool get isAvailable => MapboxRequestGuard.isEnabled(MapboxService.mapMatching) && MapboxRequestGuard.accessToken.isNotEmpty;

  /// Identifies the exact point list a result belongs to (a trip still recording gets new points).
  static String signature(List<GpsPoint> points) => points.isEmpty
      ? '0'
      : '${points.length}:${points.first.timestamp.millisecondsSinceEpoch}:${points.last.timestamp.millisecondsSinceEpoch}';

  /// Road-snapped line for [points] (the trip's display points), or null when matching is off,
  /// fails or fits too little of the trip. [finished] trips are cached with the trip.
  static Future<MatchedRoute?> forTrip(String tripId, List<GpsPoint> points, {required bool finished}) {
    if (points.length < 2 || !isAvailable || travelledM(points) < minTravelM) return Future<MatchedRoute?>.value(null);
    final String key = '$tripId|${signature(points)}';
    if (_memory.containsKey(key)) return Future<MatchedRoute?>.value(_memory[key]);
    return _inFlight.putIfAbsent(key, () async {
      try {
        MatchedRoute? result = finished ? await _readCache(tripId, points) : null;
        if (result == null) {
          result = await match(points);
          if (result != null && finished) await _writeCache(tripId, points, result);
        }
        _memory[key] = result;
        return result;
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  /// Length of the line through [points] in metres.
  static double travelledM(List<GpsPoint> points) {
    double d = 0;
    for (int i = 1; i < points.length; i++) {
      d += GpsSmoothing.distanceM(points[i - 1].latitude, points[i - 1].longitude, points[i].latitude, points[i].longitude);
    }
    return d;
  }

  /// Matches [points] (no cache). Null when a request is refused or fails, or too little matched.
  static Future<MatchedRoute?> match(List<GpsPoint> points) async {
    const int size = MapboxConfig.maxMapMatchingCoordinates;
    final List<_Chunk> chunks = <_Chunk>[];
    for (int start = 0; start < points.length - 1; start += size - 1) {
      final List<GpsPoint> part = points.sublist(start, math.min(points.length, start + size));
      _Chunk? best = await _request(part, start, 'driving');
      if (best == null) return null;
      if (best.share < retryWalkingBelow) {
        final _Chunk? walk = await _request(part, start, 'walking');
        if (walk != null && walk.share > best.share) best = walk;
      }
      chunks.add(best);
    }
    return _assemble(points, chunks);
  }

  static Future<_Chunk?> _request(List<GpsPoint> part, int offset, String profile) async {
    final String? blocked = MapboxRequestGuard.acquire(MapboxService.mapMatching, coordinates: part.length);
    if (blocked != null) return null;
    if (!await _takeMonthlyBudget()) return null;
    final String coords = part.map((p) => '${p.longitude.toStringAsFixed(6)},${p.latitude.toStringAsFixed(6)}').join(';');
    final String radiuses = part.map((p) => (p.accuracyM * 1.5).clamp(10.0, 50.0).round().toString()).join(';');
    final String timestamps = part.map((p) => (p.timestamp.millisecondsSinceEpoch ~/ 1000).toString()).join(';');
    try {
      final Response<dynamic> res = await _dio.get<dynamic>(
        'https://api.mapbox.com/matching/v5/mapbox/$profile/$coords',
        queryParameters: <String, dynamic>{
          'geometries': 'geojson',
          'overview': 'full',
          'tidy': 'true',
          'radiuses': radiuses,
          'timestamps': timestamps,
          'access_token': MapboxRequestGuard.accessToken,
        },
      );
      final Object? data = res.data;
      if (data is! Map) return null;
      // A stretch no road fits is an answer, not a failure: it keeps its GPS positions.
      if (data['code'] != 'Ok') return _Chunk.parse(const <String, Object?>{}, offset, part.length, profile);
      return _Chunk.parse(data, offset, part.length, profile);
    } on DioException catch (e) {
      // Mapbox answers 422 with code NoMatch / NoSegment for stretches it cannot place on a road.
      final Object? body = e.response?.data;
      if (body is Map && (body['code'] == 'NoMatch' || body['code'] == 'NoSegment')) {
        return _Chunk.parse(const <String, Object?>{}, offset, part.length, profile);
      }
      debugPrint('[MAP MATCHING] $profile request failed: $e');
      return null;
    } catch (e) {
      debugPrint('[MAP MATCHING] $profile request failed: $e');
      return null;
    }
  }

  /// Joins the chunk results into one line plus the line position of every input point.
  static MatchedRoute? _assemble(List<GpsPoint> points, List<_Chunk> chunks) {
    final List<List<double>> line = <List<double>>[];
    final List<int> vertexOf = List<int>.filled(points.length, -1);
    int matched = 0;
    final Set<String> profiles = <String>{};

    void addVertex(List<double> c) {
      if (line.isNotEmpty && line.last[0] == c[0] && line.last[1] == c[1]) return;
      line.add(c);
    }

    for (int ci = 0; ci < chunks.length; ci++) {
      final _Chunk ch = chunks[ci];
      final Map<int, int> base = <int, int>{}; // matching index -> first vertex in [line]
      int? openMatching;
      for (int j = ci == 0 ? 0 : 1; j < ch.tracepoints.length; j++) {
        final int pi = ch.offset + j;
        final int prev = pi > 0 ? vertexOf[pi - 1] : -1;
        final _Trace? t = ch.tracepoints[j];
        final _Matching? m = t == null ? null : ch.accepted[t.matching];
        if (t == null || m == null) {
          if (openMatching != null && j < ch.lastPointOf[openMatching]!) {
            vertexOf[pi] = math.max(prev, 0); // dropped noise inside a matched stretch: stay on the road
          } else {
            openMatching = null;
            addVertex(<double>[points[pi].longitude, points[pi].latitude]);
            vertexOf[pi] = line.length - 1;
          }
          continue;
        }
        if (!base.containsKey(t.matching)) {
          if (line.isNotEmpty) {
            final List<double> first = m.coords.first;
            if (line.last[0] == first[0] && line.last[1] == first[1]) line.removeLast();
          }
          base[t.matching] = line.length;
          line.addAll(m.coords);
          profiles.add(ch.profile);
        }
        openMatching = t.matching;
        final int v = base[t.matching]! + m.vertexAtDistance(m.distanceToWaypoint(t.waypoint));
        vertexOf[pi] = math.max(prev, math.min(v, line.length - 1));
        matched++;
      }
    }
    if (line.length < 2 || points.isEmpty) return null;
    for (int i = 0; i < vertexOf.length; i++) {
      if (vertexOf[i] < 0) vertexOf[i] = i == 0 ? 0 : vertexOf[i - 1];
    }
    final double share = matched / points.length;
    if (share < minUsefulShare) return null;
    return MatchedRoute(line: line, vertexOfPoint: vertexOf, matchedShare: share, profiles: profiles);
  }

  static Future<MatchedRoute?> _readCache(String tripId, List<GpsPoint> points) async {
    try {
      final DataSnapshot snap = await FirebaseDatabase.instance.ref('driver_routes/$tripId/matched_route').get();
      final Object? v = snap.value;
      if (v is! Map || v['v'] != cacheVersion || v['sig'] != signature(points)) return null;
      final List<List<double>> line = decodePolyline(v['line'].toString());
      final List<int> idx = v['idx'].toString().split(',').map((s) => int.tryParse(s) ?? 0).toList();
      if (line.length < 2 || idx.length != points.length) return null;
      return MatchedRoute(
        line: line,
        vertexOfPoint: idx.map((i) => i.clamp(0, line.length - 1)).toList(),
        matchedShare: (v['share'] as num?)?.toDouble() ?? 1,
        profiles: v['profiles'].toString().split(',').where((s) => s.isNotEmpty).toSet(),
      );
    } catch (e) {
      debugPrint('[MAP MATCHING] cache read failed: $e');
      return null;
    }
  }

  static Future<void> _writeCache(String tripId, List<GpsPoint> points, MatchedRoute r) async {
    try {
      await FirebaseDatabase.instance.ref('driver_routes/$tripId/matched_route').set(<String, Object>{
        'v': cacheVersion,
        'sig': signature(points),
        'line': encodePolyline(r.line),
        'idx': r.vertexOfPoint.join(','),
        'share': double.parse(r.matchedShare.toStringAsFixed(3)),
        'profiles': r.profiles.join(','),
        'at': ServerValue.timestamp,
      });
    } catch (e) {
      debugPrint('[MAP MATCHING] cache write failed (kept in memory): $e');
    }
  }

  /// Google polyline encoding, precision 6 (compact storage of [lng, lat] lines). Written with plain
  /// arithmetic instead of bit operators: on the Web those work on unsigned 32-bit values, which turned
  /// negative steps into huge numbers (a line shooting off the map).
  static String encodePolyline(List<List<double>> coords) {
    final StringBuffer out = StringBuffer();
    int lastLat = 0, lastLng = 0;
    void enc(int v) {
      int x = v < 0 ? -v * 2 - 1 : v * 2;
      while (x >= 32) {
        out.writeCharCode(32 + x % 32 + 63);
        x = x ~/ 32;
      }
      out.writeCharCode(x + 63);
    }

    for (final List<double> c in coords) {
      final int lat = (c[1] * 1e6).round(), lng = (c[0] * 1e6).round();
      enc(lat - lastLat);
      enc(lng - lastLng);
      lastLat = lat;
      lastLng = lng;
    }
    return out.toString();
  }

  static List<List<double>> decodePolyline(String s) {
    final List<List<double>> out = <List<double>>[];
    int i = 0, lat = 0, lng = 0;
    int dec() {
      int result = 0, mult = 1, b;
      do {
        b = s.codeUnitAt(i++) - 63;
        result += (b % 32) * mult;
        mult *= 32;
      } while (b >= 32 && i < s.length);
      return result.isOdd ? -(result + 1) ~/ 2 : result ~/ 2;
    }

    while (i < s.length) {
      lat += dec();
      if (i >= s.length) break;
      lng += dec();
      out.add(<double>[lng / 1e6, lat / 1e6]);
    }
    return out;
  }
}

class _Trace {
  const _Trace(this.matching, this.waypoint);
  final int matching;
  final int waypoint;
}

class _Matching {
  _Matching(this.coords, this.legDistances) {
    _cum.add(0);
    for (int i = 1; i < coords.length; i++) {
      _cum.add(_cum.last + GpsSmoothing.distanceM(coords[i - 1][1], coords[i - 1][0], coords[i][1], coords[i][0]));
    }
  }

  final List<List<double>> coords;
  final List<double> legDistances;
  final List<double> _cum = <double>[];

  double distanceToWaypoint(int w) {
    double d = 0;
    for (int i = 0; i < w && i < legDistances.length; i++) {
      d += legDistances[i];
    }
    return d;
  }

  int vertexAtDistance(double d) {
    for (int i = 0; i < _cum.length; i++) {
      if (_cum[i] >= d - 0.5) return i;
    }
    return _cum.length - 1;
  }
}

class _Chunk {
  _Chunk(this.offset, this.profile, this.tracepoints, this.accepted, this.lastPointOf, this.share);

  final int offset;
  final String profile;
  final List<_Trace?> tracepoints;
  final Map<int, _Matching> accepted;
  final Map<int, int> lastPointOf; // matching index -> last chunk point index on it
  final double share;

  static _Chunk parse(Map data, int offset, int count, String profile) {
    final Map<int, _Matching> accepted = <int, _Matching>{};
    final List<dynamic> ms = (data['matchings'] as List?) ?? const <dynamic>[];
    for (int i = 0; i < ms.length; i++) {
      final Map m = ms[i] as Map;
      final double conf = (m['confidence'] as num?)?.toDouble() ?? 0;
      final List<dynamic> c = ((m['geometry'] as Map?)?['coordinates'] as List?) ?? const <dynamic>[];
      if (conf < MapMatchingService.minConfidence || c.length < 2) continue;
      final List<double> legs = ((m['legs'] as List?) ?? const <dynamic>[])
          .map((l) => ((l as Map)['distance'] as num?)?.toDouble() ?? 0)
          .toList();
      accepted[i] = _Matching(c.map((p) => <double>[(p[0] as num).toDouble(), (p[1] as num).toDouble()]).toList(), legs);
    }
    final List<dynamic> tps = (data['tracepoints'] as List?) ?? const <dynamic>[];
    final List<_Trace?> traces = <_Trace?>[];
    final Map<int, int> last = <int, int>{};
    int ok = 0;
    for (int j = 0; j < count; j++) {
      final Object? t = j < tps.length ? tps[j] : null;
      if (t is Map && t['matchings_index'] != null) {
        final _Trace tr = _Trace((t['matchings_index'] as num).toInt(), ((t['waypoint_index'] as num?) ?? 0).toInt());
        traces.add(tr);
        if (accepted.containsKey(tr.matching)) {
          ok++;
          last[tr.matching] = j;
        }
      } else {
        traces.add(null);
      }
    }
    return _Chunk(offset, profile, traces, accepted, last, count == 0 ? 0 : ok / count);
  }
}
