import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/widgets/waste_estimation_card.dart';

/// The Objective 2.2 card at phone and desktop widths: no overflow, honest "Not configured" state, estimates labelled as
/// estimates, and the calculation breakdown reachable by tapping an area.
void main() {
  // Two distinct polygons (~27 ha and ~2.8 ha) and three look-alike boxes (placeholders).
  List<List<double>> box(double lng, double lat, double dLng, double dLat) => <List<double>>[
        <double>[lng, lat],
        <double>[lng + dLng, lat],
        <double>[lng + dLng, lat + dLat],
        <double>[lng, lat + dLat],
        <double>[lng, lat],
      ];
  final Map<String, Object?> puroks = <String, Object?>{
    'central': <String, Object?>{'name': 'Central (Purok 1)', 'boundaryGeometry': box(121.158, 13.952, 0.0025, 0.0010), 'coordinateSource': 'Test GIS'},
    'p4': <String, Object?>{'name': 'Purok 4 / El Pueblo', 'boundaryGeometry': box(121.150, 13.966, 0.0003, 0.0003)},
    'a': <String, Object?>{'name': 'Purok 2', 'boundaryGeometry': box(121.154, 13.961, 0.004, 0.0097)},
    'b': <String, Object?>{'name': 'Purok 3', 'boundaryGeometry': box(121.149, 13.960, 0.004, 0.0097)},
    'c': <String, Object?>{'name': 'Riverside', 'boundaryGeometry': box(121.163, 13.946, 0.004, 0.0097)},
    'road': <String, Object?>{'name': 'T.M. Kalaw Street'},
  };

  Future<void> pump(WidgetTester tester, Size size, Map<String, Object?> body) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: WasteEstimationCard(loader: () async => (body: body, puroks: puroks)),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  for (final Size size in <Size>[const Size(390, 800), const Size(1366, 800)]) {
    testWidgets('${size.width.toInt()} px: nothing configured shows "Not configured", no overflow', (WidgetTester tester) async {
      await pump(tester, size, <String, Object?>{'success': true, 'available': true, 'settings': null, 'areas': <Object>[]});
      expect(tester.takeException(), isNull);
      expect(find.text('Waste Estimation by Collection Area'), findsOneWidget);
      expect(find.text('Not configured'), findsWidgets);
      expect(find.textContaining('Not measured or verified collected weight'), findsOneWidget);
      expect(find.textContaining('×1.0 (neutral)'), findsOneWidget);
      expect(find.textContaining('0 of 6'), findsOneWidget);
    });

    testWidgets('${size.width.toInt()} px: configured area shows an estimate and an expandable breakdown', (WidgetTester tester) async {
      await pump(tester, size, <String, Object?>{
        'success': true,
        'available': true,
        'settings': <String, Object?>{'kg_per_hectare_day': '30', 'hectare_rate_source': 'Test source', 'seasonal_value': '1.000', 'seasonal_active': 0},
        'areas': <Object>[
          <String, Object?>{'area_key': 'central', 'size_m2': '100000', 'size_kind': 'manual', 'size_source': 'Survey', 'size_verified': 1},
        ],
      });
      expect(tester.takeException(), isNull);
      expect(find.textContaining('300 kg/day (estimate)'), findsOneWidget);
      await tester.ensureVisible(find.text('Central (Purok 1)'));
      await tester.tap(find.text('Central (Purok 1)'));
      await tester.pumpAndSettle();
      expect(find.text('= 300 kg/day'), findsOneWidget);
      expect(find.textContaining('Test source'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('placeholder-like boxes are not used as sizes; a road without geometry has no size', (WidgetTester tester) async {
    await pump(tester, const Size(390, 800), <String, Object?>{'success': true, 'available': true, 'settings': null, 'areas': <Object>[]});
    // Purok 2, Purok 3 and the road have no usable size; Riverside gets the unverified OpenStreetMap reference (62150 m²).
    expect(find.textContaining('Size unavailable'), findsNWidgets(3));
    expect(find.textContaining('62150 m²'), findsOneWidget);
  });

  testWidgets('whole barangay: 19,278 people x 0.50 kg = 9,639 kg/day, with its sources, and not added to the areas', (WidgetTester tester) async {
    await pump(tester, const Size(390, 800), <String, Object?>{
      'success': true,
      'available': true,
      'settings': <String, Object?>{'kg_per_capita_day': '0.5000', 'rate_source': 'NSWMC 2015 via Villanueva et al. 2021', 'seasonal_value': '1.000'},
      'areas': <Object>[
        <String, Object?>{'area_key': 'barangay_total', 'population': 19278, 'population_source': 'PSA 2020 CPH', 'population_year': 2020},
      ],
    });
    expect(tester.takeException(), isNull);
    expect(find.textContaining('9639 kg/day'), findsWidgets);
    expect(find.textContaining('not added to the whole-barangay figure'), findsOneWidget);
    // the summary of the areas stays at "not configured": no purok has a population or a verified size
    expect(find.textContaining('0 of 6'), findsOneWidget);
    await tester.ensureVisible(find.text('Barangay Balintawak (whole barangay)'));
    await tester.tap(find.text('Barangay Balintawak (whole barangay)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('PSA 2020 CPH'), findsOneWidget);
    expect(find.textContaining('NSWMC 2015'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tables not created yet: says so instead of showing numbers',(WidgetTester tester) async {
    await pump(tester, const Size(390, 800), <String, Object?>{'success': true, 'available': false, 'settings': null, 'areas': <Object>[]});
    expect(find.textContaining('migration pending'), findsOneWidget);
  });
}
