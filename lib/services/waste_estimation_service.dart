import 'package:dio/dio.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';

import '../api/api_service.dart';
import '../utils/osm_area_references.dart';
import '../utils/waste_estimation.dart';

/// The two raw sources of the waste estimation screens: the body of get_waste_estimation.php and the value of the
/// Firebase `puroks` node.
typedef WasteEstimationRaw = ({Object? body, Object? puroks});

/// One collection area as the screens need it: its stored geometry size and what an admin saved for it.
class WasteAreaRow {
  WasteAreaRow({required this.key, required this.name, required this.geometrySize, this.geometryNote = ''});

  final String key;
  final String name;
  final AreaSize geometrySize;
  final String geometryNote;

  /// The row saved on the server (`waste_estimation_areas`), if any.
  Map<String, dynamic>? saved;
}

class WasteEstimationLoadException implements Exception {
  WasteEstimationLoadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Everything the compact card and the details screen show, computed ONCE by lib/utils/waste_estimation.dart from the
/// same data. Estimates are for waste GENERATED; they are never added to recorded loads (capacity-equivalent 5,000 kg per
/// FULL event) or to measured weights.
class WasteEstimationData {
  WasteEstimationData._({
    required this.available,
    required this.settings,
    required this.rows,
    required this.barangay,
    required this.params,
    required this.estimates,
    required this.whole,
    required this.summary,
    required this.configs,
  });

  /// Row key of the whole-barangay (population x per-person rate) figure; kept apart from the areas.
  static const String barangayKey = 'barangay_total';

  final bool available;
  final Map<String, dynamic>? settings;
  final List<WasteAreaRow> rows;
  final WasteAreaRow barangay;
  final EstimationParams params;

  /// Same order as [rows].
  final List<AreaEstimate> estimates;
  final AreaEstimate whole;
  final EstimateSummary summary;
  final Map<String, AreaConfig> configs;

  AreaConfig configOf(WasteAreaRow r) => configs[r.key]!;
  AreaEstimate estimateOf(WasteAreaRow r) => r.key == barangayKey ? whole : estimates[rows.indexOf(r)];

  static double? _d(Object? v) => v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));
  static int? _i(Object? v) => v == null ? null : (v is num ? v.toInt() : int.tryParse('$v'));
  static bool flag(Object? v) => v == true || v == 1 || v == '1';

  static Future<WasteEstimationRaw> fetchRaw() async {
    final List<Object> r = await Future.wait<Object>(<Future<Object>>[
      ApiService().getWasteEstimation(),
      FirebaseDatabase.instance.ref('puroks').get(),
    ]);
    return (body: (r[0] as Response).data, puroks: (r[1] as DataSnapshot).value);
  }

  /// Reads the sources (or [loader], for tests) and computes the estimates. Throws [WasteEstimationLoadException].
  static Future<WasteEstimationData> load({Future<WasteEstimationRaw> Function()? loader}) async {
    try {
      return fromRaw(loader != null ? await loader() : await fetchRaw());
    } on DioException catch (e) {
      final Object? d = e.response?.data;
      throw WasteEstimationLoadException((d is Map && d['message'] != null) ? '${d['message']}' : 'Could not load the waste estimation data.');
    } catch (_) {
      throw WasteEstimationLoadException('Could not load the waste estimation data.');
    }
  }

  static WasteEstimationData fromRaw(WasteEstimationRaw raw0) {
    final Object? body = raw0.body;
    final Map<String, dynamic> data = body is Map ? Map<String, dynamic>.from(body) : <String, dynamic>{};
    final bool available = data['available'] != false;
    final Map<String, dynamic>? settings = data['settings'] is Map ? Map<String, dynamic>.from(data['settings'] as Map) : null;
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
    final Map<String, double> areas = <String, double>{};
    for (final MapEntry<String, Map> p in puroks) {
      final List<List<double>>? ring = WasteEstimation.parseRing(p.value['boundaryGeometry']);
      if (ring != null) areas['${p.value['name'] ?? p.key}'] = WasteEstimation.polygonAreaM2(ring);
    }
    final Set<String> placeholder = WasteEstimation.placeholderAreas(areas);

    final List<WasteAreaRow> rows = <WasteAreaRow>[];
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
      rows.add(WasteAreaRow(key: p.key, name: name, geometrySize: size, geometryNote: note)..saved = saved[p.key]);
    }
    rows.sort((WasteAreaRow a, WasteAreaRow b) => a.name.compareTo(b.name));
    final WasteAreaRow barangay = WasteAreaRow(key: barangayKey, name: 'Barangay Balintawak (whole barangay)', geometrySize: const AreaSize.none())
      ..saved = saved[barangayKey];

    final EstimationParams params = _params(settings);
    final Map<String, AreaConfig> configs = <String, AreaConfig>{for (final WasteAreaRow r in <WasteAreaRow>[...rows, barangay]) r.key: _config(r)};
    final List<AreaEstimate> estimates = <AreaEstimate>[for (final WasteAreaRow r in rows) WasteEstimation.estimate(configs[r.key]!, params)];
    return WasteEstimationData._(
      available: available,
      settings: settings,
      rows: rows,
      barangay: barangay,
      params: params,
      estimates: estimates,
      whole: WasteEstimation.estimate(configs[barangayKey]!, params),
      summary: WasteEstimation.summarize(estimates),
      configs: configs,
    );
  }

  static EstimationParams _params(Map<String, dynamic>? s) {
    if (s == null) return const EstimationParams();
    return EstimationParams(
      kgPerCapitaDay: _d(s['kg_per_capita_day']),
      rateSource: '${s['rate_source'] ?? ''}',
      kgPerHectareDay: _d(s['kg_per_hectare_day']),
      hectareRateSource: '${s['hectare_rate_source'] ?? ''}',
      seasonal: SeasonalMultiplier(
        value: _d(s['seasonal_value']) ?? 1.0,
        source: '${s['seasonal_source'] ?? ''}',
        validated: flag(s['seasonal_validated']),
        active: flag(s['seasonal_active']),
        appliesTo: '${s['seasonal_applies_to'] ?? ''}',
      ),
    );
  }

  static AreaConfig _config(WasteAreaRow r) {
    final Map<String, dynamic>? s = r.saved;
    AreaSize size = r.geometrySize;
    if (s != null && _d(s['size_m2']) != null) {
      size = AreaSize(
        m2: _d(s['size_m2'])!,
        kind: '${s['size_kind']}' == 'polygon' ? AreaSizeKind.polygon : AreaSizeKind.manual,
        source: '${s['size_source'] ?? ''}',
        verified: flag(s['size_verified']),
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
}

/// Number and label formatting shared by the card and the details screen.
class WasteFormat {
  WasteFormat._();

  static final NumberFormat _int = NumberFormat('#,##0');

  /// 9,639 for large values, one decimal below 100.
  static String kg(double v) => v >= 100 ? _int.format(v.round()) : v.toStringAsFixed(1);

  static String m2(double v) => _int.format(v.round());

  static String methodLabel(EstimateMethod m) {
    switch (m) {
      case EstimateMethod.perCapita:
        return 'Population × per-person rate';
      case EstimateMethod.perHectare:
        return 'Area (ha) × per-hectare rate';
      case EstimateMethod.measured:
        return 'Recorded measured weight';
      case EstimateMethod.none:
        return 'Missing sourced data';
    }
  }
}
