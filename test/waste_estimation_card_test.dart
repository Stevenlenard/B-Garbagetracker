import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/waste_estimation_service.dart';
import 'package:garbage_tracking_app/widgets/waste_estimation_card.dart';
import 'package:garbage_tracking_app/widgets/waste_estimation_details.dart';

/// Objective 2.2 UI: a compact card on the Analytics page and its details in a dialog on wide screens and a full-screen page
/// on phones. Same data and calculation everywhere (size x waste rate x holiday multiplier); estimates are labelled as
/// estimates; nothing is shown that is not configured.
void main() {
  // Three areas with a confirmed size (10, 20 and 30 ha) and one road without a size.
  final Map<String, Object?> puroks = <String, Object?>{
    'central': <String, Object?>{'name': 'Central (Purok 1)'},
    'a': <String, Object?>{'name': 'Purok 2'},
    'b': <String, Object?>{'name': 'Purok 3'},
    'road': <String, Object?>{'name': 'T.M. Kalaw Street'},
  };
  List<Object> sizes3() => <Object>[
        <String, Object?>{'area_key': 'central', 'size_m2': '100000', 'size_kind': 'manual', 'size_source': 'barangay', 'size_verified': 1},
        <String, Object?>{'area_key': 'a', 'size_m2': '200000', 'size_kind': 'manual', 'size_source': 'barangay', 'size_verified': 1},
        <String, Object?>{'area_key': 'b', 'size_m2': '300000', 'size_kind': 'manual', 'size_source': 'barangay', 'size_verified': 1},
      ];

  Map<String, Object?> body({bool rate = true, bool christmas = true}) => <String, Object?>{
        'success': true,
        'available': true,
        'settings': <String, Object?>{
          'kg_per_hectare_day': rate ? '30.0000' : null,
          'hectare_rate_source': rate ? 'Test rate: derived from the documented per-person figure' : '',
          'seasonal_value': '1.150',
          'seasonal_source': 'Iloilo City CENRO and Cagayan de Oro, holiday season +10-20 %',
          'seasonal_active': christmas ? 1 : 0,
        },
        'areas': sizes3(),
      };
  const Map<String, Object?> empty = <String, Object?>{'success': true, 'available': true, 'settings': null, 'areas': <Object>[]};

  Future<void> pump(WidgetTester tester, Size size, Map<String, Object?> b) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(padding: const EdgeInsets.all(16), child: WasteEstimationCard(loader: () async => (body: b, puroks: puroks))),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> openDetails(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey<String>('waste-estimation-card')));
    await tester.pumpAndSettle();
  }

  const List<Size> sizes = <Size>[Size(390, 844), Size(768, 1000), Size(1366, 900)];

  group('compact card', () {
    for (final Size size in sizes) {
      testWidgets('${size.width.toInt()} px: shows the total of the areas, not the list', (WidgetTester tester) async {
        await pump(tester, size, body(christmas: false));
        expect(tester.takeException(), isNull);
        expect(find.text('Waste Estimation by Area'), findsOneWidget);
        expect(find.text('Area size × waste rate × holiday multiplier'), findsOneWidget);
        expect(find.textContaining('1,800 kg/day'), findsOneWidget); // (10 + 20 + 30 ha) x 30 kg/ha/day, read from the data
        expect(find.textContaining('3 collection areas'), findsOneWidget);
        expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
        expect(find.text('Purok 2'), findsNothing);
      });
    }

    testWidgets('another rate gives another figure (nothing is hard-coded)', (WidgetTester tester) async {
      final Map<String, Object?> b = body(christmas: false);
      (b['settings'] as Map<String, Object?>)['kg_per_hectare_day'] = '10';
      await pump(tester, const Size(1000, 900), b);
      expect(find.textContaining('600 kg/day'), findsOneWidget);
    });

    testWidgets('no rate: says so, with no invented number', (WidgetTester tester) async {
      await pump(tester, const Size(1000, 900), body(rate: false));
      expect(find.text('Not configured'), findsOneWidget);
      expect(find.textContaining('Enter the waste rate'), findsOneWidget);
      expect(find.textContaining('kg/day'), findsNothing);
    });

    testWidgets('nothing saved yet: not configured', (WidgetTester tester) async {
      await pump(tester, const Size(1000, 900), empty);
      expect(find.text('Not configured'), findsOneWidget);
    });

    testWidgets('tables not created: says so and is not clickable', (WidgetTester tester) async {
      await pump(tester, const Size(1000, 900), <String, Object?>{'success': true, 'available': false});
      expect(find.textContaining('Not set up on this server yet'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
    });

    testWidgets('load failure: a message and Retry', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: WasteEstimationCard(loader: () async => throw Exception('offline')))));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not load'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('details: wide screens use a dialog, phones a full-screen page', () {
    for (final Size size in <Size>[const Size(768, 1000), const Size(1366, 900)]) {
      testWidgets('${size.width.toInt()} px: opens a centred dialog with the formula, three figures and the areas, and closes', (WidgetTester tester) async {
        await pump(tester, size, body(christmas: false));
        await openDetails(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('Waste Estimation by Collection Area'), findsOneWidget);
        expect(find.text('HOW IT IS COMPUTED'), findsOneWidget);
        expect(find.text('Area size (ha)'), findsOneWidget);
        expect(find.text('Waste rate (kg/ha/day)'), findsOneWidget);
        expect(find.text('Holiday multiplier'), findsOneWidget);
        expect(find.text('30.0 kg/ha/day'), findsOneWidget);
        expect(find.text('Regular day'), findsOneWidget);
        expect(find.text('3 areas · 60.00 ha'), findsOneWidget);
        expect(find.text('Estimate by area'), findsOneWidget);
        expect(find.text('Central (Purok 1)'), findsOneWidget);
        expect(find.text('300 kg/day'), findsOneWidget);
        expect(find.text('600 kg/day'), findsOneWidget);
        expect(find.text('900 kg/day'), findsOneWidget);
        // nothing about population, census, confidence or method labels any more
        expect(find.textContaining('population'), findsNothing);
        expect(find.textContaining('Confidence'), findsNothing);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
      });
    }

    testWidgets('1366 px: Escape closes the dialog, so does the X', (WidgetTester tester) async {
      await pump(tester, const Size(1366, 900), body(christmas: false));
      await openDetails(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      await openDetails(tester);
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('390 px: opens a full-screen page with a back button and closes', (WidgetTester tester) async {
      await pump(tester, const Size(390, 844), body(christmas: false));
      await openDetails(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('HOW IT IS COMPUTED'), findsOneWidget);
      expect(find.text('Total estimate'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('HOW IT IS COMPUTED'), findsNothing);
    });
  });

  group('areas and their calculation', () {
    for (final Size size in sizes) {
      testWidgets('${size.width.toInt()} px: an area opens to its calculation; the total adds up', (WidgetTester tester) async {
        await pump(tester, size, body(christmas: false));
        await openDetails(tester);
        await tester.ensureVisible(find.text('Purok 3'));
        await tester.tap(find.text('Purok 3'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('30.00 ha'), findsWidgets);
        expect(find.text('30.0 kg/ha/day'), findsWidgets);
        expect(find.text('1.0'), findsOneWidget);
        expect(find.text('Total'), findsOneWidget);
        expect(find.text('1,800 kg/day'), findsWidgets);
      });
    }

    testWidgets('an area without a size says what is missing and shows no number', (WidgetTester tester) async {
      await pump(tester, const Size(1000, 900), body(christmas: false));
      await openDetails(tester);
      await tester.ensureVisible(find.text('T.M. Kalaw Street'));
      await tester.tap(find.text('T.M. Kalaw Street'));
      await tester.pumpAndSettle();
      expect(find.text('no size'), findsOneWidget);
      expect(find.text('Not configured: no usable area size.'), findsOneWidget);
    });

    testWidgets('no rate: the details say it and the areas show no estimate', (WidgetTester tester) async {
      await pump(tester, const Size(1000, 900), body(rate: false));
      await openDetails(tester);
      expect(find.textContaining('The waste rate is not set'), findsOneWidget);
      expect(find.text('300 kg/day'), findsNothing);
    });

    testWidgets('the sources dropdown gives the rate, the holiday multiplier and the sizes', (WidgetTester tester) async {
      await pump(tester, const Size(1000, 900), body(christmas: true));
      await openDetails(tester);
      await tester.ensureVisible(find.text('Where the numbers come from'));
      await tester.tap(find.text('Where the numbers come from'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Test rate: derived from the documented per-person figure'), findsOneWidget);
      expect(find.textContaining('Dec 24 to Jan 1'), findsWidgets);
      expect(find.textContaining('Not validated for Lipa'), findsOneWidget);
      expect(find.text('From the collection-area boundaries confirmed by the barangay.'), findsOneWidget);
    });

    testWidgets('the admin edit dialog opens from the details', (WidgetTester tester) async {
      await pump(tester, const Size(1366, 900), body(christmas: false));
      await openDetails(tester);
      await tester.tap(find.byTooltip('Edit waste rate and holiday multiplier'));
      await tester.pumpAndSettle();
      expect(find.text('Edit waste rate and holiday multiplier'), findsWidgets);
      expect(find.text('Source of the rate'), findsOneWidget);
    });
  });

  group('holiday multiplier by date', () {
    Future<void> openOn(WidgetTester tester, DateTime day, {bool active = true}) async {
      tester.view.physicalSize = const Size(1366, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final WasteEstimationData data = WasteEstimationData.fromRaw((body: body(christmas: active), puroks: puroks), day: day);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: WasteEstimationDetails(data: data, reload: () async => data))));
      await tester.pumpAndSettle();
    }

    testWidgets('a regular day: ×1.0 today and 1,800 kg/day', (WidgetTester tester) async {
      await openOn(tester, DateTime(2026, 11, 4));
      expect(tester.takeException(), isNull);
      expect(find.text('×1.0'), findsOneWidget);
      expect(find.text('Regular day'), findsOneWidget);
      expect(find.textContaining('1,800 kg/day'), findsWidgets);
    });

    testWidgets('on Christmas the multiplier applies by itself: 1,800 × 1.15 = 2,070 kg/day, in every area', (WidgetTester tester) async {
      await openOn(tester, DateTime(2026, 12, 25));
      expect(find.text('×1.15'), findsOneWidget);
      expect(find.text('Christmas and New Year'), findsOneWidget);
      expect(find.textContaining('2,070 kg/day'), findsWidgets);
      expect(find.text('345 kg/day'), findsOneWidget); // 10 ha x 30 x 1.15
      await tester.ensureVisible(find.text('Central (Purok 1)'));
      await tester.tap(find.text('Central (Purok 1)'));
      await tester.pumpAndSettle();
      expect(find.text('1.15'), findsOneWidget);
    });

    testWidgets('not applied: ×1.0 even on Christmas', (WidgetTester tester) async {
      await openOn(tester, DateTime(2026, 12, 25), active: false);
      expect(find.text('×1.0'), findsOneWidget);
      expect(find.textContaining('1,800 kg/day'), findsWidgets);
    });

    testWidgets('a Lipa holiday without documented waste figures stays ×1.0', (WidgetTester tester) async {
      await openOn(tester, DateTime(2027, 1, 20));
      expect(find.text('×1.0'), findsOneWidget);
      expect(find.text('Regular day'), findsOneWidget);
    });
  });
}
