import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/gps_smoothing.dart';
import 'package:garbage_tracking_app/utils/road_network.dart';

void main() {
  final RoadNetwork net = RoadNetwork.fromJson(jsonDecode(File(RoadNetwork.assetPath).readAsStringSync()) as Map<String, dynamic>);
  double len(List<List<double>> p) {
    double d = 0;
    for (int i = 1; i < p.length; i++) {
      d += GpsSmoothing.distanceM(p[i - 1][1], p[i - 1][0], p[i][1], p[i][0]);
    }
    return d;
  }

  test('a simulated drive from Central (Purok 1) to Purok 4 follows the streets', () {
    final List<List<double>>? street = net.route(13.953, 121.1588, 13.9664847, 121.1501235);
    expect(street, isNotNull);
    final double straight = GpsSmoothing.distanceM(13.953, 121.1588, 13.9664847, 121.1501235);
    expect(len(street!), greaterThan(straight)); // streets are never shorter than the straight line
    expect(len(street), lessThan(straight * 2.5)); // but a sensible route, not a tour
    final List<List<double>> path = RoadNetwork.densify(street, 25);
    for (int i = 1; i < path.length; i++) {
      expect(GpsSmoothing.distanceM(path[i - 1][1], path[i - 1][0], path[i][1], path[i][0]), lessThanOrEqualTo(25.5));
    }
    for (final List<double> v in street) {
      expect(net.nodes.any((n) => n[0] == v[0] && n[1] == v[1]), isTrue); // every corner is a street vertex
    }
  });

  test('every collection area entrance can be reached by street from Central (Purok 1)', () {
    const List<List<double>> entrances = <List<double>>[
      <double>[13.949254869, 121.158850046], // Ayala Highway
      <double>[13.9551652, 121.1567505], // Brixton Homes
      <double>[13.96142346200848, 121.15445314118254], // Purok 2
      <double>[13.96014078834871, 121.1499563993106], // Purok 3
      <double>[13.946622854597587, 121.15625598161627], // Purok Paraiso
      <double>[13.9465, 121.1637], // Riverside
      <double>[13.9345, 121.162], // San Nicolas
      <double>[13.94399999538, 121.1626678714], // T.M. Kalaw Street
    ];
    for (final List<double> e in entrances) {
      expect(net.route(13.953, 121.1588, e[0], e[1]), isNotNull, reason: 'no street route to $e');
    }
  });

  test('a position far from any street gives no route (the simulation then starts at the area)', () {
    expect(net.route(14.5, 121.0, 13.953, 121.1588), isNull);
  });
}
