import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Layout contract the Map Tracking history sheet relies on (same structure as
/// TrackTrucksScreen._buildHistorySheet inside the Admin shell, which uses `extendBody`
/// and a floating bottom navigation).
const double _navHeight = 68 + 12;

Widget _shell({required bool sheetAboveNav, int trips = 30}) {
  return MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(size: Size(412, 915)),
      child: Scaffold(
        extendBody: true,
        bottomNavigationBar: const SizedBox(key: Key('nav'), height: _navHeight),
        body: Builder(builder: (context) {
          final double navInset = MediaQuery.paddingOf(context).bottom;
          return Stack(children: [
            const Positioned.fill(child: ColoredBox(color: Colors.green)), // the map
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              bottom: sheetAboveNav ? navInset : 0,
              child: DraggableScrollableSheet(
                initialChildSize: 0.42,
                minChildSize: 0.16,
                maxChildSize: 0.88,
                snap: true,
                snapSizes: const <double>[0.16, 0.42, 0.88],
                builder: (context, controller) => ColoredBox(
                  color: Colors.white,
                  child: CustomScrollView(
                    controller: controller,
                    physics: const ClampingScrollPhysics(),
                    slivers: <Widget>[
                      const SliverToBoxAdapter(child: SizedBox(height: 140, child: Text('filters + replay card'))),
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, i) => SizedBox(height: 60, child: Text('trip $i', key: ValueKey<String>('trip $i'))),
                          childCount: trips,
                        ),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 16)),
                    ],
                  ),
                ),
              ),
            ),
          ]);
        }),
      ),
    ),
  );
}

Future<void> _scrollToEnd(WidgetTester tester) async {
  for (int i = 0; i < 40; i++) {
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('extendBody reports the bottom navigation height as the body inset', (tester) async {
    double? inset;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        extendBody: true,
        bottomNavigationBar: const SizedBox(height: _navHeight),
        body: Builder(builder: (context) {
          inset = MediaQuery.paddingOf(context).bottom;
          return const SizedBox.expand();
        }),
      ),
    ));
    expect(inset, _navHeight);
  });

  testWidgets('history sheet above the nav: the last trip scrolls fully into view', (tester) async {
    await tester.pumpWidget(_shell(sheetAboveNav: true));
    await _scrollToEnd(tester);
    final double navTop = tester.getTopLeft(find.byKey(const Key('nav'))).dy;
    final Rect last = tester.getRect(find.byKey(const ValueKey<String>('trip 29')));
    expect(last.bottom, lessThanOrEqualTo(navTop), reason: 'last trip is not hidden behind the bottom navigation');
    expect(tester.takeException(), isNull);
  });

  testWidgets('regression: a sheet laid out to the screen bottom hides the last trip', (tester) async {
    await tester.pumpWidget(_shell(sheetAboveNav: false));
    await _scrollToEnd(tester);
    final double navTop = tester.getTopLeft(find.byKey(const Key('nav'))).dy;
    final Rect last = tester.getRect(find.byKey(const ValueKey<String>('trip 29')));
    expect(last.bottom, greaterThan(navTop), reason: 'the old layout put the end of the list under the nav bar');
  });

  testWidgets('the sheet expands by dragging and then scrolls with many trips', (tester) async {
    await tester.pumpWidget(_shell(sheetAboveNav: true, trips: 200));
    final double before = tester.getTopLeft(find.text('filters + replay card')).dy;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final double after = tester.getTopLeft(find.text('filters + replay card')).dy;
    expect(after, lessThan(before), reason: 'drag grows the sheet (snaps toward 0.88)');
    expect(tester.takeException(), isNull);
  });
}
