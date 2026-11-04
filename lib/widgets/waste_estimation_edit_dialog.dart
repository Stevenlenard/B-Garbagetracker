import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/api_service.dart';
import '../services/waste_estimation_service.dart';

/// Admin editing of the two numbers the estimate is made of: the waste rate (kg per hectare per day, with its source) and
/// the holiday multiplier (with its source). A value needs its source; blank means "not available". A centred dialog on
/// wide screens, a full-screen page on phones. Returns true when something was saved.
Future<bool> showWasteEstimationEdit(BuildContext context, WasteEstimationData data) async {
  final Size size = MediaQuery.sizeOf(context);
  final bool? saved;
  if (size.width < 700 || size.height < 560) {
    saved = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (BuildContext _) => Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(child: WasteEstimationEditDialog(settings: data.settings, fullScreen: true)),
      ),
    ));
  } else {
    saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext _) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: math.min(560, size.width - 48),
          height: math.min(640, size.height * 0.92),
          child: WasteEstimationEditDialog(settings: data.settings),
        ),
      ),
    );
  }
  return saved == true;
}

/// What is sent to save_waste_estimation.php. [typed] returns the text of a field, or null when the field was never built
/// (such a field keeps its SAVED value). An empty text clears the value. The per-person rate is always cleared (the
/// estimate no longer uses population) and no area row is sent, so the saved area sizes stay as they are.
({Map<String, dynamic> settings, List<Map<String, dynamic>> areas}) buildWasteEstimationPayload({
  required Map<String, dynamic>? settings,
  required String? Function(String key) typed,
  required Map<String, bool> flags,
}) {
  final Map<String, dynamic> s0 = settings ?? <String, dynamic>{};
  String? val(String key, Object? saved) {
    final String? t = typed(key);
    if (t == null) {
      final String d = saved == null ? '' : '$saved'.trim();
      return d.isEmpty ? null : d;
    }
    final String x = t.trim();
    return x.isEmpty ? null : x;
  }

  return (
    settings: <String, dynamic>{
      'kg_per_capita_day': null,
      'rate_source': '',
      'kg_per_hectare_day': val('ha', s0['kg_per_hectare_day']),
      'hectare_rate_source': val('ha_src', s0['hectare_rate_source']) ?? '',
      'seasonal_value': val('sea', s0['seasonal_value']) ?? '1',
      'seasonal_source': val('sea_src', s0['seasonal_source']) ?? '',
      'seasonal_applies_to': (s0['seasonal_applies_to'] ?? '').toString().trim().isEmpty ? 'Christmas and New Year (Dec 24 to Jan 1)' : '${s0['seasonal_applies_to']}',
      'seasonal_active': flags['seasonal_active'] == true,
      'seasonal_validated': flags['seasonal_validated'] == true,
    },
    areas: <Map<String, dynamic>>[],
  );
}

/// The same rules as backend/waste_estimation_lib.php, checked before anything is sent. Keys are the field keys of the form
/// (`ha`, `ha_src`, `sea`, `sea_src`); the values are the messages shown under the fields.
Map<String, String> validateWasteEstimationPayload(({Map<String, dynamic> settings, List<Map<String, dynamic>> areas}) p) {
  final Map<String, String> e = <String, String>{};
  double? num0(Object? v) => v == null ? null : double.tryParse('$v'.trim());
  bool blank(Object? v) => v == null || '$v'.trim().isEmpty;

  final Map<String, dynamic> s = p.settings;
  final Object? ha = s['kg_per_hectare_day'];
  if (!blank(ha)) {
    final double? n = num0(ha);
    if (n == null || n < 0.01 || n > 100000) e['ha'] = 'Enter a number from 0.01 to 100000';
    if (blank(s['hectare_rate_source'])) e['ha_src'] = 'Add the source of this rate';
  }
  final double? sea = num0(s['seasonal_value']);
  if (sea == null || sea < 0.1 || sea > 5) e['sea'] = 'Enter a number from 0.1 to 5';
  if ((s['seasonal_active'] == true || s['seasonal_validated'] == true || (sea != null && sea != 1.0)) && blank(s['seasonal_source'])) {
    e['sea_src'] = 'A multiplier needs its source and date';
  }
  return e;
}

class _E {
  static const Color teal = Color(0xFF00796B);
  static const Color mint = Color(0xFFE6F4F1);
  static const Color ink = Color(0xFF0F172A);
  static const Color muted = Color(0xFF64748B);
  static const Color border = Color(0xFFE2E8F0);
  static const Color red = Color(0xFFB91C1C);
  static const Color amber = Color(0xFF92400E);
}

class WasteEstimationEditDialog extends StatefulWidget {
  const WasteEstimationEditDialog({super.key, required this.settings, this.fullScreen = false});

  final Map<String, dynamic>? settings;
  final bool fullScreen;

  @override
  State<WasteEstimationEditDialog> createState() => _WasteEstimationEditDialogState();
}

class _WasteEstimationEditDialogState extends State<WasteEstimationEditDialog> {
  final Map<String, TextEditingController> _c = <String, TextEditingController>{};
  final Map<String, bool> _flags = <String, bool>{};
  late final String _initial;
  String? _error;
  bool _saving = false;
  bool _submitted = false;

  TextEditingController _t(String key, Object? initial) => _c.putIfAbsent(key, () => TextEditingController(text: initial == null ? '' : '$initial'));

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic> s = widget.settings ?? <String, dynamic>{};
    _flags['seasonal_active'] = WasteEstimationData.flag(s['seasonal_active']);
    _flags['seasonal_validated'] = WasteEstimationData.flag(s['seasonal_validated']);
    _initial = _snapshot();
  }

  @override
  void dispose() {
    for (final TextEditingController c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  ({Map<String, dynamic> settings, List<Map<String, dynamic>> areas}) _payload() =>
      buildWasteEstimationPayload(settings: widget.settings, typed: (String key) => _c[key]?.text, flags: _flags);

  String _snapshot() => jsonEncode(_payload().settings);

  bool get _dirty => _snapshot() != _initial;

  Future<void> _save() async {
    final p = _payload();
    final Map<String, String> errs = validateWasteEstimationPayload(p);
    if (errs.isNotEmpty) {
      setState(() {
        _submitted = true;
        _error = errs.length == 1 ? 'One field needs attention (marked in red).' : '${errs.length} fields need attention (marked in red).';
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ApiService().saveWasteEstimation(settings: p.settings, areas: p.areas);
      if (mounted) Navigator.of(context).pop(true);
      return;
    } on DioException catch (e) {
      final Object? d = e.response?.data;
      _error = (d is Map && d['message'] != null) ? '${d['message']}' : 'Could not save.';
    } catch (_) {
      _error = 'Could not save.';
    }
    if (mounted) setState(() => _saving = false);
  }

  Widget _field(String key, String label, Object? initial, Map<String, String> errs, {bool number = false, int lines = 1, String? hint, String? suffix}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: _t(key, initial),
          onChanged: (_) => setState(() {}),
          keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
          minLines: 1,
          maxLines: lines,
          style: const TextStyle(fontSize: 14, color: _E.ink),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            suffixText: suffix,
            suffixStyle: const TextStyle(fontSize: 12.5, color: _E.muted, fontWeight: FontWeight.w700),
            errorText: _submitted ? errs[key] : null,
            errorMaxLines: 2,
          ),
        ),
      );

  Widget _switch(String key, String title, {String? subtitle}) => Material(
        type: MaterialType.transparency,
        child: SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _E.ink)),
          subtitle: subtitle == null ? null : Text(subtitle, style: const TextStyle(fontSize: 12, color: _E.muted)),
          value: _flags[key] == true,
          onChanged: (bool v) => setState(() => _flags[key] = v),
        ),
      );

  Widget _card(IconData icon, String title, String helper, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _E.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            Container(width: 34, height: 34, decoration: BoxDecoration(color: _E.mint, borderRadius: BorderRadius.circular(11)), child: Icon(icon, size: 19, color: _E.teal)),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900, color: _E.ink))),
          ]),
          Padding(padding: const EdgeInsets.only(top: 8, bottom: 14), child: Text(helper, style: const TextStyle(fontSize: 12.5, height: 1.4, color: _E.muted))),
          ...children,
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final ThemeData base = Theme.of(context);
    final OutlineInputBorder normal = OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _E.border));
    final OutlineInputBorder bad = OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _E.red, width: 1.4));
    final ThemeData themed = base.copyWith(
      colorScheme: base.colorScheme.copyWith(primary: _E.teal, onPrimary: Colors.white, secondary: _E.teal, surface: Colors.white, error: _E.red),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: normal,
        enabledBorder: normal,
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _E.teal, width: 1.6)),
        errorBorder: bad,
        focusedErrorBorder: bad,
        labelStyle: const TextStyle(color: _E.muted, fontSize: 13.5),
      ),
    );
    final Map<String, String> errs = validateWasteEstimationPayload(_payload());
    final Map<String, dynamic> s = widget.settings ?? <String, dynamic>{};
    final double pad = widget.fullScreen ? 16 : 24;
    return Theme(
      data: themed,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 18, pad - 8, 10),
          child: Row(children: <Widget>[
            const Expanded(child: Text('Edit waste rate and holiday multiplier', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: _E.ink))),
            IconButton(tooltip: 'Close', onPressed: _saving ? null : () => Navigator.of(context).pop(false), icon: const Icon(Icons.close_rounded, color: _E.muted)),
          ]),
        ),
        const Divider(height: 1, color: _E.border),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(pad, 18, pad, 18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              _card(Icons.eco_rounded, 'Waste rate', 'How much waste one hectare of a collection area generates in a day. Every area uses the same rate. A value needs its source.', <Widget>[
                _field('ha', 'Waste rate', s['kg_per_hectare_day'], errs, number: true, suffix: 'kg/ha/day'),
                _field('ha_src', 'Source of the rate', s['hectare_rate_source'], errs, lines: 4, hint: 'Document or reasoning this rate comes from'),
              ]),
              _card(Icons.celebration_rounded, 'Holiday multiplier', 'Multiplies the estimate from Dec 24 to Jan 1 (Christmas and New Year). Every other day uses 1.0.', <Widget>[
                _field('sea', 'Multiplier', s['seasonal_value'] ?? '1', errs, number: true, suffix: '×'),
                _switch('seasonal_active', 'Apply on Dec 24 to Jan 1'),
                _field('sea_src', 'Source and date of the multiplier', s['seasonal_source'], errs, lines: 4),
                _switch('seasonal_validated', 'Measured in Lipa', subtitle: 'Turn on only when the value comes from Lipa data.'),
              ]),
              if (_error != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(12)),
                  child: Text(_error!, style: const TextStyle(fontSize: 13, color: _E.red, fontWeight: FontWeight.w700)),
                ),
            ]),
          ),
        ),
        const Divider(height: 1, color: _E.border),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: pad, vertical: 12),
          child: Row(children: <Widget>[
            Expanded(child: Text(_dirty ? 'Unsaved changes' : 'No changes', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _dirty ? _E.amber : _E.muted))),
            OutlinedButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(false),
              style: OutlinedButton.styleFrom(foregroundColor: _E.ink, side: const BorderSide(color: _E.border), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
              child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            FilledButton(
              onPressed: (_saving || !_dirty) ? null : _save,
              style: FilledButton.styleFrom(backgroundColor: _E.teal, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12)),
              child: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Save', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ]),
        ),
      ]),
    );
  }
}
