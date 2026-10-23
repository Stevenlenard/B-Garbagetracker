import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/widgets/app_data_table.dart';

void main() {
  Future<void> pump(WidgetTester t, List<String> rows, {void Function(String)? onTap}) async {
    t.view.physicalSize = const Size(1200, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AppDataTable<String>(
            rows: rows,
            pageSize: 5,
            onRowTap: onTap,
            columns: <AppTableColumn<String>>[
              AppTableColumn<String>(label: 'Name', flex: 3, sortKey: (String r) => r, cell: (String r, int i) => Text(r)),
            ],
          ),
        ),
      ),
    ));
  }

  testWidgets('pages long lists and says which rows are shown', (WidgetTester t) async {
    await pump(t, <String>[for (int i = 1; i <= 12; i++) 'User ${i.toString().padLeft(2, '0')}']);
    expect(find.text('Showing 1–5 of 12'), findsOneWidget);
    expect(find.text('User 06'), findsNothing);
    await t.tap(find.byTooltip('Next page'));
    await t.pumpAndSettle();
    expect(find.text('Showing 6–10 of 12'), findsOneWidget);
    expect(find.text('User 06'), findsOneWidget);
  });

  testWidgets('a sortable header sorts ascending, then descending', (WidgetTester t) async {
    await pump(t, <String>['Carlo', 'Ana', 'Bea']);
    await t.tap(find.text('NAME'));
    await t.pumpAndSettle();
    expect(t.getTopLeft(find.text('Ana')).dy, lessThan(t.getTopLeft(find.text('Carlo')).dy));
    await t.tap(find.text('NAME'));
    await t.pumpAndSettle();
    expect(t.getTopLeft(find.text('Carlo')).dy, lessThan(t.getTopLeft(find.text('Ana')).dy));
  });

  testWidgets('tapping a row reports it', (WidgetTester t) async {
    String? got;
    await pump(t, <String>['Ana', 'Bea'], onTap: (String r) => got = r);
    await t.tap(find.text('Bea'));
    expect(got, 'Bea');
  });
}
