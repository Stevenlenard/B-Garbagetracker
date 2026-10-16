import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/chatbot/faq_bot.dart';
import 'package:garbage_tracking_app/chatbot/fleet_snapshot.dart';
import 'package:garbage_tracking_app/widgets/truck_chat_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(TruckChatLauncher.debugResetSpots);

  Future<List<BotAction>> pump(WidgetTester t, String role) async {
    final List<BotAction> opened = <BotAction>[];
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: Stack(children: [const Positioned.fill(child: ColoredBox(color: Colors.white)), TruckChatLauncher(role: role, onAction: opened.add, fleet: const Stream<FleetSnapshot>.empty(), schedules: const Stream.empty(), loadStats: () async => null)])),
    ));
    await t.tap(find.byIcon(Icons.local_shipping_rounded));
    await t.pump(const Duration(milliseconds: 400));
    return opened;
  }

  Future<void> ask(WidgetTester t, String q) async {
    await t.enterText(find.byType(TextField), q);
    await t.testTextInput.receiveAction(TextInputAction.send);
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a resident gets an answer with a button that opens the screen', (WidgetTester t) async {
    final List<BotAction> opened = await pump(t, 'resident');
    expect(find.text('Truck Buddy'), findsOneWidget);
    await ask(t, 'nasaan na ang truck');
    expect(find.textContaining('Open Truck Tracking to see every truck'), findsOneWidget);
    await t.ensureVisible(find.text('Open Truck Tracking'));
    await t.pump();
    await t.tap(find.text('Open Truck Tracking'));
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 400));
    expect(opened, <BotAction>[BotAction.track]);
    expect(find.text('Truck Buddy'), findsNothing); // panel closed after navigating
  });

  testWidgets('a resident asking an admin-only question is declined', (WidgetTester t) async {
    await pump(t, 'resident');
    await ask(t, 'how do I approve new users');
    expect(find.text('Administrator only'), findsOneWidget);
    expect(find.textContaining('Pending driver registrations'), findsNothing);
  });

  testWidgets('the launcher is a Positioned and does not resize its Stack', (WidgetTester t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 500, height: 400, child: Stack(key: ValueKey<String>('host'), children: [TruckChatLauncher(role: 'driver', fleet: Stream<FleetSnapshot>.empty())]))))));
    expect(t.getSize(find.byKey(const ValueKey<String>('host'))), const Size(500, 400));
  });

  testWidgets('the button can be dragged and taps still reach the page under it', (WidgetTester t) async {
    int pageTaps = 0;
    t.view.physicalSize = const Size(1000, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: Stack(children: [
        Positioned.fill(child: GestureDetector(onTap: () => pageTaps++, child: const ColoredBox(color: Colors.white))),
        const TruckChatLauncher(role: 'resident', fleet: Stream<FleetSnapshot>.empty()),
      ])),
    ));
    final Finder btn = find.byIcon(Icons.local_shipping_rounded);
    final Offset before = t.getCenter(btn);
    await t.drag(btn, const Offset(-400, -300));
    await t.pump();
    final Offset after = t.getCenter(btn);
    expect(after.dx, lessThan(before.dx - 300));
    expect(after.dy, lessThan(before.dy - 200));
    await t.tapAt(const Offset(900, 700)); // where the button used to be
    expect(pageTaps, 1);
  });

  testWidgets('the open chat can be dragged by its header and stays open', (WidgetTester t) async {
    await pump(t, 'resident');
    final Finder title = find.text('Truck Buddy');
    final Offset before = t.getCenter(title);
    final TestGesture g = await t.startGesture(before);
    await g.moveBy(const Offset(-30, 0));
    await t.pump();
    await g.moveBy(const Offset(-470, 0));
    await t.pump();
    await g.up();
    await t.pump();
    expect(find.text('Truck Buddy'), findsOneWidget);
    expect(t.getCenter(title).dx, lessThan(before.dx - 400));
  });

  test('truck registry counts only real trucks (plate number, not "Unknown")', () {
    expect(
      TruckChatLauncherCounting.registeredTrucks(<String, Object>{
        'GT-001': <String, Object>{'plateNumber': 'ABC 123'},
        'GT-002': <String, Object>{'plateNumber': 'XYZ 9'},
        'Unknown': <String, Object>{'plateNumber': 'x'},
        'GT-009': <String, Object>{'odometerKm': 1},
      }),
      2,
    );
  });

  testWidgets('the conversation is kept: a new chat window shows the earlier messages', (WidgetTester t) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await pump(t, 'admin');
    await ask(t, 'how can i manage complaints');
    expect(find.textContaining('Complaint Management (called Complaint Center on phones)'), findsOneWidget);
    // Leave the page (the launcher is disposed), then come back: the discussion is still there.
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await pump(t, 'admin');
    await t.pump(const Duration(milliseconds: 100));
    // The chat opens at the newest message; scrolling up shows the earlier discussion.
    await t.drag(find.byType(ListView), const Offset(0, 2000));
    await t.pump(const Duration(milliseconds: 600));
    expect(find.text('how can i manage complaints'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    // A short follow-up uses the previous question.
    await ask(t, 'paano?');
    expect(find.textContaining('Complaint Management (called Complaint Center on phones)'), findsWidgets);
    expect(find.textContaining('not sure I understood'), findsNothing);
    expect(find.textContaining("don't have an answer"), findsNothing);
    // Start over clears it.
    await t.tap(find.byTooltip('Start over'));
    await t.pump();
    expect(find.text('how can i manage complaints'), findsNothing);
  });
}
