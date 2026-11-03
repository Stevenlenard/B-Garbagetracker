import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/widgets/waste_estimation_card.dart';

/// Objective 2.2 UI: a compact card on the Analytics page, details (Overview / Area Details / Parameters & Sources) in a
/// dialog on wide screens and a full-screen page on phones. Same data and calculation everywhere; estimates are labelled
/// as estimates; nothing is shown that is not configured.
void main() {
  // Two distinct polygons (~27 ha and ~2.8 ha) and three look-alike boxes (placeholders), one road without geometry.
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

  const Map<String, Object?> empty = <String, Object?>{'success': true, 'available': true, 'settings': null, 'areas': <Object>[]};
  final Map<String, Object?> seeded = <String, Object?>{
    'success': true,
    'available': true,
    'settings': <String, Object?>{'kg_per_capita_day': '0.5000', 'rate_source': 'NSWMC 2015 via Villanueva et al. 2021', 'seasonal_value': '1.000'},
    'areas': <Object>[
      <String, Object?>{'area_key': 'barangay_total', 'population': 19278, 'population_source': 'PSA 2020 CPH', 'population_year': 2020},
    ],
  };

  Future<void> pump(WidgetTester tester, Size size, Map<String, Object?> body) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(padding: const EdgeInsets.all(16), child: WasteEstimationCard(loader: () async => (body: body, puroks: puroks))),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openDetails(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey<String>('waste-estimation-card')));
    await tester.pumpAndSettle();
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  const List<Size> sizes = <Size>[Size(390, 844), Size(768, 1000), Size(1366, 900)];

  group('compact card', () {
    for (final Size size in sizes) {
      testWidgets('${size.width.toInt()} px: shows the barangay estimate from the data, not the list of areas', (WidgetTester tester) async {
        await pump(tester, size, seeded);
        expect(tester.takeException(), isNull);
        expect(find.text('Waste Estimation by Area'), findsOneWidget);
        expect(find.text('Area-based estimated waste generation per collection area'), findsOneWidget);
        expect(find.textContaining('9,639'), findsOneWidget); // 19,278 x 0.50: read from the data, not hard-coded
        expect(find.text('Barangay estimate'), findsOneWidget);
        expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
        expect(find.text('Riverside'), findsNothing); // the 10 areas are not on the Analytics page any more
      });
    }

    testWidgets('another population gives another figure (nothing is hard-coded)', (WidgetTester tester) async {
      final Map<String, Object?> other = <String, Object?>{
        ...seeded,
        'areas': <Object>[
          <String, Object?>{'area_key': 'barangay_total', 'population': 1000, 'population_source': 'x', 'population_year': 2020},
        ],
      };
      await pump(tester, sizes[0], other);
      expect(find.textContaining('500'), findsOneWidget);
      expect(find.textContaining('9,639'), findsNothing);
    });

    testWidgets('nothing configured: says so, with no invented number', (WidgetTester tester) async {
      await pump(tester, sizes[0], empty);
      expect(find.text('Not configured'), findsOneWidget);
      expect(find.textContaining('kg/day'), findsNothing);
    });

    testWidgets('tables not created: says so and is not clickable', (WidgetTester tester) async {
      await pump(tester, sizes[0], <String, Object?>{'success': true, 'available': false, 'settings': null, 'areas': <Object>[]});
      expect(find.textContaining('Not set up on this server yet'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('waste-estimation-card')), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Waste Estimation by Collection Area'), findsNothing);
    });

    testWidgets('load failure: a message and Retry', (WidgetTester tester) async {
      tester.view.physicalSize = sizes[0];
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      int calls = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: WasteEstimationCard(loader: () async {
            calls++;
            if (calls == 1) throw StateError('boom');
            return (body: seeded, puroks: puroks);
          }),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Could not load the waste estimation data.'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.textContaining('9,639'), findsOneWidget);
    });
  });

  group('details: wide screens use a dialog, phones a full-screen page', () {
    for (final Size size in <Size>[sizes[1], sizes[2]]) {
      testWidgets('${size.width.toInt()} px: opens a centred dialog with the overview and closes', (WidgetTester tester) async {
        await pump(tester, size, seeded);
        await openDetails(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('Waste Estimation by Collection Area'), findsOneWidget);
        expect(find.text('Estimated waste generation using documented parameters.'), findsOneWidget);
        expect(find.text('Areas configured'), findsOneWidget);
        expect(find.text('Whole barangay (est.)'), findsOneWidget);
        expect(find.text('×1.0 (Neutral)'), findsOneWidget);
        expect(find.textContaining('9,639 kg/day'), findsWidgets);
        expect(find.textContaining('not measured collected waste'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
      });
    }

    testWidgets('1366 px: Escape closes the dialog, so does the X', (WidgetTester tester) async {
      await pump(tester, sizes[2], seeded);
      await openDetails(tester);
      expect(find.byType(Dialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      await openDetails(tester);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('390 px: opens a full-screen page with a back button and closes', (WidgetTester tester) async {
      await pump(tester, sizes[0], seeded);
      await openDetails(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('Waste Estimation by Collection Area'), findsOneWidget);
      expect(find.text('Areas configured'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('Waste Estimation by Area'), findsOneWidget);
    });
  });

  for (final Size size in sizes) {
    final bool narrow = size.width < 520;
    final String areasTab = narrow ? 'Areas' : 'Area Details';
    final String sourcesTab = narrow ? 'Sources' : 'Parameters & Sources';

    testWidgets('${size.width.toInt()} px: Area Details lists the areas, searches, and expands with the calculation', (WidgetTester tester) async {
      await pump(tester, size, seeded);
      await openDetails(tester);
      await tapText(tester, areasTab);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Collection areas (6)'), findsOneWidget);
      expect(find.text('Riverside'), findsOneWidget);
      expect(find.text('Purok 2'), findsOneWidget);
      // the four areas with nothing usable are "Not Configured"; the whole barangay is an estimate
      expect(find.text('Not Configured'), findsNWidgets(3)); // Purok 2, Purok 3, the road
      // search
      await tester.enterText(find.byType(TextField), 'river');
      await tester.pumpAndSettle();
      expect(find.text('Riverside'), findsOneWidget);
      expect(find.text('Purok 2'), findsNothing);
      expect(find.textContaining('Collection areas (1 of 6)'), findsOneWidget);
      // expand: the OpenStreetMap size, unverified, with its source
      await tester.tap(find.byKey(const ValueKey<String>('area-c')));
      await tester.pumpAndSettle();
      expect(find.textContaining('62,150'), findsOneWidget);
      expect(find.textContaining('Not verified'), findsOneWidget);
      expect(find.textContaining('OpenStreetMap way/407890456'), findsOneWidget);
      // an area without an estimate says what is needed, not "None" / "n/a" rows
      expect(find.text('To estimate this area'), findsOneWidget);
      expect(find.text('Limitations'), findsNothing);
      expect(find.text('Estimation method'), findsNothing);
      expect(find.text('Waste-generation rate'), findsNothing);
      // no match
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.textContaining('No collection area matches'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${size.width.toInt()} px: the whole barangay row shows its formula and sources', (WidgetTester tester) async {
      await pump(tester, size, seeded);
      await openDetails(tester);
      await tapText(tester, areasTab);
      await tester.tap(find.byKey(const ValueKey<String>('area-barangay_total')));
      await tester.pumpAndSettle();
      expect(find.text('Calculation breakdown'), findsOneWidget);
      expect(find.textContaining('= 9639 kg/day'), findsOneWidget);
      expect(find.textContaining('PSA 2020 CPH'), findsWidgets);
      expect(find.textContaining('NSWMC 2015'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${size.width.toInt()} px: Parameters & Sources shows the rates, sources, boundaries and method', (WidgetTester tester) async {
      await pump(tester, size, seeded);
      await openDetails(tester);
      await tapText(tester, sourcesTab);
      expect(tester.takeException(), isNull);
      expect(find.text('Population-based estimation'), findsOneWidget);
      expect(find.textContaining('0.5 kg per person per day'), findsOneWidget);
      expect(find.textContaining('NSWMC 2015 via Villanueva'), findsWidgets);
      expect(find.text('Area-based estimation (per hectare)'), findsOneWidget);
      expect(find.text('Seasonal multiplier'), findsOneWidget);
      expect(find.text('Geographic boundary sources'), findsOneWidget);
      // the sections are collapsed except the first; a collapsed one shows a one-line summary and opens on tap
      expect(find.textContaining('retrieved 2026-11-04'), findsNothing);
      expect(find.textContaining('sizes available'), findsOneWidget);
      await tapText(tester, 'Geographic boundary sources');
      expect(find.textContaining('retrieved 2026-11-04'), findsOneWidget);
      expect(find.text('Calculation methodology'), findsOneWidget);
      await tapText(tester, 'Calculation methodology');
      expect(find.textContaining('Otherwise: population × kg per person per day'), findsOneWidget);
      await tester.ensureVisible(find.text('Edit parameters'));
      expect(find.text('Edit parameters'), findsOneWidget);
    });

    testWidgets('${size.width.toInt()} px: the admin edit dialog still opens from the details', (WidgetTester tester) async {
      await pump(tester, size, seeded);
      await openDetails(tester);
      await tester.tap(find.byTooltip('Edit parameters').first);
      await tester.pumpAndSettle();
      expect(find.text('Estimation parameters'), findsOneWidget);
      expect(find.text('Barangay Balintawak (whole barangay)'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Estimation parameters'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a narrow dialog (a window narrowed after opening) keeps a one-line header and room for the content', (WidgetTester tester) async {
    await pump(tester, sizes[2], seeded);
    await openDetails(tester);
    tester.view.physicalSize = const Size(420, 700);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // whatever route is on screen, the content area is most of the screen, not squeezed under a tall header
    final Rect body = tester.getRect(find.byType(SingleChildScrollView).last);
    expect(body.height, greaterThan(380));
    expect(find.text('Waste Estimation'), findsOneWidget); // the compact one-line title
    expect(find.textContaining('Estimated waste generation using documented parameters.'), findsNothing);
  });

  testWidgets('nothing configured: the overview says so and the areas stay Not Configured, no estimate anywhere', (WidgetTester tester) async {
    await pump(tester, sizes[2], empty);
    await openDetails(tester);
    expect(find.textContaining('0 of 6'), findsOneWidget);
    expect(find.textContaining('No collection area has enough sourced data yet'), findsOneWidget);
    expect(find.textContaining('kg/day'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unconfigured area shows no empty rows, only what is missing', (WidgetTester tester) async {
    await pump(tester, sizes[2], seeded);
    await openDetails(tester);
    await tapText(tester, 'Area Details');
    await tester.enterText(find.byType(TextField), 'purok 2');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('area-a')));
    await tester.pumpAndSettle();
    for (final String gone in <String>['Source verification', 'Estimation method', 'Waste-generation rate', 'Seasonal adjustment', 'Estimated quantity', 'Confidence', 'Area size']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    expect(find.text('To estimate this area'), findsOneWidget);
    expect(find.textContaining('A confirmed area size'), findsOneWidget);
    expect(find.textContaining('A sourced population'), findsOneWidget);
    expect(find.textContaining('A sourced waste-generation rate'), findsNothing); // the per-person rate is configured
  });

  testWidgets('the whole barangay is named once, and the Sources tab gives one clear formula', (WidgetTester tester) async {
    await pump(tester, sizes[2], seeded);
    await openDetails(tester);
    await tapText(tester, 'Parameters & Sources');
    expect(find.textContaining('19,278 people × 0.5 kg/person/day = 9,639 kg/day'), findsOneWidget);
    await tapText(tester, 'Area Details');
    expect(find.text('Barangay Balintawak'), findsOneWidget);
    expect(find.text('Barangay Balintawak (whole barangay)'), findsNothing);
  });

  testWidgets('the overview lists the first areas and points to the rest', (WidgetTester tester) async {
    await pump(tester, sizes[2], empty);
    await openDetails(tester);
    expect(find.textContaining('Collection Areas', findRichText: true), findsOneWidget);
    expect(find.textContaining('+ 1 more in Area Details'), findsOneWidget);
    await tester.tap(find.text('View all areas'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Collection areas (6)'), findsOneWidget);
  });
}
