import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/screens/collection_route_optimization_screen.dart';
import 'package:garbage_tracking_app/utils/collection_status.dart';
import 'package:garbage_tracking_app/utils/collection_visits.dart';
import 'package:garbage_tracking_app/utils/path_comparison.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------- fixtures (synthetic, test only)

const AreaGeofence purok2 = AreaGeofence(name: 'Purok 2', lat: 13.9500, lng: 121.1600, radiusM: 60);
const AreaGeofence riverside = AreaGeofence(name: 'Riverside', lat: 13.9550, lng: 121.1650, radiusM: 60);
const AreaGeofence paraiso = AreaGeofence(name: 'Paraiso', lat: 13.9600, lng: 121.1700, radiusM: 60);
const List<AreaGeofence> areas = <AreaGeofence>[purok2, riverside, paraiso];

/// 2026-10-15 10:00 Asia/Manila.
final DateTime now = DateTime.utc(2026, 10, 15, 2);
int msAt(DateTime d) => d.millisecondsSinceEpoch;

/// A trip as `driver_routes/{trip}` stores it. [plan] items: AreaGeofence = stay (6 fixes, 20 s
/// apart = 100 s), List<double> [lat, lng] = travel there in 10 fixes (20 s apart).
Map<String, Object?> trip(int startMs, List<Object> plan, {String driver = '7', String truck = 'GT-001', int stepMs = 20000}) {
  final Map<String, Object?> route = <String, Object?>{};
  int t = startMs;
  double lat = (plan.first is AreaGeofence) ? (plan.first as AreaGeofence).lat : (plan.first as List<double>)[0];
  double lng = (plan.first is AreaGeofence) ? (plan.first as AreaGeofence).lng : (plan.first as List<double>)[1];
  int i = 0;
  void fix(double la, double lo) {
    route['p${i++}'] = <String, Object?>{'lat': la, 'lng': lo, 'timestamp': t, 'status': 'ACTIVE', 'accuracy': 8.0};
    t += stepMs;
  }

  for (final Object step in plan) {
    final double toLat = step is AreaGeofence ? step.lat : (step as List<double>)[0];
    final double toLng = step is AreaGeofence ? step.lng : (step as List<double>)[1];
    for (int k = 1; k <= 10; k++) {
      fix(lat + (toLat - lat) * k / 10, lng + (toLng - lng) * k / 10);
    }
    lat = toLat;
    lng = toLng;
    if (step is AreaGeofence) {
      for (int k = 0; k < 6; k++) {
        fix(lat + k * 0.00001, lng);
      }
    }
  }
  return <String, Object?>{'driver_id': driver, 'truck_id': truck, 'route': route};
}

CollectionVisit visit(String area, DateTime at) =>
    CollectionVisit(tripId: 't', area: area, firstFixMs: msAt(at), lastFixMs: msAt(at) + 120000, fixes: 6);

class FakeSource implements CollectionDataSource {
  FakeSource(this.data);
  CollectionData data;
  final List<StreamController<CollectionData>> listeners = <StreamController<CollectionData>>[];
  int watches = 0;

  @override
  Stream<CollectionData> watch({required DateTime start, required DateTime end}) {
    watches++;
    late StreamController<CollectionData> c;
    c = StreamController<CollectionData>(onListen: () => c.add(data), onCancel: () => listeners.remove(c));
    listeners.add(c);
    return c.stream;
  }

  void push(CollectionData d) {
    data = d;
    for (final StreamController<CollectionData> c in listeners) {
      c.add(d);
    }
  }
}

void main() {
  // ---------------------------------------------------------------- status rules
  group('collection status bands (Asia/Manila days)', () {
    AreaCollectionStatus st(List<CollectionVisit> v, {DateTime? at, List<int> partial = const <int>[], List<AreaActivity> act = const <AreaActivity>[]}) =>
        CollectionStatus.evaluate(area: 'Purok 2', confirmedVisits: v, partialRecordsMs: partial, activity: act, nowMs: msAt(at ?? now));

    test('0-6 days recent, 7-13 aging, 14+ stale', () {
      expect(st(<CollectionVisit>[visit('Purok 2', now.subtract(const Duration(days: 6)))]).band, CollectionBand.recent);
      final AreaCollectionStatus seven = st(<CollectionVisit>[visit('Purok 2', now.subtract(const Duration(days: 7)))]);
      expect(seven.band, CollectionBand.aging);
      expect(seven.label, '7 days since verified visit');
      expect(st(<CollectionVisit>[visit('Purok 2', now.subtract(const Duration(days: 13)))]).band, CollectionBand.aging);
      expect(st(<CollectionVisit>[visit('Purok 2', now.subtract(const Duration(days: 14)))]).band, CollectionBand.stale);
    });

    test('days are Manila calendar days, not UTC and not 24-hour blocks', () {
      // 2026-10-14 16:30 UTC = Oct 15 00:30 Manila -> same Manila day as "now" (10:00).
      final AreaCollectionStatus s = st(<CollectionVisit>[visit('Purok 2', DateTime.utc(2026, 10, 14, 16, 30))]);
      expect(s.daysSince, 0);
      expect(s.label, 'Visited today');
      // Oct 14 23:50 Manila (15:50 UTC) is yesterday even though < 24 h ago.
      expect(st(<CollectionVisit>[visit('Purok 2', DateTime.utc(2026, 10, 14, 15, 50))]).daysSince, 1);
      expect(CollectionStatus.formatManila(msAt(DateTime.utc(2026, 10, 14, 16, 30))), 'Oct 15, 2026, 12:30 AM');
    });

    test('status ages with time alone (no new record)', () {
      final List<CollectionVisit> v = <CollectionVisit>[visit('Purok 2', now.subtract(const Duration(days: 5)))];
      expect(st(v).band, CollectionBand.recent);
      expect(st(v, at: now.add(const Duration(days: 2))).band, CollectionBand.aging);
      expect(st(v, at: now.add(const Duration(days: 9))).band, CollectionBand.stale);
      expect(CollectionStatus.nextBoundary(now), DateTime.utc(2026, 10, 15, 16), reason: 'next Manila midnight');
    });

    test('unknown stays unknown: no date is invented and it is not called missed', () {
      final AreaCollectionStatus s = st(const <CollectionVisit>[]);
      expect(s.band, CollectionBand.unknown);
      expect(s.lastConfirmedMs, isNull);
      expect(s.daysSince, isNull);
      expect(s.explanation(const CollectionStatusConfig()), contains('not proof of a missed collection'));
      expect(s.matches(StatusFilter.sevenPlus, const CollectionStatusConfig()), isFalse);
      expect(s.matches(StatusFilter.fourteenPlus, const CollectionStatusConfig()), isFalse);
    });

    test('partial: own state without a full visit; a newer partial does not change the band', () {
      expect(st(const <CollectionVisit>[], partial: <int>[msAt(now)]).band, CollectionBand.partialOnly);
      final AreaCollectionStatus s = st(<CollectionVisit>[visit('Purok 2', now.subtract(const Duration(days: 9)))],
          partial: <int>[msAt(now.subtract(const Duration(days: 1)))]);
      expect(s.band, CollectionBand.aging);
      expect(s.hasNewerPartial, isTrue);
      expect(s.daysSince, 9);
    });

    test('weekly-progress marks and approach alerts are activity, never a confirmed collection', () {
      final Map<String, List<AreaActivity>> act = CollectionStatus.activityFromWeeklyProgress(<String, Object?>{
        '2026-W42': <String, Object?>{
          '7': <String, Object?>{
            'areas': <String, Object?>{
              'Purok 2': <String, Object?>{'completed': true, 'completionSource': 'GPS_PROXIMITY', 'timestamp': msAt(now)},
              'Riverside': <String, Object?>{'completed': true, 'completionSource': 'MANUAL_ALERT', 'timestamp': msAt(now)},
              'Paraiso': <String, Object?>{'completed': true, 'completionSource': 'SIMULATION', 'timestamp': msAt(now)},
            }
          }
        }
      }, (String k) => k);
      final AreaCollectionStatus s = st(const <CollectionVisit>[], act: act['Purok 2']!);
      expect(s.band, CollectionBand.unknown);
      expect(s.latestActivity?.source, contains('GPS proximity'));
      expect(act['Riverside']!.single.source, 'Driver approach alert');
      expect(act.containsKey('Paraiso'), isFalse, reason: 'simulation ignored');
    });

    test('labels say visit (truck presence), never collected', () {
      for (final AreaCollectionStatus s in <AreaCollectionStatus>[
        st(<CollectionVisit>[visit('Purok 2', now)]),
        st(<CollectionVisit>[visit('Purok 2', now.subtract(const Duration(days: 9)))]),
        st(const <CollectionVisit>[]),
      ]) {
        expect(s.label.toLowerCase(), isNot(contains('collected')));
        expect(s.label.toLowerCase(), isNot(contains('confirmed collection')));
      }
    });

    test('labels carry text and symbol, not colour alone', () {
      expect(st(<CollectionVisit>[visit('Purok 2', now)]).symbol, '✓');
      expect(st(<CollectionVisit>[visit('Purok 2', now.subtract(const Duration(days: 20)))]).symbol, '◷');
      expect(st(const <CollectionVisit>[]).symbol, '?');
    });
  });

  group('completion evidence', () {
    test('a quick GPS pass through an area is NOT a confirmed visit', () {
      final Map<String, Object?> pass = trip(msAt(now.subtract(const Duration(hours: 3))), <Object>[
        <double>[13.9490, 121.1590],
        <double>[13.9510, 121.1610], // straight through Purok 2 at 20 s steps, no stay
      ]);
      final VisitSummary v = CollectionVisits.detect(
          trips: <String, Object?>{'pass': pass}, areas: areas, start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 15));
      expect(v.visits, isEmpty);
      final AreaCollectionStatus s = CollectionStatus.evaluate(area: 'Purok 2', confirmedVisits: v.visits, nowMs: msAt(now));
      expect(s.band, CollectionBand.unknown);
    });

    test('a 100 s stay while ACTIVE is a confirmed visit', () {
      final VisitSummary v = CollectionVisits.detect(
          trips: <String, Object?>{'t1': trip(msAt(now.subtract(const Duration(hours: 3))), <Object>[purok2])},
          areas: areas, start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 15));
      expect(v.visits.map((CollectionVisit x) => x.area), <String>['Purok 2']);
    });
  });

  // ---------------------------------------------------------------- path comparison
  group('historical path comparison', () {
    final DateTime d1 = now.subtract(const Duration(days: 3));
    final DateTime d2 = now.subtract(const Duration(days: 2));
    PathAnalysis analyse(Map<String, Object?> trips) =>
        PathComparisonEngine.analyze(trips: trips, areas: areas, start: DateTime(2026, 10, 1), end: DateTime(2026, 10, 15));

    test('same coverage: shortest recorded path, its stop order and the median baseline', () {
      final PathAnalysis a = analyse(<String, Object?>{
        'direct': trip(msAt(d1), <Object>[purok2, riverside, paraiso]),
        'detour': trip(msAt(d2), <Object>[purok2, <double>[13.9500, 121.1700], riverside, paraiso]),
      });
      expect(a.comparisons, hasLength(1));
      final PathComparison c = a.comparisons.single;
      expect(c.shortest.tripId, 'direct');
      expect(c.shortest.areaOrder, <String>['Purok 2', 'Riverside', 'Paraiso']);
      expect(c.paths.last.distanceKm, greaterThan(c.shortest.distanceKm));
      expect(c.savingVsMedianKm, greaterThan(0));
      expect(c.basis, contains('check current road access'));
      // Time inside areas is separated from travel time.
      expect(c.shortest.inAreaMs, greaterThan(0));
      expect(c.shortest.travelMs + c.shortest.inAreaMs, c.shortest.durationMs);
    });

    test('different coverage is not compared: insufficient history, no recommendation', () {
      final PathAnalysis a = analyse(<String, Object?>{
        'a': trip(msAt(d1), <Object>[purok2, riverside, paraiso]),
        'b': trip(msAt(d2), <Object>[purok2, riverside]),
      });
      expect(a.comparisons, isEmpty);
      expect(a.validPaths, hasLength(2));
    });

    test('unreliable traces are excluded with the reason', () {
      final Map<String, Object?> gap = trip(msAt(d1), <Object>[purok2, riverside, paraiso]);
      final Map route = gap['route']! as Map;
      int k = 0;
      for (final Object? p in route.values) {
        if (k++ > 20) (p! as Map)['timestamp'] = ((p as Map)['timestamp'] as int) + 10 * 60000; // 10-min hole
      }
      final Map<String, Object?> jump = trip(msAt(d2), <Object>[purok2, riverside, paraiso]);
      final Map jumpPoint = ((jump['route']! as Map)['p20']! as Map); // a transit fix between areas
      jumpPoint['lat'] = (jumpPoint['lat'] as double) + 0.01; // ~1.1 km away in 20 s
      final PathAnalysis a = analyse(<String, Object?>{
        'gap': gap,
        'jump': jump,
        'short': trip(msAt(d1), <Object>[purok2, riverside], stepMs: 20000)..['route'] = <String, Object?>{},
        'one': trip(msAt(d2), <Object>[purok2]),
      });
      expect(a.validPaths, isEmpty);
      expect(a.rejected.keys.join(' '), allOf(contains('gap'), contains('jump'), contains('fewer than 2')));
    });

    test('simulation trips are ignored', () {
      final PathAnalysis a = analyse(<String, Object?>{
        'sim': trip(msAt(d1), <Object>[purok2, riverside])..['is_simulation'] = true,
      });
      expect(a.tripsExamined, 0);
    });
  });

  // ---------------------------------------------------------------- screen
  group('screen (no map, fake records)', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    CollectionData data(Map<String, Object?> trips) => CollectionData(areas: areas, trips: trips, weeklyProgress: null);
    final Map<String, Object?> twoComparable = <String, Object?>{
      'direct': trip(msAt(now.subtract(const Duration(days: 3))), <Object>[purok2, riverside, paraiso]),
      'detour': trip(msAt(now.subtract(const Duration(days: 9))), <Object>[purok2, <double>[13.9500, 121.1700], riverside, paraiso]),
    };

    Future<FakeSource> pump(WidgetTester t, String role, Map<String, Object?> trips, {Size size = const Size(1366, 900), DateTime Function()? clock}) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final FakeSource src = FakeSource(data(trips));
      await t.pumpWidget(MaterialApp(
        home: CollectionRouteOptimizationScreen(role: role, userId: '7', source: src, clock: clock ?? () => now, showMap: false),
      ));
      await t.pump();
      return src;
    }

    testWidgets('resident: status, details and history; no planning or comparison', (WidgetTester t) async {
      await pump(t, 'resident', twoComparable);
      expect(find.text('Collection Route Optimization'), findsOneWidget);
      expect(find.text('Visited 3 days ago'), findsNWidgets(3));
      expect(find.text('Route from past trips'), findsNothing);
      expect(find.byKey(const ValueKey<String>('select-reference-path')), findsNothing);
      await t.tap(find.byKey(const ValueKey<String>('area-Riverside')));
      await t.pump();
      expect(find.byKey(const ValueKey<String>('area-details')), findsOneWidget);
      expect(find.text('Last verified visit'), findsOneWidget);
      expect(find.textContaining('GT-001'), findsNothing, reason: 'residents see dates, not truck/driver details');
    });

    testWidgets('driver: comparison of own trips and the reference-path action', (WidgetTester t) async {
      await pump(t, 'driver', twoComparable);
      expect(find.text('Route from past trips'), findsOneWidget);
      expect(find.textContaining('Stop order of the shortest trip: Purok 2 → Riverside → Paraiso'), findsOneWidget);
      await t.ensureVisible(find.byKey(const ValueKey<String>('select-reference-path')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey<String>('select-reference-path')));
      await t.pump();
      await t.scrollUntilVisible(find.textContaining('Your reference path'), 200, scrollable: find.byType(Scrollable).last);
      expect(find.textContaining('Your reference path'), findsOneWidget);
      final SharedPreferences p = await SharedPreferences.getInstance();
      expect(p.getString('collection_reference_path_v1'), 'direct');
    });

    testWidgets('driver: trips of other drivers are not used', (WidgetTester t) async {
      await pump(t, 'driver', <String, Object?>{
        for (final MapEntry<String, Object?> e in twoComparable.entries) e.key: (Map<String, Object?>.from(e.value! as Map)..['driver_id'] = '99'),
      });
      // Not enough of the driver's own history: the section is not shown at all.
      expect(find.byKey(const ValueKey<String>('route-from-past-trips')), findsNothing);
      expect(find.text('Visited 3 days ago'), findsNWidgets(3));
    });

    testWidgets('admin: comparison without the driver planning action', (WidgetTester t) async {
      await pump(t, 'admin', twoComparable);
      expect(find.text('Route from past trips'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('select-reference-path')), findsNothing);
    });

    testWidgets('insufficient history: no comparison section, status stays available', (WidgetTester t) async {
      await pump(t, 'admin', <String, Object?>{'only': twoComparable['direct']});
      expect(find.byKey(const ValueKey<String>('route-from-past-trips')), findsNothing);
      expect(find.textContaining('Insufficient'), findsNothing);
      expect(find.text('Visited 3 days ago'), findsNWidgets(3));
    });

    testWidgets('filters: 7+ and 14+ days', (WidgetTester t) async {
      await pump(t, 'resident', <String, Object?>{
        'old': trip(msAt(now.subtract(const Duration(days: 15))), <Object>[purok2]),
        'mid': trip(msAt(now.subtract(const Duration(days: 8))), <Object>[riverside]),
      });
      expect(find.text('No verified visit record'), findsOneWidget); // Paraiso
      await t.tap(find.widgetWithText(FilterChip, '14+ days'));
      await t.pump();
      expect(find.byKey(const ValueKey<String>('area-Purok 2')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('area-Riverside')), findsNothing);
      expect(find.byKey(const ValueKey<String>('area-Paraiso')), findsNothing, reason: 'unknown is not 14+');
      await t.tap(find.widgetWithText(FilterChip, '7+ days'));
      await t.pump();
      expect(find.byKey(const ValueKey<String>('area-Riverside')), findsOneWidget);
    });

    testWidgets('live update: a new verified visit updates the marker list (debounced)', (WidgetTester t) async {
      final FakeSource src = await pump(t, 'resident', <String, Object?>{});
      expect(find.text('No verified visit record'), findsNWidgets(3));
      src.push(data(<String, Object?>{'new': trip(msAt(now.subtract(const Duration(hours: 2))), <Object>[paraiso])}));
      await t.pump(const Duration(seconds: 3));
      expect(find.text('Visited today'), findsOneWidget);
      expect(src.watches, 1, reason: 'one subscription');
    });

    testWidgets('ageing without writes on resume; listener cancelled on close', (WidgetTester t) async {
      DateTime clock = now;
      final FakeSource src = await pump(t, 'resident',
          <String, Object?>{'t': trip(msAt(now.subtract(const Duration(days: 5))), <Object>[purok2])}, clock: () => clock);
      expect(find.text('Visited 5 days ago'), findsOneWidget);
      clock = now.add(const Duration(days: 3));
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pump();
      expect(find.text('8 days since verified visit'), findsOneWidget);
      await t.pumpWidget(const MaterialApp(home: SizedBox()));
      await t.pump();
      expect(src.listeners, isEmpty, reason: 'subscription ended with the screen');
    });

    testWidgets('weekly marks keyed by area id show as activity, not as collection', (WidgetTester t) async {
      t.view.physicalSize = const Size(1366, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final FakeSource src = FakeSource(CollectionData(
        areas: areas,
        trips: const <String, Object?>{},
        areaIdToName: const <String, String>{'p7': 'Riverside'},
        weeklyProgress: <String, Object?>{
          'w': <String, Object?>{
            '7': <String, Object?>{
              'areas': <String, Object?>{
                'p7': <String, Object?>{'completed': true, 'completionSource': 'MANUAL_ALERT', 'timestamp': msAt(now)},
              }
            }
          }
        },
      ));
      await t.pumpWidget(MaterialApp(home: CollectionRouteOptimizationScreen(role: 'admin', source: src, clock: () => now, showMap: false)));
      await t.pump();
      await t.tap(find.byKey(const ValueKey<String>('area-Riverside')));
      await t.pump();
      expect(find.text('No verified visit record'), findsNWidgets(3));
      expect(find.textContaining('Driver approach alert; not a verified visit'), findsOneWidget);
    });

    Future<void> pumpWithMap(WidgetTester t, String role, Size size) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: CollectionRouteOptimizationScreen(role: role, userId: '7', source: FakeSource(data(twoComparable)), clock: () => now),
      ));
      await t.pump();
    }

    testWidgets('the page opens on Today and says how many areas were collected that day', (WidgetTester t) async {
      await pumpWithMap(t, 'admin', const Size(1400, 900));
      expect(t.takeException(), isNull);
      expect(find.text('Today'), findsOneWidget);
      expect(find.textContaining('Collection status · Today'), findsOneWidget);
      expect(find.textContaining('collected today'), findsOneWidget);
      expect(find.text('Live'), findsOneWidget);
    });

    testWidgets('phone with map: draggable bottom summary, no overflow', (WidgetTester t) async {
      await pumpWithMap(t, 'driver', const Size(390, 844));
      expect(t.takeException(), isNull);
      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
      expect(find.textContaining('Collection status'), findsOneWidget);
      expect(find.text('Recent'), findsOneWidget, reason: 'status counts double as the legend');
      await t.drag(find.textContaining('Collection status'), const Offset(0, -400));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('Recently visited'), findsOneWidget, reason: 'grouped list after dragging the sheet up');
    });

    testWidgets('desktop with map: compact card expands into the grouped list and can be moved', (WidgetTester t) async {
      await pumpWithMap(t, 'admin', const Size(1366, 900));
      expect(t.takeException(), isNull);
      expect(find.text('Recently visited'), findsNothing, reason: 'compact summary first');
      await t.tap(find.byKey(const ValueKey<String>('collection-panel-toggle')));
      await t.pumpAndSettle();
      expect(find.text('Recently visited'), findsOneWidget);
      final Offset before = t.getTopLeft(find.textContaining('Collection status'));
      await t.drag(find.textContaining('Collection status'), const Offset(300, -40));
      await t.pumpAndSettle();
      expect(t.getTopLeft(find.textContaining('Collection status')), isNot(before));
      expect(t.takeException(), isNull);
    });

    testWidgets('narrow phone layout renders without overflow', (WidgetTester t) async {
      await pump(t, 'driver', twoComparable, size: const Size(360, 780));
      expect(t.takeException(), isNull);
      expect(find.text('Route from past trips'), findsOneWidget);
    });
  });

  group('no routing service', () {
    test('the feature sources use no Mapbox routing API and no HTTP client', () {
      for (final String f in <String>[
        'lib/screens/collection_route_optimization_screen.dart',
        'lib/utils/collection_status.dart',
        'lib/utils/path_comparison.dart',
      ]) {
        final String src = File(f).readAsStringSync();
        expect(src.contains('api.mapbox.com'), isFalse, reason: f);
        expect(src.contains('package:dio'), isFalse, reason: f);
        expect(src.contains('package:http'), isFalse, reason: f);
        expect(src.contains('RouteOptimizationService'), isFalse, reason: f);
      }
    });
  });
}
