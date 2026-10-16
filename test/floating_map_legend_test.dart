import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/widgets/floating_map_legend.dart';
import 'package:garbage_tracking_app/widgets/truck_legend.dart';

// A phone-like map screen: header (status bar 24 + 12 + 50), map controls on the right
// above a bottom area (nav bar + sheet).
const double _headerBottom = 24 + 12 + 50;
const double _bottomClear = 300;
const EdgeInsets _right = EdgeInsets.only(right: 12, top: _headerBottom + 10, bottom: _bottomClear);
const EdgeInsets _left = EdgeInsets.only(left: 12, top: _headerBottom + 54, bottom: 200);

int mapPans = 0;
int mapTaps = 0;
String? selected;

Widget _screen({Size size = const Size(412, 915), List<String> trucks = const <String>['GT-003', 'GT-001']}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Scaffold(
        body: Stack(children: [
          // Stand-in for the Mapbox map: counts gestures that reach it.
          Positioned.fill(
            child: GestureDetector(
              key: const Key('map'),
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (_) => mapPans++,
              onTap: () => mapTaps++,
            ),
          ),
          Positioned.fill(
            child: FloatingMapLegend(
              sessionId: 'test',
              leftInsets: _left,
              rightInsets: _right,
              child: TruckLegend(truckIds: trucks, decorated: false, selectedId: selected, onSelect: (String id) => selected = id),
            ),
          ),
          // Header painted on top, like the real screen.
          const Positioned(left: 0, right: 0, top: 0, height: _headerBottom, child: ColoredBox(key: Key('header'), color: Colors.black12)),
        ]),
      ),
    ),
  );
}

Rect _card(WidgetTester t) {
  final Finder f = find.byKey(const ValueKey<String>('legend-expanded'));
  return t.getRect(f.evaluate().isNotEmpty ? f : find.byKey(const ValueKey<String>('legend-collapsed')));
}

Future<void> _setSize(WidgetTester t, Size s) async {
  t.view.physicalSize = s;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

void _expectInsideSafeArea(Rect r, Size screen, EdgeInsets insets) {
  expect(r.top, greaterThanOrEqualTo(insets.top - 0.01), reason: 'below the header');
  expect(r.bottom, lessThanOrEqualTo(screen.height - insets.bottom + 0.01), reason: 'above controls / bottom nav');
  expect(r.left, greaterThanOrEqualTo(0));
  expect(r.right, lessThanOrEqualTo(screen.width));
}

void main() {
  setUp(() {
    FloatingMapLegend.resetSession();
    mapPans = 0;
    mapTaps = 0;
    selected = null;
  });

  testWidgets('initially fully visible, docked right, clear of the header', (t) async {
    await _setSize(t, const Size(412, 915));
    await t.pumpWidget(_screen());
    await t.pumpAndSettle();
    final Rect r = _card(t);
    _expectInsideSafeArea(r, const Size(412, 915), _right);
    expect(r.right, closeTo(412 - 12, 0.5));
    expect(find.text('GT-003'), findsOneWidget);
    expect(find.text('Marker ring = status'), findsOneWidget);
    expect(r.overlaps(t.getRect(find.byKey(const Key('header')))), isFalse);
  });

  testWidgets('dragging by the handle moves the legend and does not pan the map', (t) async {
    await _setSize(t, const Size(412, 915));
    await t.pumpWidget(_screen());
    await t.pumpAndSettle();
    final Rect before = _card(t);
    await t.drag(find.byKey(const ValueKey<String>('legend-handle')), const Offset(0, 150));
    await t.pumpAndSettle();
    final Rect after = _card(t);
    expect(after.top, closeTo(before.top + 150, 1));
    expect(mapPans, 0, reason: 'the map must not pan while the legend is dragged');

    // Outside the legend, map gestures still work.
    await t.dragFrom(const Offset(100, 600), const Offset(0, -80));
    await t.tapAt(const Offset(100, 600));
    expect(mapPans, greaterThan(0));
    expect(mapTaps, 1);
  });

  testWidgets('drag past the edges is clamped; release docks to the nearer side', (t) async {
    await _setSize(t, const Size(412, 915));
    await t.pumpWidget(_screen());
    await t.pumpAndSettle();
    // Far up: stops below the header.
    await t.drag(find.byKey(const ValueKey<String>('legend-handle')), const Offset(0, -2000));
    await t.pumpAndSettle();
    expect(_card(t).top, closeTo(_right.top, 0.5));
    // Far down: stops above the controls / bottom navigation.
    await t.drag(find.byKey(const ValueKey<String>('legend-handle')), const Offset(0, 4000));
    await t.pumpAndSettle();
    expect(_card(t).bottom, closeTo(915 - _right.bottom, 0.5));
    // Across to the left: docks to the left edge, inside the left safe band.
    await t.drag(find.byKey(const ValueKey<String>('legend-handle')), const Offset(-300, -2000));
    await t.pumpAndSettle();
    final Rect r = _card(t);
    expect(r.left, closeTo(12, 0.5));
    _expectInsideSafeArea(r, const Size(412, 915), _left);
  });

  testWidgets('collapse shows a compact tab; expand restores the real legend', (t) async {
    await _setSize(t, const Size(412, 915));
    await t.pumpWidget(_screen());
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey<String>('legend-collapse')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('legend-collapsed')), findsOneWidget);
    expect(find.text('GT-003'), findsNothing);
    final Rect tab = _card(t);
    expect(tab.height, lessThan(50));
    expect(tab.right, closeTo(412 - 12, 0.5), reason: 'stays docked on its edge');
    await t.tap(find.byKey(const ValueKey<String>('legend-expand')));
    await t.pumpAndSettle();
    expect(find.text('GT-003'), findsOneWidget);
    expect(find.text('GT-001'), findsOneWidget);
  });

  testWidgets('truck chips stay tappable inside the floating legend', (t) async {
    await _setSize(t, const Size(412, 915));
    await t.pumpWidget(_screen());
    await t.pumpAndSettle();
    await t.tap(find.text('GT-003'));
    expect(selected, 'GT-003');
    expect(mapTaps, 0);
  });

  testWidgets('resize / rotation recomputes bounds and keeps it visible', (t) async {
    await _setSize(t, const Size(412, 915));
    await t.pumpWidget(_screen());
    await t.pumpAndSettle();
    await t.drag(find.byKey(const ValueKey<String>('legend-handle')), const Offset(0, 4000)); // lowest
    await t.pumpAndSettle();

    t.view.physicalSize = const Size(915, 412); // landscape
    await t.pumpWidget(_screen(size: const Size(915, 412)));
    await t.pumpAndSettle();
    final Rect r = _card(t);
    // The right band (below header, above controls) is only 16 px in landscape here, so it
    // uses the left band; either way it hugs a screen edge of the NEW size.
    expect((r.left - 12).abs() < 0.5 || (r.right - (915 - 12)).abs() < 0.5, isTrue, reason: 'docked to an edge: $r');
    expect(r.top, greaterThanOrEqualTo(_right.top - 0.01), reason: 'never moves under the header');
    expect(r.bottom, lessThanOrEqualTo(412));
    expect(t.takeException(), isNull);

    t.view.physicalSize = const Size(1400, 900); // desktop window
    await t.pumpWidget(_screen(size: const Size(1400, 900)));
    await t.pumpAndSettle();
    _expectInsideSafeArea(_card(t), const Size(1400, 900), _right);
  });

  testWidgets('many trucks on a short screen: legend scrolls instead of covering the nav', (t) async {
    await _setSize(t, const Size(360, 640));
    await t.pumpWidget(_screen(size: const Size(360, 640), trucks: List<String>.generate(8, (int i) => 'GT-00${i + 1}')));
    await t.pumpAndSettle();
    final Rect r = _card(t);
    // Whichever side it uses, it stays inside that side's safe band.
    final EdgeInsets side = r.left < 180 ? _left : _right;
    _expectInsideSafeArea(r, const Size(360, 640), side);
    expect(t.takeException(), isNull);
  });

  testWidgets('a side with no room (map controls) falls back to the other side', (t) async {
    await _setSize(t, const Size(412, 915));
    const EdgeInsets crowdedRight = EdgeInsets.only(right: 12, top: 96, bottom: 800); // ~19 px band
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          Positioned.fill(
            child: FloatingMapLegend(
              sessionId: 'fallback',
              leftInsets: _left,
              rightInsets: crowdedRight,
              child: const TruckLegend(truckIds: <String>['GT-003', 'GT-001'], decorated: false),
            ),
          ),
        ]),
      ),
    ));
    await t.pumpAndSettle();
    final Rect r = _card(t);
    expect(r.left, closeTo(12, 0.5), reason: 'shown on the left, where it fits');
    _expectInsideSafeArea(r, const Size(412, 915), _left);
  });

  test('LegendBounds.effectiveDock keeps the chosen side when it fits, else the roomier one', () {
    const LegendBounds b = LegendBounds(
      area: Size(400, 800),
      leftInsets: EdgeInsets.only(top: 100, bottom: 300), // 400 band
      rightInsets: EdgeInsets.only(top: 100, bottom: 600), // 100 band
    );
    expect(b.effectiveDock(LegendDock.right, 80), LegendDock.right);
    expect(b.effectiveDock(LegendDock.right, 150), LegendDock.left);
    expect(b.effectiveDock(LegendDock.left, 500), LegendDock.left, reason: 'neither fits: taller band');
    expect(b.effectiveDock(LegendDock.right, 500), LegendDock.left);
    expect(b.maxHeightAnySide, 400);
  });

  testWidgets('position is remembered for the session', (t) async {
    await _setSize(t, const Size(412, 915));
    await t.pumpWidget(_screen());
    await t.pumpAndSettle();
    await t.drag(find.byKey(const ValueKey<String>('legend-handle')), const Offset(-300, 0));
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox()); // leave the screen
    await t.pumpWidget(_screen());
    await t.pumpAndSettle();
    expect(_card(t).left, closeTo(12, 0.5));
  });

  test('LegendBounds: a band shorter than the legend pins it to the top of the band', () {
    const LegendBounds b = LegendBounds(area: Size(400, 300), leftInsets: _left, rightInsets: _right);
    final (double minTop, double maxTop) = b.topRange(LegendDock.right, 250);
    expect(minTop, _right.top);
    expect(maxTop, _right.top);
    expect(b.maxHeight(LegendDock.right), 48.0);
  });
}
