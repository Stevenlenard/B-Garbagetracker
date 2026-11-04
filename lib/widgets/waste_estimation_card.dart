import 'package:flutter/material.dart';

import '../services/waste_estimation_service.dart';
import 'waste_estimation_details.dart';

export '../services/waste_estimation_service.dart' show WasteEstimationRaw;

/// Objective 2.2: the compact "Waste Estimation by Area" card of the Analytics page. It shows the total of the area
/// estimates (size x waste rate x holiday multiplier) from the same data and calculation as the details screen (lib/services/waste_estimation_service.dart ->
/// lib/utils/waste_estimation.dart) and opens the details (a dialog on wide screens, a full-screen page on phones).
///
/// The figure is an estimate of waste GENERATED. It is kept apart from the recorded loads (capacity-equivalent 5,000 kg per
/// FULL event) and never added to them.
class WasteEstimationCard extends StatefulWidget {
  const WasteEstimationCard({super.key, this.loader});

  /// Replaces the network/Firebase read (tests only).
  final Future<WasteEstimationRaw> Function()? loader;

  @override
  State<WasteEstimationCard> createState() => _WasteEstimationCardState();
}

class _WasteEstimationCardState extends State<WasteEstimationCard> {
  static const Color _teal = Color(0xFF00796B);
  static const Color _mint = Color(0xFFE6F4F1);
  static const Color _ink = Color(0xFF0F172A);
  static const Color _muted = Color(0xFF64748B);
  static const Color _border = Color(0xFFE2E8F0);

  WasteEstimationData? _data;
  bool _loading = true;
  String? _error;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    WasteEstimationData? data;
    String? error;
    try {
      data = await WasteEstimationData.load(loader: widget.loader);
    } on WasteEstimationLoadException catch (e) {
      error = e.message;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (data != null) {
        _data = data;
        _error = null;
      } else {
        _error = error;
      }
    });
  }

  Future<WasteEstimationData?> _reload() async {
    await _load(silent: true);
    return _data;
  }

  bool get _canOpen => !_loading && _error == null && _data != null && _data!.available;

  void _open() {
    if (!_canOpen) return;
    showWasteEstimationDetails(context, data: _data!, reload: _reload);
  }

  @override
  Widget build(BuildContext context) {
    final bool mobile = MediaQuery.sizeOf(context).width < 700;
    final bool openable = _canOpen;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: openable ? SystemMouseCursors.click : MouseCursor.defer,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _hover && openable ? _teal.withValues(alpha: 0.45) : _border),
          boxShadow: <BoxShadow>[BoxShadow(color: Colors.black.withValues(alpha: _hover && openable ? 0.07 : 0.03), blurRadius: _hover && openable ? 20 : 16, offset: const Offset(0, 4))],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey<String>('waste-estimation-card'),
            onTap: openable ? _open : null,
            hoverColor: _mint.withValues(alpha: 0.35),
            splashColor: _teal.withValues(alpha: 0.08),
            highlightColor: _teal.withValues(alpha: 0.05),
            child: Padding(
              padding: EdgeInsets.all(mobile ? 18 : 24),
              child: Semantics(
                button: openable,
                label: 'Waste Estimation by Area',
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(color: _mint, borderRadius: BorderRadius.circular(13)),
                      child: const Icon(Icons.eco_rounded, color: _teal, size: 24),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                        Text('Waste Estimation by Area', style: TextStyle(fontSize: mobile ? 17 : 20, fontWeight: FontWeight.w900, color: _ink, letterSpacing: -0.3)),
                        const SizedBox(height: 3),
                        Text('Area size × waste rate × holiday multiplier', style: TextStyle(fontSize: mobile ? 12 : 13, fontWeight: FontWeight.w500, color: _muted)),
                      ]),
                    ),
                    if (openable) const Padding(padding: EdgeInsets.only(top: 8, left: 6), child: Icon(Icons.chevron_right_rounded, color: _muted, size: 26)),
                  ]),
                  const SizedBox(height: 18),
                  _value(),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _value() {
    if (_loading) {
      return ClipRRect(borderRadius: BorderRadius.circular(6), child: const LinearProgressIndicator(minHeight: 4, color: _teal, backgroundColor: _mint));
    }
    if (_error != null) {
      return Row(children: <Widget>[
        Expanded(child: Text(_error!, style: const TextStyle(fontSize: 13, color: Color(0xFFB91C1C), fontWeight: FontWeight.w600))),
        TextButton.icon(onPressed: _load, icon: const Icon(Icons.refresh_rounded, size: 18), label: const Text('Retry'), style: TextButton.styleFrom(foregroundColor: _teal)),
      ]);
    }
    final WasteEstimationData d = _data!;
    if (!d.available) {
      return const Text('Not set up on this server yet. The estimation tables have not been created, so no estimate can be shown.', style: TextStyle(fontSize: 13, height: 1.4, color: _muted, fontWeight: FontWeight.w600));
    }
    if (d.totalKgPerDay == null) {
      return const Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text('Not configured', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: _ink)),
        SizedBox(height: 2),
        Text('Enter the waste rate and its source to estimate', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _muted)),
      ]);
    }
    final double m = d.params.multiplier;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Text.rich(TextSpan(children: <InlineSpan>[
        TextSpan(text: WasteFormat.kg(d.totalKgPerDay!), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: _ink, letterSpacing: -0.5)),
        const TextSpan(text: ' kg/day', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _muted)),
      ])),
      const SizedBox(height: 2),
      Text('${d.summary.configuredCount} collection areas · holiday multiplier ${WasteFormat.multiplier(m)} today',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _muted)),
    ]);
  }
}
