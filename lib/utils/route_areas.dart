import 'collection_visits.dart';

/// Which puroks a recorded trip passed through, from its GPS fixes and the purok boundaries.
/// (Recorded trips do not store visited areas, so they are derived from the route itself.)
class RouteAreas {
  RouteAreas._();

  /// Long routes are sampled (at most [maxSamples] fixes) so the check stays cheap.
  static Set<String> passedThrough(List<List<double>> latLngs, List<AreaGeofence> areas, {int maxSamples = 400}) {
    final Set<String> found = <String>{};
    if (areas.isEmpty || latLngs.isEmpty) return found;
    final int step = latLngs.length > maxSamples ? (latLngs.length / maxSamples).ceil() : 1;
    for (int i = 0; i < latLngs.length && found.length < areas.length; i += step) {
      final List<double> p = latLngs[i];
      for (final AreaGeofence g in areas) {
        if (!found.contains(g.name) && g.contains(p[0], p[1])) found.add(g.name);
      }
    }
    return found;
  }
}
