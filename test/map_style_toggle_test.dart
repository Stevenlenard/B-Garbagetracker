import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/widgets/map_style_toggle.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart';

void main() {
  testWidgets('Map | Satellite switch reports the chosen style', (WidgetTester t) async {
    bool? chosen;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: MapStyleToggle(satellite: false, onChanged: (bool v) => chosen = v))),
    ));
    expect(find.text('Map'), findsOneWidget);
    expect(find.text('Satellite'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey<String>('map-style-Satellite')));
    expect(chosen, isTrue);
  });

  testWidgets('compact variant shows icons only', (WidgetTester t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: MapStyleToggle(satellite: true, compact: true, onChanged: (_) {}))),
    ));
    expect(find.text('Satellite'), findsNothing);
    expect(find.byIcon(Icons.satellite_alt_rounded), findsOneWidget);
  });

  test('every map uses the same two styles; Map is the default Standard style', () {
    expect(MapStyles.map, MapboxStyles.STANDARD);
    expect(MapStyles.satellite, MapboxStyles.SATELLITE_STREETS);
  });
}
