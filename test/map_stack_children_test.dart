import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The tracking map cards are Stacks whose children are all Positioned. If an optional overlay
/// returns a bare SizedBox.shrink() it becomes the only non-positioned child, the Stack sizes
/// itself to 0x0 and the whole Truck Tracking screen goes blank (seen whenever no truck was online).
void main() {
  for (final String path in <String>[
    'lib/screens/resident_track_truck_screen.dart',
    'lib/screens/track_trucks_screen.dart',
  ]) {
    test('$path: empty map overlays stay Positioned', () {
      final String src = File(path).readAsStringSync();
      final RegExp legend = RegExp(r'Widget _buildTruckLegend\([\s\S]*?\n  }\n');
      final String body = legend.firstMatch(src)!.group(0)!;
      expect(body.contains('return const SizedBox.shrink()'), isFalse);
      expect(body.contains('if (ids.isEmpty) return const Positioned('), isTrue);
      if (src.contains('Widget _buildMapStatusOverlay()')) {
        expect(src.contains('_mapLoadError == null) return const SizedBox.shrink()'), isFalse);
      }
    });
  }
}
