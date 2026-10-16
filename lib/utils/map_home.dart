import 'dart:math' as math;

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

/// The maps' home view: Barangay Balintawak, Lipa City.
///
/// Every map asks to start here, but on some Android devices (e.g. right after installing) the
/// starting view is ignored and the map opens on the whole globe. [ensure] puts the camera back
/// on the barangay when it is zoomed out to region/globe level or far from Lipa; a view the user
/// or the app chose inside the barangay is never changed.
class MapHome {
  MapHome._();

  static const double lat = 13.9565;
  static const double lng = 121.1620;
  static const double defaultZoom = 14.2;

  static Position get center => Position(lng, lat);

  /// Zoomed out to region/globe level, or more than 40 km from the barangay.
  static bool needsHome(double zoom, double cameraLat, double cameraLng) => zoom < 9 || distanceKm(cameraLat, cameraLng, lat, lng) > 40;

  static double distanceKm(double lat1, double lng1, double lat2, double lng2) {
    const double r = 6371;
    final double dLat = (lat2 - lat1) * math.pi / 180;
    final double dLng = (lng2 - lng1) * math.pi / 180;
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * r * math.asin(math.min(1, math.sqrt(a)));
  }

  static Future<void> ensure(MapboxMap? map, {double zoom = defaultZoom}) async {
    if (map == null) return;
    try {
      final CameraState c = await map.getCameraState();
      final Position p = c.center.coordinates;
      if (needsHome(c.zoom, p.lat.toDouble(), p.lng.toDouble())) {
        await map.setCamera(CameraOptions(center: Point(coordinates: center), zoom: zoom));
      }
    } catch (_) {/* map not ready or disposed */}
  }
}
