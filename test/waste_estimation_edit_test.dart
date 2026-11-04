import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/waste_estimation_service.dart';
import 'package:garbage_tracking_app/widgets/waste_estimation_edit_dialog.dart';

/// The admin form edits only the two numbers the estimate is made of: the waste rate (kg per hectare per day) and the holiday
/// multiplier, each with its source. A value needs its source; blank means "not available". The saved area sizes are never
/// sent, so they can never be wiped from this form, and the per-person rate (population) is always cleared.
void main() {
  const Map<String, dynamic> settings = <String, dynamic>{
    'kg_per_capita_day': '0.5000',
    'rate_source': 'NSWMC 2015',
    'kg_per_hectare_day': '36.7500',
    'hectare_rate_source': 'Derived rate',
    'seasonal_value': '1.150',
    'seasonal_source': 'Iloilo City CENRO',
    'seasonal_applies_to': 'Christmas and New Year (Dec 24 to Jan 1)',
    'seasonal_active': 1,
  };

  group('payload', () {
    test('nothing touched: the saved rate and multiplier are sent back unchanged, no area rows', () {
      final p = buildWasteEstimationPayload(settings: settings, typed: (String _) => null, flags: <String, bool>{'seasonal_active': true});
      expect(p.settings['kg_per_hectare_day'], '36.7500');
      expect(p.settings['hectare_rate_source'], 'Derived rate');
      expect(p.settings['seasonal_value'], '1.150');
      expect(p.settings['seasonal_source'], 'Iloilo City CENRO');
      expect(p.settings['seasonal_active'], true);
      expect(p.areas, isEmpty);
    });

    test('the old per-person rate is always cleared (the estimate does not use population)', () {
      final p = buildWasteEstimationPayload(settings: settings, typed: (String _) => null, flags: <String, bool>{});
      expect(p.settings['kg_per_capita_day'], isNull);
      expect(p.settings['rate_source'], '');
    });

    test('a typed value replaces the saved one; an emptied field clears it', () {
      final Map<String, String> typed = <String, String>{'ha': '40', 'ha_src': ' New source ', 'sea_src': ''};
      final p = buildWasteEstimationPayload(settings: settings, typed: (String k) => typed[k], flags: <String, bool>{});
      expect(p.settings['kg_per_hectare_day'], '40');
      expect(p.settings['hectare_rate_source'], 'New source');
      expect(p.settings['seasonal_source'], '');
      expect(p.settings['seasonal_active'], false);
    });
  });

  group('validation (the same rules as the backend)', () {
    ({Map<String, dynamic> settings, List<Map<String, dynamic>> areas}) of(Map<String, dynamic> s) => (settings: s, areas: <Map<String, dynamic>>[]);

    test('the saved starting values are valid', () {
      expect(validateWasteEstimationPayload(buildWasteEstimationPayload(settings: settings, typed: (String _) => null, flags: <String, bool>{'seasonal_active': true})), isEmpty);
    });

    test('a rate needs its source, and a number in range', () {
      expect(validateWasteEstimationPayload(of(<String, dynamic>{'kg_per_hectare_day': '30', 'hectare_rate_source': '', 'seasonal_value': '1'})), containsPair('ha_src', 'Add the source of this rate'));
      expect(validateWasteEstimationPayload(of(<String, dynamic>{'kg_per_hectare_day': '0', 'hectare_rate_source': 's', 'seasonal_value': '1'})).keys, contains('ha'));
      expect(validateWasteEstimationPayload(of(<String, dynamic>{'kg_per_hectare_day': 'abc', 'hectare_rate_source': 's', 'seasonal_value': '1'})).keys, contains('ha'));
      expect(validateWasteEstimationPayload(of(<String, dynamic>{'kg_per_hectare_day': null, 'hectare_rate_source': '', 'seasonal_value': '1'})), isEmpty); // blank is allowed: not configured
    });

    test('a multiplier other than 1.0, or switched on, needs its source and date', () {
      expect(validateWasteEstimationPayload(of(<String, dynamic>{'seasonal_value': '1.15', 'seasonal_source': ''})).keys, contains('sea_src'));
      expect(validateWasteEstimationPayload(of(<String, dynamic>{'seasonal_value': '1', 'seasonal_active': true, 'seasonal_source': ''})).keys, contains('sea_src'));
      expect(validateWasteEstimationPayload(of(<String, dynamic>{'seasonal_value': '9', 'seasonal_source': 's'})).keys, contains('sea'));
      expect(validateWasteEstimationPayload(of(<String, dynamic>{'seasonal_value': '1', 'seasonal_source': ''})), isEmpty);
    });
  });

  group('form', () {
    Future<void> open(WidgetTester tester, Size size, {Map<String, dynamic>? s}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final WasteEstimationData data = WasteEstimationData.fromRaw((
        body: <String, Object?>{'success': true, 'available': true, 'settings': s ?? settings, 'areas': <Object>[]},
        puroks: <String, Object?>{'a': <String, Object?>{'name': 'Riverside'}},
      ));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Builder(builder: (BuildContext c) => Center(child: ElevatedButton(onPressed: () => showWasteEstimationEdit(c, data), child: const Text('go'))))),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    testWidgets('a value without its source: Save is refused on the screen, with the field marked and the change shown', (WidgetTester tester) async {
      await open(tester, const Size(1366, 900), s: <String, dynamic>{'seasonal_value': '1.000'});
      expect(find.text('No changes'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Waste rate'), '30');
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes'), findsOneWidget);
      expect(find.text('Add the source of this rate'), findsNothing); // not before the first Save
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Add the source of this rate'), findsOneWidget);
      expect(find.textContaining('One field needs attention'), findsOneWidget);
      expect(find.text('Edit waste rate and holiday multiplier'), findsOneWidget); // still open, nothing was sent
      await tester.enterText(find.widgetWithText(TextField, 'Source of the rate'), 'Test document, 2026');
      await tester.pumpAndSettle();
      expect(find.text('Add the source of this rate'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final Size size in const <Size>[Size(390, 844), Size(768, 1000), Size(1366, 900)]) {
      testWidgets('${size.width.toInt()} px: two sections, no population anywhere, no overflow, closes on Cancel', (WidgetTester tester) async {
        await open(tester, size);
        expect(tester.takeException(), isNull);
        expect(find.text('Edit waste rate and holiday multiplier'), findsOneWidget);
        expect(find.text('Waste rate'), findsWidgets);
        expect(find.text('Holiday multiplier'), findsOneWidget);
        expect(find.text('Source of the rate'), findsOneWidget);
        expect(find.textContaining('opulation'), findsNothing);
        expect(find.textContaining('person'), findsNothing);
        expect(find.text('Save'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Edit waste rate and holiday multiplier'), findsNothing);
      });
    }
  });
}
