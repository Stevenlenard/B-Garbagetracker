import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../api/api_service.dart';

const Color _teal = Color(0xFF00897B);
const Color _tealDark = Color(0xFF00695C);
const Color _ink = Color(0xFF1A1A1A);
const Color _muted = Color(0xFF9E9E9E);
const Color _amber = Color(0xFFF59E0B);

bool _isPlaceholder(String id) {
  final String s = id.trim().toLowerCase();
  return s.isEmpty || s == 'unknown' || s == 'none' || s == 'null';
}

/// A truck from the registry, with the driver (if any) it is already assigned to.
class TruckChoice {
  const TruckChoice(this.id, this.plate, this.usedBy);
  final String id;
  final String plate;
  final String? usedBy;
}

/// Registry trucks (Firebase `trucks`), each marked with the active driver that already has it.
List<TruckChoice> buildTruckChoices(Map<dynamic, dynamic> registry, List<dynamic> users, {required String forDriverId}) {
  final Map<String, String> usedBy = <String, String>{};
  for (final dynamic u in users) {
    if (u is! Map || (u['role'] ?? '').toString().toLowerCase() != 'driver') continue;
    final bool archived = u['is_archived'] == 1 || u['is_archived'] == '1' || u['is_archived'] == true;
    final String t = (u['preferred_truck'] ?? '').toString().trim().toLowerCase();
    final String uid = (u['user_id'] ?? u['id'] ?? '').toString();
    if (archived || _isPlaceholder(t) || uid == forDriverId) continue;
    usedBy[t] = (u['name'] ?? u['username'] ?? 'another driver').toString();
  }
  final List<TruckChoice> out = <TruckChoice>[];
  registry.forEach((dynamic k, dynamic v) {
    final String id = k.toString();
    if (_isPlaceholder(id)) return;
    final String plate = v is Map ? (v['plateNumber'] ?? v['plate_number'] ?? '').toString() : '';
    out.add(TruckChoice(id, plate, usedBy[id.toLowerCase()]));
  });
  out.sort((TruckChoice a, TruckChoice b) {
    if ((a.usedBy == null) != (b.usedBy == null)) return a.usedBy == null ? -1 : 1; // free trucks first
    return a.id.compareTo(b.id);
  });
  return out;
}

/// "Assigned Truck" row of a driver's profile, with a Change button (admin only).
class AssignedTruckTile extends StatelessWidget {
  const AssignedTruckTile({super.key, required this.truckId, required this.onPressed});

  final String? truckId;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final bool has = truckId != null && !_isPlaceholder(truckId!);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: has ? const Color(0xFFE0F2F1) : const Color(0xFFFFF4E0), borderRadius: BorderRadius.circular(12)),
            child: Icon(Icons.local_shipping_outlined, color: has ? _teal : _amber, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              const Text('Assigned Truck', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _muted)),
              const SizedBox(height: 4),
              Text(has ? truckId! : 'No truck assigned',
                  key: const ValueKey<String>('assigned-truck-value'),
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: has ? _ink : const Color(0xFFB45309))),
              const SizedBox(height: 2),
              const Text('The truck this driver drives (Truck ID)', style: TextStyle(fontSize: 11, color: _muted, fontWeight: FontWeight.w500)),
            ]),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            key: const ValueKey<String>('assign-truck-open'),
            onPressed: onPressed,
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFFE0F2F1),
              foregroundColor: _tealDark,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
            ),
            icon: Icon(has ? Icons.swap_horiz_rounded : Icons.add_rounded, size: 18),
            label: Text(has ? 'Change' : 'Assign', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// Opens the truck picker for [driver]. Returns the new truck id ('' = removed) or null if nothing changed.
Future<String?> showAssignTruckSheet(
  BuildContext context, {
  required Map<dynamic, dynamic> driver,
  required List<dynamic> users,
  required ApiService api,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) => _AssignTruckSheet(driver: driver, users: users, api: api),
  );
}

class _AssignTruckSheet extends StatefulWidget {
  const _AssignTruckSheet({required this.driver, required this.users, required this.api});
  final Map<dynamic, dynamic> driver;
  final List<dynamic> users;
  final ApiService api;

  @override
  State<_AssignTruckSheet> createState() => _AssignTruckSheetState();
}

class _AssignTruckSheetState extends State<_AssignTruckSheet> {
  List<TruckChoice>? _trucks;
  String? _selected;
  bool _saving = false;
  String? _error;

  String get _driverId => (widget.driver['user_id'] ?? widget.driver['id']).toString();
  String get _current => (widget.driver['preferred_truck'] ?? '').toString();
  bool get _hasCurrent => !_isPlaceholder(_current);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final DataSnapshot snap = await FirebaseDatabase.instance.ref('trucks').get();
      final Object? v = snap.value;
      final Map<dynamic, dynamic> reg = v is Map ? v : <dynamic, dynamic>{};
      if (mounted) setState(() => _trucks = buildTruckChoices(reg, widget.users, forDriverId: _driverId));
    } catch (_) {
      if (mounted) setState(() => _trucks = <TruckChoice>[]);
    }
  }

  Future<void> _save(String truckId) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final int id = int.parse(_driverId);
      final res = await widget.api.assignDriverTruck(id, truckId);
      final Map<dynamic, dynamic> body = res.data is Map ? res.data as Map : <dynamic, dynamic>{};
      if (body['success'] != true) {
        if (mounted) setState(() => _error = (body['message'] ?? 'Could not save the assignment.').toString());
        return;
      }
      // Drivers' apps read their truck from here; keep it in step with the database.
      await FirebaseDatabase.instance.ref('users/$_driverId').update(<String, Object?>{'preferred_truck': truckId.isEmpty ? null : truckId});
      if (mounted) Navigator.of(context).pop(truckId);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save the assignment. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Size size = MediaQuery.of(context).size;
    final bool wide = size.width >= 700;
    final String name = (widget.driver['name'] ?? widget.driver['username'] ?? 'driver').toString();
    final List<TruckChoice>? trucks = _trucks;
    return Align(
      alignment: wide ? Alignment.center : Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: wide ? 520 : double.infinity, maxHeight: size.height * 0.86),
        child: Container(
          margin: wide ? EdgeInsets.zero : EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: wide ? BorderRadius.circular(28) : const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 18), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
            const Text('Assign truck', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: _ink, letterSpacing: -0.4)),
            const SizedBox(height: 4),
            Text('Choose the truck $name will drive. One truck can have one active driver.',
                style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280), fontWeight: FontWeight.w500, height: 1.35)),
            const SizedBox(height: 16),
            Flexible(
              child: trucks == null
                  ? const Padding(padding: EdgeInsets.symmetric(vertical: 40), child: Center(child: CircularProgressIndicator(color: _teal, strokeWidth: 3)))
                  : trucks.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 32),
                          child: Center(child: Text('No trucks are registered yet.', style: TextStyle(color: _muted, fontWeight: FontWeight.w600))))
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: trucks.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemBuilder: (BuildContext _, int i) => _truckCard(trucks[i]),
                        ),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(14)),
                child: Row(children: <Widget>[
                  const Icon(Icons.error_outline_rounded, size: 18, color: Color(0xFFDC2626)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_error!, style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 12.5, fontWeight: FontWeight.w600))),
                ]),
              ),
            ],
            const SizedBox(height: 16),
            Row(children: <Widget>[
              if (_hasCurrent)
                TextButton(
                  key: const ValueKey<String>('assign-truck-remove'),
                  onPressed: _saving ? null : () => _save(''),
                  style: TextButton.styleFrom(foregroundColor: const Color(0xFFB91C1C), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14)),
                  child: const Text('Remove truck', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              const Spacer(),
              SizedBox(
                height: 48,
                child: FilledButton(
                  key: const ValueKey<String>('assign-truck-confirm'),
                  onPressed: (_saving || _selected == null) ? null : () => _save(_selected!),
                  style: FilledButton.styleFrom(
                    backgroundColor: _teal,
                    disabledBackgroundColor: const Color(0xFFE5E7EB),
                    padding: const EdgeInsets.symmetric(horizontal: 26),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                  ),
                  child: _saving
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : Text(_selected == null ? 'Select a truck' : 'Assign $_selected', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _truckCard(TruckChoice t) {
    final bool current = _hasCurrent && t.id.toLowerCase() == _current.toLowerCase();
    final bool taken = t.usedBy != null;
    final bool selected = _selected == t.id;
    final Color accent = taken ? const Color(0xFF9CA3AF) : _teal;
    return Opacity(
      opacity: taken ? 0.55 : 1,
      child: Material(
        color: selected ? const Color(0xFFE0F2F1) : const Color(0xFFF8FAFB),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: ValueKey<String>('truck-choice-${t.id}'),
          borderRadius: BorderRadius.circular(18),
          onTap: (taken || current || _saving) ? null : () => setState(() => _selected = selected ? null : t.id),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: selected ? _teal : const Color(0xFFEDF1F5), width: selected ? 1.6 : 1),
            ),
            child: Row(children: <Widget>[
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(13)),
                child: Icon(Icons.local_shipping_rounded, color: accent, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text(t.id, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _ink)),
                  const SizedBox(height: 2),
                  Text(t.plate.isEmpty ? 'No plate number' : 'Plate ${t.plate}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280), fontWeight: FontWeight.w500)),
                ]),
              ),
              const SizedBox(width: 8),
              if (current)
                _badge('Current', const Color(0xFFD1FAE5), const Color(0xFF047857))
              else if (taken)
                Flexible(child: _badge('In use · ${t.usedBy}', const Color(0xFFF3F4F6), const Color(0xFF6B7280)))
              else
                Icon(selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded, color: selected ? _teal : const Color(0xFFCBD5E1), size: 24),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _badge(String text, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: fg)),
      );
}
