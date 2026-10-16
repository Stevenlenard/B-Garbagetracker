import 'package:flutter/material.dart';

import '../utils/truck_identity.dart';

/// Compact legend of the trucks currently on a map: identity colour + truck id.
/// Tapping a chip selects that truck (its route is highlighted by the host map);
/// tapping it again clears the selection. The ring colour on the map means STATUS.
class TruckLegend extends StatelessWidget {
  const TruckLegend({
    super.key,
    required this.truckIds,
    this.selectedId,
    this.onSelect,
    this.maxVisible = 8,
    this.decorated = true,
  });

  final Iterable<String> truckIds;
  final String? selectedId;
  final ValueChanged<String>? onSelect;
  final int maxVisible;

  /// False when hosted inside another card (e.g. FloatingMapLegend): no own background.
  final bool decorated;

  @override
  Widget build(BuildContext context) {
    final List<String> ids = truckIds.map(TruckIdentity.normalize).where((String s) => s.isNotEmpty).toSet().toList()..sort();
    if (ids.isEmpty) return const SizedBox.shrink();
    final List<String> shown = ids.take(maxVisible).toList();
    final int hidden = ids.length - shown.length;

    return Container(
      constraints: const BoxConstraints(maxWidth: 190),
      padding: decorated ? const EdgeInsets.fromLTRB(10, 8, 10, 8) : const EdgeInsets.fromLTRB(8, 2, 10, 8),
      decoration: decorated
          ? BoxDecoration(
              color: Colors.white.withOpacity(0.94),
              borderRadius: BorderRadius.circular(14),
              boxShadow: const [BoxShadow(color: Color(0x26000000), blurRadius: 8, offset: Offset(0, 2))],
            )
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Trucks', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF455A64), letterSpacing: 0.4)),
          const SizedBox(height: 6),
          for (final String id in shown)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onSelect == null ? null : () => onSelect!(id),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                margin: const EdgeInsets.only(bottom: 2),
                decoration: BoxDecoration(
                  color: selectedId == id ? TruckIdentity.color(id).withOpacity(0.15) : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: selectedId == id ? TruckIdentity.color(id) : Colors.transparent, width: 1.2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: TruckIdentity.color(id),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 2)],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(id, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Color(0xFF1A1A1A))),
                  ],
                ),
              ),
            ),
          if (hidden > 0)
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 2),
              child: Text('+$hidden more', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF78909C))),
            ),
          const SizedBox(height: 4),
          const Text('Marker ring = status', style: TextStyle(fontSize: 10, color: Color(0xFF78909C), fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
