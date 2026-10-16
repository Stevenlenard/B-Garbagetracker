import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Smallest Matrix request for the driver's stop ordering.
///
/// Stop-to-stop travel times depend only on the collection areas, so each pair is requested
/// once and cached. A later optimization (new trip, re-optimize after a completed area, moved
/// truck) only needs the row from the truck's position to the remaining stops:
///
///   some stop pair not cached: sources = all, destinations = all -> (N + 1)^2 elements
///   all pairs cached:          sources = 0,   destinations = 1..N -> N elements
class MatrixRequestPlan {
  const MatrixRequestPlan._(this.stopIds, this.sources, this.destinations, this.cachedPairs);

  /// Identity of each stop (index i here = coordinate i + 1 in the request).
  final List<String> stopIds;

  /// Source indices, or null for "all".
  final List<int>? sources;

  /// Destination indices, or null for "all".
  final List<int>? destinations;

  /// Cached stop-to-stop durations (only for a row request).
  final Map<String, num?>? cachedPairs;

  int get coordinateCount => stopIds.length + 1;
  bool get isRowRequest => cachedPairs != null;

  int get elements =>
      (sources?.length ?? coordinateCount) * (destinations?.length ?? coordinateCount);

  static String pairKey(String from, String to) => '$from>$to';

  static MatrixRequestPlan create({required List<String> stopIds, required Map<String, num?> cache}) {
    final int n = stopIds.length;
    bool complete = n > 0;
    for (int i = 0; i < n && complete; i++) {
      for (int j = 0; j < n && complete; j++) {
        if (i != j && !cache.containsKey(pairKey(stopIds[i], stopIds[j]))) complete = false;
      }
    }
    if (!complete) return MatrixRequestPlan._(stopIds, null, null, null);
    return MatrixRequestPlan._(stopIds, const <int>[0], List<int>.generate(n, (int i) => i + 1), cache);
  }

  Map<String, String> get queryParameters => <String, String>{
        if (sources != null) 'sources': sources!.join(';'),
        if (destinations != null) 'destinations': destinations!.join(';'),
      };

  /// Full (N+1) x (N+1) duration matrix (index 0 = truck) from the response [durations]
  /// (shape sources x destinations) plus, for a row request, the cached stop pairs.
  /// Costs back to the truck (column 0) are not needed for an open tour and stay null.
  List<List<num?>> assemble(List<dynamic> durations) {
    List<num?> row(dynamic r) => <num?>[for (final dynamic v in r as List<dynamic>) v as num?];
    if (!isRowRequest) return <List<num?>>[for (final dynamic r in durations) row(r)];
    final int n = stopIds.length;
    return <List<num?>>[
      <num?>[0, ...row(durations.first)],
      for (int i = 0; i < n; i++)
        <num?>[null, for (int j = 0; j < n; j++) i == j ? 0 : cachedPairs![pairKey(stopIds[i], stopIds[j])]],
    ];
  }

  /// Stop-to-stop pairs of a full response, for the cache (empty for a row request).
  Map<String, num?> pairsFrom(List<dynamic> durations) {
    if (isRowRequest) return const <String, num?>{};
    final List<List<num?>> full = assemble(durations);
    final Map<String, num?> out = <String, num?>{};
    for (int i = 0; i < stopIds.length; i++) {
      for (int j = 0; j < stopIds.length; j++) {
        if (i != j) out[pairKey(stopIds[i], stopIds[j])] = full[i + 1][j + 1];
      }
    }
    return out;
  }
}

/// Identity of a stop: name + coordinates rounded to ~1 m (a moved area gets new pairs).
String stopId(Map<String, dynamic> s) =>
    '${s['name']}@${(s['lat'] as num).toStringAsFixed(5)},${(s['lng'] as num).toStringAsFixed(5)}';

/// Where cached stop pairs are kept.
abstract class StopMatrixStore {
  Future<Map<String, num?>> read();
  Future<void> merge(Map<String, num?> pairs);
}

/// Device storage (survives app restarts). Pairs expire after [maxAge]; at most [maxPairs]
/// are kept (newest first).
class PrefsStopMatrixStore implements StopMatrixStore {
  PrefsStopMatrixStore({this.maxPairs = 2000, this.maxAge = const Duration(days: 30), DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  static const String _prefsKey = 'route_stop_pairs_v1';
  final int maxPairs;
  final Duration maxAge;
  final DateTime Function() _clock;

  Future<Map<String, dynamic>> _raw(SharedPreferences p) async {
    try {
      final Object? v = jsonDecode(p.getString(_prefsKey) ?? '{}');
      return v is Map<String, dynamic> ? v : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  @override
  Future<Map<String, num?>> read() async {
    try {
      final int now = _clock().millisecondsSinceEpoch;
      final Map<String, dynamic> raw = await _raw(await SharedPreferences.getInstance());
      final Map<String, num?> out = <String, num?>{};
      raw.forEach((String k, dynamic e) {
        if (e is List && e.length == 2 && now - ((e[1] as num?) ?? 0) <= maxAge.inMilliseconds) {
          out[k] = e[0] as num?;
        }
      });
      return out;
    } catch (_) {
      return <String, num?>{}; // a cache problem only costs one full request
    }
  }

  @override
  Future<void> merge(Map<String, num?> pairs) async {
    if (pairs.isEmpty) return;
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final Map<String, dynamic> raw = await _raw(p);
      final int now = _clock().millisecondsSinceEpoch;
      pairs.forEach((String k, num? v) => raw[k] = <Object?>[v, now]);
      if (raw.length > maxPairs) {
        final List<String> keys = raw.keys.toList()
          ..sort((String a, String b) => ((raw[a][1] as num?) ?? 0).compareTo((raw[b][1] as num?) ?? 0));
        for (final String k in keys.take(raw.length - maxPairs)) {
          raw.remove(k);
        }
      }
      await p.setString(_prefsKey, jsonEncode(raw));
    } catch (_) {}
  }
}

class MemoryStopMatrixStore implements StopMatrixStore {
  final Map<String, num?> pairs = <String, num?>{};
  @override
  Future<Map<String, num?>> read() async => Map<String, num?>.from(pairs);
  @override
  Future<void> merge(Map<String, num?> p) async => pairs.addAll(p);
}
