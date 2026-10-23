import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/api_service.dart';
import '../models/route_assignment.dart';
import '../services/collection_schedule_service.dart';
import '../utils/repeat_dates.dart';
import '../services/route_assignment_service.dart';
import '../services/service_area_service.dart';
import '../utils/app_theme.dart';
import '../utils/custom_notification.dart';
import '../widgets/app_date_range_picker.dart';

/// Admin: assign a driver + truck + service areas to a collection date, and follow the
/// server-computed status (Pending, In Progress, Completed, Missed, Cancelled).
/// Data comes only from the assignment endpoints; nothing is computed or stored locally.
class RouteAssignmentsScreen extends StatefulWidget {
  const RouteAssignmentsScreen({super.key, this.isEmbedded = false, this.onBack, this.service});

  final bool isEmbedded;
  final VoidCallback? onBack;
  final RouteAssignmentService? service;

  @override
  State<RouteAssignmentsScreen> createState() => _RouteAssignmentsScreenState();
}

class _DriverOption {
  const _DriverOption(this.id, this.name, this.truck);
  final int id;
  final String name;
  final String truck;
}

const Color _teal = Color(0xFF00796B);
const Color _ink = Color(0xFF1A1A1A);
const Color _muted = Color(0xFF6B7280);
const Color _line = Color(0xFFE5E7EB);
const Color _mint = Color(0xFFE0F2F1);
const Color _pageBg = Color(0xFFF8F9FA);

String _initials(String name) {
  final List<String> parts = name.trim().split(RegExp(r'\s+')).where((String p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
}

IconData _statusIcon(AssignmentStatus s) {
  switch (s) {
    case AssignmentStatus.pending:
      return Icons.schedule_rounded;
    case AssignmentStatus.inProgress:
      return Icons.local_shipping_rounded;
    case AssignmentStatus.completed:
      return Icons.check_circle_rounded;
    case AssignmentStatus.missed:
      return Icons.error_outline_rounded;
    case AssignmentStatus.cancelled:
    case AssignmentStatus.unknown:
      return Icons.cancel_outlined;
  }
}

class _RouteAssignmentsScreenState extends State<RouteAssignmentsScreen> {
  late final RouteAssignmentService _service = widget.service ?? RouteAssignmentService();
  final ApiService _api = ApiService();
  final DateFormat _day = DateFormat('yyyy-MM-dd');

  late DateTimeRange _range;
  bool _loading = true;
  String? _error;
  AssignmentFailure _failure = AssignmentFailure.none;
  List<RouteAssignment> _items = <RouteAssignment>[];
  AssignmentSummary _summary = AssignmentSummary.empty;
  AssignmentStatus? _statusFilter;

  List<_DriverOption> _drivers = <_DriverOption>[];
  Map<int, String> _driverNames = <int, String>{};
  List<ServiceArea> _areas = <ServiceArea>[];

  @override
  void initState() {
    super.initState();
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    _range = DateTimeRange(start: today, end: today.add(const Duration(days: 6)));
    _load();
    _loadOptions();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final AssignmentResult<AssignmentList> r =
        await _service.list(startDate: _day.format(_range.start), endDate: _day.format(_range.end));
    if (!mounted) return;
    setState(() {
      _loading = false;
      _failure = r.failure;
      if (r.isOk) {
        _items = r.value!.items;
        _summary = r.value!.summary;
      } else {
        _error = r.message;
        _items = <RouteAssignment>[];
        _summary = AssignmentSummary.empty;
      }
    });
  }

  Future<void> _loadOptions() async {
    try {
      final res = await _api.getUsers();
      final List raw = (res.data is Map && res.data['success'] == true) ? (res.data['users'] as List? ?? const []) : const [];
      final List<_DriverOption> drivers = <_DriverOption>[];
      final Map<int, String> names = <int, String>{};
      for (final Object? u in raw) {
        if (u is! Map || (u['role'] ?? '').toString().toLowerCase() != 'driver') continue;
        final int id = int.tryParse(u['user_id'].toString()) ?? 0;
        if (id <= 0) continue;
        names[id] = (u['name'] ?? 'Driver $id').toString();
        if (u['is_archived'].toString() == '1') continue;
        drivers.add(_DriverOption(id, names[id]!, (u['preferred_truck'] ?? '').toString()));
      }
      drivers.sort((_DriverOption a, _DriverOption b) => a.name.compareTo(b.name));
      final List<ServiceArea> areas = await ServiceAreaService().getTruckCollectionStops();
      if (!mounted) return;
      setState(() {
        _drivers = drivers;
        _driverNames = names;
        _areas = areas;
      });
    } catch (e) {
      debugPrint('[ASSIGNMENTS] options could not be loaded: $e');
    }
  }

  Future<void> _pickRange() async {
    final AppDatePick? pick = await showAppDateRangePicker(
      context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      initialRange: _range,
    );
    final DateTimeRange? r = pick?.range;
    if (r == null) return;
    setState(() => _range = r);
    _load();
  }

  /// Moves the shown period by its own length (a week stays a week).
  void _shiftRange(int direction) {
    final int days = _range.end.difference(_range.start).inDays + 1;
    setState(() => _range = DateTimeRange(
          start: _range.start.add(Duration(days: days * direction)),
          end: _range.end.add(Duration(days: days * direction)),
        ));
    _load();
  }

  Future<void> _openForm([RouteAssignment? existing]) async {
    if (_drivers.isEmpty || _areas.isEmpty) {
      CustomNotification.showTopNotification(context, 'Drivers or service areas are still loading. Try again in a moment.', true);
      _loadOptions();
      return;
    }
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => _AssignmentForm(
        service: _service,
        drivers: _drivers,
        areas: _areas,
        existing: existing,
      ),
    );
    if (saved == true) _load();
  }

  Future<void> _cancel(RouteAssignment a) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.event_busy_rounded, color: Color(0xFFC62828), size: 32),
        title: const Text('Cancel assignment?'),
        content: Text(
          'The ${_prettyDate(a.date)} assignment for ${_driverNames[a.driverId] ?? 'driver ${a.driverId}'} will be marked Cancelled. The record is kept.',
          textAlign: TextAlign.center,
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFC62828)),
            child: const Text('Cancel assignment'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final AssignmentResult<RouteAssignment> r = await _service.cancel(a.id);
    if (!mounted) return;
    CustomNotification.showTopNotification(context, r.isOk ? 'Assignment cancelled.' : (r.message ?? 'Could not cancel.'), !r.isOk);
    _load();
  }

  static Color statusColor(AssignmentStatus s) {
    switch (s) {
      case AssignmentStatus.pending:
        return const Color(0xFF1E88E5);
      case AssignmentStatus.inProgress:
        return const Color(0xFFF59E0B);
      case AssignmentStatus.completed:
        return const Color(0xFF2E7D32);
      case AssignmentStatus.missed:
        return const Color(0xFFC62828);
      case AssignmentStatus.cancelled:
      case AssignmentStatus.unknown:
        return Colors.blueGrey;
    }
  }

  String _prettyDate(String ymd) {
    final DateTime? d = DateTime.tryParse(ymd);
    return d == null ? ymd : DateFormat('EEE, MMM d').format(d);
  }

  String _dayHeader(String ymd) {
    final DateTime? d = DateTime.tryParse(ymd);
    if (d == null) return ymd;
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final int diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
    final String pretty = DateFormat('EEEE, MMMM d').format(d);
    if (diff == 0) return 'Today · $pretty';
    if (diff == 1) return 'Tomorrow · $pretty';
    if (diff == -1) return 'Yesterday · $pretty';
    return pretty;
  }

  @override
  Widget build(BuildContext context) {
    final List<RouteAssignment> shown =
        _statusFilter == null ? _items : _items.where((RouteAssignment a) => a.status == _statusFilter).toList();
    // Group by date, in date order.
    final Map<String, List<RouteAssignment>> byDay = <String, List<RouteAssignment>>{};
    for (final RouteAssignment a in List<RouteAssignment>.of(shown)..sort((RouteAssignment x, RouteAssignment y) => x.date.compareTo(y.date))) {
      byDay.putIfAbsent(a.date, () => <RouteAssignment>[]).add(a);
    }
    return Scaffold(
      backgroundColor: _pageBg,
      body: SafeArea(
        child: LayoutBuilder(builder: (BuildContext context, BoxConstraints box) {
          final bool wide = box.maxWidth >= 720;
          final double pad = wide ? 24 : 16;
          return RefreshIndicator(
            color: _teal,
            onRefresh: _load,
            child: ListView(
              padding: EdgeInsets.fromLTRB(pad, pad, pad, 120),
              children: <Widget>[
                _header(wide),
                const SizedBox(height: 16),
                _toolbar(),
                const SizedBox(height: 14),
                _summaryTiles(box.maxWidth - pad * 2),
                const SizedBox(height: 18),
                if (_loading)
                  const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator(color: _teal)))
                else if (_error != null)
                  _stateBox(Icons.cloud_off_rounded, _error!, retry: _failure != AssignmentFailure.notConfigured)
                else if (shown.isEmpty)
                  _emptyState()
                else
                  for (final MapEntry<String, List<RouteAssignment>> day in byDay.entries) ...<Widget>[
                    _dayLabel(day.key, day.value.length, box.maxWidth - pad * 2),
                    _cardGrid(day.value, box.maxWidth - pad * 2),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _header(bool wide) {
    final Widget newButton = FilledButton.icon(
      onPressed: _failure == AssignmentFailure.none && !_loading ? () => _openForm() : null,
      icon: const Icon(Icons.add_rounded, size: 20),
      label: const Text('New assignment'),
      style: FilledButton.styleFrom(
        backgroundColor: _teal,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    );
    final Widget title = Row(children: <Widget>[
      if (widget.onBack != null)
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: IconButton(onPressed: widget.onBack, icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20)),
        ),
      Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: _mint, borderRadius: BorderRadius.circular(14)),
        child: const Icon(Icons.assignment_ind_rounded, color: _teal),
      ),
      const SizedBox(width: 12),
      const Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('Route Assignments', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: _ink)),
          SizedBox(height: 2),
          Text('Who collects where, with which truck, on each collection day',
              style: TextStyle(fontSize: 12.5, color: _muted)),
        ]),
      ),
    ]);
    if (wide) return Row(children: <Widget>[Expanded(child: title), const SizedBox(width: 12), newButton]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[title, const SizedBox(height: 12), newButton]);
  }

  Widget _toolbar() {
    final String label = DateUtils.isSameDay(_range.start, _range.end)
        ? DateFormat('MMM d, yyyy').format(_range.start)
        : '${DateFormat('MMM d').format(_range.start)} – ${DateFormat('MMM d, yyyy').format(_range.end)}';
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _line)),
      child: Row(children: <Widget>[
        IconButton(onPressed: _loading ? null : () => _shiftRange(-1), icon: const Icon(Icons.chevron_left_rounded), tooltip: 'Previous period'),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _pickRange,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
                const Icon(Icons.calendar_month_rounded, size: 18, color: _teal),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800, color: _ink, fontSize: 14)),
                ),
              ]),
            ),
          ),
        ),
        IconButton(onPressed: _loading ? null : () => _shiftRange(1), icon: const Icon(Icons.chevron_right_rounded), tooltip: 'Next period'),
        Container(width: 1, height: 24, color: _line),
        IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh_rounded, color: _teal), tooltip: 'Refresh'),
      ]),
    );
  }

  Widget _summaryTiles(double width) {
    final List<(AssignmentStatus?, String, int, Color, IconData)> tiles = <(AssignmentStatus?, String, int, Color, IconData)>[
      (null, 'All', _summary.total, _teal, Icons.dashboard_rounded),
      (AssignmentStatus.pending, 'Pending', _summary.pending, statusColor(AssignmentStatus.pending), _statusIcon(AssignmentStatus.pending)),
      (AssignmentStatus.inProgress, 'In Progress', _summary.inProgress, statusColor(AssignmentStatus.inProgress), _statusIcon(AssignmentStatus.inProgress)),
      (AssignmentStatus.completed, 'Completed', _summary.completed, statusColor(AssignmentStatus.completed), _statusIcon(AssignmentStatus.completed)),
      (AssignmentStatus.missed, 'Missed', _summary.missed, statusColor(AssignmentStatus.missed), _statusIcon(AssignmentStatus.missed)),
      (AssignmentStatus.cancelled, 'Cancelled', _summary.cancelled, statusColor(AssignmentStatus.cancelled), _statusIcon(AssignmentStatus.cancelled)),
    ];
    // 6 across on wide screens, 3 on tablets, 2 on phones.
    final int cols = width >= 900 ? 6 : (width >= 480 ? 3 : 2);
    const double gap = 10;
    final double w = (width - gap * (cols - 1)) / cols;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: <Widget>[
        for (final (AssignmentStatus?, String, int, Color, IconData) t in tiles) SizedBox(width: w, child: _tile(t.$1, t.$2, t.$3, t.$4, t.$5)),
      ],
    );
  }

  Widget _tile(AssignmentStatus? s, String label, int n, Color c, IconData icon) {
    final bool sel = _statusFilter == s;
    return Material(
      color: sel ? c.withValues(alpha: 0.10) : Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => setState(() => _statusFilter = s),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: sel ? c : _line, width: sel ? 1.6 : 1),
          ),
          child: Row(children: <Widget>[
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 18, color: c),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text('$n', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: sel ? c : _ink, height: 1.1)),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: _muted, fontWeight: FontWeight.w600)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _dayLabel(String ymd, int count, double width) {
    final double maxText = (width - 80).clamp(80, double.infinity);
    final DateTime now = DateTime.now();
    final bool isToday = ymd == _day.format(now);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Row(children: <Widget>[
        Container(width: 8, height: 8, decoration: BoxDecoration(color: isToday ? _teal : _muted.withValues(alpha: 0.5), shape: BoxShape.circle)),
        const SizedBox(width: 8),
        // Capped so the line after it always shows, also on narrow phones.
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxText),
          child: Text(_dayHeader(ymd),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: isToday ? _teal : _ink)),
        ),
        const SizedBox(width: 8),
        Text('$count', style: const TextStyle(color: _muted, fontWeight: FontWeight.w700, fontSize: 12)),
        const SizedBox(width: 10),
        const Expanded(child: Divider(color: _line, height: 1)),
      ]),
    );
  }

  Widget _cardGrid(List<RouteAssignment> items, double width) {
    final int cols = width >= 1150 ? 3 : (width >= 720 ? 2 : 1);
    const double gap = 12;
    final double w = (width - gap * (cols - 1)) / cols;
    return Wrap(spacing: gap, runSpacing: gap, children: <Widget>[for (final RouteAssignment a in items) SizedBox(width: w, child: _card(a))]);
  }

  Widget _emptyState() {
    final bool filtered = _items.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: _line)),
      child: Column(children: <Widget>[
        Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(color: _mint, shape: BoxShape.circle),
          child: const Icon(Icons.event_note_rounded, size: 34, color: _teal),
        ),
        const SizedBox(height: 14),
        Text(filtered ? 'No assignments with this status' : 'No assignments in this period',
            textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _ink)),
        const SizedBox(height: 6),
        Text(
          filtered
              ? 'Choose another status above to see the other assignments.'
              : 'Assign a driver, a truck and the service areas for a collection day. The driver sees it as "Today\'s Assignment".',
          textAlign: TextAlign.center,
          style: const TextStyle(color: _muted, fontSize: 13, height: 1.4),
        ),
        if (!filtered && _failure == AssignmentFailure.none) ...<Widget>[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => _openForm(),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Create the first assignment'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _teal,
              side: const BorderSide(color: _teal),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _stateBox(IconData icon, String text, {bool retry = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: _line)),
      child: Column(children: <Widget>[
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.10), shape: BoxShape.circle),
          child: Icon(icon, color: Colors.orange.shade700, size: 30),
        ),
        const SizedBox(height: 12),
        Text(text, textAlign: TextAlign.center, style: const TextStyle(color: _ink, fontWeight: FontWeight.w600)),
        if (retry) ...<Widget>[
          const SizedBox(height: 10),
          TextButton.icon(onPressed: _load, icon: const Icon(Icons.refresh_rounded, size: 18), label: const Text('Retry')),
        ],
      ]),
    );
  }

  Widget _infoPill(IconData icon, String text, {Color color = _muted}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(9)),
      child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 5),
        Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
      ]),
    );
  }

  Widget _card(RouteAssignment a) {
    final Color c = statusColor(a.status);
    final String name = _driverNames[a.driverId] ?? 'Driver ${a.driverId}';
    final bool cancelled = a.status == AssignmentStatus.cancelled;
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), boxShadow: AppTheme.pulidongShadow),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Container(width: 5, color: c),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Row(children: <Widget>[
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: c.withValues(alpha: 0.12),
                    child: Text(_initials(name), style: TextStyle(color: c, fontWeight: FontWeight.w900, fontSize: 14)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                            color: cancelled ? _muted : _ink,
                            decoration: cancelled ? TextDecoration.lineThrough : null,
                          )),
                      Text(_prettyDate(a.date), style: const TextStyle(fontSize: 12, color: _muted)),
                    ]),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                    decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                      Icon(_statusIcon(a.status), size: 13, color: c),
                      const SizedBox(width: 4),
                      Text(assignmentStatusLabel(a.status), style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 11.5)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 12),
                Wrap(spacing: 6, runSpacing: 6, children: <Widget>[
                  _infoPill(Icons.local_shipping_rounded, a.truckId, color: _teal),
                  _infoPill(Icons.place_rounded, '${a.areas.length} area${a.areas.length == 1 ? '' : 's'}'),
                  _infoPill(Icons.route_rounded, '${a.trips.length} trip${a.trips.length == 1 ? '' : 's'} linked'),
                  if (a.tripsInterrupted > 0)
                    _infoPill(Icons.warning_amber_rounded, '${a.tripsInterrupted} interrupted', color: Colors.orange.shade800),
                ]),
                const SizedBox(height: 12),
                const Text('SERVICE AREAS', style: TextStyle(fontSize: 10.5, letterSpacing: 0.8, fontWeight: FontWeight.w800, color: _muted)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: <Widget>[
                  for (int i = 0; i < a.areas.length; i++)
                    Container(
                      padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
                      decoration: BoxDecoration(
                        color: _mint.withValues(alpha: cancelled ? 0.4 : 1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                        Container(
                          width: 18,
                          height: 18,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(color: _teal, shape: BoxShape.circle),
                          child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900)),
                        ),
                        const SizedBox(width: 6),
                        Text(a.areas[i].name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF004D40))),
                      ]),
                    ),
                ]),
                if (a.notes != null && a.notes!.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    const Icon(Icons.sticky_note_2_outlined, size: 15, color: _muted),
                    const SizedBox(width: 6),
                    Expanded(child: Text(a.notes!, style: const TextStyle(fontSize: 12.5, color: _muted, fontStyle: FontStyle.italic))),
                  ]),
                ],
                if (a.isEditable) ...<Widget>[
                  const SizedBox(height: 8),
                  const Divider(height: 1, color: _line),
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: <Widget>[
                    TextButton.icon(
                      onPressed: () => _openForm(a),
                      icon: const Icon(Icons.edit_rounded, size: 16),
                      label: const Text('Edit'),
                      style: TextButton.styleFrom(foregroundColor: _teal),
                    ),
                    TextButton.icon(
                      onPressed: () => _cancel(a),
                      icon: const Icon(Icons.cancel_outlined, size: 16),
                      label: const Text('Cancel'),
                      style: TextButton.styleFrom(foregroundColor: const Color(0xFFC62828)),
                    ),
                  ]),
                ] else
                  const SizedBox(height: 4),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _AssignmentForm extends StatefulWidget {
  const _AssignmentForm({required this.service, required this.drivers, required this.areas, this.existing});
  final RouteAssignmentService service;
  final List<_DriverOption> drivers;
  final List<ServiceArea> areas;
  final RouteAssignment? existing;

  @override
  State<_AssignmentForm> createState() => _AssignmentFormState();
}

class _AssignmentFormState extends State<_AssignmentForm> {
  final TextEditingController _truck = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  int? _driverId;
  late DateTime _date;
  final Set<String> _areaKeys = <String>{};
  bool _saving = false;
  String? _error;

  // Repeat weekly (new assignments only): the same driver, truck and areas on the chosen weekdays
  // from the collection date until [_until]. Each day is saved as its own assignment.
  bool _repeat = false;
  final Set<int> _weekdays = <int>{};
  late DateTime _until;
  String? _progress;

  static const int _maxRepeatDays = 60;
  static const List<String> _dayShort = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// Dates the repeat creates, in order (at most [_maxRepeatDays]).
  List<DateTime> get _repeatDates => weeklyRepeatDates(start: _date, until: _until, weekdays: _weekdays, max: _maxRepeatDays);

  Future<void> _useCollectionSchedule() async {
    try {
      final Map<String, CollectionSchedule> all = await CollectionScheduleService.watch().first.timeout(const Duration(seconds: 8));
      final Set<int> days = <int>{};
      for (final ServiceArea a in widget.areas.where((ServiceArea a) => _areaKeys.contains(a.id))) {
        days.addAll(CollectionScheduleService.forPurok(all, a.name)?.days ?? const <int>[]);
      }
      if (!mounted) return;
      if (days.isEmpty) {
        setState(() => _error = 'The selected areas have no collection days set (System Settings > Collection Schedule).');
        return;
      }
      setState(() {
        _weekdays
          ..clear()
          ..addAll(days);
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'The collection schedule could not be loaded.');
    }
  }

  Future<void> _pickUntil() async {
    final DateTime? d = await showAppSingleDatePicker(
      context,
      firstDate: _date,
      lastDate: _date.add(const Duration(days: 120)),
      initialDate: _until.isBefore(_date) ? _date : _until,
      title: 'Repeat until',
    );
    if (d != null) setState(() => _until = d);
  }

  @override
  void initState() {
    super.initState();
    final RouteAssignment? e = widget.existing;
    final DateTime now = DateTime.now();
    _date = e != null ? (DateTime.tryParse(e.date) ?? now) : DateTime(now.year, now.month, now.day);
    _until = _date.add(const Duration(days: 27));
    _weekdays.add(_date.weekday);
    if (e != null) {
      _driverId = e.driverId;
      _truck.text = e.truckId;
      _notes.text = e.notes ?? '';
      _areaKeys.addAll(e.areas.map((AssignmentArea a) => a.key));
    }
    _truck.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _truck.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_driverId == null) return setState(() => _error = 'Select a driver.');
    if (_truck.text.trim().isEmpty) return setState(() => _error = 'Choose or enter the truck.');
    if (_areaKeys.isEmpty) return setState(() => _error = 'Select at least one service area.');
    setState(() {
      _saving = true;
      _error = null;
    });
    final List<AssignmentArea> areas = widget.areas
        .where((ServiceArea a) => _areaKeys.contains(a.id))
        .map((ServiceArea a) => AssignmentArea(key: a.id, name: a.name))
        .toList();
    // Keep areas of an edited assignment that are no longer configured.
    for (final AssignmentArea old in widget.existing?.areas ?? const <AssignmentArea>[]) {
      if (_areaKeys.contains(old.key) && !areas.any((AssignmentArea x) => x.key == old.key)) areas.add(old);
    }
    if (widget.existing == null && _repeat) {
      await _saveRepeated(areas);
      return;
    }
    final AssignmentResult<RouteAssignment> r = await widget.service.save(
      assignmentId: widget.existing?.id,
      date: DateFormat('yyyy-MM-dd').format(_date),
      driverId: _driverId!,
      truckId: _truck.text.trim(),
      areas: areas,
      notes: _notes.text,
    );
    if (!mounted) return;
    if (r.isOk) {
      CustomNotification.showTopNotification(context, widget.existing == null ? 'Assignment created.' : 'Assignment updated.', false);
      Navigator.pop(context, true);
    } else {
      setState(() {
        _saving = false;
        _error = r.message;
      });
    }
  }

  /// Saves one assignment per repeat date; days that cannot be saved (e.g. the driver or truck is
  /// already assigned that day) are skipped and listed, the others are kept.
  Future<void> _saveRepeated(List<AssignmentArea> areas) async {
    final List<DateTime> dates = _repeatDates;
    if (dates.isEmpty) {
      setState(() {
        _saving = false;
        _error = 'Choose at least one weekday between the collection date and the end date.';
      });
      return;
    }
    int created = 0;
    final List<String> skipped = <String>[];
    for (int i = 0; i < dates.length; i++) {
      if (!mounted) return;
      setState(() => _progress = 'Saving ${i + 1} of ${dates.length}…');
      final AssignmentResult<RouteAssignment> r = await widget.service.save(
        date: DateFormat('yyyy-MM-dd').format(dates[i]),
        driverId: _driverId!,
        truckId: _truck.text.trim(),
        areas: areas,
        notes: _notes.text,
      );
      if (r.isOk) {
        created++;
      } else {
        skipped.add('${DateFormat('MMM d').format(dates[i])}: ${r.message}');
      }
    }
    if (!mounted) return;
    if (created == 0) {
      setState(() {
        _saving = false;
        _progress = null;
        _error = 'No assignment was saved.\n${skipped.take(4).join('\n')}';
      });
      return;
    }
    CustomNotification.showTopNotification(
      context,
      skipped.isEmpty
          ? '$created assignments created.'
          : '$created of ${dates.length} assignments created. Skipped ${skipped.length}: ${skipped.take(2).join('; ')}${skipped.length > 2 ? '…' : ''}',
      skipped.isNotEmpty,
    );
    Navigator.pop(context, true);
  }

  Future<void> _pickDate() async {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime? d = await showAppSingleDatePicker(
      context,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
      initialDate: _date.isBefore(today) ? today : _date,
      title: 'Collection date',
    );
    if (d != null) {
      setState(() {
        _date = d;
        if (_until.isBefore(d)) _until = d.add(const Duration(days: 27));
        if (_weekdays.isEmpty) _weekdays.add(d.weekday);
      });
    }
  }

  Widget _repeatSection() {
    final List<DateTime> dates = _repeatDates;
    final List<int> days = _weekdays.toList()..sort();
    return Container(
      margin: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        color: _repeat ? _mint.withValues(alpha: 0.55) : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _repeat ? _teal.withValues(alpha: 0.35) : _line),
      ),
      padding: const EdgeInsets.fromLTRB(14, 6, 10, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        Row(children: <Widget>[
          const Icon(Icons.event_repeat_rounded, size: 18, color: _teal),
          const SizedBox(width: 8),
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('Repeat weekly', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5, color: _ink)),
              Text('Same driver, truck and areas on the chosen days', style: TextStyle(fontSize: 11.5, color: _muted)),
            ]),
          ),
          Switch(
            key: const ValueKey<String>('repeat-weekly'),
            value: _repeat,
            activeThumbColor: Colors.white,
            activeTrackColor: _teal,
            onChanged: (bool v) => setState(() {
              _repeat = v;
              _error = null;
            }),
          ),
        ]),
        if (_repeat) ...<Widget>[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: <Widget>[
            for (int d = 1; d <= 7; d++)
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => setState(() {
                  _weekdays.contains(d) ? _weekdays.remove(d) : _weekdays.add(d);
                  _error = null;
                }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 50,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: _weekdays.contains(d) ? _teal : Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _weekdays.contains(d) ? _teal : _line),
                  ),
                  child: Text(_dayShort[d - 1],
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: _weekdays.contains(d) ? Colors.white : _ink)),
                ),
              ),
          ]),
          const SizedBox(height: 10),
          Row(children: <Widget>[
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: _pickUntil,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: _line)),
                  child: Row(children: <Widget>[
                    const Text('Until ', style: TextStyle(fontSize: 12.5, color: _muted, fontWeight: FontWeight.w600)),
                    Expanded(child: Text(DateFormat('EEE, MMM d, yyyy').format(_until), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _ink))),
                    const Icon(Icons.calendar_month_rounded, size: 18, color: _teal),
                  ]),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _areaKeys.isEmpty ? null : _useCollectionSchedule,
              style: TextButton.styleFrom(foregroundColor: _teal, visualDensity: VisualDensity.compact),
              icon: const Icon(Icons.auto_awesome_rounded, size: 16),
              label: const Text('Use collection schedule'),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            dates.isEmpty
                ? 'No dates yet: choose at least one weekday.'
                : 'Creates ${dates.length} assignment${dates.length == 1 ? '' : 's'}: ${days.map((int d) => _dayShort[d - 1]).join(', ')}, '
                    '${DateFormat('MMM d').format(dates.first)} – ${DateFormat('MMM d').format(dates.last)}'
                    '${dates.length >= _maxRepeatDays ? ' (limit $_maxRepeatDays)' : ''}.',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _teal),
          ),
        ],
      ]),
    );
  }

  Widget _section(IconData icon, String title, {Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Row(children: <Widget>[
        Icon(icon, size: 17, color: _teal),
        const SizedBox(width: 6),
        Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5, color: _ink))),
        if (trailing != null) trailing,
      ]),
    );
  }

  InputDecoration _input(String hint) => InputDecoration(
        hintText: hint,
        isDense: true,
        filled: true,
        fillColor: const Color(0xFFF9FAFB),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _line)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _line)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _teal, width: 1.6)),
      );

  Widget _choice(String label, bool selected, VoidCallback onTap, {IconData? icon}) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? _teal : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? _teal : _line),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
          Icon(selected ? Icons.check_rounded : (icon ?? Icons.add_rounded), size: 16, color: selected ? Colors.white : _muted),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: selected ? Colors.white : _ink)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<String> knownTrucks =
        widget.drivers.map((_DriverOption d) => d.truck).where((String t) => t.isNotEmpty && t != 'None' && t != 'Unknown').toSet().toList()..sort();
    final bool narrow = MediaQuery.of(context).size.width < 600;
    final bool allAreas = _areaKeys.length == widget.areas.length && widget.areas.isNotEmpty;

    final Widget body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      _section(Icons.person_rounded, 'Driver'),
      DropdownButtonFormField<int>(
        initialValue: widget.drivers.any((_DriverOption d) => d.id == _driverId) ? _driverId : null,
        isExpanded: true,
        decoration: _input('Select a driver'),
        borderRadius: BorderRadius.circular(14),
        items: widget.drivers
            .map((_DriverOption d) => DropdownMenuItem<int>(
                  value: d.id,
                  child: Row(children: <Widget>[
                    CircleAvatar(
                      radius: 13,
                      backgroundColor: _mint,
                      child: Text(_initials(d.name), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: _teal)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(d.name, overflow: TextOverflow.ellipsis)),
                    if (d.truck.isNotEmpty && d.truck != 'None' && d.truck != 'Unknown')
                      Text(d.truck, style: const TextStyle(fontSize: 12, color: _muted, fontWeight: FontWeight.w600)),
                  ]),
                ))
            .toList(),
        onChanged: (int? v) => setState(() {
          _driverId = v;
          _error = null;
          final _DriverOption d = widget.drivers.firstWhere((_DriverOption x) => x.id == v);
          if (_truck.text.trim().isEmpty && d.truck.isNotEmpty && d.truck != 'None') _truck.text = d.truck;
        }),
      ),
      _section(Icons.local_shipping_rounded, 'Truck'),
      if (knownTrucks.isNotEmpty) ...<Widget>[
        Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
          for (final String t in knownTrucks)
            _choice(t, _truck.text.trim().toUpperCase() == t.toUpperCase(), () => setState(() {
                  _truck.text = t;
                  _error = null;
                }), icon: Icons.local_shipping_outlined),
        ]),
        const SizedBox(height: 10),
      ],
      TextField(controller: _truck, decoration: _input('Or type another truck, e.g. GT-004')),
      const Padding(
        padding: EdgeInsets.only(top: 6, left: 2),
        child: Text('Must match the truck the driver signs in with.', style: TextStyle(fontSize: 11.5, color: _muted)),
      ),
      _section(Icons.event_rounded, 'Collection date'),
      InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _pickDate,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(12), border: Border.all(color: _line)),
          child: Row(children: <Widget>[
            Expanded(
              child: Text(DateFormat('EEEE, MMMM d, yyyy').format(_date),
                  style: const TextStyle(fontWeight: FontWeight.w700, color: _ink)),
            ),
            const Icon(Icons.calendar_month_rounded, color: _teal, size: 20),
          ]),
        ),
      ),
      if (widget.existing == null) _repeatSection(),
      _section(
        Icons.place_rounded,
        'Service areas  ·  ${_areaKeys.length} selected',
        trailing: TextButton(
          onPressed: () => setState(() {
            allAreas ? _areaKeys.clear() : _areaKeys.addAll(widget.areas.map((ServiceArea a) => a.id));
            _error = null;
          }),
          style: TextButton.styleFrom(foregroundColor: _teal, visualDensity: VisualDensity.compact),
          child: Text(allAreas ? 'Clear' : 'Select all'),
        ),
      ),
      Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
        for (final ServiceArea a in widget.areas)
          _choice(a.name, _areaKeys.contains(a.id), () => setState(() {
                _areaKeys.contains(a.id) ? _areaKeys.remove(a.id) : _areaKeys.add(a.id);
                _error = null;
              })),
      ]),
      _section(Icons.sticky_note_2_outlined, 'Notes (optional)'),
      TextField(controller: _notes, maxLength: 255, maxLines: 2, minLines: 1, decoration: _input('Anything the driver should know')),
      if (_error != null)
        Container(
          margin: const EdgeInsets.only(top: 4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: const Color(0xFFFDECEA), borderRadius: BorderRadius.circular(12)),
          child: Row(children: <Widget>[
            const Icon(Icons.error_outline_rounded, color: Color(0xFFC62828), size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(_error!, style: const TextStyle(color: Color(0xFFC62828), fontWeight: FontWeight.w700))),
          ]),
        ),
    ]);

    final Widget actions = Row(children: <Widget>[
      Expanded(
        child: OutlinedButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          style: OutlinedButton.styleFrom(
            foregroundColor: _ink,
            side: const BorderSide(color: _line),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('Close'),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        flex: 2,
        child: FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.check_rounded, size: 18),
          label: Text(_saving
              ? (_progress ?? 'Saving...')
              : (widget.existing != null
                  ? 'Save changes'
                  : (_repeat ? 'Save ${_repeatDates.length} assignment${_repeatDates.length == 1 ? '' : 's'}' : 'Save assignment'))),
          style: FilledButton.styleFrom(
            backgroundColor: _teal,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            textStyle: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ),
    ]);

    return Dialog(
      insetPadding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 40, vertical: narrow ? 16 : 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 8, 0),
            child: Row(children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: _mint, borderRadius: BorderRadius.circular(12)),
                child: Icon(widget.existing == null ? Icons.add_task_rounded : Icons.edit_calendar_rounded, color: _teal, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(widget.existing == null ? 'New assignment' : 'Edit assignment',
                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: _ink)),
              ),
              IconButton(onPressed: _saving ? null : () => Navigator.pop(context, false), icon: const Icon(Icons.close_rounded)),
            ]),
          ),
          Flexible(
            child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: body),
          ),
          const Divider(height: 1, color: _line),
          Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 16), child: actions),
        ]),
      ),
    );
  }
}
