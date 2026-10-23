import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'app_date_range_picker.dart';

enum PeriodPreset { today, last7, last30, custom }

/// The period a page shows. Every admin page uses the same presets, so the same choice always
/// means the same days: Today, the last 7 days (today included), the last 30 days, or a custom range.
class ReportPeriod {
  const ReportPeriod._(this.preset, this.range);

  final PeriodPreset preset;

  /// First day 00:00 to last day 23:59:59.999 (local calendar days).
  final DateTimeRange range;

  static DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);
  static DateTime _endOf(DateTime d) => DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

  factory ReportPeriod.today([DateTime? now]) {
    final DateTime d = _day(now ?? DateTime.now());
    return ReportPeriod._(PeriodPreset.today, DateTimeRange(start: d, end: _endOf(d)));
  }

  factory ReportPeriod.lastDays(int days, [DateTime? now]) {
    final DateTime d = _day(now ?? DateTime.now());
    return ReportPeriod._(days == 7 ? PeriodPreset.last7 : PeriodPreset.last30,
        DateTimeRange(start: d.subtract(Duration(days: days - 1)), end: _endOf(d)));
  }

  factory ReportPeriod.custom(DateTimeRange r) =>
      ReportPeriod._(PeriodPreset.custom, DateTimeRange(start: _day(r.start), end: _endOf(r.end)));

  factory ReportPeriod.of(PeriodPreset p, [DateTime? now]) => switch (p) {
        PeriodPreset.today => ReportPeriod.today(now),
        PeriodPreset.last7 => ReportPeriod.lastDays(7, now),
        PeriodPreset.last30 => ReportPeriod.lastDays(30, now),
        PeriodPreset.custom => ReportPeriod.today(now),
      };

  DateTime get startDay => _day(range.start);
  DateTime get endDay => _day(range.end);
  int get days => endDay.difference(startDay).inDays + 1;
  bool get isSingleDay => days == 1;

  /// Short caption for cards and headers: "Today", "Last 7 days", "Oct 3 – Oct 9".
  String get label {
    switch (preset) {
      case PeriodPreset.today:
        return 'Today';
      case PeriodPreset.last7:
        return 'Last 7 days';
      case PeriodPreset.last30:
        return 'Last 30 days';
      case PeriodPreset.custom:
        return isSingleDay
            ? DateFormat('MMM d, yyyy').format(startDay)
            : '${DateFormat('MMM d').format(startDay)} – ${DateFormat('MMM d, yyyy').format(endDay)}';
    }
  }

  /// The same period again for a later "now" (a page left open past midnight); custom ranges stay.
  ReportPeriod refreshed([DateTime? now]) => preset == PeriodPreset.custom ? this : ReportPeriod.of(preset, now);
}

/// Segmented "Today | 7 days | 30 days | Custom" control used on every admin page.
class PeriodSelector extends StatelessWidget {
  const PeriodSelector({super.key, required this.value, required this.onChanged, this.maxDays, this.compact = false});

  final ReportPeriod value;
  final ValueChanged<ReportPeriod> onChanged;

  /// Longest custom range allowed (e.g. Route History loads at most 31 days).
  final int? maxDays;
  final bool compact;

  static const Color _teal = Color(0xFF00796B);
  static const Color _ink = Color(0xFF1F2A27);

  @override
  Widget build(BuildContext context) {
    Widget seg(String text, PeriodPreset p, {IconData? icon, VoidCallback? onTap}) {
      final bool on = value.preset == p;
      return Material(
        color: on ? _teal : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: ValueKey<String>('period-${p.name}'),
          borderRadius: BorderRadius.circular(10),
          onTap: onTap ?? () => onChanged(ReportPeriod.of(p)),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 9 : 12, vertical: compact ? 6 : 7),
            child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 14, color: on ? Colors.white : _teal),
                const SizedBox(width: 5),
              ],
              Text(text,
                  style: TextStyle(
                      fontSize: compact ? 12 : 12.5, fontWeight: FontWeight.w800, color: on ? Colors.white : _ink, letterSpacing: 0.1)),
            ]),
          ),
        ),
      );
    }

    Future<void> pickCustom() async {
      final DateTime today = DateTime.now();
      final AppDatePick? pick = await showAppDateRangePicker(
        context,
        initialRange: value.range,
        lastDate: today,
      );
      final DateTimeRange? r = pick?.range;
      if (r == null) return;
      DateTimeRange range = r;
      final int? max = maxDays;
      if (max != null && range.end.difference(range.start).inDays + 1 > max) {
        range = DateTimeRange(start: range.end.subtract(Duration(days: max - 1)), end: range.end);
      }
      onChanged(ReportPeriod.custom(range));
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F4),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFE2E8E6)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
        seg('Today', PeriodPreset.today),
        seg(compact ? '7d' : '7 days', PeriodPreset.last7),
        seg(compact ? '30d' : '30 days', PeriodPreset.last30),
        seg(value.preset == PeriodPreset.custom ? value.label : 'Custom', PeriodPreset.custom,
            icon: Icons.calendar_month_rounded, onTap: pickCustom),
      ]),
    );
  }
}
