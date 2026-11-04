import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/waste_estimation_service.dart';
import '../utils/waste_estimation.dart';
import 'waste_estimation_edit_dialog.dart';

/// The details of Objective 2.2 (Waste Estimation by Collection Area): a centred dialog on wide screens, a full-screen page
/// on phones and narrow viewports. Same data and same calculation as the compact card (lib/utils/waste_estimation.dart):
/// estimate of an area = size (ha) x waste rate (kg/ha/day) x holiday multiplier of the day. Everything shown is an
/// ESTIMATE of waste generated, apart from the recorded loads and never added to them.
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
        width: math.min(820, size.width - 48),
        height: math.min(760, size.height * 0.88),
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
  static const Color amber = Color(0xFF92400E);
  static const Color amberSoft = Color(0xFFFEF3C7);
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
        const Divider(height: 1, color: _C.border),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(pad, 20, pad, 24),
            child: _body(wide),
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
                style: OutlinedButton.styleFrom(
                    foregroundColor: _C.ink, side: const BorderSide(color: _C.border), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12)),
                child: const Text('Close', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ],
      ]);
    });
  }

  Widget _header(bool wide, double pad) => Padding(
        padding: EdgeInsets.fromLTRB(pad, wide ? 22 : 12, pad - 8, wide ? 16 : 8),
        child: Row(crossAxisAlignment: wide ? CrossAxisAlignment.start : CrossAxisAlignment.center, children: <Widget>[
          Container(
            width: wide ? 48 : 38,
            height: wide ? 48 : 38,
            decoration: BoxDecoration(color: _C.mint, borderRadius: BorderRadius.circular(wide ? 14 : 12)),
            child: Icon(Icons.eco_rounded, color: _C.teal, size: wide ? 26 : 21),
          ),
          SizedBox(width: wide ? 14 : 10),
          Expanded(
            child: wide
                ? const Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Text('Waste Estimation by Collection Area', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: _C.ink, letterSpacing: -0.3)),
                    SizedBox(height: 3),
                    Text('Area size × waste rate × holiday multiplier', style: TextStyle(fontSize: 13, color: _C.muted, fontWeight: FontWeight.w500)),
                  ])
                : const Text('Waste Estimation', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: _C.ink, letterSpacing: -0.2)),
          ),
          IconButton(tooltip: 'Edit waste rate and holiday multiplier', visualDensity: wide ? null : VisualDensity.compact, onPressed: _edit, icon: const Icon(Icons.tune_rounded, color: _C.muted)),
          IconButton(tooltip: 'Close', visualDensity: wide ? null : VisualDensity.compact, onPressed: widget.onClose, icon: const Icon(Icons.close_rounded, color: _C.muted)),
        ]),
      );

  Widget _subtitleBar(double pad) => Padding(
        padding: EdgeInsets.fromLTRB(pad, 0, pad - 8, 4),
        child: Row(children: <Widget>[
          const Expanded(child: Text('Area size × waste rate × holiday multiplier', style: TextStyle(fontSize: 13, color: _C.muted, fontWeight: FontWeight.w500))),
          IconButton(tooltip: 'Edit waste rate and holiday multiplier', onPressed: _edit, icon: const Icon(Icons.tune_rounded, color: _C.muted)),
        ]),
      );

  // ------------------------------------------------------------------ body

  Widget _body(bool wide) {
    final WasteEstimationData d = _data;
    final double m = d.params.multiplier;
    final HolidayPeriod? holiday = d.params.seasonal.holidaysOnly ? HolidayCalendar.upliftOn(d.params.day) : null;
    final double? total = d.totalKgPerDay;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      if (!d.available)
        _notice('Not set up on this server yet. The estimation tables have not been created, so no estimate can be shown.')
      else ...<Widget>[
        _formula(wide),
        const SizedBox(height: 14),
        if (!d.params.hasRate) ...<Widget>[
          _notice('The waste rate is not set. Tap the sliders icon above to enter the rate (kg per hectare per day) and its source.'),
          const SizedBox(height: 14),
        ],
        _tiles(wide, d, m, holiday, total),
        const SizedBox(height: 22),
        const Text('Estimate by area', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: _C.ink)),
        const SizedBox(height: 4),
        const Text('Tap an area to see its calculation.', style: TextStyle(fontSize: 12.5, color: _C.muted)),
        const SizedBox(height: 10),
        _areas(d, m),
        const SizedBox(height: 18),
        _sources(d),
      ],
    ]);
  }

  Widget _notice(String text) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: _C.amberSoft, borderRadius: BorderRadius.circular(14)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const Icon(Icons.info_outline_rounded, size: 18, color: _C.amber),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13, height: 1.4, color: _C.amber, fontWeight: FontWeight.w600))),
        ]),
      );

  Widget _formula(bool wide) {
    Widget part(String t) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: _C.teal.withValues(alpha: 0.25))),
          child: Text(t, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: _C.tealDark)),
        );
    Widget op(String t) => Text(t, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _C.muted));
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(wide ? 18 : 14),
      decoration: BoxDecoration(color: _C.mintSoft, borderRadius: BorderRadius.circular(16), border: Border.all(color: _C.mint)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        const Text('HOW IT IS COMPUTED', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 0.8, color: _C.teal)),
        const SizedBox(height: 10),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 10, runSpacing: 8, children: <Widget>[
          part('Area size (ha)'),
          op('×'),
          part('Waste rate (kg/ha/day)'),
          op('×'),
          part('Holiday multiplier'),
          op('='),
          part('Waste per day (kg)'),
        ]),
      ]),
    );
  }

  Widget _tile(String label, String value, String unit, String sub) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _C.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _C.muted)),
          const SizedBox(height: 6),
          Text.rich(TextSpan(children: <InlineSpan>[
            TextSpan(text: value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: _C.ink, letterSpacing: -0.4)),
            if (unit.isNotEmpty) TextSpan(text: ' $unit', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: _C.muted)),
          ])),
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(fontSize: 12.5, color: _C.muted)),
        ]),
      );

  Widget _tiles(bool wide, WasteEstimationData d, double m, HolidayPeriod? holiday, double? total) {
    final List<Widget> tiles = <Widget>[
      _tile('Waste rate', d.params.hasRate ? '${d.params.kgPerHectareDay}' : '—', d.params.hasRate ? 'kg/ha/day' : '', 'Per hectare, every day'),
      _tile('Holiday multiplier today', WasteFormat.multiplier(m), '', holiday != null ? holiday.name : 'Regular day'),
      _tile('Total estimate', total == null ? '—' : WasteFormat.kg(total), total == null ? '' : 'kg/day',
          total == null ? 'No area has a number' : '${d.summary.configuredCount} areas · ${WasteFormat.ha(d.summary.hectares)} ha'),
    ];
    if (!wide) {
      return Column(children: <Widget>[for (final Widget t in tiles) Padding(padding: const EdgeInsets.only(bottom: 10), child: SizedBox(width: double.infinity, child: t))]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      for (int i = 0; i < tiles.length; i++) ...<Widget>[if (i > 0) const SizedBox(width: 12), Expanded(child: tiles[i])],
    ]);
  }

  Widget _areas(WasteEstimationData d, double m) {
    final List<Widget> rows = <Widget>[for (int i = 0; i < d.rows.length; i++) _areaRow(d.rows[i], d.estimates[i], m)];
    final double? total = d.totalKgPerDay;
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: _C.border)),
      clipBehavior: Clip.antiAlias,
      child: Material(
          type: MaterialType.transparency,
          child: Column(children: <Widget>[
        for (int i = 0; i < rows.length; i++) ...<Widget>[if (i > 0) const Divider(height: 1, color: _C.border), rows[i]],
        const Divider(height: 1, color: _C.border),
        Container(
          color: _C.mintSoft,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(children: <Widget>[
            const Expanded(child: Text('Total', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: _C.ink))),
            Text(d.summary.configuredCount > 0 ? '${WasteFormat.ha(d.summary.hectares)} ha' : '—', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _C.muted)),
            const SizedBox(width: 16),
            Text(total == null ? '—' : '${WasteFormat.kg(total)} kg/day', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w900, color: _C.tealDark)),
          ]),
        ),
      ])),
    );
  }

  Widget _areaRow(WasteAreaRow r, AreaEstimate e, double m) {
    final String size = e.size.usable ? '${WasteFormat.ha(e.hectares)} ha' : 'no size';
    final String result = e.hasNumber ? '${WasteFormat.kg(e.kgPerDay!)} kg/day' : '—';
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: PageStorageKey<String>('waste-area-${r.key}'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Text(r.name, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: _C.ink)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
          Text(size, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _C.muted)),
          const SizedBox(width: 14),
          Text(result, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: e.hasNumber ? _C.tealDark : _C.muted)),
        ]),
        children: <Widget>[
          if (e.hasNumber)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: _C.mintSoft, borderRadius: BorderRadius.circular(12)),
              child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: <Widget>[
                _num('${WasteFormat.ha(e.hectares)} ha'),
                _op('×'),
                _num('${e.rate} kg/ha/day'),
                _op('×'),
                _num(m == m.roundToDouble() ? m.toStringAsFixed(1) : m.toStringAsFixed(2)),
                _op('='),
                Text('${WasteFormat.kg(e.kgPerDay!)} kg/day', style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w900, color: _C.tealDark)),
              ]),
            )
          else
            Text(e.reason, style: const TextStyle(fontSize: 13, color: _C.muted)),
        ],
      ),
    );
  }

  Widget _num(String t) => Text(t, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _C.ink));
  Widget _op(String t) => Text(t, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _C.muted));

  Widget _sources(WasteEstimationData d) {
    final SeasonalMultiplier s = d.params.seasonal;
    final HolidayPeriod xmas = HolidayCalendar.periods.firstWhere((HolidayPeriod p) => p.uplift);
    final double? regular = d.regularDayKg;
    final double? onXmas = d.holidayKg(xmas);
    Widget item(String title, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _C.ink)),
            const SizedBox(height: 2),
            Text(text, style: const TextStyle(fontSize: 12.5, height: 1.45, color: _C.muted)),
          ]),
        );
    return Container(
      decoration: BoxDecoration(color: _C.soft, borderRadius: BorderRadius.circular(16), border: Border.all(color: _C.border)),
      child: Material(
        type: MaterialType.transparency,
        child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          leading: const Icon(Icons.fact_check_outlined, color: _C.muted),
          title: const Text('Where the numbers come from', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: _C.ink)),
          children: <Widget>[
            item('Waste rate', d.params.hasRate ? d.params.hectareRateSource : 'Not set.'),
            item(
              'Holiday multiplier',
              s.applied
                  ? 'Applies from ${xmas.dates} (${xmas.name}) and is 1.0 on every other day. ${regular != null && onXmas != null ? 'The total is ${WasteFormat.kg(regular)} kg/day on a regular day and ${WasteFormat.kg(onXmas)} kg/day on those days. ' : ''}${s.source}${s.validated ? '' : ' Not validated for Lipa.'}'
                  : 'Not applied (1.0).',
            ),
            item('Area sizes', 'From the collection-area boundaries confirmed by the barangay.'),
            item('What this is', 'An estimate of waste generated, not a measured weight. It is never added to the recorded loads.'),
          ],
        ),
      )),
    );
  }
}
