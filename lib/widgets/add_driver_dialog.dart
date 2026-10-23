import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_service.dart';

/// Admin form that creates a driver account (public driver sign-up is closed). The account is
/// active at once; the admin hands the username and temporary password to the driver.
/// Returns true when an account was created.
Future<bool> showAddDriverDialog(BuildContext context, {ApiService? api}) async {
  final bool? created = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (BuildContext ctx) => _AddDriverDialog(api: api ?? ApiService()),
  );
  return created ?? false;
}

class _AddDriverDialog extends StatefulWidget {
  const _AddDriverDialog({required this.api});
  final ApiService api;

  @override
  State<_AddDriverDialog> createState() => _AddDriverDialogState();
}

class _AddDriverDialogState extends State<_AddDriverDialog> {
  static const Color _teal = Color(0xFF00796B);
  static const Color _ink = Color(0xFF1F2A27);

  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _license = TextEditingController();
  final TextEditingController _password = TextEditingController(text: _generatePassword());
  bool _saving = false;
  bool _showPassword = true;
  String? _serverError;
  bool _created = false;

  static String _generatePassword() {
    const String letters = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ';
    const String digits = '23456789';
    final math.Random r = math.Random.secure();
    final String core = List<String>.generate(6, (_) => letters[r.nextInt(letters.length)]).join();
    return '$core${digits[r.nextInt(digits.length)]}${digits[r.nextInt(digits.length)]}';
  }

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[_name, _username, _email, _phone, _license, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _serverError = null);
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final res = await widget.api.register(<String, dynamic>{
        'role': 'driver',
        'name': _name.text.trim(),
        'username': _username.text.trim(),
        'email': _email.text.trim(),
        'phone': _phone.text.trim(),
        'license_number': _license.text.trim(),
        'password': _password.text,
        'termsAccepted': 1,
      });
      final Object? data = res.data;
      if (data is Map && data['success'] == true) {
        setState(() => _created = true);
      } else {
        setState(() => _serverError = data is Map ? (data['message']?.toString() ?? 'The account could not be created.') : 'The account could not be created.');
      }
    } catch (e) {
      setState(() => _serverError = 'The account could not be created. Check the connection and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _decor(String label, IconData icon, {String? hint, Widget? suffix}) => InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 19, color: _teal),
        suffixIcon: suffix,
        filled: true,
        fillColor: const Color(0xFFF7F9F8),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFDDE5E2))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFDDE5E2))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _teal, width: 1.8)),
      );

  Widget _field(TextEditingController c, String label, IconData icon,
          {String? hint, String? Function(String?)? validator, List<TextInputFormatter>? formatters, TextInputType? keyboard, Widget? suffix, bool obscure = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          controller: c,
          validator: validator,
          inputFormatters: formatters,
          keyboardType: keyboard,
          obscureText: obscure,
          decoration: _decor(label, icon, hint: hint, suffix: suffix),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _ink),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
          child: _created ? _successView() : _formView(),
        ),
      ),
    );
  }

  Widget _header(IconData icon, String title, String subtitle) => Row(children: <Widget>[
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: _teal.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(14)),
          child: Icon(icon, color: _teal, size: 24),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: _ink)),
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
          ]),
        ),
      ]);

  Widget _formView() {
    return Form(
      key: _form,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: <Widget>[
        _header(Icons.person_add_alt_1_rounded, 'Add Driver', 'The account is active at once. Give the driver the username and password.'),
        const SizedBox(height: 20),
        _field(_name, 'Full name', Icons.badge_outlined,
            validator: (String? v) => (v ?? '').trim().length < 2 ? 'Enter the driver\'s full name.' : null),
        _field(_username, 'Username', Icons.person_outline_rounded,
            hint: 'e.g. juan_delacruz (no spaces)',
            formatters: <TextInputFormatter>[FilteringTextInputFormatter.deny(RegExp(r'\s')), LengthLimitingTextInputFormatter(50)],
            validator: (String? v) => (v ?? '').trim().length < 3 ? 'Use 3 to 50 characters, no spaces.' : null),
        _field(_email, 'Email', Icons.mail_outline_rounded,
            keyboard: TextInputType.emailAddress,
            validator: (String? v) {
              final String t = (v ?? '').trim();
              if (t.isEmpty) return 'Enter an email (used for password reset).';
              return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$').hasMatch(t) ? null : 'Enter a valid email address.';
            }),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Expanded(
            child: _field(_phone, 'Contact number', Icons.phone_outlined,
                keyboard: TextInputType.phone,
                formatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
                validator: (String? v) => (v ?? '').isNotEmpty && (v ?? '').length != 11 ? '11 digits (09xxxxxxxxx).' : null),
          ),
          const SizedBox(width: 10),
          Expanded(child: _field(_license, 'License number', Icons.credit_card_rounded,
              validator: (String? v) => (v ?? '').trim().isEmpty ? 'Enter the license number.' : null)),
        ]),
        _field(_password, 'Temporary password', Icons.lock_outline_rounded,
            obscure: !_showPassword,
            validator: (String? v) => (v ?? '').length < 6 ? 'At least 6 characters.' : null,
            suffix: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
              IconButton(
                tooltip: _showPassword ? 'Hide' : 'Show',
                icon: Icon(_showPassword ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 19, color: Colors.grey.shade600),
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
              IconButton(
                tooltip: 'Generate a new password',
                icon: const Icon(Icons.autorenew_rounded, size: 19, color: _teal),
                onPressed: () => setState(() => _password.text = _generatePassword()),
              ),
            ])),
        if (_serverError != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFD93025).withValues(alpha: 0.07), borderRadius: BorderRadius.circular(12)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              const Icon(Icons.error_outline_rounded, size: 18, color: Color(0xFFD93025)),
              const SizedBox(width: 10),
              Expanded(child: Text(_serverError!, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF8C1D18)))),
            ]),
          ),
        const SizedBox(height: 6),
        Row(children: <Widget>[
          Expanded(
            child: OutlinedButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(false),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF3C4A45),
                side: const BorderSide(color: Color(0xFFD5DDD9)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: FilledButton.icon(
              onPressed: _saving ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: _teal,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_rounded, size: 18),
              label: Text(_saving ? 'Creating…' : 'Create account', style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _successView() {
    final String details = 'Garbage Tracker driver login\nUsername: ${_username.text.trim()}\nTemporary password: ${_password.text}';
    Widget line(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: <Widget>[
            SizedBox(width: 150, child: Text(label, style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600))),
            Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _ink))),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: <Widget>[
      _header(Icons.verified_rounded, 'Driver account created', '${_name.text.trim()} can log in now.'),
      const SizedBox(height: 18),
      Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF6F8F7),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE3E9E6)),
        ),
        child: Column(children: <Widget>[
          line('Username', _username.text.trim()),
          line('Temporary password', _password.text),
        ]),
      ),
      const SizedBox(height: 10),
      Text('Give these to the driver in person. They can change the password in Account Settings.',
          style: TextStyle(fontSize: 12.5, height: 1.4, color: Colors.grey.shade700)),
      const SizedBox(height: 18),
      Row(children: <Widget>[
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: details));
              if (!mounted) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Login details copied')));
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: _teal,
              side: const BorderSide(color: _teal),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copy details', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: _teal,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
      ]),
    ]);
  }
}
