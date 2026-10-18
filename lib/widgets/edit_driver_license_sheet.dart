import 'package:flutter/material.dart';

import '../api/api_service.dart';

const Color _teal = Color(0xFF00897B);
const Color _tealDark = Color(0xFF00695C);
const Color _ink = Color(0xFF1A1A1A);
const Color _muted = Color(0xFF9E9E9E);

final RegExp _licenseFormat = RegExp(r'^[a-zA-Z0-9!@#$%^&*(),.?":{}|<> -]+$');

/// Null when [value] is acceptable, otherwise the message to show.
String? validateLicenseNumber(String value) {
  final String v = value.trim();
  if (v.isEmpty) return "Enter the driver's license number.";
  if (v.length > 40) return 'That is too long (40 characters at most).';
  if (!_licenseFormat.hasMatch(v)) return 'Use letters, numbers, spaces and dashes only.';
  return null;
}

/// "Driver's License No." row of a driver's profile, with an Edit button (admin only).
class DriverLicenseTile extends StatelessWidget {
  const DriverLicenseTile({super.key, required this.license, required this.onPressed});

  final String? license;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final bool has = license != null && license!.trim().isNotEmpty;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFFF8F9FA), borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.badge_outlined, color: Color(0xFF00897B), size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              const Text("Driver's License No.", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _muted)),
              const SizedBox(height: 4),
              Text(has ? license!.trim() : 'Not provided',
                  key: const ValueKey<String>('license-value'),
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: has ? _ink : _muted)),
              const SizedBox(height: 2),
              const Text("The person's own license, not the truck", style: TextStyle(fontSize: 11, color: _muted, fontWeight: FontWeight.w500)),
            ]),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            key: const ValueKey<String>('edit-license-open'),
            onPressed: onPressed,
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFFE0F2F1),
              foregroundColor: _tealDark,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
            ),
            icon: const Icon(Icons.edit_outlined, size: 17),
            label: const Text('Edit', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

/// Opens the license editor. Returns the saved license number, or null if nothing changed.
Future<String?> showEditDriverLicenseSheet(
  BuildContext context, {
  required Map<dynamic, dynamic> driver,
  required ApiService api,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) => _EditLicenseSheet(driver: driver, api: api),
  );
}

class _EditLicenseSheet extends StatefulWidget {
  const _EditLicenseSheet({required this.driver, required this.api});
  final Map<dynamic, dynamic> driver;
  final ApiService api;

  @override
  State<_EditLicenseSheet> createState() => _EditLicenseSheetState();
}

class _EditLicenseSheetState extends State<_EditLicenseSheet> {
  late final TextEditingController _c = TextEditingController(text: (widget.driver['license_number'] ?? '').toString().trim());
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String? problem = validateLicenseNumber(_c.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final int id = int.parse((widget.driver['user_id'] ?? widget.driver['id']).toString());
      final res = await widget.api.updateDriverLicense(id, _c.text.trim());
      final Map<dynamic, dynamic> body = res.data is Map ? res.data as Map : <dynamic, dynamic>{};
      if (body['success'] != true) {
        if (mounted) setState(() => _error = (body['message'] ?? 'Could not save the license number.').toString());
        return;
      }
      if (mounted) Navigator.of(context).pop(_c.text.trim());
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool wide = MediaQuery.of(context).size.width >= 700;
    final String name = (widget.driver['name'] ?? widget.driver['username'] ?? 'the driver').toString();
    return Align(
      alignment: wide ? Alignment.center : Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: wide ? 480 : double.infinity),
        child: Container(
          margin: EdgeInsets.only(bottom: wide ? 0 : MediaQuery.of(context).viewInsets.bottom),
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 22),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: wide ? BorderRadius.circular(28) : const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 18), decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
            const Text("Driver's license number", style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: _ink, letterSpacing: -0.4)),
            const SizedBox(height: 4),
            Text("Enter the number on $name's own driver's license. The truck is chosen separately with Assign.",
                style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280), fontWeight: FontWeight.w500, height: 1.35)),
            const SizedBox(height: 18),
            TextField(
              key: const ValueKey<String>('license-field'),
              controller: _c,
              autofocus: true,
              enabled: !_saving,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              decoration: InputDecoration(
                hintText: 'e.g. N01-23-456789',
                prefixIcon: const Icon(Icons.badge_outlined, color: _teal),
                filled: true,
                fillColor: const Color(0xFFF8FAFB),
                errorText: _error,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFEDF1F5))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFEDF1F5))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: _teal, width: 1.6)),
              ),
            ),
            const SizedBox(height: 20),
            Row(children: <Widget>[
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(foregroundColor: const Color(0xFF6B7280), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
                child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
              const Spacer(),
              SizedBox(
                height: 48,
                child: FilledButton(
                  key: const ValueKey<String>('license-save'),
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: _teal,
                    padding: const EdgeInsets.symmetric(horizontal: 30),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                  ),
                  child: _saving
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : const Text('Save', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
