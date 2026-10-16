import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/notification_inbox.dart';
import 'package:garbage_tracking_app/widgets/notification_center.dart';

import 'support/fake_rtdb.dart';

void main() {
  final DateTime now = DateTime(2026, 10, 16, 12);
  int at(int hoursAgo) => now.subtract(Duration(hours: hoursAgo)).millisecondsSinceEpoch;

  Map<String, Object> feed() => <String, Object>{
        'a': <String, Object>{'type': 'auto_approach', 'title': 'Garbage Truck Approaching', 'message': 'GT-007 is 5 min away', 'timestamp': at(1)},
        'b': <String, Object>{'type': 'auto_arrival', 'title': 'Truck arrived', 'message': 'GT-007 arrived', 'timestamp': at(2)},
        'c': <String, Object>{'type': 'COMPLAINT_RESOLVED', 'title': 'Complaint resolved', 'message': 'Done', 'timestamp': at(30)},
        'x': <String, Object>{'type': 'NEW_REGISTRATION', 'title': 'Not for me', 'timestamp': at(1)},
      };

  Future<(FakeRtdb, NotificationInbox)> pump(WidgetTester t, {List<Map>? opened}) async {
    final FakeRtdb db = FakeRtdb();
    final NotificationInbox inbox = NotificationInbox(db: db, role: 'resident', userId: 24);
    t.view.physicalSize = const Size(500, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NotificationCenter(
          source: Stream<Object?>.value(feed()),
          isRelevant: (Map n) => n['type'] != 'NEW_REGISTRATION',
          inbox: inbox,
          clock: () => now,
          onOpen: opened?.add,
        ),
      ),
    ));
    await t.pumpAndSettle();
    return (db, inbox);
  }

  testWidgets('shows relevant items grouped Today / Yesterday with unread count', (WidgetTester t) async {
    await pump(t);
    expect(find.text('Garbage Truck Approaching'), findsOneWidget);
    expect(find.text('Complaint resolved'), findsOneWidget);
    expect(find.text('Not for me'), findsNothing);
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('YESTERDAY'), findsOneWidget);
    expect(find.text('3 unread · 3 total'), findsOneWidget);
  });

  testWidgets('swipe left or right removes an item for this user only', (WidgetTester t) async {
    final (FakeRtdb db, NotificationInbox inbox) = await pump(t);
    await t.drag(find.text('Garbage Truck Approaching'), const Offset(-400, 0));
    await t.pumpAndSettle();
    expect(find.text('Garbage Truck Approaching'), findsNothing);
    await t.drag(find.text('Truck arrived'), const Offset(400, 0));
    await t.pumpAndSettle();
    expect(find.text('Truck arrived'), findsNothing);
    final InboxState s = await inbox.load();
    expect(s.dismissed, containsAll(<String>['a', 'b']));
  });

  testWidgets('Clear all (confirmed) empties the list', (WidgetTester t) async {
    final (FakeRtdb db, NotificationInbox inbox) = await pump(t);
    await t.tap(find.byKey(const ValueKey<String>('notif-clear-all')));
    await t.pumpAndSettle();
    expect(find.text('Clear all notifications?'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, 'Clear all'));
    await t.pumpAndSettle();
    expect(find.text('No notifications'), findsOneWidget);
    expect((await inbox.load()).clearedBeforeMs, at(1));
  });

  testWidgets('undo brings a removed item back', (WidgetTester t) async {
    await pump(t);
    await t.drag(find.text('Complaint resolved'), const Offset(-400, 0));
    await t.pumpAndSettle();
    expect(find.text('Complaint resolved'), findsNothing);
    await t.tap(find.text('UNDO'));
    await t.pumpAndSettle();
    expect(find.text('Complaint resolved'), findsOneWidget);
  });

  test('styles and relative time', () {
    expect(NotificationStyle.of(<String, Object>{'type': 'auto_arrival'}).label, 'Arrived');
    expect(NotificationStyle.of(<String, Object>{'type': 'manual_alert'}).label, 'Driver alert');
    expect(NotificationStyle.ago(<String, Object>{'timestamp': at(3)}, now), '3 hours ago');
  });
}
