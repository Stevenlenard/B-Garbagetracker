import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/api_service.dart';
import '../services/waste_estimation_service.dart';

/// Admin editing of the estimation parameters and the confirmed area rows. Same behaviour as before (every value needs its
/// source; blank means "not available"; the same save call), now laid out in sections: a centred dialog on wide screens, a
/// full-screen page on phones. Returns true when something was saved.
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
          width: math.min(760, size.width - 48),
          height: math.min(780, size.height * 0.9),
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

class _E {
  static const Color teal = Color(0xFF00796B);
  static const Color tealDark = Color(0xFF00695C);
  static const Color mint = Color(0xFFE6F4F1);
  static const Color mintSoft = Color(0xFFF1F9F7);
  static const Color ink = Color(0xFF0F172A);
  static const Color muted = Color(0xFF64748B);
  static const Color border = Color(0xFFE2E8F0);
  static const Color soft = Color(0xFFF8FAFC);
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
  String? _error;
  bool _saving = false;

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
  }

  @override
  void dispose() {
    for (final TextEditingController c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String? _v(String key) {
    final String s = (_c[key]?.text ?? '').trim();
    return s.isEmpty ? null : s;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final payload = buildWasteEstimationPayload(
      settings: widget.settings,
      rows: widget.rows,
      typed: (String key) => _c[key]?.text,
      flags: _flags,
    );
    final Map<String, dynamic> settings = payload.settings;
    final List<Map<String, dynamic>> areas = payload.areas;
    try {
      await ApiService().saveWasteEstimation(settings: settings, areas: areas);
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

  Widget _field(String key, String label, Object? initial, {bool number = false, int lines = 1, String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: _t(key, initial),
          onChanged: (_) => setState(() {}),
          keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
          minLines: 1,
          maxLines: lines,
          style: const TextStyle(fontSize: 14, color: _E.ink),
          decoration: InputDecoration(labelText: label, hintText: hint),
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

  @override
  Widget build(BuildContext context) {
    final ThemeData base = Theme.of(context);
    final OutlineInputBorder normal = OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _E.border));
    final ThemeData themed = base.copyWith(
      colorScheme: base.colorScheme.copyWith(primary: _E.teal, onPrimary: Colors.white, secondary: _E.teal, surface: Colors.white),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) => s.contains(WidgetState.selected) ? Colors.white : Colors.white),
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
        border: normal,
        enabledBorder: normal,
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _E.teal, width: 1.6)),
      ),
      textSelectionTheme: const TextSelectionThemeData(cursorColor: _E.teal),
    );
    return Theme(
      data: themed,
      child: LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
        final bool wide = c.maxWidth >= 560;
        final double pad = wide ? 24 : 16;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          _header(pad),
          const Divider(height: 1, color: _E.border),
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(pad, 16, pad, 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                _rates(wide),
                _seasonal(wide),
                _areas(),
              ]),
            ),
          ),
          if (_error != null)
            Container(
              margin: EdgeInsets.fromLTRB(pad, 0, pad, 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(12)),
              child: Row(children: <Widget>[
                const Icon(Icons.error_outline_rounded, color: Color(0xFFB91C1C), size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(_error!, style: const TextStyle(fontSize: 13, color: Color(0xFF991B1B), fontWeight: FontWeight.w700))),
              ]),
            ),
          const Divider(height: 1, color: _E.border),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: pad, vertical: 12),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: <Widget>[
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                style: TextButton.styleFrom(foregroundColor: _E.muted, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
                child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(backgroundColor: _E.teal, padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                child: Text(_saving ? 'Saving…' : 'Save', style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
            ]),
          ),
        ]);
      }),
    );
  }

  Widget _header(double pad) => Padding(
        padding: EdgeInsets.fromLTRB(pad, 16, pad - 8, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Container(width: 42, height: 42, decoration: BoxDecoration(color: _E.mint, borderRadius: BorderRadius.circular(13)), child: const Icon(Icons.tune_rounded, color: _E.teal, size: 22)),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('Estimation parameters', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: _E.ink, letterSpacing: -0.2)),
              SizedBox(height: 2),
              Text('Every value needs its source (document, date). Leave blank if not available; nothing is assumed.', style: TextStyle(fontSize: 12.5, height: 1.35, color: _E.muted, fontWeight: FontWeight.w500)),
            ]),
          ),
          IconButton(tooltip: widget.fullScreen ? 'Back' : 'Close', onPressed: _saving ? null : () => Navigator.of(context).pop(false), icon: Icon(widget.fullScreen ? Icons.arrow_back_rounded : Icons.close_rounded, color: _E.muted)),
        ]),
      );

  Widget _card(IconData icon, String title, String helper, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _E.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            Container(width: 32, height: 32, decoration: BoxDecoration(color: _E.mint, borderRadius: BorderRadius.circular(10)), child: Icon(icon, size: 18, color: _E.teal)),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: _E.ink))),
          ]),
          if (helper.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6, bottom: 2), child: Text(helper, style: const TextStyle(fontSize: 12, height: 1.35, color: _E.muted))),
          const SizedBox(height: 12),
          ...children,
        ]),
      );

  Widget _rates(bool wide) {
    final Map<String, dynamic> s = widget.settings ?? <String, dynamic>{};
    final Widget person = Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      const _Sub('Per person'),
      _field('cap', 'kg per person per day', s['kg_per_capita_day'], number: true),
      _field('cap_src', 'Source of the per-person rate', s['rate_source'], lines: 3, hint: 'Document, author, year'),
    ]);
    final Widget hectare = Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      const _Sub('Per hectare'),
      _field('ha', 'kg per hectare per day', s['kg_per_hectare_day'], number: true),
      _field('ha_src', 'Source of the per-hectare rate', s['hectare_rate_source'], lines: 3, hint: 'Document, author, year'),
    ]);
    return _card(Icons.scale_outlined, 'Waste-generation rates', 'Used with a population (per person) or with an area size (per hectare).', <Widget>[
      if (wide) Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[Expanded(child: person), const SizedBox(width: 16), Expanded(child: hectare)]) else ...<Widget>[person, const SizedBox(height: 4), hectare],
    ]);
  }

  Widget _seasonal(bool wide) {
    final Map<String, dynamic> s = widget.settings ?? <String, dynamic>{};
    final Widget value = _field('sea', 'Multiplier (1.0 = neutral)', s['seasonal_value'] ?? 1, number: true);
    final Widget appliesTo = _field('sea_to', 'Applies to', s['seasonal_applies_to'], hint: 'Days or seasons');
    return _card(Icons.event_repeat_outlined, 'Seasonal multiplier', 'Neutral (1.0) unless it has a documented source and date.', <Widget>[
      if (wide) Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[Expanded(child: value), const SizedBox(width: 16), Expanded(child: appliesTo)]) else ...<Widget>[value, appliesTo],
      _field('sea_src', 'Source and date of the multiplier', s['seasonal_source'], lines: 2, hint: 'Document, author, date'),
      _switch('seasonal_active', 'Apply the multiplier'),
      _switch('seasonal_validated', 'Evidence is on file (validated)'),
    ]);
  }

  Widget _areas() {
    return _card(Icons.map_outlined, 'Population and area sizes', 'Open an area to confirm its size or population. Leave blank what is not documented.', <Widget>[
      for (final WasteAreaRow r in widget.rows) _areaEditor(r),
    ]);
  }

  String _summary(WasteAreaRow r, bool whole) {
    final List<String> parts = <String>[];
    final String? pop = _v('pop_${r.key}') ?? (_c.containsKey('pop_${r.key}') ? null : (r.saved?['population'] == null ? null : '${r.saved!['population']}'));
    parts.add(pop == null ? 'No population' : 'Population $pop');
    if (!whole) {
      final String? m2 = _v('m2_${r.key}') ?? (_c.containsKey('m2_${r.key}') ? null : (r.saved?['size_m2'] == null ? null : '${r.saved!['size_m2']}'));
      parts.add(m2 == null ? 'no confirmed size' : 'size $m2 m²');
    }
    return parts.join(' · ');
  }

  Widget _areaEditor(WasteAreaRow r) {
    final bool whole = r.key == WasteEstimationData.barangayKey;
    final bool open = _open.contains(r.key);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: open ? _E.mintSoft : Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: open ? const Color(0xFFCFE8E2) : _E.border)),
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
              Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: _E.muted),
            ]),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              if (!whole) ...<Widget>[
                const _Sub('Area size'),
                _field('m2_${r.key}', 'Confirmed size (m²)', r.saved?['size_m2'], number: true),
                _field('m2src_${r.key}', 'Source of the size', r.saved?['size_source'], lines: 2, hint: 'Survey, map layer, date'),
                _switch('v_${r.key}', 'Verified against the real collection area'),
                const SizedBox(height: 8),
              ],
              const _Sub('Population'),
              _field('pop_${r.key}', 'Population', r.saved?['population'], number: true),
              _field('popsrc_${r.key}', 'Source of the population', r.saved?['population_source'], lines: 2, hint: 'Census, barangay record'),
              _field('popyr_${r.key}', 'Population year', r.saved?['population_year'], number: true),
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
