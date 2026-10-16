import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/widgets/map_view_switch.dart';

void main() {
  testWidgets('Map | Route plan switch reports the tapped view and ignores the current one', (WidgetTester tester) async {
    final List<int> taps = <int>[];
    int selected = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) => MapViewSwitch(
              options: kMapRoutePlanOptions,
              selected: selected,
              onChanged: (int i) => setState(() {
                taps.add(i);
                selected = i;
              }),
            ),
          ),
        ),
      ),
    ));
    expect(find.text('Map'), findsOneWidget);
    expect(find.text('Route plan'), findsOneWidget);

    await tester.tap(find.text('Map')); // already selected
    await tester.pump();
    expect(taps, isEmpty);

    await tester.tap(find.text('Route plan'));
    await tester.pump();
    expect(taps, <int>[1]);

    await tester.tap(find.text('Map'));
    await tester.pump();
    expect(taps, <int>[1, 0]);
  });
}
