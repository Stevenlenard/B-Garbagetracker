import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/collection_visits.dart';
import 'package:garbage_tracking_app/utils/route_areas.dart';

void main() {
  // Two puroks: a square polygon and a circular geofence (200 m).
  const AreaGeofence central = AreaGeofence(
    name: 'Central (Purok 1)',
    lat: 13.9550,
    lng: 121.1600,
    radiusM: 100,
    polygon: <List<double>>[
      <double>[121.1590, 13.9540],
      <double>[121.1610, 13.9540],
      <double>[121.1610, 13.9560],
      <double>[121.1590, 13.9560],
    ],
  );
  const AreaGeofence riverside = AreaGeofence(name: 'Riverside', lat: 13.9500, lng: 121.1700, radiusM: 200);

  test('a route through a purok polygon counts for that purok only', () {
    final Set<String> a = RouteAreas.passedThrough(<List<double>>[
      <double>[13.9530, 121.1580], // outside
      <double>[13.9550, 121.1600], // inside Central
      <double>[13.9570, 121.1620], // outside
    ], const <AreaGeofence>[central, riverside]);
    expect(a, <String>{'Central (Purok 1)'});
  });

  test('a route touching two puroks lists both; none -> empty', () {
    expect(
        RouteAreas.passedThrough(<List<double>>[
          <double>[13.9550, 121.1600],
          <double>[13.9501, 121.1701],
        ], const <AreaGeofence>[central, riverside]),
        <String>{'Central (Purok 1)', 'Riverside'});
    expect(RouteAreas.passedThrough(<List<double>>[<double>[14.1, 121.3]], const <AreaGeofence>[central, riverside]), isEmpty);
  });

  test('no GPS points or no boundaries: nothing is claimed', () {
    expect(RouteAreas.passedThrough(const <List<double>>[], const <AreaGeofence>[central]), isEmpty);
    expect(RouteAreas.passedThrough(<List<double>>[<double>[13.9550, 121.1600]], const <AreaGeofence>[]), isEmpty);
  });

  test('long routes are sampled but still find the purok', () {
    final List<List<double>> route = <List<double>>[
      for (int i = 0; i < 5000; i++) <double>[13.9550, 121.1600 + (i - 2500) * 0.000001],
    ];
    expect(RouteAreas.passedThrough(route, const <AreaGeofence>[central]), contains('Central (Purok 1)'));
  });
}
