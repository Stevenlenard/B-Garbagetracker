import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/models/driver_trip.dart';
import 'package:garbage_tracking_app/services/driver_route_history_service.dart';
import 'package:garbage_tracking_app/utils/truck_identity.dart';

String src(String path) => File(path).readAsStringSync().replaceAll(String.fromCharCodes(<int>[13, 10]), String.fromCharCode(10));

DriverTrip trip({String id = 'trip-1', String truck = 'GT-007', String driver = 'Steven Espaldon'}) => DriverTrip.fromJson({
      'trip_id': id,
      'driver_id': '15',
      'driver_name': driver,
      'truck_id': truck,
      'route_status': 'FULL',
      'start_time': '2026-10-12 08:00:00',
      'total_distance_km': 4.2,
      'raw_full_time': '2026-10-12 09:00:00',
      'has_full_event': true,
    });

void main() {
  group('Resident dashboard exposes Route History on every layout', () {
    final String dash = src('lib/screens/resident_dashboard.dart');

    test('web: sidebar entry "Route History"; phones: dashboard card', () {
      expect(dash.contains("_buildSidebarItem(4, Icons.route_rounded, 'Route History')"), isTrue);
      // Web/desktop reaches it from the sidebar; the card is only in the mobile (Android) home layout.
      expect('_buildActionCard("Route History"'.allMatches(dash).length, 1);
      expect(dash.indexOf('_buildActionCard("Route History"'), greaterThan(dash.indexOf('_buildSectionHeader("Collection History"')));
    });

    test('the Android home layout has its own entry (the root cause: it had none)', () {
      final int mobileHome = dash.indexOf('_buildSectionHeader("Collection History"');
      final int reports = dash.indexOf('_buildSectionHeader("Reports & Feedback"');
      expect(mobileHome, greaterThan(0));
      expect(mobileHome, lessThan(reports));
    });

    test('tapping the card selects the Route History section (index 4)', () {
      expect(dash.contains('else if (title.contains("Route") || title.contains("History") || title.contains("GIS"))'), isTrue);
      expect(dash.contains('setState(() => _selectedIndex = 4);'), isTrue);
      // index 4 of the IndexedStack is the shared Route History screen
      final int stack = dash.indexOf('IndexedStack(index: _selectedIndex');
      final int hist = dash.indexOf('RouteHistoryScreen(isEmbedded: true', stack);
      expect(hist, greaterThan(stack));
    });

    test('Back and Android system back return to the Resident dashboard', () {
      final String line = dash.split('\n').firstWhere((l) => l.contains('RouteHistoryScreen(isEmbedded: true'));
      expect(line.contains('_selectedIndex = 0'), isTrue);
      expect(dash.contains('if (_selectedIndex > 0)'), isTrue);
    });

    test('no Admin navigation is reachable from the Resident dashboard', () {
      expect(dash.contains('AdminDashboard'), isFalse);
      expect(dash.contains('admin_dashboard.dart'), isFalse);
      expect(dash.contains('AdminDestinations'), isFalse);
    });
  });

  group('read-only enforcement in the data and action flow', () {
    final String history = src('lib/screens/route_history_screen.dart');
    final String service = src('lib/services/driver_route_history_service.dart');

    test('destructive and export actions refuse residents (not only hidden)', () {
      expect(history.contains('void _confirmDeleteTrip(DriverTrip trip) {\n    if (_isResident) return;'), isTrue);
      expect(history.contains('Future<void> _performDeleteTrip(DriverTrip trip) async {\n    if (_isResident) return;'), isTrue);
      expect(history.contains('void _showExportTripMenu(BuildContext context) {\n    if (_isResident) return;'), isTrue);
    });

    test('load analytics and the driver filter are not available to residents', () {
      expect(history.contains('if (!_isResident) ...['), isTrue, reason: 'Load History link');
      // Residents (and drivers, who only ever see their own trips) get no driver filter.
      expect(history.contains('if ((_isResident || _isDriver) && label == "Driver") return const SizedBox.shrink();'), isTrue);
    });

    test('residents never request the account list for filters', () {
      final int guard = history.indexOf('if (_isResident) {\n        if (mounted) setState(() => _areaOptions = dynamicAreaNames);');
      final int usersCall = history.indexOf('await _apiService.getUsers();');
      expect(guard, greaterThan(0));
      expect(guard, lessThan(usersCall));
      // and the service skips its user-list truck lookup for residents
      expect(service.contains('if (!isResident) try {'), isTrue);
    });

    test('the service ignores a resident\'s driver filter and redacts driver identity', () {
      expect(service.contains('} else if (isResident) {\n      effectiveDriverId = null;'), isTrue);
      expect(service.contains('isResident ? tripsList.map(redactForResident).toList() : tripsList'), isTrue);
    });

    test('residents see the driver name (as on the live map) but never the account id', () {
      final DriverTrip r = DriverRouteHistoryService.redactForResident(trip());
      expect(r.driverName, 'Steven Espaldon');
      expect(r.driverId.toString(), '0');
      expect(DriverRouteHistoryService.redactForResident(trip(driver: '')).driverName, 'Collection crew',
          reason: 'no recorded name: neutral label');
      expect(r.tripId, 'trip-1');
      expect(r.truckId, 'GT-007');
      expect(r.totalDistanceKm, 4.2);
      expect(r.routeStatus, 'FULL');
      expect(r.fullTime, isNotNull);
    });

    test('redaction leaves every other trip detail untouched', () {
      final DriverTrip original = trip(id: 'a', truck: 'GT-009');
      final DriverTrip r = DriverRouteHistoryService.redactForResident(original);
      expect(r.startTime, original.startTime);
      expect(r.weightKg, original.weightKg);
      expect(r.points.length, original.points.length);
      expect(r.hasFullEvent, original.hasFullEvent);
    });
  });

  group('truck and trip identities', () {
    test('each resident-visible trip keeps its own truck id, trip id and colour', () {
      final List<DriverTrip> visible = <DriverTrip>[
        trip(id: 't-7', truck: 'GT-007'),
        trip(id: 't-8', truck: 'GT-008'),
      ].map(DriverRouteHistoryService.redactForResident).toList();
      expect(visible.map((t) => t.tripId), ['t-7', 't-8']);
      expect(visible.map((t) => t.truckId), ['GT-007', 'GT-008']);
      expect(TruckIdentity.hex(visible[0].truckId), isNot(TruckIdentity.hex(visible[1].truckId)));
      // the same colour the Admin and live maps use for that truck
      expect(TruckIdentity.hex(visible[0].truckId), TruckIdentity.hex('gt-007'));
    });

    test('Route History draws the route in the truck identity colour', () {
      expect(src('lib/screens/route_history_screen.dart').contains('TruckIdentity.hex(trip.truckId)'), isTrue);
    });
  });

  group('loading, empty and failed requests', () {
    test('every source failing is an ERROR, not an empty history', () {
      const r = RouteHistoryResult(trips: <DriverTrip>[], failedSources: <String>['firebase', 'mysql'], totalSources: 2);
      expect(r.isError, isTrue);
      expect(r.isPartial, isFalse);
    });

    test('one source failing is a partial warning that keeps the other trips', () {
      final r = RouteHistoryResult(trips: <DriverTrip>[trip()], failedSources: const <String>['mysql'], totalSources: 2);
      expect(r.isError, isFalse);
      expect(r.isPartial, isTrue);
      expect(r.trips.length, 1);
    });

    test('a healthy empty result is a genuine empty history', () {
      const r = RouteHistoryResult(trips: <DriverTrip>[], failedSources: <String>[], totalSources: 2);
      expect(r.isError, isFalse);
      expect(r.isPartial, isFalse);
      expect(r.trips, isEmpty);
    });

    test('the screen shows loading, error+retry and the required empty text (source check)', () {
      final String history = src('lib/screens/route_history_screen.dart');
      expect(history.contains('_isLoadingTrips\n                      ? const Center(child: CircularProgressIndicator'), isTrue);
      expect(history.contains('Widget _buildLoadErrorView()'), isTrue);
      expect(history.contains('onPressed: _fetchTrips,\n              icon: const Icon(Icons.refresh_rounded'), isTrue);
      // One shared empty state, used by both trip lists (desktop panel and phone sheet).
      expect(history.contains('No collection route history available.'), isTrue);
      expect('_emptyTrips()'.allMatches(history).length, greaterThanOrEqualTo(3), reason: 'definition + both lists');
      // an error returns before the trip list is replaced, so it cannot look empty
      final int errorReturn = history.indexOf('if (result.isError) {');
      final int assign = history.indexOf('_trips = trips;');
      expect(errorReturn, greaterThan(0));
      expect(errorReturn, lessThan(assign));
    });
  });

  group('Admin Route History is unchanged', () {
    test('the Admin shell still hosts the same screen at index 7 with its own back target', () {
      final String admin = src('lib/screens/admin_dashboard.dart');
      expect(admin.contains('RouteHistoryScreen(key: ValueKey(\'route-history-'), isTrue);
      expect(admin.contains('_routeReturn.backTarget'), isTrue);
    });

    test('admin and driver keep export, delete and the driver filter', () {
      final String history = src('lib/screens/route_history_screen.dart');
      expect(history.contains("_currentUser?.role.toLowerCase() != 'resident'"), isTrue);
      // redaction is applied only for residents
      final String service = src('lib/services/driver_route_history_service.dart');
      expect(service.contains('final bool isResident = role == \'resident\';'), isTrue);
    });

    test('there is still ONE Route History screen implementation', () {
      expect('class RouteHistoryScreen extends StatefulWidget'.allMatches(src('lib/screens/route_history_screen.dart')).length, 1);
    });
  });
}
