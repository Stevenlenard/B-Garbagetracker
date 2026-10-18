import 'dart:math' as math;

import '../models/driver_trip.dart';

/// Straight-line distance in metres between two coordinates.
double gpsDistanceM(double lat1, double lng1, double lat2, double lng2) {
  const double r = 6371000;
  final double dLat = (lat2 - lat1) * math.pi / 180;
  final double dLng = (lng2 - lng1) * math.pi / 180;
  final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// One GPS fix as it arrived on the device.
class FixSample {
  const FixSample(this.lat, this.lng, this.accuracyM, this.arrivedAt);
  final double lat;
  final double lng;
  final double accuracyM;
  final DateTime arrivedAt;
}

/// Chooses the trip's START point.
///
/// The first fix after login is often wrong even when it reports a good accuracy: phones hand back a
/// cached position from wherever they were last used (a start point 150 m from the truck, then a
/// "journey" that never happened). A start fix therefore has to be CONFIRMED by the fix that follows
/// it, and it is the better of the two that is kept. If no confirmation comes within [patience], the
/// most accurate fix seen is used, so a trip is never blocked by a quiet receiver.
class StartFixPicker {
  StartFixPicker._();

  static const double goodAccuracyM = 35;
  static const double maxAccuracyM = 100;
  static const double fallbackMaxAccuracyM = 1000; // after the patience time any usable fix beats no trip (laptop browsers)
  static const double baseAgreementM = 25;
  static const double driftAllowanceMps = 3;
  static const Duration patience = Duration(seconds: 20);

  /// Index in [fixes] of the fix to start from, or null to keep waiting.
  static int? pick(List<FixSample> fixes, {required DateTime now}) {
    for (int i = 0; i + 1 < fixes.length; i++) {
      final FixSample a = fixes[i], b = fixes[i + 1];
      if (a.accuracyM > maxAccuracyM || b.accuracyM > maxAccuracyM) continue;
      if (math.min(a.accuracyM, b.accuracyM) > goodAccuracyM) continue;
      final double dt = b.arrivedAt.difference(a.arrivedAt).inMilliseconds / 1000.0;
      final double allowed = math.max(baseAgreementM, a.accuracyM + b.accuracyM) + driftAllowanceMps * math.max(0, dt);
      if (gpsDistanceM(a.lat, a.lng, b.lat, b.lng) <= allowed) {
        return b.accuracyM <= a.accuracyM ? i + 1 : i;
      }
    }
    if (fixes.isEmpty || now.difference(fixes.first.arrivedAt) < patience) return null;
    int best = -1;
    for (int i = 0; i < fixes.length; i++) {
      if (fixes[i].accuracyM > fallbackMaxAccuracyM) continue;
      // Prefer the most recent fix among equally good ones: the truck may have moved since.
      if (best < 0 || fixes[i].accuracyM <= fixes[best].accuracyM) best = i;
    }
    return best < 0 ? null : best;
  }
}

enum RouteRecordKind {
  /// Not worth a route point.
  skip,

  /// The truck really moved: record the new position.
  moved,

  /// Standing still: record the SAME position again (timeline stays continuous, no scribble).
  heartbeat,
}

/// Decides which GPS fixes become route points (Strava-style).
///
/// Every fix still moves the live marker, but the recorded line only gains a point when the truck moved
/// further than the GPS noise: a phone standing still reports positions that wander 10-30 m and speeds of
/// several km/h, which drew star-shaped scribbles and inflated distance. While stationary one heartbeat
/// point per minute keeps the timeline continuous.
class RoutePointPolicy {
  RoutePointPolicy._();

  static const double minMoveM = 8;
  static const double noiseFactor = 0.75;
  static const double noiseCapM = 40;
  static const double poorAccuracyM = 50;
  static const int heartbeatSeconds = 60;
  static const int poorFixPatienceSeconds = 90;
  static const int minMovingIntervalSeconds = 2;
  static const double farEnoughToSkipIntervalM = 40;

  /// How far a fix must be from the last recorded point to count as movement.
  static double movementThresholdM(double accuracyM, double lastAccuracyM) =>
      math.max(minMoveM, noiseFactor * math.min(noiseCapM, math.max(accuracyM, lastAccuracyM)));

  static RouteRecordKind decide({
    required bool hasLastRecorded,
    required double distFromLastM,
    required double accuracyM,
    required double lastAccuracyM,
    required int secondsSinceLast,
  }) {
    if (!hasLastRecorded) return RouteRecordKind.moved;
    if (accuracyM > poorAccuracyM) {
      return secondsSinceLast >= poorFixPatienceSeconds ? RouteRecordKind.heartbeat : RouteRecordKind.skip;
    }
    if (distFromLastM >= movementThresholdM(accuracyM, lastAccuracyM) &&
        (secondsSinceLast >= minMovingIntervalSeconds || distFromLastM >= farEnoughToSkipIntervalM)) {
      return RouteRecordKind.moved;
    }
    if (secondsSinceLast >= heartbeatSeconds) return RouteRecordKind.heartbeat;
    return RouteRecordKind.skip;
  }
}

/// Collapses stationary GPS wander in an ALREADY RECORDED route, for display and statistics.
///
/// Points that stay within the noise radius of the last anchor keep their time but take the anchor's
/// position and a speed of 0, so stops keep their duration while the drawn line and the distance no
/// longer zig-zag. Real movement is untouched.
class RouteJitter {
  RouteJitter._();

  static List<GpsPoint> collapse(List<GpsPoint> points) {
    if (points.length < 2) return points;
    final List<GpsPoint> out = <GpsPoint>[];
    GpsPoint? anchor;
    for (final GpsPoint p in points) {
      if (anchor == null || p.isGapStart) {
        out.add(p);
        anchor = p;
        continue;
      }
      final double d = gpsDistanceM(anchor.latitude, anchor.longitude, p.latitude, p.longitude);
      if (d < RoutePointPolicy.movementThresholdM(p.accuracyM, anchor.accuracyM)) {
        out.add(p.copyWith(latitude: anchor.latitude, longitude: anchor.longitude, speedKmh: 0.0));
      } else {
        out.add(p);
        anchor = p;
      }
    }
    return out;
  }

  /// The same for raw Firebase route points (maps with `lat`/`lng`/`latitude`/`longitude`), already sorted by time.
  static List<Map> collapseMaps(List<Map> points) {
    if (points.length < 2) return points;
    double? num_(Object? v) => v is num ? v.toDouble() : double.tryParse('$v');
    final List<Map> out = <Map>[];
    double? aLat, aLng, aAcc;
    for (final Map p in points) {
      final double? lat = num_(p['lat'] ?? p['latitude']);
      final double? lng = num_(p['lng'] ?? p['longitude']);
      final double acc = num_(p['accuracy']) ?? 0;
      if (lat == null || lng == null) {
        out.add(p);
        continue;
      }
      if (aLat == null || aLng == null) {
        out.add(p);
        aLat = lat;
        aLng = lng;
        aAcc = acc;
        continue;
      }
      final double d = gpsDistanceM(aLat, aLng, lat, lng);
      if (d < RoutePointPolicy.movementThresholdM(acc, aAcc ?? 0)) {
        out.add(<dynamic, dynamic>{...p, 'lat': aLat, 'lng': aLng, 'latitude': aLat, 'longitude': aLng, 'speed': 0.0});
      } else {
        out.add(p);
        aLat = lat;
        aLng = lng;
        aAcc = acc;
      }
    }
    return out;
  }
}
