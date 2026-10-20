import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

/// Navigation-app look for route lines: a wide, light halo of the same colour under the solid line, so the path
/// reads clearly on both the map and the satellite style.
class RouteCasing {
  RouteCasing._();

  static String idFor(String lineLayerId) => '$lineLayerId-casing';

  /// Adds the halo under [lineLayerId] once. [color] is a hex string or a Mapbox expression (e.g. ["get", "truckColor"]);
  /// [width] is a number or an expression for the halo width.
  static Future<void> ensure(
    StyleManager style, {
    required String lineLayerId,
    required String sourceId,
    required Object color,
    Object width = 13.0,
  }) async {
    final String id = idFor(lineLayerId);
    if (!await style.styleLayerExists(lineLayerId)) return;
    if (!await style.styleLayerExists(id)) {
      await style.addLayer(
        LineLayer(
          id: id,
          sourceId: sourceId,
          lineWidth: 13.0,
          lineOpacity: 0.3,
          lineCap: LineCap.ROUND,
          lineJoin: LineJoin.ROUND,
        ),
        LayerPosition(below: lineLayerId),
      );
    }
    await style.setStyleLayerProperty(id, 'line-color', color);
    await style.setStyleLayerProperty(id, 'line-width', width);
  }
}
