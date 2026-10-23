import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/repeat_dates.dart';

void main() {
  test('Mon and Thu for four weeks from Monday Oct 26, 2026', () {
    final List<DateTime> d = weeklyRepeatDates(start: DateTime(2026, 10, 26), until: DateTime(2026, 11, 22), weekdays: <int>{1, 4});
    expect(d.length, 8);
    expect(d.first, DateTime(2026, 10, 26));
    expect(d[1], DateTime(2026, 10, 29));
    expect(d.last, DateTime(2026, 11, 19));
    expect(d.every((DateTime x) => x.weekday == 1 || x.weekday == 4), isTrue);
  });

  test('the start day is skipped when its weekday is not chosen; the limit is respected', () {
    expect(weeklyRepeatDates(start: DateTime(2026, 10, 26), until: DateTime(2026, 10, 27), weekdays: <int>{3}), isEmpty);
    expect(weeklyRepeatDates(start: DateTime(2026, 10, 26), until: DateTime(2027, 10, 26), weekdays: <int>{1, 2, 3, 4, 5, 6, 7}, max: 60).length, 60);
  });
}
