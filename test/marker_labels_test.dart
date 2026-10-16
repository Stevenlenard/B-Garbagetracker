import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/marker_labels.dart';

Map<String, dynamic> feature(String truck, double lng, double lat, {String label = ''}) => {
      'type': 'Feature',
      'geometry': {
        'type': 'Point',
        'coordinates': [lng, lat],
      },
      'properties': {'type': 'TRUCK', 'truckId': truck, 'label': label.isEmpty ? truck : label},
    };

void main() {
  group('marker identification', () {
    test('label shows driver, truck and status', () {
      expect(
        MarkerLabels.single(truckId: 'GT-007', status: 'full', driverName: 'Juan Dela Cruz'),
        'GT-007 · Juan Dela Cruz\nFULL',
      );
    });

    test('generic driver name falls back to the truck id', () {
      expect(MarkerLabels.single(truckId: 'GT-007', status: 'ACTIVE', driverName: 'Driver'), 'GT-007\nACTIVE');
    });

    test('stale GPS is flagged in the label, connectivity untouched', () {
      final String l = MarkerLabels.forNode(
        {'status': 'ACTIVE', 'driver_name': 'Ana', 'gps_at': 1000, 'lastSeen': 1000000},
        truckId: 'GT-001',
        nowMs: 1000000,
      );
      expect(l, contains('GPS delayed'));
    });

    test('trucks on the same spot keep true coordinates and share one label', () {
      final Map<String, dynamic> a = feature('GT-002', 121.05, 13.75, label: 'B · GT-002\nACTIVE');
      final Map<String, dynamic> b = feature('GT-001', 121.05, 13.75, label: 'A · GT-001\nFULL');
      final Map<String, dynamic> c = feature('GT-003', 121.20, 13.90);
      MarkerLabels.mergeOverlapping([a, b, c]);
      expect(a['geometry']['coordinates'], [121.05, 13.75]);
      expect(b['geometry']['coordinates'], [121.05, 13.75]);
      // The first (by truck id) carries every truck at the spot.
      expect(b['properties']['label'], 'A · GT-001\nFULL\nB · GT-002\nACTIVE');
      expect(a['properties']['label'], '');
      expect(b['properties']['overlap_count'], '2');
      expect(c['properties']['label'], 'GT-003');
    });

    test('nearby but distinct trucks are not merged', () {
      final a = feature('GT-001', 121.05, 13.75);
      final b = feature('GT-002', 121.0501, 13.7501); // ~15 m apart
      MarkerLabels.mergeOverlapping([a, b]);
      expect(a['properties']['label'], 'GT-001');
      expect(b['properties']['label'], 'GT-002');
    });

    test('non-truck features are left alone', () {
      final Map<String, dynamic> me = {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [121.05, 13.75]},
        'properties': {'type': 'RESIDENT', 'label': 'YOU'},
      };
      final t = feature('GT-001', 121.05, 13.75);
      MarkerLabels.mergeOverlapping([me, t]);
      expect(me['properties']['label'], 'YOU');
      expect(t['properties']['label'], 'GT-001');
    });
  });

  group('fan-out of overlapping trucks (display only)', () {
    double metersBetween(List a, List b) {
      final double lat = ((a[1] as num) + (b[1] as num)) / 2;
      final double dy = ((a[1] as num) - (b[1] as num)) * 111320;
      final double dx = ((a[0] as num) - (b[0] as num)) * 111320 * math.cos(lat * math.pi / 180);
      return math.sqrt(dx * dx + dy * dy);
    }

    test('two trucks on the same spot are spread apart; true positions kept in properties', () {
      final a = feature('GT-007', 121.16, 13.95);
      final b = feature('GT-008', 121.16, 13.95);
      MarkerLabels.fanOutOverlapping([a, b], zoom: 16);
      final List ca = a['geometry']['coordinates'] as List;
      final List cb = b['geometry']['coordinates'] as List;
      // 2 x 16 px apart at zoom 16 (~1.16 m/px at this latitude) -> roughly 35-40 m.
      expect(metersBetween(ca, cb), inInclusiveRange(30, 45));
      expect(a['properties']['true_lng'], '121.16');
      expect(b['properties']['true_lat'], '13.95');
      expect(a['properties']['fanned'], 'true');
      expect(a['properties']['label'], 'GT-007\nGT-008', reason: 'one combined label on the first marker');
      expect(b['properties']['label'], '');
    });

    test('the spread follows the zoom: closer zoom = smaller offset on the ground', () {
      final a1 = feature('GT-007', 121.16, 13.95), b1 = feature('GT-008', 121.16, 13.95);
      final a2 = feature('GT-007', 121.16, 13.95), b2 = feature('GT-008', 121.16, 13.95);
      MarkerLabels.fanOutOverlapping([a1, b1], zoom: 14);
      MarkerLabels.fanOutOverlapping([a2, b2], zoom: 17);
      expect(metersBetween(a1['geometry']['coordinates'] as List, b1['geometry']['coordinates'] as List),
          greaterThan(metersBetween(a2['geometry']['coordinates'] as List, b2['geometry']['coordinates'] as List)));
    });

    test('trucks 40 m apart overlap when zoomed out but not when zoomed in', () {
      List<Map<String, dynamic>> pair() => [feature('GT-001', 121.1600, 13.95), feature('GT-002', 121.1600, 13.95036)]; // ~40 m
      final zoomedOut = pair();
      MarkerLabels.fanOutOverlapping(zoomedOut, zoom: 13);
      expect(zoomedOut[0]['properties']['fanned'], 'true');
      final zoomedIn = pair();
      MarkerLabels.fanOutOverlapping(zoomedIn, zoom: 18);
      expect(zoomedIn[0]['properties']['fanned'], isNull);
      expect(zoomedIn[0]['geometry']['coordinates'], [121.1600, 13.95], reason: 'not overlapping: untouched');
    });

    test('positions are stable: ordered by truck id, not by arrival order', () {
      final a = feature('GT-008', 121.16, 13.95), b = feature('GT-007', 121.16, 13.95);
      final c = feature('GT-007', 121.16, 13.95), d = feature('GT-008', 121.16, 13.95);
      MarkerLabels.fanOutOverlapping([a, b], zoom: 16);
      MarkerLabels.fanOutOverlapping([c, d], zoom: 16);
      expect(b['geometry']['coordinates'], c['geometry']['coordinates']);
      expect(a['geometry']['coordinates'], d['geometry']['coordinates']);
    });

    test('three trucks each get their own spot; non-truck features untouched', () {
      final t = [feature('GT-001', 121.16, 13.95), feature('GT-002', 121.16, 13.95), feature('GT-003', 121.16, 13.95)];
      final Map<String, dynamic> me = {
        'type': 'Feature',
        'geometry': {'type': 'Point', 'coordinates': [121.16, 13.95]},
        'properties': {'type': 'RESIDENT', 'label': 'YOU'},
      };
      MarkerLabels.fanOutOverlapping([...t, me], zoom: 16);
      final Set<String> spots = t.map((f) => (f['geometry']['coordinates'] as List).join(',')).toSet();
      expect(spots.length, 3);
      expect(me['geometry']['coordinates'], [121.16, 13.95]);
      expect(me['properties']['label'], 'YOU');
    });
  });
}
