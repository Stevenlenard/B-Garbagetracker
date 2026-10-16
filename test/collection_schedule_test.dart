import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/chatbot/faq_bot.dart';
import 'package:garbage_tracking_app/screens/collection_schedule_screen.dart';
import 'package:garbage_tracking_app/services/collection_reminder_service.dart';
import 'package:garbage_tracking_app/services/collection_schedule_service.dart';

void main() {
  const CollectionSchedule central = CollectionSchedule(area: 'Central (Purok 1)', days: <int>[1, 4], time: '07:00');

  test('reminders: evening before at 7 PM and an hour before collection', () {
    final List<ReminderSlot> p = CollectionReminderService.plan(central);
    expect(p.length, 4);
    final ReminderSlot sunEvening = p.firstWhere((ReminderSlot r) => r.weekday == 7);
    expect((sunEvening.hour, sunEvening.minute), (19, 0));
    expect(sunEvening.title, 'Garbage collection tomorrow');
    final ReminderSlot monMorning = p.firstWhere((ReminderSlot r) => r.weekday == 1);
    expect((monMorning.hour, monMorning.minute), (6, 0));
    expect(p.map((ReminderSlot r) => r.id).toSet().length, 4, reason: 'unique ids');
    final ReminderSlot early = CollectionReminderService.plan(const CollectionSchedule(area: 'X', days: <int>[2], time: '05:30')).last;
    expect((early.hour, early.minute), (5, 0), reason: 'never before 5:00 AM');
  });

  test('labels and storage round trip', () {
    expect(central.summary, 'every Monday and Thursday, around 7:00 AM');
    final CollectionSchedule? back = CollectionSchedule.fromJson(<String, Object>{'area': central.area, 'days': <int>[4, 1], 'time': '07:00'});
    expect(back!.daysLabel, 'Monday and Thursday');
    expect(CollectionScheduleService.keyFor('Purok 4 / El Pueblo'), 'Purok 4 _ El Pueblo');
  });

  testWidgets('admin picks days and time, then saves', (WidgetTester t) async {
    t.view.physicalSize = const Size(900, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final List<CollectionSchedule> saved = <CollectionSchedule>[];
    await t.pumpWidget(MaterialApp(
      home: CollectionScheduleScreen(
        areaNames: const <String>['Riverside', 'Purok 2'],
        schedules: Stream<Map<String, CollectionSchedule>>.value(const <String, CollectionSchedule>{}),
        onSave: (CollectionSchedule s) async => saved.add(s),
        onRemove: (_) async {},
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('0 of 2 areas scheduled'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey<String>('day-Riverside-2')));
    await t.tap(find.byKey(const ValueKey<String>('day-Riverside-5')));
    await t.pump();
    expect(find.text('Tue · Fri  7:00 AM'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey<String>('save-Riverside')));
    await t.pumpAndSettle();
    expect(saved.single.area, 'Riverside');
    expect(saved.single.days, <int>[2, 5]);
  });

  test('admins asking how to set the schedule get the how-to', () {
    expect(FaqBot(BotRole.admin).reply('how do i set the collection schedule', schedules: const <String, CollectionSchedule>{}).entry?.id, 'admin_schedule');
  });
}
