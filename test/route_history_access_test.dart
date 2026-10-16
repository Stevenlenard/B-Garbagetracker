import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/models/driver_trip.dart';
import 'package:garbage_tracking_app/services/driver_lifecycle.dart';
import 'package:garbage_tracking_app/services/driver_session_guard.dart';
import 'package:garbage_tracking_app/utils/admin_quick_actions.dart';
import 'package:garbage_tracking_app/utils/load_history.dart';
import 'package:garbage_tracking_app/utils/route_geometry.dart';
import 'package:garbage_tracking_app/utils/route_history_navigation.dart';
import 'package:garbage_tracking_app/utils/trip_links.dart';

import 'support/fake_rtdb.dart';

String src(String path) => File(path).readAsStringSync();

Map<String, dynamic> pt(double lat, double lng, int ts, {double acc = 5.0, String color = 'GREEN'}) =>
    <String, dynamic>{'latitude': lat, 'longitude': lng, 'timestamp': ts, 'accuracy': acc, 'color': color};

DriverTrip trip(String id, {String status = 'FULL', double km = 1.0, int pointCount = 0, bool full = true}) =>
    DriverTrip.fromJson(
      <String, dynamic>{
        'trip_id': id,
        'driver_id': '7',
        'driver_name': 'Juan',
        'truck_id': 'GT-007',
        'route_status': status,
        'start_time': '2026-10-12 08:00:00',
        'total_distance_km': km,
        'raw_full_time': '2026-10-12 09:00:00',
        'full_time': '9:00 AM',
        if (full) 'has_full_event': true,
      },
      pointsList: [
        for (int i = 0; i < pointCount; i++)
          GpsPoint(
            latitude: 13.75 + i * 0.0005,
            longitude: 121.05,
            speedKmh: 10,
            heading: 0,
            accuracyM: 5,
            status: 'ACTIVE',
            timestamp: DateTime(2026, 10, 12, 8, 0, i * 5),
          ),
      ],
    );

void main() {
  group('Admin Quick Actions', () {
    test('five permanent cards; the four existing ones are unchanged', () {
      expect(kAdminQuickActions.length, 6);
      final byTitle = {for (final a in kAdminQuickActions) a.title: a};
      expect(byTitle['Analytics']!.targetIndex, AdminDestinations.analytics);
      expect(byTitle['Users']!.targetIndex, AdminDestinations.users);
      expect(byTitle['Database Center']!.targetIndex, AdminDestinations.database);
      expect(byTitle['Incidents']!.targetIndex, AdminDestinations.incidents);
      expect(byTitle['Analytics']!.subtitle, 'View system performance');
      expect(byTitle['Incidents']!.subtitle, 'Review resident reports');
    });

    test('the new card has the requested title, description and a route icon', () {
      final a = kAdminQuickActions.firstWhere((x) => x.title == 'Driver Route History');
      expect(a.subtitle, 'View recorded collection routes, trip details, and associated load history.');
      expect(a.icon, Icons.route_rounded);
      expect(a.targetIndex, AdminDestinations.routeHistory);
      expect(AdminDestinations.routeHistory, 7);
    });

    test('every action leads to a different destination', () {
      final targets = kAdminQuickActions.map((a) => a.targetIndex).toList();
      expect(targets.toSet().length, targets.length);
    });

    testWidgets('tapping the card reports the Route History destination', (tester) async {
      int? opened;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              for (final a in kAdminQuickActions)
                ListTile(title: Text(a.title), subtitle: Text(a.subtitle), onTap: () => opened = a.targetIndex),
            ],
          ),
        ),
      ));
      expect(find.text('Driver Route History'), findsOneWidget);
      await tester.tap(find.text('Driver Route History'));
      expect(opened, AdminDestinations.routeHistory);
    });

    test('dashboard wiring (source structure): shared list, Route History screen at index 7, back to dashboard', () {
      final dash = src('lib/screens/admin_dashboard.dart');
      // both layouts render the shared list
      expect(dash.contains('kAdminQuickActions'), isTrue);
      // the IndexedStack order puts RouteHistoryScreen last = index 7, independent of the map
      final order = [
        '_buildMainDashboard(',
        'TrackTrucksScreen(isEmbedded: true',
        'AnalyticsScreen(isEmbedded: true',
        'ComplaintsScreen(isEmbedded: true',
        'UserManagementScreen(isEmbedded: true',
        'DataManagementScreen(isEmbedded: true',
        'AdminSettingsScreen(isEmbedded: true',
        'RouteHistoryScreen(key:',
      ];
      int last = -1;
      for (final marker in order) {
        final at = dash.indexOf(marker, dash.indexOf('IndexedStack('));
        expect(at, greaterThan(last), reason: marker);
        last = at;
      }
      // back returns to the dashboard (index 0), including the Android system back
      final stackLine = dash.split('\n').firstWhere((l) => l.contains('RouteHistoryScreen(key:'));
      expect(stackLine.contains('_routeReturn.backTarget'), isTrue);
      expect(dash.contains('if (_selectedIndex > 0)'), isTrue);
      // the sidebar and drawer entries to the same screen are still there
      expect(dash.contains('"Driver Route History", 7'), isTrue);
    });

    test('Route History does not depend on the live map screen', () {
      final rh = src('lib/screens/route_history_screen.dart');
      expect(rh.contains('track_trucks_screen.dart'), isFalse);
      expect(rh.contains('Navigator.pop(context)'), isTrue, reason: 'standalone back path');
    });
  });

  group('Live route lines: real, valid, extending, honest', () {
    test('fewer than two valid points draw NO line (no straight line is invented)', () {
      expect(RouteGeometry.lineFeatures([]), isEmpty);
      expect(RouteGeometry.lineFeatures([pt(13.75, 121.05, 1000)]), isEmpty);
      // two points with only one valid
      expect(RouteGeometry.lineFeatures([pt(13.75, 121.05, 1000), pt(0, 0, 2000)]), isEmpty);
    });

    test('the line EXTENDS as valid GPS points arrive', () {
      final points = <Map<String, dynamic>>[];
      int prevCoords = 0;
      for (int i = 0; i < 6; i++) {
        points.add(pt(13.75 + i * 0.0003, 121.05, 1000 + i * 5000));
        final f = RouteGeometry.lineFeatures(points);
        if (i == 0) {
          expect(f, isEmpty);
          continue;
        }
        final coords = (f.single['geometry']['coordinates'] as List).length;
        expect(coords, i + 1);
        expect(coords, greaterThan(prevCoords));
        prevCoords = coords;
      }
    });

    test('invalid points are dropped, order is chronological', () {
      final f = RouteGeometry.lineFeatures([
        pt(13.7510, 121.05, 21000),
        pt(13.7500, 121.05, 1000),
        pt(0, 0, 5000),
        pt(13.7505, 121.05, 11000, acc: 250),
        pt(13.7520, 121.05, 41000),
      ]);
      final coords = f.single['geometry']['coordinates'] as List;
      expect(coords.length, 3);
      expect(coords.first[1], 13.7500);
      expect(coords.last[1], 13.7520);
    });

    test('an impossible GPS jump never becomes part of the route', () {
      final f = RouteGeometry.lineFeatures([
        pt(13.7500, 121.05, 1000),
        pt(13.7501, 121.05, 6000),
        pt(14.5000, 121.05, 7000), // ~83 km in 1 s
        pt(13.7503, 121.05, 11000),
      ]);
      final coords = f.single['geometry']['coordinates'] as List;
      expect(coords.length, 3);
      expect(coords.every((c) => (c[1] as double) < 14.0), isTrue);
    });

    test('a long gap splits the line instead of drawing across it', () {
      final f = RouteGeometry.lineFeatures([
        pt(13.7500, 121.05, 1000),
        pt(13.7502, 121.05, 6000),
        pt(13.7504, 121.05, 600000), // 10 min later
        pt(13.7506, 121.05, 605000),
      ]);
      expect(f.length, 2);
    });

    test('two drivers never merge: geometry is built per trip', () {
      final a = RouteGeometry.lineFeatures([pt(13.70, 121.0, 1000), pt(13.7005, 121.0, 6000)]);
      final b = RouteGeometry.lineFeatures([pt(14.10, 122.0, 1000), pt(14.1005, 122.0, 6000)]);
      final aLng = (a.single['geometry']['coordinates'] as List).map((c) => c[0]).toSet();
      final bLng = (b.single['geometry']['coordinates'] as List).map((c) => c[0]).toSet();
      expect(aLng.intersection(bLng), isEmpty);
    });

    test('incomplete routes are labelled, complete ones are not', () {
      expect(RouteGeometry.incompleteReason(validPointCount: 0, collectionFinalized: true, recordedDistanceKm: 3), contains('No GPS'));
      expect(RouteGeometry.incompleteReason(validPointCount: 1, collectionFinalized: true, recordedDistanceKm: 0), contains('one GPS point'));
      expect(RouteGeometry.incompleteReason(validPointCount: 30, collectionFinalized: false, recordedDistanceKm: 3), contains('not finalized'));
      expect(RouteGeometry.incompleteReason(validPointCount: 3, collectionFinalized: true, recordedDistanceKm: 4.0), contains('incomplete'));
      expect(RouteGeometry.incompleteReason(validPointCount: 40, collectionFinalized: true, recordedDistanceKm: 4.0), isNull);
    });
  });

  group('One persisted route feeds live maps and history', () {
    Future<(FakeRtdb, DriverSessionGuard, String)> startedTrip() async {
      final db = FakeRtdb();
      final g = DriverSessionGuard(db: db, driverId: '7', runtimeLabel: 'A', token: 'tok-A');
      await g.claim(truckId: 'GT-007');
      final r = await TripOpener.open(
        db: db,
        guard: g,
        driverId: '7',
        truckId: 'GT-007',
        driverName: 'Juan',
        newTripId: 'trip-1',
        startLat: 13.75,
        startLng: 121.05,
        startTimeLabel: '8:00 AM',
        nowMs: 5000,
      );
      return (db, g, r.tripId!);
    }

    Future<void> addPoints(FakeRtdb db, DriverSessionGuard g, String id, int n, {double lat = 13.75, int ts0 = 1000}) async {
      final w = TripRouteWriter(db: db, guard: g, verifyTtlMs: 0);
      for (int i = 0; i < n; i++) {
        await w.write(
          tripId: id,
          tripFinished: false,
          finishing: false,
          point: <String, Object?>{
            'latitude': lat + i * 0.0003,
            'longitude': 121.05,
            'lat': lat + i * 0.0003,
            'lng': 121.05,
            'timestamp': ts0 + i * 5000,
            'accuracy': 5.0,
            'color': 'GREEN',
            'tripId': id,
          },
        );
      }
    }

    List<Map> routeOf(FakeRtdb db, String id) {
      final Object? r = (db.read('driver_routes/$id') as Map)['route'];
      return r is Map ? r.values.map((v) => Map<String, dynamic>.from(v as Map)).toList() : <Map>[];
    }

    test('the live line and the history route start and end on the same collection points', () async {
      final (db, g, id) = await startedTrip();
      await addPoints(db, g, id, 12);
      final raw = routeOf(db, id);
      final live = RouteGeometry.cleanPoints(raw);

      final history = DriverTrip.fromJson(
        <String, dynamic>{
          ...Map<String, dynamic>.from(db.read('driver_routes/$id') as Map),
          'trip_id': id,
        },
        pointsList: (raw..sort((a, b) => (a['timestamp'] as num).compareTo(b['timestamp'] as num)))
            .map((m) => GpsPoint.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
      );
      expect(history.points.length, live.length);
      expect(history.points.first.latitude, live.first['latitude']);
      expect(history.points.last.latitude, live.last['latitude']);
    });

    test('FULL freezes the historical route; COMPLETED and post-FULL travel do not extend it', () async {
      final (db, g, id) = await startedTrip();
      await addPoints(db, g, id, 10);
      final before = routeOf(db, id).length;
      await CollectionFinalizer.finalize(
        db: db,
        guard: g,
        tripId: id,
        record: CollectionRecord.build(
          startMs: 1000,
          nowMs: 60000,
          distanceKm: 1.2,
          weightKg: 5000,
          weightType: 'ESTIMATED',
          via: 'FULL',
        ),
      );
      // The live truck marker keeps moving (separate node); the driver app writes no
      // collection points after FULL, and COMPLETED adds only unloading fields.
      await TripFinalizer.finish(
        db: db,
        guard: g,
        tripId: id,
        fields: CollectionRecord.completionFields(nowMs: 9000000, endTimeLabel: '11:00', postFullDistanceKm: 9.0),
      );
      expect(routeOf(db, id).length, before, reason: 'route points unchanged by FULL/COMPLETED');
      final trip = Map<String, dynamic>.from(db.read('driver_routes/$id') as Map);
      expect(trip['total_distance'], 1.2);
      expect(trip['post_full_distance_km'], 9.0, reason: 'travel to the landfill is stored apart');
    });

    test('a late write to a COMPLETED trip is rejected (no collection coordinate is added)', () async {
      final (db, g, id) = await startedTrip();
      await addPoints(db, g, id, 4);
      await TripFinalizer.finish(db: db, guard: g, tripId: id, fields: {'route_status': 'COMPLETED'});
      final g2 = DriverSessionGuard(db: db, driverId: '7', runtimeLabel: 'Z', token: 'tok-Z');
      await g2.claim(truckId: 'GT-007');
      await g2.bindTrip(id);
      final res = await TripRouteWriter(db: db, guard: g2, verifyTtlMs: 0).write(
        tripId: id,
        tripFinished: false,
        finishing: false,
        point: <String, Object?>{'latitude': 13.9, 'longitude': 121.2, 'timestamp': 99999999},
      );
      expect(res.denial, WriteDenial.tripFinished);
      expect(routeOf(db, id).length, 4);
    });

    test('resuming after a reconnect adds no point and no second trip', () async {
      final (db, g, id) = await startedTrip();
      await addPoints(db, g, id, 5);
      final g2 = DriverSessionGuard(db: db, driverId: '7', runtimeLabel: 'B', token: 'tok-B');
      await g2.claim(truckId: 'GT-007');
      final again = await TripOpener.open(
        db: db,
        guard: g2,
        driverId: '7',
        truckId: 'GT-007',
        driverName: 'Juan',
        newTripId: 'unused',
        pendingTripId: id,
        startLat: 13.75,
        startLng: 121.05,
        startTimeLabel: '8:00 AM',
        nowMs: 5000,
      );
      expect(again.tripId, id);
      expect(routeOf(db, id).length, 5);
      expect((db.read('driver_routes') as Map).length, 1);
    });

    test('two drivers write separate routes under separate trips', () async {
      final db = FakeRtdb();
      final g7 = DriverSessionGuard(db: db, driverId: '7', runtimeLabel: 'A', token: 'tok-A');
      final g9 = DriverSessionGuard(db: db, driverId: '9', runtimeLabel: 'B', token: 'tok-B');
      await g7.claim(truckId: 'GT-007');
      await g9.claim(truckId: 'GT-009');
      Future<String> open(DriverSessionGuard g, String d, String truck, String id) async => (await TripOpener.open(
            db: db,
            guard: g,
            driverId: d,
            truckId: truck,
            driverName: 'D$d',
            newTripId: id,
            startLat: 13.7,
            startLng: 121.0,
            startTimeLabel: 'x',
            nowMs: 5000,
          ))
              .tripId!;
      final t7 = await open(g7, '7', 'GT-007', 'trip-7');
      final t9 = await open(g9, '9', 'GT-009', 'trip-9');
      await addPoints(db, g7, t7, 4, lat: 13.70);
      await addPoints(db, g9, t9, 6, lat: 14.10);
      final r7 = routeOf(db, t7);
      final r9 = routeOf(db, t9);
      expect(r7.length, 4);
      expect(r9.length, 6);
      expect(r7.every((p) => (p['latitude'] as num) < 14), isTrue);
      expect(r9.every((p) => (p['latitude'] as num) > 14), isTrue);
      expect((db.read('driver_routes/$t7') as Map)['driver_id'], '7');
      expect((db.read('driver_routes/$t9') as Map)['driver_id'], '9');
    });
  });

  group('Route History <-> Load History share the trip id', () {
    test('Route History -> View Associated Load opens the same trip', () {
      final t = trip('trip-42', pointCount: 8);
      final link = TripLinks.toLoad(t);
      expect(link.isAvailable, isTrue);
      expect(link.tripId, 'trip-42');
      expect(link.date, isNotNull);
      expect(link.date!.day, 12);
    });

    test('Load History -> View Collection Route opens the same trip', () {
      final t = trip('trip-42');
      final link = TripLinks.toRoute(t);
      expect(link.isAvailable, isTrue);
      expect(link.tripId, 'trip-42');
    });

    test('an unfinished trip has NO load record: unavailable, never another trip', () {
      final active = trip('trip-9', status: 'ACTIVE', km: 5, full: false);
      final link = TripLinks.toLoad(active);
      expect(link.isAvailable, isFalse);
      expect(link.message, contains('FULL'));
      expect(LoadHistory.isLoad(active), isFalse);
    });

    test('a FULL trip with zero distance still has a load record', () {
      final t = trip('trip-0', km: 0);
      expect(TripLinks.toLoad(t).isAvailable, isTrue);
    });

    test('a trip without an id cannot be linked', () {
      final t = DriverTrip.fromJson(<String, dynamic>{'trip_id': '', 'route_status': 'FULL'});
      expect(TripLinks.toRoute(t).isAvailable, isFalse);
    });

    test('Route History and Load History describe one trip as one load', () {
      final routeView = trip('same', pointCount: 6);
      final loadView = trip('same');
      expect(LoadHistory.uniqueLoads([routeView, loadView]).length, 1);
    });
  });

  group('Production paths use persisted data only', () {
    test('no hard-coded route coordinates remain in the history service', () {
      final svc = src('lib/services/driver_route_history_service.dart');
      expect(svc.contains('_generateSampleRoutePoints'), isFalse);
      expect(svc.contains('121.15'), isFalse);
      expect(svc.contains('13.95'), isFalse);
    });

    test('simulated trips are excluded from history', () {
      final svc = src('lib/services/driver_route_history_service.dart');
      expect('is_simulation'.allMatches(svc).length, greaterThanOrEqualTo(2));
    });

    test('no fabricated moving/stationary defaults or invented end times', () {
      final svc = src('lib/services/driver_route_history_service.dart');
      final model = src('lib/models/driver_trip.dart');
      expect(svc.contains(': 960'), isFalse);
      expect(svc.contains(': 480'), isFalse);
      expect(model.contains('minutes: 24'), isFalse);
    });

    test('a finalized trip with no end time and no points reports an unknown duration', () {
      final t = DriverTrip.fromJson(<String, dynamic>{
        'trip_id': 'x',
        'route_status': 'COMPLETED',
        'start_time': '2026-10-12 08:00:00',
      });
      expect(t.endTime, isNull);
      expect(t.collectionSeconds, 0);
    });

    test('history trip lookup by id never returns a different trip (null when absent)', () {
      final svc = src('lib/services/driver_route_history_service.dart');
      expect(svc.contains('static Future<DriverTrip?> fetchTripById'), isTrue);
      expect(svc.contains('if (!snap.exists || snap.value is! Map) return null;'), isTrue);
    });
  });

  group('Route History stays inside the Admin shell', () {
    test('Back returns to the section Route History was opened from', () {
      final r = RouteHistoryReturn(routeHistoryIndex: 7);
      r.enter(AdminDestinations.dashboard); // Quick Action from the dashboard home
      expect(r.backTarget, AdminDestinations.dashboard);
      r.enter(AdminDestinations.liveMap); // Fleet Status / live map -> Route History
      expect(r.backTarget, AdminDestinations.liveMap);
      r.enter(AdminDestinations.analytics); // Load History -> exact trip
      expect(r.backTarget, AdminDestinations.analytics);
    });

    test('opening Route History again from Route History keeps the original section', () {
      final r = RouteHistoryReturn(routeHistoryIndex: 7);
      r.enter(AdminDestinations.analytics);
      r.enter(AdminDestinations.routeHistory);
      expect(r.backTarget, AdminDestinations.analytics);
    });

    test('every Admin entry point opens it inside the shell (source structure)', () {
      final dash = src('lib/screens/admin_dashboard.dart');
      final tracking = src('lib/screens/track_trucks_screen.dart');
      final analytics = src('lib/screens/analytics_screen.dart');
      final history = src('lib/screens/route_history_screen.dart');

      expect(dash.contains('TrackTrucksScreen(isEmbedded: true, onOpenRouteHistory: _openRouteHistory'), isTrue);
      expect(dash.contains('AnalyticsScreen(isEmbedded: true, onOpenRouteHistory: _openRouteHistory'), isTrue);
      expect(tracking.contains('widget.onOpenRouteHistory'), isTrue);
      expect(analytics.contains('widget.onOpenRouteHistory'), isTrue);
      // the requested trip travels with the request
      expect(dash.contains('initialTripId: _routeHistoryTripId'), isTrue);
      expect(dash.contains('initialTrip: _routeHistoryTrip'), isTrue);
      // Route History -> Associated Load -> another trip stays in Route History
      expect(history.contains('_openTripInPlace(tripId: tripId, trip: trip)'), isTrue);
    });

    test('there is still ONE Route History implementation and one shell', () {
      final history = src('lib/screens/route_history_screen.dart');
      expect('class RouteHistoryScreen extends StatefulWidget'.allMatches(history).length, 1);
      final entry = src('lib/screens/route_history_entry.dart');
      expect(entry.contains('AdminDashboard(initialIndex: AdminDestinations.routeHistory)'), isTrue);
      expect(entry.contains('RouteHistoryScreen()'), isTrue);
      // The route is behind the sign-in RoleGate; RouteHistoryEntry still picks the shell by role.
      expect(src('lib/main.dart').contains("'/route_history': (context) => const RoleGate(roles: {'admin', 'driver', 'resident'}, child: RouteHistoryEntry())"), isTrue);
    });

    test('no second dashboard shell or extra Scaffold wraps the embedded screen', () {
      final dash = src('lib/screens/admin_dashboard.dart');
      expect('RouteHistoryScreen(key:'.allMatches(dash).length, 1);
      expect('class AdminDashboard extends StatefulWidget'.allMatches(dash).length, 1);
    });
  });
}
