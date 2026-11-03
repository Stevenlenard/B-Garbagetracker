import 'package:dio/dio.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../api/api_service.dart';
import '../utils/osm_area_references.dart';
import '../utils/waste_estimation.dart';

/// Objective 2.2: Waste Estimation by Collection Area. One widget for Admin Web and Admin Mobile (same data, same
/// calculation in lib/utils/waste_estimation.dart). Everything shown here is an ESTIMATE of waste generated; it is kept
/// apart from the recorded loads (capacity-equivalent 5,000 kg per FULL event) and never added to them.
/// The two raw sources of the card: the response body of get_waste_estimation.php and the value of Firebase `puroks`.
typedef WasteEstimationRaw = ({Object? body, Object? puroks});

class WasteEstimationCard extends StatefulWidget {
  const WasteEstimationCard({super.key, this.loader});

  /// Replaces the network/Firebase read (tests only).
  final Future<WasteEstimationRaw> Function()? loader;

  @override
  State<WasteEstimationCard> createState() => _WasteEstimationCardState();
}

class _AreaRow {
  _AreaRow({required this.key, required this.name, required this.geometrySize, this.geometryNote = ''});

  final String key;
  final String name;
  final AreaSize geometrySize;
  final String geometryNote;
  Map<String, dynamic>? saved;
}

class _WasteEstimationCardState extends State<WasteEstimationCard> {
  bool _loading = true;
  bool _available = true;
  String? _error;
  Map<String, dynamic>? _settings;
  final List<_AreaRow> _rows = <_AreaRow>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  static double? _d(Object? v) => v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));
  static int? _i(Object? v) => v == null ? null : (v is num ? v.toInt() : int.tryParse('$v'));
  static bool _b(Object? v) => v == true || v == 1 || v == '1';

  static Future<WasteEstimationRaw> _fetch() async {
    final List<Object> r = await Future.wait<Object>(<Future<Object>>[
      ApiService().getWasteEstimation(),
      FirebaseDatabase.instance.ref('puroks').get(),
    ]);
    return (body: (r[0] as Response).data, puroks: (r[1] as DataSnapshot).value);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final WasteEstimationRaw raw0 = widget.loader != null ? await widget.loader!() : await _fetch();
      final Object? body = raw0.body;
      final Map<String, dynamic> data = body is Map ? Map<String, dynamic>.from(body) : <String, dynamic>{};
      _available = data['available'] != false;
      _settings = data['settings'] is Map ? Map<String, dynamic>.from(data['settings'] as Map) : null;
      final Map<String, Map<String, dynamic>> saved = <String, Map<String, dynamic>>{
        for (final Object? a in (data['areas'] is List ? data['areas'] as List : const <Object>[]))
          if (a is Map) '${a['area_key']}': Map<String, dynamic>.from(a),
      };

      final Object? pv = raw0.puroks;
      final List<MapEntry<String, Map>> puroks = <MapEntry<String, Map>>[];
      if (pv is Map) {
        pv.forEach((Object? k, Object? v) {
          if (v is Map) puroks.add(MapEntry<String, Map>('$k', v));
        });
      } else if (pv is List) {
        for (int i = 0; i < pv.length; i++) {
          if (pv[i] is Map) puroks.add(MapEntry<String, Map>('$i', pv[i] as Map));
        }
      }
      final Map<String, double> raw = <String, double>{};
      for (final MapEntry<String, Map> p in puroks) {
        final List<List<double>>? ring = WasteEstimation.parseRing(p.value['boundaryGeometry']);
        if (ring != null) raw['${p.value['name'] ?? p.key}'] = WasteEstimation.polygonAreaM2(ring);
      }
      final Set<String> placeholder = WasteEstimation.placeholderAreas(raw);

      _rows.clear();
      for (final MapEntry<String, Map> p in puroks) {
        final String name = '${p.value['name'] ?? p.key}';
        final bool isPh = placeholder.contains(name);
        AreaSize size = WasteEstimation.sizeFromGeometry(
          p.value['boundaryGeometry'],
          source: 'Stored boundary in Firebase puroks/${p.key} (${p.value['coordinateSource'] ?? 'source not recorded'}); not independently surveyed',
          placeholder: isPh,
        );
        String note = isPh ? 'Stored boundary is a placeholder-like box (near-identical to other areas); not used.' : size.note;
        // No usable stored boundary: an OpenStreetMap polygon of the same place is offered as an UNVERIFIED reference.
        final OsmAreaReference? osm = size.usable ? null : OsmAreaReference.forArea(name);
        if (osm != null) {
          size = AreaSize(m2: osm.sizeM2, kind: AreaSizeKind.polygon, source: osm.source, note: osm.note);
          note = osm.note;
        }
        _rows.add(_AreaRow(key: p.key, name: name, geometrySize: size, geometryNote: note)
          ..saved = saved[p.key]);
      }
      _rows.sort((_AreaRow a, _AreaRow b) => a.name.compareTo(b.name));
    } on DioException catch (e) {
      final Object? d = e.response?.data;
      _error = (d is Map && d['message'] != null) ? '${d['message']}' : 'Could not load the waste estimation data.';
    } catch (_) {
      _error = 'Could not load the waste estimation data.';
    }
    if (mounted) setState(() => _loading = false);
  }

  EstimationParams get _params {
    final Map<String, dynamic>? s = _settings;
    if (s == null) return const EstimationParams();
    return EstimationParams(
      kgPerCapitaDay: _d(s['kg_per_capita_day']),
      rateSource: '${s['rate_source'] ?? ''}',
      kgPerHectareDay: _d(s['kg_per_hectare_day']),
      hectareRateSource: '${s['hectare_rate_source'] ?? ''}',
      seasonal: SeasonalMultiplier(
        value: _d(s['seasonal_value']) ?? 1.0,
        source: '${s['seasonal_source'] ?? ''}',
        validated: _b(s['seasonal_validated']),
        active: _b(s['seasonal_active']),
        appliesTo: '${s['seasonal_applies_to'] ?? ''}',
      ),
    );
  }

  AreaConfig _config(_AreaRow r) {
    final Map<String, dynamic>? s = r.saved;
    AreaSize size = r.geometrySize;
    if (s != null && _d(s['size_m2']) != null) {
      size = AreaSize(
        m2: _d(s['size_m2'])!,
        kind: '${s['size_kind']}' == 'polygon' ? AreaSizeKind.polygon : AreaSizeKind.manual,
        source: '${s['size_source'] ?? ''}',
        verified: _b(s['size_verified']),
      );
    }
    return AreaConfig(
      name: r.name,
      size: size,
      population: _i(s?['population']),
      populationSource: '${s?['population_source'] ?? ''}',
      populationYear: _i(s?['population_year']),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData t = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _loading
            ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
            : _error != null
                ? _message(t, _error!, retry: true)
                : _content(t),
      ),
    );
  }

  Widget _message(ThemeData t, String text, {bool retry = false}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _title(t),
          const SizedBox(height: 8),
          Text(text, style: t.textTheme.bodyMedium),
          if (retry) TextButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('Retry')),
        ],
      );

  Widget _title(ThemeData t) => Text('Waste Estimation by Collection Area', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700));

  Widget _content(ThemeData t) {
    if (!_available) {
      return _message(t, 'Not set up on this server yet. The estimation tables have not been created (migration pending approval), so no area estimates can be shown.');
    }
    final EstimationParams params = _params;
    final List<AreaEstimate> estimates = <AreaEstimate>[for (final _AreaRow r in _rows) WasteEstimation.estimate(_config(r), params)];
    final EstimateSummary sum = WasteEstimation.summarize(estimates);
    final SeasonalMultiplier sm = params.seasonal;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(children: <Widget>[
          Expanded(child: _title(t)),
          IconButton(tooltip: 'Edit parameters', icon: const Icon(Icons.tune), onPressed: _edit),
        ]),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: t.colorScheme.secondaryContainer, borderRadius: BorderRadius.circular(8)),
          child: Text(
            'Estimates of waste generated per area from sourced parameters. Not measured or verified collected weight, and kept separate from the recorded loads (capacity-equivalent 5,000 kg per FULL event).',
            style: t.textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 10, children: <Widget>[
          _stat(t, 'Areas configured', '${sum.configuredCount} of ${sum.areaCount}'),
          _stat(t, 'Estimated generation', sum.configuredCount == 0 ? 'Not configured' : '${_fmt(sum.estimatedKgPerDay)} kg/day'),
          _stat(t, 'Seasonal multiplier', sm.applied ? '×${sm.effective.toStringAsFixed(2)}${sm.validated ? '' : ' (not validated)'}' : '×1.0 (neutral)'),
        ]),
        const SizedBox(height: 12),
        if (_rows.isEmpty) Text('No collection areas found.', style: t.textTheme.bodyMedium),
        for (int i = 0; i < _rows.length; i++) _areaTile(t, _rows[i], estimates[i]),
      ],
    );
  }

  Widget _stat(ThemeData t, String label, String value) => ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 140, maxWidth: 260),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(border: Border.all(color: t.dividerColor), borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(label, style: t.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(value, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          ]),
        ),
      );

  Widget _areaTile(ThemeData t, _AreaRow r, AreaEstimate e) {
    final AreaSize size = e.size;
    final String sizeText = size.usable ? '${size.hectares.toStringAsFixed(2)} ha (${size.m2.round()} m²)' : 'Size unavailable';
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Text(r.name, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Text(
        '$sizeText · ${e.hasNumber ? '${_fmt(e.kgPerDay!)} kg/day (estimate)' : 'Not configured'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      children: <Widget>[
        Align(
          alignment: Alignment.centerLeft,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            _kv(t, 'Method', _methodLabel(e.method)),
            _kv(t, 'Confidence', e.confidence),
            _kv(t, 'Size source', size.usable ? (size.source.isEmpty ? 'Not recorded' : size.source) : (r.geometryNote.isEmpty ? 'None' : r.geometryNote)),
            _kv(t, 'Size verified', size.usable ? (size.verified ? 'Yes' : 'No') : 'n/a'),
            for (final String line in e.breakdown) Padding(padding: const EdgeInsets.only(top: 2), child: Text(line, style: t.textTheme.bodySmall)),
            for (final String l in e.limitations) Padding(padding: const EdgeInsets.only(top: 2), child: Text('• $l', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error))),
          ]),
        ),
      ],
    );
  }

  Widget _kv(ThemeData t, String k, String v) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text.rich(TextSpan(children: <InlineSpan>[
          TextSpan(text: '$k: ', style: t.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
          TextSpan(text: v, style: t.textTheme.bodySmall),
        ])),
      );

  static String _methodLabel(EstimateMethod m) {
    switch (m) {
      case EstimateMethod.perCapita:
        return 'Population × per-person rate';
      case EstimateMethod.perHectare:
        return 'Area (ha) × per-hectare rate';
      case EstimateMethod.measured:
        return 'Recorded measured weight';
      case EstimateMethod.none:
        return 'None (missing sourced data)';
    }
  }

  static String _fmt(double v) => v >= 100 ? v.round().toString() : v.toStringAsFixed(1);

  Future<void> _edit() async {
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext _) => _EditDialog(settings: _settings, rows: _rows),
    );
    if (saved == true) _load();
  }
}

class _EditDialog extends StatefulWidget {
  const _EditDialog({required this.settings, required this.rows});

  final Map<String, dynamic>? settings;
  final List<_AreaRow> rows;

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  final Map<String, TextEditingController> _c = <String, TextEditingController>{};
  final Map<String, bool> _flags = <String, bool>{};
  String? _error;
  bool _saving = false;

  TextEditingController _t(String key, Object? initial) =>
      _c.putIfAbsent(key, () => TextEditingController(text: initial == null ? '' : '$initial'));

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic> s = widget.settings ?? <String, dynamic>{};
    _flags['seasonal_active'] = _WasteEstimationCardState._b(s['seasonal_active']);
    _flags['seasonal_validated'] = _WasteEstimationCardState._b(s['seasonal_validated']);
    for (final _AreaRow r in widget.rows) {
      _flags['v_${r.key}'] = _WasteEstimationCardState._b(r.saved?['size_verified']);
    }
  }

  @override
  void dispose() {
    for (final TextEditingController c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _field(String key, String label, Object? initial, {bool number = false, int lines = 1}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          controller: _t(key, initial),
          keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
          minLines: 1,
          maxLines: lines,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
        ),
      );

  String? _v(String key) {
    final String s = (_c[key]?.text ?? '').trim();
    return s.isEmpty ? null : s;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final Map<String, dynamic> settings = <String, dynamic>{
      'kg_per_capita_day': _v('cap'),
      'rate_source': _v('cap_src') ?? '',
      'kg_per_hectare_day': _v('ha'),
      'hectare_rate_source': _v('ha_src') ?? '',
      'seasonal_value': _v('sea') ?? '1',
      'seasonal_source': _v('sea_src') ?? '',
      'seasonal_applies_to': _v('sea_to') ?? '',
      'seasonal_active': _flags['seasonal_active'] == true,
      'seasonal_validated': _flags['seasonal_validated'] == true,
    };
    final List<Map<String, dynamic>> areas = <Map<String, dynamic>>[
      for (final _AreaRow r in widget.rows)
        <String, dynamic>{
          'area_key': r.key,
          'area_name': r.name,
          'size_m2': _v('m2_${r.key}'),
          'size_kind': _v('m2_${r.key}') == null ? 'none' : 'manual',
          'size_source': _v('m2src_${r.key}') ?? '',
          'size_verified': _flags['v_${r.key}'] == true,
          'population': _v('pop_${r.key}'),
          'population_source': _v('popsrc_${r.key}') ?? '',
          'population_year': _v('popyr_${r.key}'),
        },
    ];
    try {
      await ApiService().saveWasteEstimation(settings: settings, areas: areas);
      if (mounted) Navigator.of(context).pop(true);
    } on DioException catch (e) {
      final Object? d = e.response?.data;
      setState(() => _error = (d is Map && d['message'] != null) ? '${d['message']}' : 'Could not save.');
    } catch (_) {
      setState(() => _error = 'Could not save.');
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> s = widget.settings ?? <String, dynamic>{};
    return AlertDialog(
      title: const Text('Estimation parameters'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text('Every value needs its source (document, date). Leave blank if not available; nothing is assumed.'),
            const SizedBox(height: 12),
            _field('cap', 'kg per person per day', s['kg_per_capita_day'], number: true),
            _field('cap_src', 'Source of per-person rate', s['rate_source'], lines: 2),
            _field('ha', 'kg per hectare per day', s['kg_per_hectare_day'], number: true),
            _field('ha_src', 'Source of per-hectare rate', s['hectare_rate_source'], lines: 2),
            _field('sea', 'Seasonal multiplier (1.0 = neutral)', s['seasonal_value'] ?? 1, number: true),
            _field('sea_src', 'Source and date of the multiplier', s['seasonal_source'], lines: 2),
            _field('sea_to', 'Applies to (days/seasons)', s['seasonal_applies_to']),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Apply the multiplier'),
              value: _flags['seasonal_active'] == true,
              onChanged: (bool v) => setState(() => _flags['seasonal_active'] = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Evidence for the multiplier is on file (validated)'),
              value: _flags['seasonal_validated'] == true,
              onChanged: (bool v) => setState(() => _flags['seasonal_validated'] = v),
            ),
            const Divider(),
            for (final _AreaRow r in widget.rows)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(r.name),
                children: <Widget>[
                  _field('m2_${r.key}', 'Confirmed area size (m²)', r.saved?['size_m2'], number: true),
                  _field('m2src_${r.key}', 'Source of the size', r.saved?['size_source'], lines: 2),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Size verified against the real collection area'),
                    value: _flags['v_${r.key}'] == true,
                    onChanged: (bool v) => setState(() => _flags['v_${r.key}'] = v),
                  ),
                  _field('pop_${r.key}', 'Population', r.saved?['population'], number: true),
                  _field('popsrc_${r.key}', 'Source of the population', r.saved?['population_source'], lines: 2),
                  _field('popyr_${r.key}', 'Population year', r.saved?['population_year'], number: true),
                ],
              ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          ]),
        ),
      ),
      actions: <Widget>[
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
      ],
    );
  }
}
