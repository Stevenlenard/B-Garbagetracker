import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/marker_labels.dart';
import 'package:garbage_tracking_app/utils/truck_identity.dart';
import 'package:garbage_tracking_app/widgets/truck_legend.dart';

Map<String, dynamic> feature(String truck, double lng, double lat, {String status = 'ACTIVE'}) => <String, dynamic>{
      'type': 'Feature',
      'geometry': <String, dynamic>{
        'type': 'Point',
        'coordinates': <double>[lng, lat],
      },
      'properties': <String, dynamic>{
        'type': 'TRUCK',
        'truckId': truck,
        'status': status,
        ...TruckIdentity.markerProps(truck, status),
        'label': MarkerLabels.single(truckId: truck, status: status),
      },
    };

String src(String p) => File(p).readAsStringSync();

void main() {
  group('stable truck colours', () {
    test('a truck always has the same colour (case and spaces do not matter)', () {
      expect(TruckIdentity.hex('GT-007'), TruckIdentity.hex('gt-007'));
      expect(TruckIdentity.hex('GT-007'), TruckIdentity.hex('  GT-007 '));
      expect(TruckIdentity.argb('GT-007'), TruckIdentity.argb('gt-007'));
    });

    test('the colour depends only on the id, never on position or order', () {
      final List<String> a = <String>['GT-007', 'GT-008', 'GT-009'];
      final List<String> b = a.reversed.toList();
      final Map<String, String> colorsA = <String, String>{for (final String id in a) id: TruckIdentity.hex(id)};
      final Map<String, String> colorsB = <String, String>{for (final String id in b) id: TruckIdentity.hex(id)};
      expect(colorsA, colorsB);
      // asking again later (e.g. on another screen) gives the same answer
      expect(TruckIdentity.hex('GT-008'), colorsA['GT-008']);
    });

    test('neighbouring truck numbers never share a colour', () {
      final List<String> hexes = <String>[
        for (int n = 1; n <= TruckIdentity.palette.length; n++) TruckIdentity.hex('GT-${n.toString().padLeft(3, '0')}'),
      ];
      expect(hexes.toSet().length, hexes.length);
      expect(TruckIdentity.hex('GT-007') == TruckIdentity.hex('GT-008'), isFalse);
    });

    test('ids without a number still get a stable colour from the palette', () {
      final String h = TruckIdentity.hex('UNIT-ALPHA');
      expect(TruckIdentity.palette, contains(h));
      expect(TruckIdentity.hex('unit-alpha'), h);
    });

    test('the same function colours the marker and the route of a truck', () {
      expect(TruckIdentity.markerProps('GT-007', 'ACTIVE')['truckColor'], TruckIdentity.hex('GT-007'));
      expect(TruckIdentity.color('GT-007').toARGB32(), TruckIdentity.argb('GT-007'));
    });
  });

  group('status is a separate channel', () {
    test('status changes the ring, never the identity colour', () {
      final active = TruckIdentity.markerProps('GT-007', 'ACTIVE');
      final full = TruckIdentity.markerProps('GT-007', 'FULL');
      final paused = TruckIdentity.markerProps('GT-007', 'IDLE');
      final done = TruckIdentity.markerProps('GT-007', 'COMPLETED');
      expect(<String>{active['truckColor']!, full['truckColor']!, paused['truckColor']!, done['truckColor']!}.length, 1);
      expect(<String>{active['statusColor']!, full['statusColor']!, paused['statusColor']!, done['statusColor']!}.length, 4);
    });

    test('two trucks with the same status keep different identity colours', () {
      final a = TruckIdentity.markerProps('GT-007', 'ACTIVE');
      final b = TruckIdentity.markerProps('GT-008', 'ACTIVE');
      expect(a['statusColor'], b['statusColor']);
      expect(a['truckColor'], isNot(b['truckColor']));
    });
  });

  group('labels', () {
    test('the truck id is on the marker label, readable first', () {
      expect(MarkerLabels.single(truckId: 'GT-007', status: 'active'), 'GT-007\nACTIVE');
      expect(MarkerLabels.single(truckId: 'GT-007', status: 'FULL', driverName: 'Juan'), 'GT-007 · Juan\nFULL');
      expect(MarkerLabels.single(truckId: 'GT-008', status: 'IDLE', driverName: 'Driver'), 'GT-008\nIDLE');
    });
  });

  group('overlapping trucks', () {
    test('both stay selectable as nested rings; coordinates are never modified', () {
      final a = feature('GT-007', 121.0500, 13.7500);
      final b = feature('GT-008', 121.0500, 13.7500);
      final aCoords = List<double>.from(a['geometry']['coordinates'] as List);
      final bCoords = List<double>.from(b['geometry']['coordinates'] as List);

      MarkerLabels.mergeOverlapping(<Map<String, dynamic>>[a, b]);

      expect(a['geometry']['coordinates'], aCoords);
      expect(b['geometry']['coordinates'], bCoords);
      final int ra = int.parse(a['properties']['radius'] as String);
      final int rb = int.parse(b['properties']['radius'] as String);
      expect(ra, isNot(rb), reason: 'different ring sizes so both trucks can be seen and tapped');
      // the larger ring is drawn first (lower sort key), the smaller on top
      final int sa = int.parse(a['properties']['sortKey'] as String);
      final int sb = int.parse(b['properties']['sortKey'] as String);
      expect((ra > rb) == (sa < sb), isTrue);
      // identity colours stay different
      expect(a['properties']['truckColor'], isNot(b['properties']['truckColor']));
    });

    test('nearly identical coordinates (a few metres) are also treated as overlapping', () {
      final a = feature('GT-007', 121.050000, 13.750000);
      final b = feature('GT-008', 121.050010, 13.750010); // ~1.5 m apart
      MarkerLabels.mergeOverlapping(<Map<String, dynamic>>[a, b]);
      expect(a['properties']['overlap_count'], '2');
      expect(b['properties']['overlap_count'], '2');
    });

    test('combined label lists both truck ids on one spot', () {
      final a = feature('GT-007', 121.05, 13.75);
      final b = feature('GT-008', 121.05, 13.75, status: 'FULL');
      MarkerLabels.mergeOverlapping(<Map<String, dynamic>>[a, b]);
      final String all = '${a['properties']['label']}${b['properties']['label']}';
      expect(all, contains('GT-007'));
      expect(all, contains('GT-008'));
    });

    test('trucks that are far apart are left as single markers', () {
      final a = feature('GT-007', 121.05, 13.75);
      final b = feature('GT-008', 121.06, 13.76);
      MarkerLabels.mergeOverlapping(<Map<String, dynamic>>[a, b]);
      expect(a['properties']['radius'], '10');
      expect(b['properties']['radius'], '10');
    });
  });

  group('route identity (the same colour on every map)', () {
    test('live and history routes use the truck identity colour (source check)', () {
      final admin = src('lib/screens/track_trucks_screen.dart');
      final resident = src('lib/screens/resident_track_truck_screen.dart');
      final history = src('lib/screens/route_history_screen.dart');
      expect(admin.contains("props['truckColor'] = TruckIdentity.hex(tid)"), isTrue);
      expect(admin.contains('"line-color", ["get", "truckColor"]'), isTrue);
      expect(resident.contains('TruckIdentity.hex(truckId)'), isTrue);
      expect(history.contains('TruckIdentity.hex(trip.truckId)'), isTrue);
      // markers on every live surface
      expect(admin.contains('...TruckIdentity.markerProps(tid, status)'), isTrue);
      expect(resident.contains('...TruckIdentity.markerProps(tid, status)'), isTrue);
      expect(src('lib/widgets/mapbox_view.dart').contains('TruckIdentity.markerProps'), isTrue);
    });

    test('the selected truck route is highlighted above the others (admin sort key + width)', () {
      final admin = src('lib/screens/track_trucks_screen.dart');
      expect(admin.contains("props['sortKey'] = selected ? '10' : '0'"), isTrue);
      expect(admin.contains("props['width'] = selected ? '9' : '5'"), isTrue);
      expect(admin.contains('"line-sort-key"'), isTrue);
      final resident = src('lib/screens/resident_track_truck_screen.dart');
      expect(resident.contains('moveStyleLayer(layerId'), isTrue);
    });

    test('no new layers or sources are created for identity: existing layers are restyled', () {
      final admin = src('lib/screens/track_trucks_screen.dart');
      // one live route source/layer for all trucks (not one per truck)
      expect(admin.contains('static const String _liveRouteSourceId = "admin-live-routes-source"'), isTrue);
      expect('addSource(GeoJsonSource(id: _liveRouteSourceId'.allMatches(admin).length, 1);
    });
  });

  group('legend', () {
    testWidgets('shows each truck id with its identity colour and reports taps', (tester) async {
      String? tapped;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TruckLegend(
            truckIds: const <String>['gt-008', 'GT-007', 'GT-007'],
            selectedId: 'GT-008',
            onSelect: (String id) => tapped = id,
          ),
        ),
      ));
      expect(find.text('GT-007'), findsOneWidget, reason: 'duplicates collapse, ids normalized');
      expect(find.text('GT-008'), findsOneWidget);
      expect(find.text('Marker ring = status'), findsOneWidget);
      await tester.tap(find.text('GT-007'));
      expect(tapped, 'GT-007');
    });

    testWidgets('empty fleet renders nothing', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: TruckLegend(truckIds: <String>[]))));
      expect(find.text('Trucks'), findsNothing);
    });

    testWidgets('long fleets are summarized', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TruckLegend(truckIds: <String>[for (int i = 1; i <= 12; i++) 'GT-${i.toString().padLeft(3, '0')}'], maxVisible: 5),
          ),
        ),
      ));
      expect(find.text('+7 more'), findsOneWidget);
    });
  });
}
