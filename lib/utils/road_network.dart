import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;

import 'gps_smoothing.dart';

/// The street network around the Balintawak collection areas (OpenStreetMap), used to move a
/// SIMULATED truck along real streets instead of jumping between places.
///
/// Built from `assets/maps/balintawak_roads.json` (main roads, residential streets and service lanes).
/// Service lanes cost three times their length, so a route uses them only when no street fits.
/// One-way rules are not modelled.
class RoadNetwork {
  RoadNetwork._(this.nodes, this._adj);

  static const String assetPath = 'assets/maps/balintawak_roads.json';
  static const List<double> _classCost = <double>[1, 1, 3];

  /// Snapping further than this (metres) from any street gives no route.
  static const double maxSnapM = 400;

  /// [lng, lat] of every node.
  final List<List<double>> nodes;
  final List<List<_Edge>> _adj;
  final Map<int, List<int>> _grid = <int, List<int>>{};
  static const double _cell = 0.002;

  static RoadNetwork? _loaded;

  static Future<RoadNetwork> load() async =>
      _loaded ??= RoadNetwork.fromJson(jsonDecode(await rootBundle.loadString(assetPath)) as Map<String, dynamic>);

  factory RoadNetwork.fromJson(Map<String, dynamic> json) {
    final List<List<double>> nodes = (json['nodes'] as List)
        .map((n) => <double>[((n as List)[0] as num).toDouble(), (n[1] as num).toDouble()])
        .toList();
    final List<List<_Edge>> adj = List<List<_Edge>>.generate(nodes.length, (_) => <_Edge>[]);
    for (final e in json['edges'] as List) {
      final List l = e as List;
      final int a = (l[0] as num).toInt(), b = (l[1] as num).toInt();
      final int cls = l.length > 2 ? (l[2] as num).toInt() : 0;
      final double len = GpsSmoothing.distanceM(nodes[a][1], nodes[a][0], nodes[b][1], nodes[b][0]);
      final double cost = len * _classCost[cls.clamp(0, _classCost.length - 1)];
      adj[a].add(_Edge(b, cost));
      adj[b].add(_Edge(a, cost));
    }
    final RoadNetwork net = RoadNetwork._(nodes, adj);
    for (int i = 0; i < nodes.length; i++) {
      if (adj[i].isEmpty) continue;
      net._grid.putIfAbsent(_key(nodes[i][0], nodes[i][1]), () => <int>[]).add(i);
    }
    return net;
  }

  static int _key(double lng, double lat) => (lng / _cell).floor() * 100000 + (lat / _cell).floor();

  /// Nearest connected node to a position, or null when no street is within [maxSnapM].
  int? nearestNode(double lat, double lng) {
    int? best;
    double bestD = maxSnapM;
    final int cx = (lng / _cell).floor(), cy = (lat / _cell).floor();
    for (int dx = -2; dx <= 2; dx++) {
      for (int dy = -2; dy <= 2; dy++) {
        for (final int i in _grid[(cx + dx) * 100000 + (cy + dy)] ?? const <int>[]) {
          final double d = GpsSmoothing.distanceM(lat, lng, nodes[i][1], nodes[i][0]);
          if (d < bestD) {
            bestD = d;
            best = i;
          }
        }
      }
    }
    return best;
  }

  /// Street route between two positions as [lng, lat] points (shortest by cost), or null when either
  /// end is not near a street or the two are not connected.
  List<List<double>>? route(double fromLat, double fromLng, double toLat, double toLng) {
    final int? s = nearestNode(fromLat, fromLng), t = nearestNode(toLat, toLng);
    if (s == null || t == null) return null;
    if (s == t) return <List<double>>[nodes[s]];
    final int n = nodes.length;
    final List<double> dist = List<double>.filled(n, double.infinity);
    final List<int> prev = List<int>.filled(n, -1);
    final _Heap heap = _Heap();
    dist[s] = 0;
    heap.push(s, 0);
    while (heap.isNotEmpty) {
      final _HeapItem it = heap.pop();
      if (it.cost > dist[it.node]) continue;
      if (it.node == t) break;
      for (final _Edge e in _adj[it.node]) {
        final double nd = it.cost + e.cost;
        if (nd < dist[e.to]) {
          dist[e.to] = nd;
          prev[e.to] = it.node;
          heap.push(e.to, nd);
        }
      }
    }
    if (dist[t] == double.infinity) return null;
    final List<List<double>> path = <List<double>>[];
    for (int v = t; v != -1; v = prev[v]) {
      path.add(nodes[v]);
    }
    return path.reversed.toList();
  }

  /// [path] resampled so no two consecutive points are more than [maxStepM] apart; every street
  /// vertex is kept, so corners stay on the street.
  static List<List<double>> densify(List<List<double>> path, double maxStepM) {
    if (path.length < 2) return path;
    final List<List<double>> out = <List<double>>[path.first];
    for (int i = 1; i < path.length; i++) {
      final List<double> a = path[i - 1], b = path[i];
      final double d = GpsSmoothing.distanceM(a[1], a[0], b[1], b[0]);
      final int parts = math.max(1, (d / maxStepM).ceil());
      for (int k = 1; k <= parts; k++) {
        final double f = k / parts;
        out.add(<double>[a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f]);
      }
    }
    return out;
  }
}

class _Edge {
  const _Edge(this.to, this.cost);
  final int to;
  final double cost;
}

class _HeapItem {
  const _HeapItem(this.node, this.cost);
  final int node;
  final double cost;
}

class _Heap {
  final List<_HeapItem> _a = <_HeapItem>[];
  bool get isNotEmpty => _a.isNotEmpty;

  void push(int node, double cost) {
    _a.add(_HeapItem(node, cost));
    int i = _a.length - 1;
    while (i > 0) {
      final int p = (i - 1) >> 1;
      if (_a[p].cost <= _a[i].cost) break;
      final _HeapItem t = _a[p];
      _a[p] = _a[i];
      _a[i] = t;
      i = p;
    }
  }

  _HeapItem pop() {
    final _HeapItem top = _a.first;
    final _HeapItem last = _a.removeLast();
    if (_a.isNotEmpty) {
      _a[0] = last;
      int i = 0;
      while (true) {
        final int l = 2 * i + 1, r = l + 1;
        int m = i;
        if (l < _a.length && _a[l].cost < _a[m].cost) m = l;
        if (r < _a.length && _a[r].cost < _a[m].cost) m = r;
        if (m == i) break;
        final _HeapItem t = _a[m];
        _a[m] = _a[i];
        _a[i] = t;
        i = m;
      }
    }
    return top;
  }
}
