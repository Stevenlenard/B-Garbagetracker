import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

/// Base map styles used by every map in the app.
class MapStyles {
  MapStyles._();

  /// The default look of every map (Mapbox Standard, what MapWidget loads when no style is set).
  static const String map = MapboxStyles.STANDARD;

  /// Satellite imagery with roads and place names on top.
  static const String satellite = MapboxStyles.SATELLITE_STREETS;

  /// Switches [map] between the two styles. Custom layers (trucks, routes, purok markers) are
  /// removed by a style change; each screen redraws them in its style-loaded handler.
  static Future<void> apply(MapboxMap? map, {required bool satellite}) async {
    if (map == null) return;
    try {
      await map.style.setStyleURI(satellite ? MapStyles.satellite : MapStyles.map);
    } catch (e) {
      debugPrint('[MAP STYLE] switch failed: $e');
    }
  }
}

/// Compact "Map | Satellite" switch that floats over a map. Frosted pill, teal for the active
/// side; [compact] shows icons only (small dashboard maps, phones).
class MapStyleToggle extends StatelessWidget {
  const MapStyleToggle({super.key, required this.satellite, required this.onChanged, this.compact = false});

  final bool satellite;
  final ValueChanged<bool> onChanged;
  final bool compact;

  static const Color _teal = Color(0xFF00796B);

  @override
  Widget build(BuildContext context) {
    return PointerInterceptor(
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white),
          boxShadow: const [BoxShadow(color: Color(0x26000000), blurRadius: 14, offset: Offset(0, 4))],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _segment(icon: Icons.map_rounded, label: 'Map', active: !satellite, onTap: () => onChanged(false)),
          _segment(icon: Icons.satellite_alt_rounded, label: 'Satellite', active: satellite, onTap: () => onChanged(true)),
        ]),
      ),
    );
  }

  Widget _segment({required IconData icon, required String label, required bool active, required VoidCallback onTap}) {
    return Tooltip(
      message: compact ? label : '',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey<String>('map-style-$label'),
          borderRadius: BorderRadius.circular(11),
          onTap: active ? null : onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            padding: EdgeInsets.symmetric(horizontal: compact ? 9 : 12, vertical: compact ? 7 : 8),
            decoration: BoxDecoration(
              color: active ? _teal : Colors.transparent,
              borderRadius: BorderRadius.circular(11),
              boxShadow: active ? [BoxShadow(color: _teal.withValues(alpha: 0.3), blurRadius: 8, offset: const Offset(0, 3))] : null,
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: compact ? 17 : 16, color: active ? Colors.white : const Color(0xFF475569)),
              if (!compact) ...[
                const SizedBox(width: 6),
                Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: active ? Colors.white : const Color(0xFF475569))),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
