import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/api_service.dart';
import '../services/waste_estimation_service.dart';

/// Admin editing of the estimation parameters and the confirmed area rows. Same save call and same rules as before (every
/// value needs its source; blank means "not available"), laid out in sections with the rules checked on the screen too:
/// a centred dialog on wide screens, a full-screen page on phones. Returns true when something was saved.
Future<bool> showWasteEstimationEdit(BuildContext context, WasteEstimationData data) async {
  final List<WasteAreaRow> rows = <WasteAreaRow>[data.barangay, ...data.rows];
  final Size size = MediaQuery.sizeOf(context);
  final bool? saved;
  if (size.width < 700 || size.height < 560) {
    saved = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (BuildContext _) => Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(child: WasteEstimationEditDialog(settings: data.settings, rows: rows, fullScreen: true)),
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
          width: math.min(780, size.width - 48),
          height: math.min(800, size.height * 0.92),
          child: WasteEstimationEditDialog(settings: data.settings, rows: rows),
        ),
      ),
    );
  }
  return saved == true;
}

/// What is sent to save_waste_estimation.php. [typed] returns the text of a field, or null when the field was never built
/// (an area that was not opened): such a field keeps its SAVED value, so saving never wipes what was not touched. An empty
/// text clears the value.
({Map<String, dynamic> settings, List<Map<String, dynamic>> areas}) buildWasteEstimationPayload({
  required Map<String, dynamic>? settings,
  required List<WasteAreaRow> rows,
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
      'kg_per_capita_day': val('cap', s0['kg_per_capita_day']),
      'rate_source': val('cap_src', s0['rate_source']) ?? '',
      'kg_per_hectare_day': val('ha', s0['kg_per_hectare_day']),
      'hectare_rate_source': val('ha_src', s0['hectare_rate_source']) ?? '',
      'seasonal_value': val('sea', s0['seasonal_value']) ?? '1',
      'seasonal_source': val('sea_src', s0['seasonal_source']) ?? '',
      'seasonal_applies_to': val('sea_to', s0['seasonal_applies_to']) ?? '',
      'seasonal_active': flags['seasonal_active'] == true,
      'seasonal_validated': flags['seasonal_validated'] == true,
    },
    areas: <Map<String, dynamic>>[
      for (final WasteAreaRow r in rows)
        <String, dynamic>{
          'area_key': r.key,
          'area_name': r.name,
          'size_m2': val('m2_${r.key}', r.saved?['size_m2']),
          'size_kind': val('m2_${r.key}', r.saved?['size_m2']) == null ? 'none' : 'manual',
          'size_source': val('m2src_${r.key}', r.saved?['size_source']) ?? '',
          'size_verified': flags['v_${r.key}'] == true,
          'population': val('pop_${r.key}', r.saved?['population']),
          'population_source': val('popsrc_${r.key}', r.saved?['population_source']) ?? '',
          'population_year': val('popyr_${r.key}', r.saved?['population_year']),
        },
    ],
  );
}

/// The same rules as backend/waste_estimation_lib.php, checked before anything is sent. Keys are the field keys of the form
/// (`cap`, `cap_src`, `m2_<area>`, ...); the values are the messages shown under the fields.
Map<String, String> validateWasteEstimationPayload(({Map<String, dynamic> settings, List<Map<String, dynamic>> areas}) p) {
  final Map<String, String> e = <String, String>{};
  double? num0(Object? v) => v == null ? null : double.tryParse('$v'.trim());
  bool blank(Object? v) => v == null || '$v'.trim().isEmpty;

  final Map<String, dynamic> s = p.settings;
  final Object? cap = s['kg_per_capita_day'];
  if (!blank(cap)) {
    final double? n = num0(cap);
    if (n == null || n < 0.01 || n > 10) e['cap'] = 'Enter a number from 0.01 to 10';
    if (blank(s['rate_source'])) e['cap_src'] = 'Add the source of this rate';
  }
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

  for (final Map<String, dynamic> a in p.areas) {
    final String k = '${a['area_key']}';
    final Object? m2 = a['size_m2'];
    if (!blank(m2)) {
      final double? n = num0(m2);
      if (n == null || n < 1 || n > 1e9) e['m2_$k'] = 'Enter a size in square metres';
      if (blank(a['size_source'])) e['m2src_$k'] = 'Add the source of this size';
    }
    final Object? pop = a['population'];
    if (!blank(pop)) {
      final double? n = num0(pop);
      if (n == null || n < 1 || n > 5000000) e['pop_$k'] = 'Enter a whole number of people';
      if (blank(a['population_source'])) e['popsrc_$k'] = 'Add the source of this population';
    }
    final Object? yr = a['population_year'];
    if (!blank(yr)) {
      final double? n = num0(yr);
      if (n == null || n < 1900 || n > 2100) e['popyr_$k'] = 'Enter a year';
    }
  }
  return e;
}

class _E {
  static const Color teal = Color(0xFF00796B);
  static const Color tealDark = Color(0xFF00695C);
  static const Color mint = Color(0xFFE6F4F1);
  static const Color mintSoft = Color(0xFFF1F9F7);
  static const Color ink = Color(0xFF0F172A);
  static const Color muted = Color(0xFF64748B);
  static const Color border = Color(0xFFE2E8F0);
  static const Color soft = Color(0xFFF8FAFC);
  static const Color red = Color(0xFFB91C1C);
  static const Color amber = Color(0xFF92400E);
}

class WasteEstimationEditDialog extends StatefulWidget {
  const WasteEstimationEditDialog({super.key, required this.settings, required this.rows, this.fullScreen = false});

  final Map<String, dynamic>? settings;
  final List<WasteAreaRow> rows;
  final bool fullScreen;

  @override
  State<WasteEstimationEditDialog> createState() => _WasteEstimationEditDialogState();
}

class _WasteEstimationEditDialogState extends State<WasteEstimationEditDialog> {
  final Map<String, TextEditingController> _c = <String, TextEditingController>{};
  final Map<String, bool> _flags = <String, bool>{};
  final Set<String> _open = <String>{};
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
    for (final WasteAreaRow r in widget.rows) {
      _flags['v_${r.key}'] = WasteEstimationData.flag(r.saved?['size_verified']);
    }
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
      buildWasteEstimationPayload(settings: widget.settings, rows: widget.rows, typed: (String key) => _c[key]?.text, flags: _flags);

  String _snapshot() {
    final p = _payload();
    return jsonEncode(<Object>[p.settings, p.areas]);
  }

  bool get _dirty => _snapshot() != _initial;

  /// The areas whose fields have an error (so they can be opened).
  Set<String> _areasWithErrors(Map<String, String> errs) {
    final Set<String> out = <String>{};
    for (final String k in errs.keys) {
      for (final String prefix in <String>['m2src_', 'm2_', 'popsrc_', 'popyr_', 'pop_']) {
        if (k.startsWith(prefix)) {
          out.add(k.substring(prefix.length));
          break;
        }
      }
    }
    return out;
  }

  Future<void> _save() async {
    final p = _payload();
    final Map<String, String> errs = validateWasteEstimationPayload(p);
    if (errs.isNotEmpty) {
      setState(() {
        _submitted = true;
        _open.addAll(_areasWithErrors(errs));
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

  // ------------------------------------------------------------------ pieces

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

  Widget _chip(String text, {Color bg = _E.mint, Color fg = _E.tealDark, IconData? icon}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
          if (icon != null) ...<Widget>[Icon(icon, size: 13, color: fg), const SizedBox(width: 4)],
          Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: fg)),
        ]),
      );

  Widget _card(int n, IconData icon, String title, String helper, Widget? status, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _E.border), boxShadow: <BoxShadow>[BoxShadow(color: Colors.black.withValues(alpha: 0.025), blurRadius: 10, offset: const Offset(0, 3))]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            Container(width: 34, height: 34, decoration: BoxDecoration(color: _E.mint, borderRadius: BorderRadius.circular(11)), child: Icon(icon, size: 19, color: _E.teal)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text('STEP $n', style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, color: _E.teal, letterSpacing: 0.9)),
                Text(title, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900, color: _E.ink)),
              ]),
            ),
            if (status != null) status,
          ]),
          if (helper.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(helper, style: const TextStyle(fontSize: 12.5, height: 1.4, color: _E.muted))),
          const SizedBox(height: 14),
          ...children,
        ]),
      );

  bool _has(String key, Object? saved) {
    final String? t = _c[key]?.text;
    if (t != null) return t.trim().isNotEmpty;
    return saved != null && '$saved'.trim().isNotEmpty;
  }

  // ----------------------------------------------------------------- layout

  @override
  Widget build(BuildContext context) {
    final ThemeData base = Theme.of(context);
    final OutlineInputBorder normal = OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _E.border));
    final OutlineInputBorder bad = OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _E.red, width: 1.4));
    final ThemeData themed = base.copyWith(
      colorScheme: base.colorScheme.copyWith(primary: _E.teal, onPrimary: Colors.white, secondary: _E.teal, surface: Colors.white, error: _E.red),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(Colors.white),
        trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) => s.contains(WidgetState.selected) ? _E.teal : const Color(0xFFCBD5E1)),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: _E.soft,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
        labelStyle: const TextStyle(fontSize: 13, color: _E.muted),
        floatingLabelStyle: const TextStyle(fontSize: 13, color: _E.teal, fontWeight: FontWeight.w700),
        hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF94A3B8)),
        errorStyle: const TextStyle(fontSize: 12, color: _E.red, fontWeight: FontWeight.w600),
        border: normal,
        enabledBorder: normal,
        errorBorder: bad,
        focusedErrorBorder: bad,
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _E.teal, width: 1.6)),
      ),
      textSelectionTheme: const TextSelectionThemeData(cursorColor: _E.teal),
    );
    final Map<String, String> errs = validateWasteEstimationPayload(_payload());
    final bool dirty = _dirty;
    return Theme(
      data: themed,
      child: LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
        final bool wide = c.maxWidth >= 560;
        final double pad = wide ? 24 : 16;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          _header(pad),
          const Divider(height: 1, color: _E.border),
          Expanded(
            child: Container(
              color: _E.soft,
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(pad, 16, pad, 20),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                  _rates(wide, errs),
                  _seasonal(wide, errs),
                  _areas(errs),
                ]),
              ),
            ),
          ),
          if (_error != null)
            Container(
              margin: EdgeInsets.fromLTRB(pad, 10, pad, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(12)),
              child: Row(children: <Widget>[
                const Icon(Icons.error_outline_rounded, color: _E.red, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(_error!, style: const TextStyle(fontSize: 13, color: Color(0xFF991B1B), fontWeight: FontWeight.w700))),
              ]),
            ),
          Container(
            decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: _E.border))),
            padding: EdgeInsets.symmetric(horizontal: pad, vertical: 12),
            child: Row(children: <Widget>[
              Expanded(
                child: Row(children: <Widget>[
                  Container(width: 8, height: 8, decoration: BoxDecoration(color: dirty ? const Color(0xFFF59E0B) : const Color(0xFFCBD5E1), shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Flexible(child: Text(dirty ? 'Unsaved changes' : 'No changes', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: dirty ? _E.amber : _E.muted))),
                ]),
              ),
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                style: TextButton.styleFrom(foregroundColor: _E.muted, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
                child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 6),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_rounded, size: 18),
                label: Text(_saving ? 'Saving…' : 'Save', style: const TextStyle(fontWeight: FontWeight.w800)),
                style: FilledButton.styleFrom(backgroundColor: _E.teal, padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              ),
            ]),
          ),
        ]);
      }),
    );
  }

  Widget _header(double pad) => Container(
        decoration: const BoxDecoration(gradient: LinearGradient(colors: <Color>[_E.mint, Colors.white], begin: Alignment.topLeft, end: Alignment.bottomRight)),
        padding: EdgeInsets.fromLTRB(pad, 16, pad - 8, 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: _E.teal, borderRadius: BorderRadius.circular(14), boxShadow: <BoxShadow>[BoxShadow(color: _E.teal.withValues(alpha: 0.25), blurRadius: 10, offset: const Offset(0, 4))]),
            child: const Icon(Icons.tune_rounded, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('Estimation parameters', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: _E.ink, letterSpacing: -0.2)),
              SizedBox(height: 3),
              Text('Every value needs its source (document, date). Leave blank what is not documented; nothing is assumed.', style: TextStyle(fontSize: 12.5, height: 1.35, color: _E.muted, fontWeight: FontWeight.w500)),
            ]),
          ),
          IconButton(tooltip: widget.fullScreen ? 'Back' : 'Close', onPressed: _saving ? null : () => Navigator.of(context).pop(false), icon: Icon(widget.fullScreen ? Icons.arrow_back_rounded : Icons.close_rounded, color: _E.muted)),
        ]),
      );

  Widget _rates(bool wide, Map<String, String> errs) {
    final Map<String, dynamic> s = widget.settings ?? <String, dynamic>{};
    final Widget person = Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      const _Sub('Per person'),
      _field('cap', 'kg per person per day', s['kg_per_capita_day'], errs, number: true, suffix: 'kg/day'),
      _field('cap_src', 'Source of the per-person rate', s['rate_source'], errs, lines: 3, hint: 'Document, author, year'),
    ]);
    final Widget hectare = Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      const _Sub('Per hectare'),
      _field('ha', 'kg per hectare per day', s['kg_per_hectare_day'], errs, number: true, suffix: 'kg/ha/day'),
      _field('ha_src', 'Source of the per-hectare rate', s['hectare_rate_source'], errs, lines: 3, hint: 'Document, author, year'),
    ]);
    final int set = (_has('cap', s['kg_per_capita_day']) ? 1 : 0) + (_has('ha', s['kg_per_hectare_day']) ? 1 : 0);
    return _card(
      1,
      Icons.scale_outlined,
      'Waste-generation rates',
      'Used with a population (per person) or with an area size (per hectare).',
      set == 0 ? _chip('Not set', bg: const Color(0xFFF1F5F9), fg: _E.muted) : _chip('$set of 2 set', icon: Icons.check_rounded),
      <Widget>[
        if (wide) Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[Expanded(child: person), const SizedBox(width: 16), Expanded(child: hectare)]) else ...<Widget>[person, const SizedBox(height: 2), hectare],
      ],
    );
  }

  Widget _seasonal(bool wide, Map<String, String> errs) {
    final Map<String, dynamic> s = widget.settings ?? <String, dynamic>{};
    final Widget value = _field('sea', 'Holiday multiplier (1.0 = neutral)', s['seasonal_value'] ?? 1, errs, number: true, suffix: '×');
    final Widget appliesTo = _field('sea_to', 'Note on where it applies', s['seasonal_applies_to'], errs, hint: 'Cities, years');
    final bool applied = _flags['seasonal_active'] == true;
    return _card(
      2,
      Icons.event_repeat_outlined,
      'Seasonal multiplier',
      'Applied automatically on Christmas and New Year (Dec 24 to Jan 1); every other day is 1.0. Neutral unless it has a documented source and date.',
      applied ? _chip('Applied', bg: const Color(0xFFFEF3C7), fg: _E.amber) : _chip('Neutral', icon: Icons.check_rounded),
      <Widget>[
        if (wide) Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[Expanded(child: value), const SizedBox(width: 16), Expanded(child: appliesTo)]) else ...<Widget>[value, appliesTo],
        _field('sea_src', 'Source and date of the multiplier', s['seasonal_source'], errs, lines: 2, hint: 'Document, author, date'),
        _switch('seasonal_active', 'Apply on holidays automatically'),
        _switch('seasonal_validated', 'Evidence is on file (validated)'),
      ],
    );
  }

  Widget _areas(Map<String, String> errs) {
    int withData = 0;
    for (final WasteAreaRow r in widget.rows) {
      if (_has('pop_${r.key}', r.saved?['population']) || _has('m2_${r.key}', r.saved?['size_m2'])) withData++;
    }
    return _card(
      3,
      Icons.map_outlined,
      'Population and area sizes',
      'Open an area to confirm its size or population. Leave blank what is not documented.',
      withData == 0 ? _chip('None yet', bg: const Color(0xFFF1F5F9), fg: _E.muted) : _chip('$withData of ${widget.rows.length}', icon: Icons.check_rounded),
      <Widget>[for (final WasteAreaRow r in widget.rows) _areaEditor(r, errs)],
    );
  }

  String _summary(WasteAreaRow r, bool whole) {
    String? read(String key, Object? saved) {
      final String? t = _c[key]?.text;
      final String v = (t ?? (saved == null ? '' : '$saved')).trim();
      return v.isEmpty ? null : v;
    }

    final List<String> parts = <String>[];
    final String? pop = read('pop_${r.key}', r.saved?['population']);
    parts.add(pop == null ? 'No population' : 'Population $pop');
    if (!whole) {
      final String? m2 = read('m2_${r.key}', r.saved?['size_m2']);
      parts.add(m2 == null ? 'no confirmed size' : 'size $m2 m²');
    }
    return parts.join(' · ');
  }

  Widget _areaEditor(WasteAreaRow r, Map<String, String> errs) {
    final bool whole = r.key == WasteEstimationData.barangayKey;
    final bool hasError = errs.keys.any((String k) => k.endsWith('_${r.key}'));
    final bool open = _open.contains(r.key);
    final bool filled = _has('pop_${r.key}', r.saved?['population']) || _has('m2_${r.key}', r.saved?['size_m2']);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: open ? _E.mintSoft : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _submitted && hasError ? _E.red : (open ? const Color(0xFFCFE8E2) : _E.border), width: _submitted && hasError ? 1.4 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        InkWell(
          key: ValueKey<String>('edit-${r.key}'),
          onTap: () => setState(() => open ? _open.remove(r.key) : _open.add(r.key)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: <Widget>[
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text(r.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _E.ink)),
                  const SizedBox(height: 2),
                  Text(_summary(r, whole), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: _E.muted, fontWeight: FontWeight.w600)),
                ]),
              ),
              if (_submitted && hasError) ...<Widget>[_chip('Fix', bg: const Color(0xFFFEE2E2), fg: _E.red, icon: Icons.error_outline_rounded), const SizedBox(width: 6)] else if (filled) ...<Widget>[const Icon(Icons.check_circle_rounded, size: 18, color: _E.teal), const SizedBox(width: 6)],
              Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: _E.muted),
            ]),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              if (!whole) ...<Widget>[
                const _Sub('Area size'),
                _field('m2_${r.key}', 'Confirmed size (m²)', r.saved?['size_m2'], errs, number: true, suffix: 'm²'),
                _field('m2src_${r.key}', 'Source of the size', r.saved?['size_source'], errs, lines: 2, hint: 'Survey, map layer, date'),
                _switch('v_${r.key}', 'Verified against the real collection area'),
                const SizedBox(height: 8),
              ],
              const _Sub('Population'),
              _field('pop_${r.key}', 'Population', r.saved?['population'], errs, number: true, suffix: 'people'),
              _field('popsrc_${r.key}', 'Source of the population', r.saved?['population_source'], errs, lines: 2, hint: 'Census, barangay record'),
              _field('popyr_${r.key}', 'Population year', r.saved?['population_year'], errs, number: true),
            ]),
          ),
      ]),
    );
  }
}

class _Sub extends StatelessWidget {
  const _Sub(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text.toUpperCase(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: _E.tealDark, letterSpacing: 0.8)),
      );
}
