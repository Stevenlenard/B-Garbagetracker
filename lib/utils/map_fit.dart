import 'dart:math' as math;

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

/// Camera helpers shared by the live maps.
class MapFit {
  MapFit._();

  /// Centre and zoom that show every given [lngLat] point (one point: a close street view).
  static CameraOptions camera(List<List<double>> lngLat, {double maxZoom = 17.0, double minZoom = 12.0}) {
    final double minLng = lngLat.map((p) => p[0]).reduce(math.min), maxLng = lngLat.map((p) => p[0]).reduce(math.max);
    final double minLat = lngLat.map((p) => p[1]).reduce(math.min), maxLat = lngLat.map((p) => p[1]).reduce(math.max);
    final double span = math.max(maxLng - minLng, maxLat - minLat);
    // ~1.2 zoom levels of margin around the trucks
    final double zoom = span < 1e-6 ? maxZoom : (math.log(360 / span) / math.ln2 - 1.2).clamp(minZoom, maxZoom).toDouble();
    return CameraOptions(center: Point(coordinates: Position((minLng + maxLng) / 2, (minLat + maxLat) / 2)), zoom: zoom);
  }

  /// Smooth follow step: glide the camera to the truck instead of jumping.
  static void glide(MapboxMap? map, double lat, double lng) {
    if (map == null || lat == 0 || lng == 0) return;
    map.easeTo(CameraOptions(center: Point(coordinates: Position(lng, lat))), MapAnimationOptions(duration: 900));
  }
}
