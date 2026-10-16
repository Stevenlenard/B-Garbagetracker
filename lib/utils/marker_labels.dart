import 'dart:math' as math;

import 'fleet_status.dart';

/// Marker identification for the live maps.
///
/// Every truck marker is labelled with its driver, its truck and its operational
/// status, so simultaneous trucks are never confused. Trucks that sit on (almost)
/// the same spot keep their TRUE coordinates; instead the first marker of the spot
/// carries one combined label listing every truck there.
class MarkerLabels {
  MarkerLabels._();

  /// Cell size in degrees (~5.5 m): trucks closer than this share one label.
  static const double overlapCellDeg = 0.00005;

  static String single({
    required String truckId,
    required String status,
    String? driverName,
    bool gpsDelayed = false,
  }) {
    final String name = (driverName ?? '').trim();
    // The truck id leads (readable at a glance); the driver follows when known.
    final String head = name.isEmpty || name.toLowerCase() == 'driver' ? truckId : '$truckId · $name';
    final String tail = gpsDelayed ? '${status.toUpperCase()} · GPS delayed' : status.toUpperCase();
    return '$head\n$tail';
  }

  /// Convenience for a live truck node.
  static String forNode(Map node, {required String truckId, int? nowMs}) => single(
        truckId: truckId,
        status: FleetStatus.normalizeStatus(node['status'], fallback: 'ACTIVE'),
        driverName: (node['driver_name'] ?? node['driverName'])?.toString(),
        gpsDelayed: !FleetStatus.isGpsFresh(node, nowMs: nowMs),
      );

  /// Merges labels of TRUCK point features that overlap. Coordinates are never
  /// changed. Features without a `label` property, or that are not points, are left
  /// untouched. Mutates and returns [features].
  static List<Map<String, dynamic>> mergeOverlapping(List<Map<String, dynamic>> features) {
    final Map<String, List<Map<String, dynamic>>> cells = <String, List<Map<String, dynamic>>>{};
    for (final Map<String, dynamic> f in features) {
      final Object? geom = f['geometry'];
      final Object? props = f['properties'];
      if (geom is! Map || props is! Map || props['label'] == null) continue;
      if (props['type'] != null && props['type'] != 'TRUCK') continue;
      final Object? c = geom['coordinates'];
      if (c is! List || c.length < 2 || c[0] is! num || c[1] is! num) continue;
      final String key =
          '${((c[0] as num) / overlapCellDeg).round()}:${((c[1] as num) / overlapCellDeg).round()}';
      cells.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(f);
    }
    for (final List<Map<String, dynamic>> group in cells.values) {
      if (group.length < 2) continue;
      group.sort((a, b) =>
          (a['properties']['truckId'] ?? '').toString().compareTo((b['properties']['truckId'] ?? '').toString()));
      final String combined = group.map((f) => f['properties']['label'].toString()).join('\n');
      for (int i = 0; i < group.length; i++) {
        final Map props = group[i]['properties'] as Map;
        props['label'] = i == 0 ? combined : '';
        // String on purpose: GeoJSON property maps are often inferred as Map<String, String>.
        props['overlap_count'] = '${group.length}';
        // Concentric rings (coordinates untouched): first truck outermost, later ones nested.
        final int radius = (15 - 4 * i) < 7 ? 7 : (15 - 4 * i);
        props['radius'] = '$radius';
        props['sortKey'] = '${100 - radius}';
        props['overlap_rank'] = '$i';
      }
    }
    return features;
  }

  /// Screen distance (px) under which two truck markers are treated as overlapping.
  static const double fanOverlapPx = 26;

  /// Distance (px) of each marker from the group's centre once fanned out.
  static const double fanRadiusPx = 16;

  /// Fans out TRUCK markers that would overlap on screen at [zoom]: each group is spread on a
  /// small circle (ordered by truck id, so positions are stable between updates) around the
  /// group's centre, so every truck stays visible and tappable. The first marker carries one
  /// combined label for the group. Display only: the true position is kept in `true_lng` /
  /// `true_lat` and the source records are never changed. Mutates and returns [features].
  static List<Map<String, dynamic>> fanOutOverlapping(List<Map<String, dynamic>> features, {required double zoom}) {
    final List<Map<String, dynamic>> trucks = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> f in features) {
      final Object? geom = f['geometry'];
      final Object? props = f['properties'];
      if (geom is! Map || props is! Map) continue;
      if (props['type'] != null && props['type'] != 'TRUCK') continue;
      final Object? c = geom['coordinates'];
      if (c is! List || c.length < 2 || c[0] is! num || c[1] is! num) continue;
      trucks.add(f);
    }
    if (trucks.length < 2) return features;

    double lngOf(Map<String, dynamic> f) => ((f['geometry']['coordinates'] as List)[0] as num).toDouble();
    double latOf(Map<String, dynamic> f) => ((f['geometry']['coordinates'] as List)[1] as num).toDouble();
    // Mapbox GL: world = 512 * 2^zoom px.
    double metersPerPx(double lat) => 78271.517 * math.cos(lat * math.pi / 180) / math.pow(2, zoom);

    // Union-find over pairs closer than fanOverlapPx on screen.
    final List<int> parent = List<int>.generate(trucks.length, (int i) => i);
    int find(int i) => parent[i] == i ? i : (parent[i] = find(parent[i]));
    for (int i = 0; i < trucks.length; i++) {
      for (int j = i + 1; j < trucks.length; j++) {
        final double lat = (latOf(trucks[i]) + latOf(trucks[j])) / 2;
        final double dy = (latOf(trucks[i]) - latOf(trucks[j])) * 111320;
        final double dx = (lngOf(trucks[i]) - lngOf(trucks[j])) * 111320 * math.cos(lat * math.pi / 180);
        if (math.sqrt(dx * dx + dy * dy) / metersPerPx(lat) < fanOverlapPx) parent[find(i)] = find(j);
      }
    }
    final Map<int, List<Map<String, dynamic>>> groups = <int, List<Map<String, dynamic>>>{};
    for (int i = 0; i < trucks.length; i++) {
      groups.putIfAbsent(find(i), () => <Map<String, dynamic>>[]).add(trucks[i]);
    }

    for (final List<Map<String, dynamic>> group in groups.values) {
      if (group.length < 2) continue;
      group.sort((a, b) =>
          (a['properties']['truckId'] ?? '').toString().compareTo((b['properties']['truckId'] ?? '').toString()));
      final double cLat = group.map(latOf).reduce((a, b) => a + b) / group.length;
      final double cLng = group.map(lngOf).reduce((a, b) => a + b) / group.length;
      final double rM = (fanRadiusPx + 3 * (group.length - 2)) * metersPerPx(cLat);
      final String combined = group
          .map((f) => (f['properties']['label'] ?? '').toString())
          .where((String l) => l.isNotEmpty)
          .join('\n');
      for (int i = 0; i < group.length; i++) {
        final Map<String, dynamic> f = group[i];
        final Map props = f['properties'] as Map;
        final double a = -math.pi / 2 + 2 * math.pi * i / group.length; // first one at the top
        final double lat = cLat + rM * math.sin(a) / 111320;
        final double lng = cLng + rM * math.cos(a) / (111320 * math.cos(cLat * math.pi / 180));
        // Strings on purpose: GeoJSON property maps are often inferred as Map<String, String>.
        props['true_lng'] = '${lngOf(f)}';
        props['true_lat'] = '${latOf(f)}';
        f['geometry'] = <String, dynamic>{'type': 'Point', 'coordinates': <double>[lng, lat]};
        if (props.containsKey('label')) props['label'] = i == 0 ? combined : '';
        props['overlap_count'] = '${group.length}';
        props['overlap_rank'] = '$i';
        props['fanned'] = 'true';
        props['radius'] = '10'; // side by side now: no nested rings needed
        props['sortKey'] = '90';
      }
    }
    return features;
  }
}
