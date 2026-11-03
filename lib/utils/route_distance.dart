import 'dart:math' as math;

import 'gps_quality.dart';
import 'route_geometry.dart';

/// Distance of a recorded route, measured from the stored points with the same rules every map draws them with.
///
/// The phone adds up distance while it records (`_distance`), and it cannot tell GPS wander from driving at that moment:
/// a phone left in a building for hours recorded 7.2 km on 3 Nov 2026 where the truck covered about 1.2 km. The figure that
/// is frozen when the driver presses FULL (and read by Load History, the Waste Collection Summary and Analytics) is
/// therefore measured again from the stored points once the trip is over: long stays and the wander around them are
/// collapsed ([RouteJitter]), bad fixes are dropped and the stretches joined as the maps join them ([RouteGeometry.cleanPoints]),
/// and the length of that line is summed. The phone's own figure stays on the record as `distance_km_device`.
class RouteDistance {
  RouteDistance._();

  /// The server must hold fixes this recent, or the stored route is not the whole route yet (points waiting on the
  /// phone) and measuring it would under-count.
  static const int maxLastFixAgeMs = 3 * 60 * 1000;

  static int _ts(Object? v) {
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}') ?? 0;
  }

  /// Length (km) of the stored [points] after stays, wander and bad fixes are removed. A move that cannot have happened
  /// (the truck was moved untracked) is not travel and is not counted.
  static double correctedKm(Iterable<Map> points) {
    final List<Map> sorted = points.where((Map p) => _ts(p['timestamp']) > 0).toList()
      ..sort((Map a, Map b) => _ts(a['timestamp']).compareTo(_ts(b['timestamp'])));
    if (sorted.length < 2) return 0;
    final List<Map> clean = RouteGeometry.cleanPoints(RouteJitter.collapseMaps(sorted));
    double m = 0;
    for (int i = 1; i < clean.length; i++) {
      if (clean[i][RouteGeometry.linkKey] == 'broken') continue;
      final Map a = clean[i - 1], b = clean[i];
      m += RouteGeometry.distanceM(
        _num(a['lat'] ?? a['latitude']),
        _num(a['lng'] ?? a['longitude']),
        _num(b['lat'] ?? b['latitude']),
        _num(b['lng'] ?? b['longitude']),
      );
    }
    return m / 1000.0;
  }

  static double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0.0;

  /// The distance to freeze: the corrected one, but never more than the phone's own (this can only remove false
  /// distance), and the phone's own when the stored route cannot be trusted to be complete.
  static double chooseKm({required double deviceKm, required double? correctedKm, required int fixes, required int? lastFixAgeMs}) {
    if (correctedKm == null || fixes < 2) return deviceKm;
    if (lastFixAgeMs == null || lastFixAgeMs < 0 || lastFixAgeMs > maxLastFixAgeMs) return deviceKm;
    return math.min(deviceKm, correctedKm);
  }
}
