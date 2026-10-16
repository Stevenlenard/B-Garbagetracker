import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api/api_service.dart';
import '../models/route_assignment.dart';
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

class _RouteAssignmentsScreenState extends State<RouteAssignmentsScreen> {
  static const Color teal = Color(0xFF00796B);
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
        title: const Text('Cancel assignment?'),
        content: Text('The ${a.date} assignment for ${_driverNames[a.driverId] ?? 'driver ${a.driverId}'} will be marked Cancelled. The record is kept.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Cancel assignment', style: TextStyle(color: Colors.red))),
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

  @override
  Widget build(BuildContext context) {
    final List<RouteAssignment> shown =
        _statusFilter == null ? _items : _items.where((RouteAssignment a) => a.status == _statusFilter).toList();
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
            children: <Widget>[
              Row(children: <Widget>[
                if (widget.onBack != null)
                  IconButton(onPressed: widget.onBack, icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20)),
                const Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Text('Route Assignments', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
                    SizedBox(height: 2),
                    Text('Driver, truck and service areas per collection day', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ]),
                ),
                ElevatedButton.icon(
                  onPressed: _failure == AssignmentFailure.none && !_loading ? () => _openForm() : null,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('New'),
                  style: ElevatedButton.styleFrom(backgroundColor: teal, foregroundColor: Colors.white),
                ),
              ]),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _pickRange,
                  icon: const Icon(Icons.date_range_rounded, size: 18),
                  label: Text(DateUtils.isSameDay(_range.start, _range.end) ? DateFormat('MMM d, yyyy').format(_range.start) : '${DateFormat('MMM d').format(_range.start)} – ${DateFormat('MMM d, yyyy').format(_range.end)}'),
                ),
                IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh_rounded), tooltip: 'Refresh'),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: <Widget>[
                _countChip(null, 'All', _summary.total),
                _countChip(AssignmentStatus.pending, 'Pending', _summary.pending),
                _countChip(AssignmentStatus.inProgress, 'In Progress', _summary.inProgress),
                _countChip(AssignmentStatus.completed, 'Completed', _summary.completed),
                _countChip(AssignmentStatus.missed, 'Missed', _summary.missed),
                _countChip(AssignmentStatus.cancelled, 'Cancelled', _summary.cancelled),
              ]),
              const SizedBox(height: 12),
              if (_loading)
                const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: teal)))
              else if (_error != null)
                _stateBox(Icons.error_outline_rounded, _error!, retry: _failure != AssignmentFailure.notConfigured)
              else if (shown.isEmpty)
                _stateBox(Icons.event_busy_rounded,
                    _items.isEmpty ? 'No assignments in this period.' : 'No assignments with this status in this period.')
              else
                ...shown.map(_card),
            ],
          ),
        ),
      ),
    );
  }

  Widget _countChip(AssignmentStatus? s, String label, int n) {
    final bool sel = _statusFilter == s;
    return ChoiceChip(
      label: Text('$label ($n)'),
      selected: sel,
      onSelected: (_) => setState(() => _statusFilter = s),
      selectedColor: (s == null ? teal : statusColor(s)).withValues(alpha: 0.15),
    );
  }

  Widget _stateBox(IconData icon, String text, {bool retry = false}) {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.grey.shade200)),
      child: Column(children: <Widget>[
        Icon(icon, color: Colors.grey, size: 32),
        const SizedBox(height: 8),
        Text(text, textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade700)),
        if (retry) TextButton(onPressed: _load, child: const Text('Retry')),
      ]),
    );
  }

  Widget _card(RouteAssignment a) {
    final Color c = statusColor(a.status);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), boxShadow: AppTheme.pulidongShadow),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Expanded(
            child: Text('${a.date} · ${_driverNames[a.driverId] ?? 'Driver ${a.driverId}'}',
                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
            child: Text(assignmentStatusLabel(a.status), style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 11)),
          ),
        ]),
        const SizedBox(height: 4),
        Text('Truck ${a.truckId} · ${a.trips.length} linked trip(s)${a.tripsInterrupted > 0 ? ' · ${a.tripsInterrupted} interrupted' : ''}',
            style: TextStyle(color: Colors.grey.shade700, fontSize: 12)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: a.areas.map((AssignmentArea x) => Chip(label: Text(x.name, style: const TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact)).toList()),
        if (a.notes != null && a.notes!.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text(a.notes!, style: TextStyle(fontSize: 12, color: Colors.grey.shade600))),
        if (a.isEditable)
          Row(mainAxisAlignment: MainAxisAlignment.end, children: <Widget>[
            TextButton.icon(onPressed: () => _openForm(a), icon: const Icon(Icons.edit_rounded, size: 16), label: const Text('Edit')),
            TextButton.icon(
              onPressed: () => _cancel(a),
              icon: const Icon(Icons.cancel_outlined, size: 16, color: Colors.red),
              label: const Text('Cancel', style: TextStyle(color: Colors.red)),
            ),
          ]),
      ]),
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

  @override
  void initState() {
    super.initState();
    final RouteAssignment? e = widget.existing;
    final DateTime now = DateTime.now();
    _date = e != null ? (DateTime.tryParse(e.date) ?? now) : DateTime(now.year, now.month, now.day);
    if (e != null) {
      _driverId = e.driverId;
      _truck.text = e.truckId;
      _notes.text = e.notes ?? '';
      _areaKeys.addAll(e.areas.map((AssignmentArea a) => a.key));
    }
  }

  @override
  void dispose() {
    _truck.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_driverId == null) return setState(() => _error = 'Select a driver.');
    if (_truck.text.trim().isEmpty) return setState(() => _error = 'Enter the truck.');
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

  @override
  Widget build(BuildContext context) {
    final List<String> knownTrucks =
        widget.drivers.map((_DriverOption d) => d.truck).where((String t) => t.isNotEmpty && t != 'None' && t != 'Unknown').toSet().toList()..sort();
    return AlertDialog(
      title: Text(widget.existing == null ? 'New assignment' : 'Edit assignment'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            DropdownButtonFormField<int>(
              initialValue: widget.drivers.any((_DriverOption d) => d.id == _driverId) ? _driverId : null,
              decoration: const InputDecoration(labelText: 'Driver'),
              items: widget.drivers.map((_DriverOption d) => DropdownMenuItem<int>(value: d.id, child: Text(d.name))).toList(),
              onChanged: (int? v) => setState(() {
                _driverId = v;
                final _DriverOption d = widget.drivers.firstWhere((_DriverOption x) => x.id == v);
                if (_truck.text.trim().isEmpty && d.truck.isNotEmpty && d.truck != 'None') _truck.text = d.truck;
              }),
            ),
            const SizedBox(height: 8),
            TextField(controller: _truck, decoration: const InputDecoration(labelText: 'Truck', helperText: 'Must match the truck the driver signs in with')),
            if (knownTrucks.isNotEmpty)
              Wrap(spacing: 6, children: knownTrucks.map((String t) => ActionChip(label: Text(t), onPressed: () => setState(() => _truck.text = t))).toList()),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Collection date'),
              subtitle: Text(DateFormat('EEE, MMM d, yyyy').format(_date)),
              trailing: const Icon(Icons.calendar_month_rounded),
              onTap: () async {
                final DateTime now = DateTime.now();
                final DateTime today = DateTime(now.year, now.month, now.day);
                final DateTime? d = await showAppSingleDatePicker(
                  context,
                  firstDate: today,
                  lastDate: today.add(const Duration(days: 365)),
                  initialDate: _date.isBefore(today) ? today : _date,
                  title: 'Collection date',
                );
                if (d != null) setState(() => _date = d);
              },
            ),
            const Text('Service areas', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: widget.areas
                  .map((ServiceArea a) => FilterChip(
                        label: Text(a.name),
                        selected: _areaKeys.contains(a.id),
                        onSelected: (bool on) => setState(() => on ? _areaKeys.add(a.id) : _areaKeys.remove(a.id)),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 8),
            TextField(controller: _notes, maxLength: 255, decoration: const InputDecoration(labelText: 'Notes (optional)')),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context, false), child: const Text('Close')),
        ElevatedButton(
          onPressed: _saving ? null : _save,
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00796B), foregroundColor: Colors.white),
          child: Text(_saving ? 'Saving...' : 'Save'),
        ),
      ],
    );
  }
}
