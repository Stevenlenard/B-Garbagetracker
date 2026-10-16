import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Result of [showAppDateRangePicker]. `null` from the dialog means it was cancelled
/// (no change); [cleared] is only returned when the caller allowed clearing.
class AppDatePick {
  /// First day 00:00:00 to last day 23:59:59 (a single day when start and end share a date).
  final DateTimeRange? range;
  final bool cleared;
  const AppDatePick._(this.range, this.cleared);
  const AppDatePick.range(DateTimeRange r) : this._(r, false);
  static const AppDatePick clearedPick = AppDatePick._(null, true);

  bool get isSingleDay => range != null && DateUtils.isSameDay(range!.start, range!.end);
}

/// The app's one date picker (the "Select Date Range" calendar from GIS Route History).
///
/// One tap selects a single day; a second tap on a later day extends it to a range (a tap on
/// an earlier day moves the start). Tapping again after a range is complete starts a new
/// selection. With [singleDate] every tap selects just that day, for fields that need exactly
/// one date. Days outside [firstDate]..[lastDate] are disabled.
Future<AppDatePick?> showAppDateRangePicker(
  BuildContext context, {
  DateTimeRange? initialRange,
  DateTime? firstDate,
  DateTime? lastDate,
  bool singleDate = false,
  bool clearable = false,
  String? title,
  String? applyLabel,
}) {
  return showDialog<AppDatePick>(
    context: context,
    builder: (BuildContext context) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: AppDateRangePicker(
          initialRange: initialRange,
          firstDate: firstDate,
          lastDate: lastDate,
          singleDate: singleDate,
          clearable: clearable,
          title: title ?? (singleDate ? 'Select Date' : 'Select Date Range'),
          applyLabel: applyLabel ?? (singleDate ? 'Apply Date' : 'Apply Date Range'),
        ),
      ),
    ),
  );
}

/// Convenience for single-date fields: returns the chosen day (00:00) or null when cancelled.
Future<DateTime?> showAppSingleDatePicker(
  BuildContext context, {
  DateTime? initialDate,
  DateTime? firstDate,
  DateTime? lastDate,
  String? title,
}) async {
  final AppDatePick? pick = await showAppDateRangePicker(
    context,
    initialRange: initialDate == null ? null : DateTimeRange(start: initialDate, end: initialDate),
    firstDate: firstDate,
    lastDate: lastDate,
    singleDate: true,
    title: title,
  );
  return pick?.range == null ? null : DateUtils.dateOnly(pick!.range!.start);
}

class AppDateRangePicker extends StatefulWidget {
  final DateTimeRange? initialRange;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final bool singleDate;
  final bool clearable;
  final String title;
  final String applyLabel;

  const AppDateRangePicker({
    super.key,
    this.initialRange,
    this.firstDate,
    this.lastDate,
    this.singleDate = false,
    this.clearable = false,
    this.title = 'Select Date Range',
    this.applyLabel = 'Apply Date Range',
  });

  @override
  State<AppDateRangePicker> createState() => _AppDateRangePickerState();
}

class _AppDateRangePickerState extends State<AppDateRangePicker> {
  static const Color _teal = Color(0xFF00796B);
  static const Color _tealLight = Color(0xFFE0F2F1);

  late DateTime _currentMonth;
  DateTime? _rangeStart;
  DateTime? _rangeEnd;
  // True while only a start day is chosen and the next tap may extend it to a range.
  bool _awaitingEnd = false;

  DateTime? get _first => widget.firstDate == null ? null : DateUtils.dateOnly(widget.firstDate!);
  DateTime? get _last => widget.lastDate == null ? null : DateUtils.dateOnly(widget.lastDate!);

  @override
  void initState() {
    super.initState();
    final DateTimeRange? r = widget.initialRange;
    if (r != null) {
      _rangeStart = DateUtils.dateOnly(r.start);
      _rangeEnd = DateUtils.dateOnly(widget.singleDate ? r.start : r.end);
    }
    final DateTime anchor = _rangeStart ?? _clamp(DateUtils.dateOnly(DateTime.now()));
    _currentMonth = DateTime(anchor.year, anchor.month);
  }

  DateTime _clamp(DateTime d) {
    if (_first != null && d.isBefore(_first!)) return _first!;
    if (_last != null && d.isAfter(_last!)) return _last!;
    return d;
  }

  bool _enabled(DateTime d) => !(_first != null && d.isBefore(_first!)) && !(_last != null && d.isAfter(_last!));

  void _onDayTapped(DateTime date) {
    setState(() {
      if (widget.singleDate || !_awaitingEnd || _rangeStart == null) {
        _rangeStart = date;
        _rangeEnd = date;
        _awaitingEnd = !widget.singleDate;
      } else if (date.isBefore(_rangeStart!)) {
        _rangeStart = date;
      } else {
        _rangeEnd = date;
        _awaitingEnd = false;
      }
    });
  }

  bool get _canGoBack => _first == null || DateTime(_currentMonth.year, _currentMonth.month).isAfter(DateTime(_first!.year, _first!.month));
  bool get _canGoForward => _last == null || DateTime(_currentMonth.year, _currentMonth.month).isBefore(DateTime(_last!.year, _last!.month));

  @override
  Widget build(BuildContext context) {
    final bool hasRange = _rangeStart != null && _rangeEnd != null;
    final bool isSingleDay = hasRange && DateUtils.isSameDay(_rangeStart, _rangeEnd);

    final String dateDisplay = _rangeStart == null
        ? (widget.singleDate ? 'Tap a day' : 'Tap a day, or two days for a range')
        : (isSingleDay
            ? DateFormat('MMM d, yyyy').format(_rangeStart!)
            : "${DateFormat('MMM d').format(_rangeStart!)} – ${DateFormat('MMM d, yyyy').format(_rangeEnd!)}");

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 20, spreadRadius: -2)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: _teal)),
                    const SizedBox(height: 2),
                    Text(dateDisplay, style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              if (widget.clearable)
                TextButton(
                  onPressed: () => Navigator.pop(context, AppDatePick.clearedPick),
                  child: const Text('Clear', style: TextStyle(fontWeight: FontWeight.bold, color: _teal)),
                ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: Colors.grey),
              ),
            ],
          ),
          const Divider(height: 28),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(DateFormat('MMMM yyyy').format(_currentMonth), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Color(0xFF1A1A1A))),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left_rounded),
                    onPressed: _canGoBack ? () => setState(() => _currentMonth = DateTime(_currentMonth.year, _currentMonth.month - 1)) : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right_rounded),
                    onPressed: _canGoForward ? () => setState(() => _currentMonth = DateTime(_currentMonth.year, _currentMonth.month + 1)) : null,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: const [
              Text("S", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
              Text("M", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
              Text("T", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
              Text("W", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
              Text("T", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
              Text("F", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
              Text("S", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),

          _buildDaysGrid(),

          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.grey,
                    side: const BorderSide(color: Colors.grey),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text("Cancel", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: _rangeStart != null
                      ? () {
                          final DateTime s = _rangeStart!;
                          final DateTime e = _rangeEnd ?? s;
                          Navigator.pop(
                            context,
                            AppDatePick.range(DateTimeRange(
                              start: DateTime(s.year, s.month, s.day),
                              end: DateTime(e.year, e.month, e.day, 23, 59, 59),
                            )),
                          );
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _teal,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(widget.applyLabel, style: const TextStyle(fontWeight: FontWeight.w900)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDaysGrid() {
    final DateTime firstDayOfMonth = DateTime(_currentMonth.year, _currentMonth.month, 1);
    final int daysInMonth = DateTime(_currentMonth.year, _currentMonth.month + 1, 0).day;
    final int leadingPadding = firstDayOfMonth.weekday % 7;

    final List<Widget> dayWidgets = [];
    for (int i = 0; i < leadingPadding; i++) {
      dayWidgets.add(const SizedBox.shrink());
    }

    for (int day = 1; day <= daysInMonth; day++) {
      final DateTime date = DateTime(_currentMonth.year, _currentMonth.month, day);
      final bool enabled = _enabled(date);
      final bool isStart = _rangeStart != null && DateUtils.isSameDay(date, _rangeStart);
      final bool isEnd = _rangeEnd != null && DateUtils.isSameDay(date, _rangeEnd);
      final bool isInRange = _rangeStart != null && _rangeEnd != null && date.isAfter(_rangeStart!) && date.isBefore(_rangeEnd!);

      dayWidgets.add(
        GestureDetector(
          onTap: enabled ? () => _onDayTapped(date) : null,
          child: Container(
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: isStart || isEnd ? _teal : (isInRange ? _tealLight : Colors.transparent),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              "$day",
              style: TextStyle(
                fontSize: 12,
                fontWeight: isStart || isEnd || isInRange ? FontWeight.bold : FontWeight.normal,
                color: !enabled
                    ? Colors.black26
                    : (isStart || isEnd ? Colors.white : (isInRange ? _teal : Colors.black87)),
              ),
            ),
          ),
        ),
      );
    }

    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: dayWidgets,
    );
  }
}
