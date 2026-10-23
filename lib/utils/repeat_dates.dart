/// Dates a weekly repeat creates: every day from [start] to [until] (inclusive) whose weekday
/// (1 = Monday ... 7 = Sunday) is in [weekdays], in order, at most [max] dates.
List<DateTime> weeklyRepeatDates({required DateTime start, required DateTime until, required Set<int> weekdays, int max = 60}) {
  final List<DateTime> out = <DateTime>[];
  for (DateTime d = DateTime(start.year, start.month, start.day);
      !d.isAfter(until) && out.length < max;
      d = DateTime(d.year, d.month, d.day + 1)) {
    if (weekdays.contains(d.weekday)) out.add(d);
  }
  return out;
}
