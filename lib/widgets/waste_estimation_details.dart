import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/waste_estimation_service.dart';
import '../utils/osm_area_references.dart';
import '../utils/waste_estimation.dart';
import 'waste_estimation_edit_dialog.dart';

/// The details of Objective 2.2 (Waste Estimation by Collection Area): a centred dialog on wide screens, a full-screen page
/// on phones and narrow viewports. Same data and same calculation as the compact card (lib/utils/waste_estimation.dart);
/// everything shown is an ESTIMATE of waste generated, apart from the recorded loads and never added to them.
Future<void> showWasteEstimationDetails(
  BuildContext context, {
  required WasteEstimationData data,
  required Future<WasteEstimationData?> Function() reload,
}) {
  final Size size = MediaQuery.sizeOf(context);
  if (size.width < 700) {
    return Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext ctx) => Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          foregroundColor: _C.ink,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(tooltip: 'Back', icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.of(ctx).pop()),
          title: const Text('Waste Estimation by Collection Area', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        ),
        body: SafeArea(top: false, child: WasteEstimationDetails(data: data, reload: reload, fullScreen: true)),
      ),
    ));
  }
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: math.min(1040, size.width - 48),
        height: math.min(780, size.height * 0.88),
        child: WasteEstimationDetails(data: data, reload: reload, onClose: () => Navigator.of(ctx).pop()),
      ),
    ),
  );
}

class _C {
  static const Color teal = Color(0xFF00796B);
  static const Color tealDark = Color(0xFF00695C);
  static const Color mint = Color(0xFFE6F4F1);
  static const Color mintSoft = Color(0xFFF1F9F7);
  static const Color ink = Color(0xFF0F172A);
  static const Color muted = Color(0xFF64748B);
  static const Color border = Color(0xFFE2E8F0);
  static const Color soft = Color(0xFFF8FAFC);
}

class WasteEstimationDetails extends StatefulWidget {
  const WasteEstimationDetails({super.key, required this.data, required this.reload, this.fullScreen = false, this.onClose});

  final WasteEstimationData data;
  final Future<WasteEstimationData?> Function() reload;
  final bool fullScreen;
  final VoidCallback? onClose;

  @override
  State<WasteEstimationDetails> createState() => _WasteEstimationDetailsState();
}

class _WasteEstimationDetailsState extends State<WasteEstimationDetails> {
  late WasteEstimationData _data = widget.data;
  int _tab = 0;
  final TextEditingController _search = TextEditingController();
  final Set<String> _open = <String>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _edit() async {
    final bool saved = await showWasteEstimationEdit(context, _data);
    if (!saved) return;
    final WasteEstimationData? fresh = await widget.reload();
    if (fresh != null && mounted) setState(() => _data = fresh);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
      final bool wide = c.maxWidth >= 640;
      final double pad = wide ? 28 : 16;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        if (!widget.fullScreen) _header(wide, pad) else _subtitleBar(pad),
        Padding(padding: EdgeInsets.fromLTRB(pad, widget.fullScreen ? 4 : 0, pad, 14), child: _tabs(c.maxWidth)),
        const Divider(height: 1, color: _C.border),
        Expanded(
          child: SingleChildScrollView(
            key: ValueKey<int>(_tab),
            padding: EdgeInsets.fromLTRB(pad, 18, pad, 24),
            child: _body(wide, c.maxWidth - pad * 2),
          ),
        ),
        if (!widget.fullScreen) ...<Widget>[
          const Divider(height: 1, color: _C.border),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: pad, vertical: 12),
            child: Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton(
                onPressed: widget.onClose,
                style: OutlinedButton.styleFrom(foregroundColor: _C.ink, side: const BorderSide(color: _C.border), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14)),
                child: const Text('Close', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ],
      ]);
    });
  }

  Widget _header(bool wide, double pad) => Padding(
        padding: EdgeInsets.fromLTRB(pad, 22, pad - 8, 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: _C.mint, borderRadius: BorderRadius.circular(14)),
            child: const Icon(Icons.eco_rounded, color: _C.teal, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('Waste Estimation by Collection Area', style: TextStyle(fontSize: wide ? 22 : 18, fontWeight: FontWeight.w900, color: _C.ink, letterSpacing: -0.3)),
              const SizedBox(height: 3),
              const Text('Estimated waste generation using documented parameters.', style: TextStyle(fontSize: 13, color: _C.muted, fontWeight: FontWeight.w500)),
            ]),
          ),
          IconButton(tooltip: 'Edit parameters', onPressed: _edit, icon: const Icon(Icons.tune_rounded, color: _C.muted)),
          IconButton(tooltip: 'Close', onPressed: widget.onClose, icon: const Icon(Icons.close_rounded, color: _C.muted)),
        ]),
      );

  Widget _subtitleBar(double pad) => Padding(
        padding: EdgeInsets.fromLTRB(pad, 0, pad - 8, 4),
        child: Row(children: <Widget>[
          const Expanded(child: Text('Estimated waste generation using documented parameters.', style: TextStyle(fontSize: 13, color: _C.muted, fontWeight: FontWeight.w500))),
          IconButton(tooltip: 'Edit parameters', onPressed: _edit, icon: const Icon(Icons.tune_rounded, color: _C.muted)),
        ]),
      );

  Widget _tabs(double width) {
    final bool narrow = width < 520;
    final List<(String, IconData)> items = <(String, IconData)>[
      ('Overview', Icons.dashboard_outlined),
      (narrow ? 'Areas' : 'Area Details', Icons.map_outlined),
      (narrow ? 'Sources' : 'Parameters & Sources', Icons.fact_check_outlined),
    ];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: _C.soft, borderRadius: BorderRadius.circular(14), border: Border.all(color: _C.border)),
      child: Row(children: <Widget>[
        for (int i = 0; i < items.length; i++)
          Expanded(
            child: Semantics(
              button: true,
              selected: _tab == i,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => setState(() => _tab = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: EdgeInsets.symmetric(vertical: 11, horizontal: narrow ? 4 : 10),
                  decoration: BoxDecoration(color: _tab == i ? _C.teal : Colors.transparent, borderRadius: BorderRadius.circular(10)),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
                    if (!narrow) ...<Widget>[Icon(items[i].$2, size: 17, color: _tab == i ? Colors.white : _C.muted), const SizedBox(width: 7)],
                    Flexible(
                      child: Text(items[i].$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: _tab == i ? Colors.white : _C.muted)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _body(bool wide, double width) {
    switch (_tab) {
      case 1:
        return _areaDetails(wide);
      case 2:
        return _parameters(wide);
      default:
        return _overview(wide, width);
    }
  }

  // ---------------------------------------------------------------- Overview

  Widget _overview(bool wide, double width) {
    final WasteEstimationData d = _data;
    final SeasonalMultiplier sm = d.params.seasonal;
    final double cardW = wide ? (width - 24) / 3 : (width - 12) / 2;
    final List<Widget> cards = <Widget>[
      _statCard(Icons.pin_drop_outlined, 'Areas configured', '${d.summary.configuredCount} of ${d.summary.areaCount}', 'with a sourced estimate', cardW),
      _statCard(Icons.groups_2_outlined, 'Whole barangay (est.)', d.whole.hasNumber ? '${WasteFormat.kg(d.whole.kgPerDay!)} kg/day' : 'Not configured', 'population × per-person rate', cardW),
      _statCard(Icons.event_repeat_outlined, 'Seasonal multiplier', sm.applied ? '×${sm.effective.toStringAsFixed(2)}${sm.validated ? '' : ' (not validated)'}' : '×1.0 (Neutral)', sm.applied ? 'applied' : 'not applied', wide ? cardW : width),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Wrap(spacing: 12, runSpacing: 12, children: cards),
      const SizedBox(height: 16),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: <Color>[_C.mint, Color(0xFFF4FBF9)], begin: Alignment.topLeft, end: Alignment.bottomRight),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFCFE8E2)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const Row(children: <Widget>[
            Icon(Icons.recycling_rounded, color: _C.teal, size: 20),
            SizedBox(width: 8),
            Expanded(child: Text('Area-Based Waste Estimation', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: _C.tealDark))),
          ]),
          const SizedBox(height: 8),
          const Text(
            'Estimates per collection area using area size, population and waste-generation rate. This is estimated waste generation, not measured collected waste, and it is kept separate from the recorded loads (capacity-equivalent 5,000 kg per FULL event).',
            style: TextStyle(fontSize: 13, height: 1.45, color: _C.ink),
          ),
          if (d.summary.configuredCount == 0) ...<Widget>[
            const SizedBox(height: 8),
            const Text(
              'No collection area has enough sourced data yet. The whole-barangay figure above is population-based and is not split among the areas.',
              style: TextStyle(fontSize: 12.5, height: 1.4, color: _C.muted, fontWeight: FontWeight.w600),
            ),
          ],
        ]),
      ),
      const SizedBox(height: 22),
      Row(children: <Widget>[
        Expanded(
          child: Text.rich(
            TextSpan(children: <InlineSpan>[
              TextSpan(text: 'Collection Areas', style: TextStyle(fontSize: wide ? 18 : 16, fontWeight: FontWeight.w900, color: _C.ink)),
              TextSpan(text: '  ${d.rows.length}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _C.muted)),
            ]),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(child: TextButton(onPressed: () => setState(() => _tab = 1), child: const Text('View all areas', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w800, color: _C.teal)))),
      ]),
      const SizedBox(height: 8),
      if (d.rows.isEmpty)
        const _Empty('No collection areas found.')
      else
        _areaTable(d.rows.take(5).toList(), wide, expandable: false, offset: 0),
      if (d.rows.length > 5)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('+ ${d.rows.length - 5} more in Area Details', style: const TextStyle(fontSize: 12.5, color: _C.muted, fontWeight: FontWeight.w600)),
        ),
    ]);
  }

  Widget _statCard(IconData icon, String label, String value, String hint, double width) => ConstrainedBox(
        constraints: BoxConstraints(minWidth: 0, maxWidth: math.max(120, width)),
        child: SizedBox(
          width: math.max(120, width),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _C.border), boxShadow: <BoxShadow>[BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 12, offset: const Offset(0, 3))]),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Container(width: 40, height: 40, decoration: BoxDecoration(color: _C.mint, borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: _C.teal, size: 21)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _C.muted)),
                  const SizedBox(height: 4),
                  Text(value, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: _C.ink)),
                  const SizedBox(height: 2),
                  Text(hint, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: _C.muted)),
                ]),
              ),
            ]),
          ),
        ),
      );

  // ------------------------------------------------------------ Area Details

  Widget _areaDetails(bool wide) {
    final WasteEstimationData d = _data;
    final String q = _search.text.trim().toLowerCase();
    final List<WasteAreaRow> list = <WasteAreaRow>[for (final WasteAreaRow r in d.rows) if (q.isEmpty || r.name.toLowerCase().contains(q)) r];
    final bool showWhole = q.isEmpty || 'whole barangay'.contains(q) || d.barangay.name.toLowerCase().contains(q);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      TextField(
        controller: _search,
        onChanged: (_) => setState(() {}),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search area...',
          isDense: true,
          prefixIcon: const Icon(Icons.search_rounded, size: 20, color: _C.muted),
          suffixIcon: q.isEmpty ? null : IconButton(tooltip: 'Clear search', icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => setState(_search.clear)),
          filled: true,
          fillColor: _C.soft,
          contentPadding: const EdgeInsets.symmetric(vertical: 13, horizontal: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _C.border)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _C.border)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _C.teal, width: 1.5)),
        ),
      ),
      const SizedBox(height: 14),
      if (showWhole) ...<Widget>[
        const _SectionLabel('Whole barangay'),
        _areaCard(d.barangay, wide, index: null),
        const SizedBox(height: 6),
        const Text('Estimated separately; not the sum of the areas below.', style: TextStyle(fontSize: 12, color: _C.muted)),
        const SizedBox(height: 16),
      ],
      _SectionLabel('Collection areas (${list.length}${q.isEmpty ? '' : ' of ${d.rows.length}'})'),
      if (list.isEmpty) _Empty(q.isEmpty ? 'No collection areas found.' : 'No collection area matches "$q".') else _areaTable(list, wide, expandable: true, offset: 0),
    ]);
  }

  /// Table (wide) or cards (narrow) of areas.
  Widget _areaTable(List<WasteAreaRow> rows, bool wide, {required bool expandable, required int offset}) {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _C.border)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: <Widget>[
        if (wide)
          Container(
            color: _C.mintSoft,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: const Row(children: <Widget>[
              SizedBox(width: 34, child: _Th('#')),
              Expanded(flex: 3, child: _Th('Collection Area')),
              Expanded(flex: 2, child: _Th('Area Size')),
              Expanded(flex: 2, child: _Th('Est. Generation')),
              Expanded(flex: 3, child: _Th('Method / Source')),
              Expanded(flex: 2, child: _Th('Status')),
              SizedBox(width: 28),
            ]),
          ),
        for (int i = 0; i < rows.length; i++) ...<Widget>[
          if (i > 0 || wide) const Divider(height: 1, color: _C.border),
          _areaItem(rows[i], wide, index: _data.rows.indexOf(rows[i]) + 1 + offset, expandable: expandable),
        ],
      ]),
    );
  }

  Widget _areaCard(WasteAreaRow r, bool wide, {int? index}) => Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _C.border)),
        clipBehavior: Clip.antiAlias,
        child: _areaItem(r, wide, index: index, expandable: true),
      );

  Widget _areaItem(WasteAreaRow r, bool wide, {int? index, required bool expandable}) {
    final WasteEstimationData d = _data;
    final AreaEstimate e = d.estimateOf(r);
    final AreaConfig cfg = d.configOf(r);
    final bool isWhole = r.key == WasteEstimationData.barangayKey;
    final bool open = expandable && _open.contains(r.key);
    final String size = isWhole ? 'Whole barangay' : (e.size.usable ? '${(e.size.hectares).toStringAsFixed(2)} ha' : '—');
    final String est = e.hasNumber ? '${WasteFormat.kg(e.kgPerDay!)} kg/day' : '—';
    final String method = e.hasNumber ? WasteFormat.methodLabel(e.method) : (isWhole ? 'Missing sourced data' : (e.size.usable ? _shortSource(e.size) : 'Missing sourced data'));
    final _Status st = _statusOf(e, cfg);

    final Widget summary = wide
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(children: <Widget>[
              SizedBox(width: 34, child: Text(index == null ? '' : index.toString().padLeft(2, '0'), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _C.muted))),
              Expanded(flex: 3, child: Text(r.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: _C.ink))),
              Expanded(flex: 2, child: Text(size, style: const TextStyle(fontSize: 13, color: _C.ink))),
              Expanded(flex: 2, child: Text(est, style: TextStyle(fontSize: 13, fontWeight: e.hasNumber ? FontWeight.w800 : FontWeight.w500, color: e.hasNumber ? _C.ink : _C.muted))),
              Expanded(flex: 3, child: Padding(padding: const EdgeInsets.only(right: 8), child: Text(method, style: const TextStyle(fontSize: 12.5, color: _C.muted)))),
              Expanded(flex: 2, child: Align(alignment: Alignment.centerLeft, child: _Pill(st))),
              SizedBox(width: 28, child: expandable ? Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: _C.muted) : null),
            ]),
          )
        : Padding(
            padding: const EdgeInsets.all(14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text(r.name, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: _C.ink)),
                  const SizedBox(height: 4),
                  Text('$size · $est', style: TextStyle(fontSize: 12.5, color: e.hasNumber ? _C.ink : _C.muted, fontWeight: e.hasNumber ? FontWeight.w700 : FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(method, style: const TextStyle(fontSize: 12, color: _C.muted)),
                  const SizedBox(height: 8),
                  _Pill(st),
                ]),
              ),
              if (expandable) Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: _C.muted),
            ]),
          );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      if (expandable)
        InkWell(
          key: ValueKey<String>('area-${r.key}'),
          onTap: () => setState(() => open ? _open.remove(r.key) : _open.add(r.key)),
          hoverColor: _C.mintSoft,
          child: summary,
        )
      else
        summary,
      if (open) _areaExpanded(r, e, cfg, isWhole),
    ]);
  }

  Widget _areaExpanded(WasteAreaRow r, AreaEstimate e, AreaConfig cfg, bool isWhole) {
    final SeasonalMultiplier sm = _data.params.seasonal;
    final AreaSize s = e.size;
    final List<(String, String)> facts = <(String, String)>[
      ('Area name', r.name),
      if (!isWhole) ('Area size', s.usable ? '${s.hectares.toStringAsFixed(2)} ha (${WasteFormat.m2(s.m2)} m²)' : 'Not available'),
      if (!isWhole) ('Boundary source', s.usable ? (s.source.isEmpty ? 'Not recorded' : s.source) : (r.geometryNote.isEmpty ? 'None on record' : r.geometryNote)),
      if (!isWhole) ('Source verification', s.usable ? (s.verified ? 'Verified by an admin' : 'Not verified') : 'n/a'),
      if (isWhole || cfg.population != null) ('Population', cfg.hasPopulation ? '${WasteFormat.m2(cfg.population!.toDouble())}${cfg.populationYear != null ? ' (${cfg.populationYear})' : ''}, ${cfg.populationSource}' : 'Not configured'),
      ('Estimation method', WasteFormat.methodLabel(e.method)),
      ('Waste-generation rate', _rateFor(e)),
      ('Seasonal adjustment', sm.applied ? '×${sm.effective.toStringAsFixed(2)} (${sm.source}${sm.validated ? '' : '; not validated'})' : '×1.0 (neutral, none applied)'),
      ('Estimated quantity', e.hasNumber ? '${WasteFormat.kg(e.kgPerDay!)} kg/day (estimate of waste generated)' : 'No estimate: missing sourced data'),
      ('Confidence', e.confidence),
    ];
    return Container(
      width: double.infinity,
      color: _C.mintSoft,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        for (final (String, String) f in facts) _Fact(f.$1, f.$2),
        if (e.breakdown.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          const Text('Calculation breakdown', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900, color: _C.tealDark)),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: _C.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[for (final String line in e.breakdown) Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(line, style: const TextStyle(fontSize: 12.5, height: 1.35, color: _C.ink)))]),
          ),
        ],
        if (e.limitations.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          const Text('Limitations', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900, color: Color(0xFFB45309))),
          const SizedBox(height: 4),
          for (final String l in e.limitations) Padding(padding: const EdgeInsets.only(bottom: 2), child: Text('• $l', style: const TextStyle(fontSize: 12.5, height: 1.35, color: Color(0xFF92400E)))),
        ],
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(onPressed: _edit, icon: const Icon(Icons.edit_outlined, size: 17), label: const Text('Edit parameters', style: TextStyle(fontWeight: FontWeight.w800)), style: TextButton.styleFrom(foregroundColor: _C.teal)),
        ),
      ]),
    );
  }

  String _rateFor(AreaEstimate e) {
    final EstimationParams p = _data.params;
    switch (e.method) {
      case EstimateMethod.perCapita:
        return '${p.kgPerCapitaDay} kg/person/day (${p.rateSource})';
      case EstimateMethod.perHectare:
        return '${p.kgPerHectareDay} kg/ha/day (${p.hectareRateSource})';
      case EstimateMethod.measured:
        return 'Recorded weight (no rate)';
      case EstimateMethod.none:
        return 'Not applicable: nothing sourced to apply';
    }
  }

  // ----------------------------------------------------------- Parameters

  Widget _parameters(bool wide) {
    final WasteEstimationData d = _data;
    final EstimationParams p = d.params;
    final SeasonalMultiplier sm = p.seasonal;
    final AreaConfig bc = d.configOf(d.barangay);
    final int verifiedSizes = d.rows.where((WasteAreaRow r) => d.configOf(r).size.verified).length;
    final int usableSizes = d.rows.where((WasteAreaRow r) => d.configOf(r).size.usable).length;
    final int withPopulation = d.rows.where((WasteAreaRow r) => d.configOf(r).hasPopulation).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      _Section(Icons.groups_2_outlined, 'Population-based estimation', <Widget>[
        _Fact('Waste-generation rate', p.hasCapitaRate ? '${p.kgPerCapitaDay} kg per person per day' : 'Not configured'),
        _Fact('Rate source', p.hasCapitaRate ? p.rateSource : 'None on record'),
        _Fact('Barangay population', bc.hasPopulation ? '${WasteFormat.m2(bc.population!.toDouble())}${bc.populationYear != null ? ' (${bc.populationYear})' : ''}' : 'Not configured'),
        _Fact('Population source', bc.hasPopulation ? bc.populationSource : 'None on record'),
        if (d.whole.breakdown.isNotEmpty) _Fact('Barangay estimate', d.whole.breakdown.join('  '), strong: true),
      ]),
      _Section(Icons.square_foot_outlined, 'Area-based estimation (per hectare)', <Widget>[
        _Fact('Rate', p.hasHectareRate ? '${p.kgPerHectareDay} kg per hectare per day' : 'Not configured'),
        _Fact('Rate source', p.hasHectareRate ? p.hectareRateSource : 'None on record: no documented per-hectare rate for Balintawak'),
      ]),
      _Section(Icons.event_repeat_outlined, 'Seasonal multiplier', <Widget>[
        _Fact('Value', '×${sm.value.toStringAsFixed(2)}'),
        _Fact('Applied', sm.applied ? 'Yes (×${sm.effective.toStringAsFixed(2)})' : 'No (neutral, ×1.0)'),
        _Fact('Evidence on file', sm.validated ? 'Yes' : 'No: not validated'),
        _Fact('Source and date', sm.source.isEmpty ? 'None on record' : sm.source),
        if (sm.appliesTo.isNotEmpty) _Fact('Applies to', sm.appliesTo),
      ]),
      _Section(Icons.map_outlined, 'Geographic boundary sources', <Widget>[
        _Fact('Verification status', '$verifiedSizes of ${d.rows.length} sizes verified · $usableSizes with a usable size · $withPopulation with a sourced population'),
        const _Fact('OpenStreetMap', 'Polygons retrieved ${OsmAreaReference.retrieved}; volunteer-mapped, not an official boundary. Always shown as unverified.'),
        for (final WasteAreaRow r in d.rows) _Fact(r.name, _boundaryLine(d, r)),
      ]),
      const _Section(Icons.functions_rounded, 'Calculation methodology', <Widget>[
        _Bullet('Measured weight, when a load is attributable to exactly one area, is used as recorded and is not multiplied.'),
        _Bullet('Otherwise: population × kg per person per day × seasonal multiplier.'),
        _Bullet('Otherwise: area in hectares × kg per hectare per day × seasonal multiplier.'),
        _Bullet('Without a sourced input there is no number: nothing is assumed or split from another figure.'),
        _Bullet('Estimates are waste generated. They are never added to the recorded loads (capacity-equivalent 5,000 kg per FULL event) or to measured weights.'),
      ]),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: _edit,
          icon: const Icon(Icons.tune_rounded, size: 18),
          label: const Text('Edit parameters', style: TextStyle(fontWeight: FontWeight.w800)),
          style: FilledButton.styleFrom(backgroundColor: _C.teal, padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        ),
      ),
    ]);
  }

  String _boundaryLine(WasteEstimationData d, WasteAreaRow r) {
    final AreaSize s = d.configOf(r).size;
    if (!s.usable) return r.geometryNote.isEmpty ? 'No usable boundary or size' : r.geometryNote;
    return '${s.hectares.toStringAsFixed(2)} ha · ${_shortSource(s)} · ${s.verified ? 'verified' : 'unverified'}';
  }

  // --------------------------------------------------------------- helpers

  static String _shortSource(AreaSize s) {
    if (s.source.contains('OpenStreetMap')) return 'OpenStreetMap (volunteer)';
    final RegExpMatch? m = RegExp(r'\((.*?)\);').firstMatch(s.source);
    final String base = m != null ? m.group(1)! : (s.source.isEmpty ? 'Source not recorded' : s.source);
    return s.verified ? base : '$base (unverified)';
  }

  static _Status _statusOf(AreaEstimate e, AreaConfig c) {
    if (e.hasNumber) return e.isMeasured ? const _Status('Measured', Color(0xFFDCFCE7), Color(0xFF15803D)) : const _Status('Estimated', Color(0xFFD9F0EC), Color(0xFF00695C));
    if (c.size.usable) return const _Status('Size only', Color(0xFFFEF3C7), Color(0xFF92400E));
    return const _Status('Not Configured', Color(0xFFFEE2E2), Color(0xFFB91C1C));
  }
}

class _Status {
  const _Status(this.label, this.bg, this.fg);

  final String label;
  final Color bg;
  final Color fg;
}

class _Pill extends StatelessWidget {
  const _Pill(this.status);

  final _Status status;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: status.bg, borderRadius: BorderRadius.circular(20)),
        child: Text(status.label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: status.fg)),
      );
}

class _Th extends StatelessWidget {
  const _Th(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(text, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, color: _C.tealDark, letterSpacing: 0.2));
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: _C.ink)));
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: _C.soft, borderRadius: BorderRadius.circular(14), border: Border.all(color: _C.border)),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: _C.muted, fontWeight: FontWeight.w600)),
      );
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, {this.strong = false});

  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
          final bool stack = c.maxWidth < 420;
          final Widget l = Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _C.muted));
          final Widget v = Text(value, style: TextStyle(fontSize: 13, height: 1.35, fontWeight: strong ? FontWeight.w800 : FontWeight.w600, color: _C.ink));
          if (stack) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[l, const SizedBox(height: 1), v]);
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[SizedBox(width: 170, child: l), Expanded(child: v)]);
        }),
      );
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const Padding(padding: EdgeInsets.only(top: 6), child: Icon(Icons.circle, size: 5, color: _C.teal)),
          const SizedBox(width: 9),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.4, color: _C.ink))),
        ]),
      );
}

class _Section extends StatelessWidget {
  const _Section(this.icon, this.title, this.children);

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _C.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            Container(width: 32, height: 32, decoration: BoxDecoration(color: _C.mint, borderRadius: BorderRadius.circular(10)), child: Icon(icon, size: 18, color: _C.teal)),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: _C.ink))),
          ]),
          const SizedBox(height: 12),
          ...children,
        ]),
      );
}
