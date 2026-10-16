import 'dart:async';

import 'package:flutter/material.dart';

import '../services/collection_schedule_service.dart';
import '../services/service_area_service.dart';

/// Admin: the usual collection days and time of every purok. Residents see their purok's
/// schedule on the dashboard, get weekly reminders on their phone, and Truck Buddy answers
/// "what day is collection?" from it. Areas without a schedule stay "Not set" (nothing guessed).
class CollectionScheduleScreen extends StatefulWidget {
  const CollectionScheduleScreen({super.key, this.areaNames, this.schedules, this.onSave, this.onRemove});

  /// Tests: data sources (defaults: service areas, Firebase schedule).
  final List<String>? areaNames;
  final Stream<Map<String, CollectionSchedule>>? schedules;
  final Future<void> Function(CollectionSchedule)? onSave;
  final Future<void> Function(String area)? onRemove;

  @override
  State<CollectionScheduleScreen> createState() => _CollectionScheduleScreenState();
}

class _CollectionScheduleScreenState extends State<CollectionScheduleScreen> {
  static const Color _teal = Color(0xFF00796B);
  static const Color _ink = Color(0xFF1A2B3C);
  static const Color _muted = Color(0xFF64748B);

  List<String> _areas = const <String>[];
  Map<String, CollectionSchedule> _saved = const <String, CollectionSchedule>{};
  final Map<String, CollectionSchedule> _draft = <String, CollectionSchedule>{};
  final Set<String> _saving = <String>{};
  StreamSubscription<Map<String, CollectionSchedule>>? _sub;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadAreas();
    _sub = (widget.schedules ?? CollectionScheduleService.watch()).listen((Map<String, CollectionSchedule> m) {
      if (mounted) setState(() {
        _saved = m;
        _loaded = true;
      });
    }, onError: (Object _) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  Future<void> _loadAreas() async {
    List<String> names = List<String>.from(widget.areaNames ?? const <String>[]);
    if (widget.areaNames == null) {
      try {
        names = (await ServiceAreaService().getAllServiceAreas()).map((ServiceArea a) => a.name).where((String n) => n.trim().isNotEmpty).toSet().toList();
      } catch (_) {}
      if (names.isEmpty) names = List<String>.from(ServiceAreaService.documentedAreaNames);
    }
    names.sort();
    if (mounted) setState(() => _areas = names);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  CollectionSchedule _current(String area) =>
      _draft[area] ?? CollectionScheduleService.forPurok(_saved, area) ?? CollectionSchedule(area: area, days: const <int>[], time: '07:00');

  bool _changed(String area) {
    final CollectionSchedule? d = _draft[area];
    if (d == null) return false;
    final CollectionSchedule? s = CollectionScheduleService.forPurok(_saved, area);
    return s == null ? d.days.isNotEmpty : (s.time != d.time || s.note != d.note || (s.days.toSet().length != d.days.toSet().length || !s.days.toSet().containsAll(d.days)));
  }

  void _toggleDay(String area, int day) {
    final CollectionSchedule c = _current(area);
    final List<int> days = c.days.contains(day) ? (c.days.where((int d) => d != day).toList()) : (<int>[...c.days, day]..sort());
    setState(() => _draft[area] = CollectionSchedule(area: area, days: days, time: c.time, note: c.note));
  }

  Future<void> _pickTime(String area) async {
    final CollectionSchedule c = _current(area);
    final TimeOfDay? t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: c.hour, minute: c.minute));
    if (t == null) return;
    final String time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    setState(() => _draft[area] = CollectionSchedule(area: area, days: c.days, time: time, note: c.note));
  }

  Future<void> _save(String area) async {
    final CollectionSchedule c = _current(area);
    setState(() => _saving.add(area));
    try {
      if (c.days.isEmpty) {
        await (widget.onRemove ?? CollectionScheduleService.remove)(area);
      } else {
        await (widget.onSave ?? CollectionScheduleService.save)(c);
      }
      _draft.remove(area);
      _toast(c.days.isEmpty ? 'Schedule removed for $area' : 'Saved: $area · ${c.summary}');
    } catch (e) {
      _toast('Could not save. Check the connection and try again.', error: true);
    } finally {
      if (mounted) setState(() => _saving.remove(area));
    }
  }

  void _toast(String m, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      behavior: SnackBarBehavior.floating,
      backgroundColor: error ? const Color(0xFFC62828) : _ink,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final int set = _areas.where((String a) => CollectionScheduleService.forPurok(_saved, a) != null).length;
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        foregroundColor: _ink,
        elevation: 0,
        shape: const Border(bottom: BorderSide(color: Color(0xFFE6EBF0))),
        title: const Text('Collection Schedule', style: TextStyle(fontWeight: FontWeight.w900)),
      ),
      body: !_loaded || _areas.isEmpty
          ? const Center(child: CircularProgressIndicator(color: _teal))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
              children: <Widget>[
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                      _intro(set),
                      const SizedBox(height: 14),
                      for (final String a in _areas) _areaCard(a),
                    ]),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _intro(int set) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: <Color>[Color(0xFF00897B), Color(0xFF00695C)]),
        borderRadius: BorderRadius.circular(22),
        boxShadow: <BoxShadow>[BoxShadow(color: _teal.withValues(alpha: 0.25), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      child: Row(children: <Widget>[
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(16)),
          child: const Icon(Icons.event_repeat_rounded, color: Colors.white),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text('$set of ${_areas.length} areas scheduled', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 16)),
            const SizedBox(height: 3),
            Text(
              'Residents see their purok\'s days on the dashboard and get a reminder the evening before and about an hour before collection.',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.88), fontSize: 12.5, height: 1.35, fontWeight: FontWeight.w600),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _areaCard(String area) {
    final CollectionSchedule c = _current(area);
    final bool changed = _changed(area);
    final bool saving = _saving.contains(area);
    final bool isSet = CollectionScheduleService.forPurok(_saved, area) != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: changed ? _teal.withValues(alpha: 0.5) : const Color(0xFFE6EBF0), width: changed ? 1.5 : 1),
        boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x0D000000), blurRadius: 14, offset: Offset(0, 5))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Icon(Icons.place_rounded, color: isSet ? _teal : _muted, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(area, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: _ink))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: c.days.isEmpty ? const Color(0xFFF1F5F9) : const Color(0xFFE0F2F1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              c.days.isEmpty ? 'Not set' : '${c.days.map((int d) => CollectionSchedule.dayShort[d - 1]).join(' · ')}  ${c.timeLabel}',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: c.days.isEmpty ? _muted : _teal),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
          for (int d = 1; d <= 7; d++)
            InkWell(
              key: ValueKey<String>('day-$area-$d'),
              borderRadius: BorderRadius.circular(14),
              onTap: () => _toggleDay(area, d),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 52,
                padding: const EdgeInsets.symmetric(vertical: 9),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.days.contains(d) ? _teal : const Color(0xFFF4F7F8),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: c.days.contains(d) ? _teal : const Color(0xFFE2E8F0)),
                ),
                child: Text(CollectionSchedule.dayShort[d - 1],
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: c.days.contains(d) ? Colors.white : _ink)),
              ),
            ),
        ]),
        const SizedBox(height: 14),
        Row(children: <Widget>[
          OutlinedButton.icon(
            onPressed: () => _pickTime(area),
            icon: const Icon(Icons.schedule_rounded, size: 18),
            label: Text('Around ${c.timeLabel}'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _ink,
              side: const BorderSide(color: Color(0xFFE2E8F0)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const Spacer(),
          FilledButton.icon(
            key: ValueKey<String>('save-$area'),
            onPressed: changed && !saving ? () => _save(area) : null,
            icon: saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Icon(c.days.isEmpty && isSet ? Icons.delete_outline_rounded : Icons.check_rounded, size: 18),
            label: Text(c.days.isEmpty && isSet ? 'Remove' : 'Save'),
            style: FilledButton.styleFrom(backgroundColor: c.days.isEmpty && isSet ? const Color(0xFFC62828) : _teal, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          ),
        ]),
      ]),
    );
  }
}
