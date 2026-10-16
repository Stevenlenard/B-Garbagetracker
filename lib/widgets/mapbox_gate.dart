import 'package:flutter/material.dart';

import '../config/mapbox_config.dart';

/// Shows [child] (a Mapbox `MapWidget`) only when a Mapbox token is configured for this build.
/// Without one the map area shows an honest notice; nothing else on the screen changes and no
/// map request is made with another account's token.
class MapboxGate extends StatelessWidget {
  const MapboxGate({super.key, required this.child});

  final Widget child;

  @visibleForTesting
  static bool? debugConfigured;

  static bool get configured => debugConfigured ?? MapboxConfig.isConfigured;

  @override
  Widget build(BuildContext context) {
    if (configured) return child;
    return Container(
      color: const Color(0xFFF1F4F6),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(16),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.map_outlined, color: Color(0xFF7A8A94), size: 32),
          SizedBox(height: 8),
          Text(
            'Map not configured',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF41525C)),
          ),
          SizedBox(height: 4),
          Text(
            'This build has no Mapbox access token. Tracking data and the rest of the app still work.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Color(0xFF6B7B85)),
          ),
        ],
      ),
    );
  }
}
