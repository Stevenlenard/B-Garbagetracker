import 'dart:math' as math;

/// Did the truck PASS a collection area? Used for the weekly progress mark ("area covered"), which is separate
/// from a verified collection visit (that one still needs a dwell).
///
/// A pass is the travelled step (previous fix -> this fix) touching the area: within [radiusM] of the entrance point,
/// or of the whole road segment entrance -> end for highway-type areas. Using the step instead of single fixes means a
/// truck driving past at normal speed counts even when fixes are several seconds (tens of metres) apart.
class AreaPass {
  AreaPass._();

  /// A step longer than this, or older than [maxStepSeconds], is not trusted as a straight path (GPS outage).
  static const double maxStepM = 400;
  static const int maxStepSeconds = 120;
  static const double minRadiusM = 100; // the collection-area radius (AreaGeofence.areaRadiusM)

  static bool touches({
    required double lat,
    required double lng,
    double? prevLat,
    double? prevLng,
    int? stepSeconds,
    required double entranceLat,
    required double entranceLng,
    double? endLat,
    double? endLng,
    required double radiusM,
  }) {
    final double r = math.max(radiusM, minRadiusM);
    // local metre plane around the entrance
    final double kLat = 111320.0;
    final double kLng = 111320.0 * math.cos(entranceLat * math.pi / 180);
    double x(double lo) => (lo - entranceLng) * kLng;
    double y(double la) => (la - entranceLat) * kLat;

    final double ax = x(lng), ay = y(lat);
    double bx = ax, by = ay;
    if (prevLat != null && prevLng != null && stepSeconds != null && stepSeconds <= maxStepSeconds) {
      final double px = x(prevLng), py = y(prevLat);
      if (math.sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay)) <= maxStepM) {
        bx = px;
        by = py;
      }
    }
    final double ex = (endLat != null && endLng != null) ? x(endLng) : 0;
    final double ey = (endLat != null && endLng != null) ? y(endLat) : 0;
    return _segSegDist(ax, ay, bx, by, 0, 0, ex, ey) <= r;
  }

  static double _pointSeg(double px, double py, double ax, double ay, double bx, double by) {
    final double dx = bx - ax, dy = by - ay;
    final double l2 = dx * dx + dy * dy;
    double t = l2 == 0 ? 0 : ((px - ax) * dx + (py - ay) * dy) / l2;
    t = t.clamp(0.0, 1.0);
    final double cx = ax + t * dx, cy = ay + t * dy;
    return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
  }

  static bool _cross(double ax, double ay, double bx, double by, double cx, double cy, double dx, double dy) {
    double o(double px, double py, double qx, double qy, double rx, double ry) => (qx - px) * (ry - py) - (qy - py) * (rx - px);
    final double o1 = o(ax, ay, bx, by, cx, cy), o2 = o(ax, ay, bx, by, dx, dy);
    final double o3 = o(cx, cy, dx, dy, ax, ay), o4 = o(cx, cy, dx, dy, bx, by);
    return o1 * o2 < 0 && o3 * o4 < 0;
  }

  static double _segSegDist(double ax, double ay, double bx, double by, double cx, double cy, double dx, double dy) {
    if (_cross(ax, ay, bx, by, cx, cy, dx, dy)) return 0;
    return [
      _pointSeg(ax, ay, cx, cy, dx, dy),
      _pointSeg(bx, by, cx, cy, dx, dy),
      _pointSeg(cx, cy, ax, ay, bx, by),
      _pointSeg(dx, dy, ax, ay, bx, by),
    ].reduce(math.min);
  }
}
