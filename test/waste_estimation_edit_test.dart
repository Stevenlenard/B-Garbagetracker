import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/waste_estimation_service.dart';
import 'package:garbage_tracking_app/utils/waste_estimation.dart';
import 'package:garbage_tracking_app/widgets/waste_estimation_edit_dialog.dart';

/// Saving the estimation parameters must never wipe what the admin did not touch: the areas are collapsed in the form, so
/// most of their fields are never built. A field that was never built keeps its saved value; an emptied field clears it.
void main() {
  WasteAreaRow row(String key, String name, Map<String, dynamic>? saved) => WasteAreaRow(key: key, name: name, geometrySize: const AreaSize.none())..saved = saved;

  final List<WasteAreaRow> rows = <WasteAreaRow>[
    row('barangay_total', 'Barangay Balintawak (whole barangay)', <String, dynamic>{'population': 19278, 'population_source': 'PSA 2020 CPH', 'population_year': 2020}),
    row('a', 'Riverside', <String, dynamic>{'size_m2': '62150.00', 'size_source': 'Survey 2026', 'size_verified': 1, 'population': null}),
    row('b', 'Purok 2', null),
  ];
  const Map<String, dynamic> settings = <String, dynamic>{
    'kg_per_capita_day': '0.5000',
    'rate_source': 'NSWMC 2015',
    'seasonal_value': '1.000',
    'seasonal_active': 0,
  };

  group('payload', () {
    test('nothing opened or touched: every saved value is sent back unchanged', () {
      final p = buildWasteEstimationPayload(settings: settings, rows: rows, typed: (String _) => null, flags: <String, bool>{'v_a': true});
      expect(p.settings['kg_per_capita_day'], '0.5000');
      expect(p.settings['rate_source'], 'NSWMC 2015');
      expect(p.settings['seasonal_value'], '1.000');
      final Map<String, dynamic> whole = p.areas.firstWhere((Map<String, dynamic> a) => a['area_key'] == 'barangay_total');
      expect(whole['population'], '19278');
      expect(whole['population_source'], 'PSA 2020 CPH');
      expect(whole['population_year'], '2020');
      final Map<String, dynamic> riverside = p.areas.firstWhere((Map<String, dynamic> a) => a['area_key'] == 'a');
      expect(riverside['size_m2'], '62150.00');
      expect(riverside['size_kind'], 'manual');
      expect(riverside['size_source'], 'Survey 2026');
      expect(riverside['size_verified'], true);
      final Map<String, dynamic> p2 = p.areas.firstWhere((Map<String, dynamic> a) => a['area_key'] == 'b');
      expect(p2['size_m2'], isNull);
      expect(p2['size_kind'], 'none');
      expect(p2['population'], isNull);
    });

    test('a typed value replaces the saved one; an emptied field clears it', () {
      final Map<String, String> typed = <String, String>{'pop_barangay_total': '20000', 'popsrc_barangay_total': ' PSA 2024 ', 'm2_a': ''};
      final p = buildWasteEstimationPayload(settings: settings, rows: rows, typed: (String k) => typed[k], flags: <String, bool>{});
      final Map<String, dynamic> whole = p.areas.firstWhere((Map<String, dynamic> a) => a['area_key'] == 'barangay_total');
      expect(whole['population'], '20000');
      expect(whole['population_source'], 'PSA 2024');
      expect(whole['population_year'], '2020'); // not touched
      final Map<String, dynamic> riverside = p.areas.firstWhere((Map<String, dynamic> a) => a['area_key'] == 'a');
      expect(riverside['size_m2'], isNull);
      expect(riverside['size_kind'], 'none');
    });

    test('the rate fields are always sent, and the seasonal switches follow the flags', () {
      final Map<String, String> typed = <String, String>{'cap': '0.55', 'cap_src': 'New source', 'sea': '1.1', 'sea_src': 'Doc, 2026'};
      final p = buildWasteEstimationPayload(settings: settings, rows: rows, typed: (String k) => typed[k], flags: <String, bool>{'seasonal_active': true, 'seasonal_validated': false});
      expect(p.settings['kg_per_capita_day'], '0.55');
      expect(p.settings['rate_source'], 'New source');
      expect(p.settings['seasonal_value'], '1.1');
      expect(p.settings['seasonal_active'], true);
      expect(p.settings['seasonal_validated'], false);
    });
  });

  group('form', () {
    Future<void> open(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final WasteEstimationData data = WasteEstimationData.fromRaw((
        body: <String, Object?>{
          'success': true,
          'available': true,
          'settings': settings,
          'areas': <Object>[
            <String, Object?>{'area_key': 'barangay_total', 'population': 19278, 'population_source': 'PSA 2020 CPH', 'population_year': 2020},
          ],
        },
        puroks: <String, Object?>{'a': <String, Object?>{'name': 'Riverside'}},
      ));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Builder(builder: (BuildContext c) => Center(child: ElevatedButton(onPressed: () => showWasteEstimationEdit(c, data), child: const Text('go'))))),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
    }

    for (final Size size in const <Size>[Size(390, 844), Size(768, 1000), Size(1366, 900)]) {
      testWidgets('${size.width.toInt()} px: sections, no overflow, areas collapsed with a one-line summary, open on tap', (WidgetTester tester) async {
        await open(tester, size);
        expect(tester.takeException(), isNull);
        expect(find.text('Estimation parameters'), findsOneWidget);
        expect(find.text('Waste-generation rates'), findsOneWidget);
        expect(find.text('Seasonal multiplier'), findsOneWidget);
        expect(find.text('Population and area sizes'), findsOneWidget);
        expect(find.text('Save'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);
        // the whole barangay is collapsed and says what it holds
        await tester.ensureVisible(find.byKey(const ValueKey<String>('edit-barangay_total')));
        expect(find.textContaining('Population 19278'), findsOneWidget);
        expect(find.text('Source of the population'), findsNothing);
        await tester.tap(find.byKey(const ValueKey<String>('edit-barangay_total')));
        await tester.pumpAndSettle();
        expect(find.text('Source of the population'), findsOneWidget);
        expect(find.text('Confirmed size (m²)'), findsNothing); // the whole barangay has no size
        await tester.ensureVisible(find.byKey(const ValueKey<String>('edit-a')));
        await tester.tap(find.byKey(const ValueKey<String>('edit-a')));
        await tester.pumpAndSettle();
        expect(find.text('Confirmed size (m²)'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Estimation parameters'), findsNothing);
      });
    }
  });
}
