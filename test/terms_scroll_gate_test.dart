import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/widgets/terms_acceptance_dialog.dart';

void main() {
  testWidgets('the agreement can be ticked only after both documents were scrolled to the end', (WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => TermsAcceptanceDialog.show(context, onAcceptAndSubmit: () async => true),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle(const Duration(seconds: 1));

    Checkbox box() => t.widget<Checkbox>(find.byType(Checkbox));
    expect(box().onChanged, isNull, reason: 'not read yet');
    expect(find.text('Scroll to the end of both documents to continue.'), findsOneWidget);

    // Terms: scroll to the end.
    await t.fling(find.byType(SingleChildScrollView).first, const Offset(0, -20000), 8000);
    await t.pumpAndSettle();
    expect(box().onChanged, isNull, reason: 'privacy policy not read yet');

    // Privacy policy: open the tab and scroll to the end.
    await t.tap(find.text('Privacy Policy'));
    await t.pumpAndSettle();
    await t.fling(find.byType(SingleChildScrollView).last, const Offset(0, -20000), 8000);
    await t.pumpAndSettle();
    expect(box().onChanged, isNotNull);
    expect(find.text('Scroll to the end of both documents to continue.'), findsNothing);
  });
}
