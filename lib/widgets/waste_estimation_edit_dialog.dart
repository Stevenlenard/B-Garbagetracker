import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/api_service.dart';
import '../services/waste_estimation_service.dart';

/// Admin editing of the estimation parameters and the confirmed area rows (unchanged behaviour: every value needs its
/// source; blank means "not available"). Returns true when something was saved.
Future<bool> showWasteEstimationEdit(BuildContext context, WasteEstimationData data) async {
  final bool? saved = await showDialog<bool>(
    context: context,
    builder: (BuildContext _) => WasteEstimationEditDialog(settings: data.settings, rows: <WasteAreaRow>[data.barangay, ...data.rows]),
  );
  return saved == true;
}

class WasteEstimationEditDialog extends StatefulWidget {
  const WasteEstimationEditDialog({super.key, required this.settings, required this.rows});

  final Map<String, dynamic>? settings;
  final List<WasteAreaRow> rows;

  @override
  State<WasteEstimationEditDialog> createState() => _WasteEstimationEditDialogState();
}

class _WasteEstimationEditDialogState extends State<WasteEstimationEditDialog> {
  final Map<String, TextEditingController> _c = <String, TextEditingController>{};
  final Map<String, bool> _flags = <String, bool>{};
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
      for (final WasteAreaRow r in widget.rows)
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
            for (final WasteAreaRow r in widget.rows)
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
