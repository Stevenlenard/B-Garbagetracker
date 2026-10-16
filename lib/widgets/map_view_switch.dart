import 'package:flutter/material.dart';

/// One option of a [MapViewSwitch].
class MapViewOption {
  const MapViewOption(this.label, this.icon, {this.color = const Color(0xFF00796B)});
  final String label;
  final IconData icon;
  final Color color;
}

/// Compact segmented switch between views of one map panel (the same pill as the Admin
/// Fleet GIS "Live | History" switch), e.g. "Map | Route plan".
class MapViewSwitch extends StatelessWidget {
  const MapViewSwitch({super.key, required this.options, required this.selected, required this.onChanged});

  final List<MapViewOption> options;
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F4F8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < options.length; i++)
            Semantics(
              button: true,
              selected: i == selected,
              child: GestureDetector(
                key: ValueKey<String>('map-view-${options[i].label}'),
                behavior: HitTestBehavior.opaque,
                onTap: i == selected ? null : () => onChanged(i),
                child: MouseRegion(
                  cursor: i == selected ? SystemMouseCursors.basic : SystemMouseCursors.click,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: i == selected ? options[i].color : Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(options[i].icon, size: 12, color: i == selected ? Colors.white : Colors.grey),
                        const SizedBox(width: 4),
                        Text(
                          options[i].label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            color: i == selected ? Colors.white : const Color(0xFF455A64),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The two views of a role's map panel: the live map and Collection Route Optimization
/// (collection status from recorded visits; no road-routing request).
const List<MapViewOption> kMapRoutePlanOptions = <MapViewOption>[
  MapViewOption('Map', Icons.map_rounded),
  MapViewOption('Route plan', Icons.alt_route_rounded, color: Color(0xFF1565C0)),
];
