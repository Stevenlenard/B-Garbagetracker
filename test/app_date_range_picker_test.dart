import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/widgets/app_date_range_picker.dart';

void main() {
  Future<AppDatePick?> open(
    WidgetTester tester, {
    DateTimeRange? initialRange,
    DateTime? firstDate,
    DateTime? lastDate,
    bool singleDate = false,
    bool clearable = false,
    required Future<void> Function() interact,
  }) async {
    AppDatePick? result;
    bool closed = false;
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await showAppDateRangePicker(
                  context,
                  initialRange: initialRange,
                  firstDate: firstDate,
                  lastDate: lastDate,
                  singleDate: singleDate,
                  clearable: clearable,
                );
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await interact();
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    return result;
  }

  final DateTimeRange oct8to15 = DateTimeRange(start: DateTime(2026, 10, 8), end: DateTime(2026, 10, 15));

  testWidgets('one tap then apply returns a single whole day', (WidgetTester tester) async {
    final AppDatePick? r = await open(tester, initialRange: oct8to15, interact: () async {
      await tester.tap(find.text('20'));
      await tester.pump();
      expect(find.text('Oct 20, 2026'), findsOneWidget);
      await tester.tap(find.text('Apply Date Range'));
    });
    expect(r!.range!.start, DateTime(2026, 10, 20));
    expect(r.range!.end, DateTime(2026, 10, 20, 23, 59, 59));
    expect(r.isSingleDay, isTrue);
  });

  testWidgets('two taps return a range; an earlier second tap moves the start', (WidgetTester tester) async {
    final AppDatePick? r = await open(tester, initialRange: oct8to15, interact: () async {
      await tester.tap(find.text('12'));
      await tester.pump();
      await tester.tap(find.text('5'));
      await tester.pump();
      await tester.tap(find.text('22'));
      await tester.pump();
      expect(find.text('Oct 5 – Oct 22, 2026'), findsOneWidget);
      await tester.tap(find.text('Apply Date Range'));
    });
    expect(r!.range!.start, DateTime(2026, 10, 5));
    expect(r.range!.end, DateTime(2026, 10, 22, 23, 59, 59));
    expect(r.isSingleDay, isFalse);
  });

  testWidgets('cancel returns null (no change)', (WidgetTester tester) async {
    final AppDatePick? r = await open(tester, initialRange: oct8to15, interact: () async {
      await tester.tap(find.text('Cancel'));
    });
    expect(r, isNull);
  });

  testWidgets('clear is offered only when clearable', (WidgetTester tester) async {
    final AppDatePick? r = await open(tester, initialRange: oct8to15, clearable: true, interact: () async {
      await tester.tap(find.text('Clear'));
    });
    expect(r!.cleared, isTrue);
    expect(r.range, isNull);
  });

  testWidgets('days after lastDate cannot be selected', (WidgetTester tester) async {
    final AppDatePick? r = await open(
      tester,
      initialRange: DateTimeRange(start: DateTime(2026, 10, 8), end: DateTime(2026, 10, 8)),
      lastDate: DateTime(2026, 10, 15),
      interact: () async {
        await tester.tap(find.text('10'));
        await tester.pump();
        await tester.tap(find.text('20')); // disabled: ignored
        await tester.pump();
        await tester.tap(find.text('Apply Date Range'));
      },
    );
    expect(r!.range!.start, DateTime(2026, 10, 10));
    expect(r.range!.end, DateTime(2026, 10, 10, 23, 59, 59));
  });

  testWidgets('single-date mode never forms a range', (WidgetTester tester) async {
    final AppDatePick? r = await open(tester, initialRange: oct8to15, singleDate: true, interact: () async {
      expect(find.text('Select Date'), findsOneWidget);
      await tester.tap(find.text('12'));
      await tester.pump();
      await tester.tap(find.text('18'));
      await tester.pump();
      await tester.tap(find.text('Apply Date'));
    });
    expect(r!.range!.start, DateTime(2026, 10, 18));
    expect(r.isSingleDay, isTrue);
  });
}
