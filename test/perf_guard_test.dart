import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards against the causes of the lag seen when two or three people used the system at the same time. Each of these used
/// to hand the app far more data than it needed, or rebuild a whole screen for a few characters, many times a second:
///  * the admin dashboard and Analytics listened to the whole `driver_routes` node (4 MB and growing) and recomputed from
///    it with every route point any driver recorded;
///  * every map listened to a whole route (up to ~800 points, and the whole trip on some) for every new point;
///  * the clock and the ETA countdown called setState on 3000-line screens every second;
///  * a poll of an endpoint that always fails ran every 3 / 8 seconds and re-processed every truck each time.
void main() {
  String src(String f) => File(f).readAsStringSync();

  const List<String> screens = <String>[
    'lib/screens/admin_dashboard.dart',
    'lib/screens/analytics_screen.dart',
    'lib/screens/resident_track_truck_screen.dart',
    'lib/screens/track_trucks_screen.dart',
    'lib/screens/standalone_gis_web_screen.dart',
    'lib/screens/driver_track_truck_screen.dart',
    'lib/screens/driver_dashboard.dart',
  ];

  test('no screen listens to the whole driver_routes node, to a whole trip, or to a whole route with onValue', () {
    final RegExp wholeNode = RegExp(r"ref\('driver_routes'\)\.onValue");
    final RegExp wholeTrip = RegExp(r"ref\('driver_routes/[^'/]*'\)\.onValue");
    final RegExp wholeRoute = RegExp(r"driver_routes/[^'\n]*/route'\)\.onValue");
    for (final String f in screens) {
      final String s = src(f);
      expect(wholeNode.hasMatch(s), isFalse, reason: '$f listens to the whole driver_routes');
      expect(wholeTrip.hasMatch(s), isFalse, reason: '$f listens to a whole trip');
      expect(wholeRoute.hasMatch(s), isFalse, reason: '$f listens to a whole route');
    }
  });

  test('the maps follow a route through RoutePointsFeed, Admin and Analytics through ChildrenFeed', () {
    for (final String f in <String>[
      'lib/screens/resident_track_truck_screen.dart',
      'lib/screens/track_trucks_screen.dart',
      'lib/screens/standalone_gis_web_screen.dart',
      'lib/screens/driver_track_truck_screen.dart',
    ]) {
      expect(src(f).contains('RoutePointsFeed.listen('), isTrue, reason: f);
    }
    expect(src('lib/screens/admin_dashboard.dart').contains('ChildrenFeed.listen('), isTrue);
    expect(src('lib/screens/analytics_screen.dart').contains('ChildrenFeed.listen('), isTrue);
  });

  test('the admin coverage reads only the selected period and is recomputed at most every 10 seconds', () {
    final String a = src('lib/screens/admin_dashboard.dart');
    expect(a.contains('HistoryDates.firebaseKeyBounds(p.startDay, p.endDay)'), isTrue);
    expect(a.contains("minGap: const Duration(seconds: 10)"), isTrue);
    expect(a.contains('_watchCoverageTrips();'), isTrue);
  });

  test('Analytics still has every trip (the arrival regression is fitted on all of them), recomputed at most every 15 seconds', () {
    final String n = src('lib/screens/analytics_screen.dart');
    expect(n.contains("ChildrenFeed.listen(_database.ref('driver_routes')"), isTrue);
    expect(n.contains('minGap: const Duration(seconds: 15)'), isTrue);
    expect(n.contains('ArrivalRegression.extract(_allDriverRoutes, _geofences)'), isTrue);
  });

  test('the maps keep joining the end of the line to the live marker, so the line stays smooth between route points', () {
    for (final String f in <String>[
      'lib/screens/resident_track_truck_screen.dart',
      'lib/screens/track_trucks_screen.dart',
      'lib/screens/standalone_gis_web_screen.dart',
      'lib/screens/driver_track_truck_screen.dart',
    ]) {
      expect(src(f).contains('RouteGeometry.withLiveTail('), isTrue, reason: f);
    }
  });

  test('the poll of the always-failing MySQL positions is gone from the maps', () {
    final RegExp poll = RegExp(r'Timer\.periodic\([^;]*_syncPhpLocations');
    for (final String f in <String>[
      'lib/screens/resident_track_truck_screen.dart',
      'lib/screens/track_trucks_screen.dart',
      'lib/screens/standalone_gis_web_screen.dart',
    ]) {
      expect(poll.hasMatch(src(f)), isFalse, reason: f);
    }
  });

  test('the clock and the ETA countdown rebuild only their own widget', () {
    for (final String f in <String>['lib/screens/admin_dashboard.dart', 'lib/screens/resident_dashboard.dart', 'lib/screens/driver_dashboard.dart']) {
      expect(src(f).contains('ValueNotifier<String> _currentTime'), isTrue, reason: f);
    }
    final String r = src('lib/screens/resident_dashboard.dart');
    expect(r.contains('ValueNotifier<String> _etaText'), isTrue);
    expect(RegExp(r'setState\([^;]*_etaText').hasMatch(r), isFalse);
    expect(src('lib/screens/driver_track_truck_screen.dart').contains('setState(() => _currentTime = time)'), isFalse);
  });

  test('the driver app reads its own route once instead of listening to it', () {
    final String d = src('lib/screens/driver_dashboard.dart');
    final int from = d.indexOf('void _setupRoutePointsListener()');
    final String body = d.substring(from, d.indexOf('void _setupPurokListener()', from));
    expect(body.contains('.onValue'), isFalse);
    expect(body.contains('.get().then('), isTrue);
  });

  test('the map pulse updates the style at most four times a second', () {
    for (final String f in <String>['lib/widgets/mapbox_view.dart', 'lib/screens/resident_track_truck_screen.dart']) {
      expect(src(f).contains('Timer.periodic(const Duration(milliseconds: 120)'), isFalse, reason: f);
      expect(src(f).contains('Timer.periodic(const Duration(milliseconds: 250)'), isTrue, reason: f);
    }
  });
}
