import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/area_eta.dart';
import 'package:garbage_tracking_app/utils/stationary_excursion.dart';

/// Who may be alerted, and when. Residents are alerted only for the areas of the driver's assignment of the day, and never
/// from GPS wander around a phone that stayed in one place (3 Nov 2026: a phone on a table for 3 hours "approached"
/// Central and Ayala Highway and "arrived" at Ayala, residents of areas the truck was not collecting got ETA alerts).
void main() {
  const double lat0 = 13.95, lng0 = 121.16;
  final double kLng = math.cos(lat0 * math.pi / 180);
  final Map<String, dynamic> fixture = jsonDecode(File('test/fixtures/nov3_stationary_trip.json').readAsStringSync()) as Map<String, dynamic>;
  final List<List<num>> fx = <List<num>>[for (final dynamic r in fixture['fixes'] as List) (r as List).cast<num>()];
  final int base = DateTime(2026, 11, 3, 10, 3, 11).millisecondsSinceEpoch;

  double lat(List<num> r) => lat0 + r[2] / 111320;
  double lng(List<num> r) => lng0 + r[1] / (111320 * kLng);
  int ts(List<num> r) => base + r[0].toInt();

  group('StayHold on the real 3 Nov 2026 fixes', () {
    final StayHold hold = StayHold();
    final List<bool> held = <bool>[for (final List<num> r in fx) hold.offer(lat(r), lng(r), ts(r))];
    int minutes(int i) => fx[i][0] ~/ 60000;

    test('the walk from the start to the apartment is never held', () {
      for (int i = 0; i < fx.length; i++) {
        if (minutes(i) < 37) expect(held[i], isFalse, reason: 'fix $i at ${minutes(i)} min');
      }
    });

    test('once the phone has stayed 10+ minutes, the wander around it is held (the bursts of 12:28-12:43 and 12:59-13:20)', () {
      final List<int> burst = <int>[
        for (int i = 0; i < fx.length; i++)
          if ((minutes(i) >= 144 && minutes(i) <= 160) || (minutes(i) >= 176 && minutes(i) <= 197)) i,
      ];
      expect(burst.length, greaterThan(300));
      final int heldCount = burst.where((int i) => held[i]).length;
      // ignore: avoid_print
      print('Nov 3 bursts: ${burst.length} fixes, ${heldCount} held');
      expect(heldCount / burst.length, greaterThan(0.95));
    });

    test('no fix of the bursts that could touch an area near the apartment (100 m geofence) gets through', () {
      // an area 186 m from the stay, towards where the bursts reached (Central (Purok 1) is 186 m from the apartment)
      final List<int> far = <int>[for (int i = 0; i < fx.length; i++) if (minutes(i) >= 144) i];
      final int farthest = far.reduce((int a, int b) {
        double d(int i) => math.sqrt(math.pow(fx[i][1] + 300, 2) + math.pow(fx[i][2] + 300, 2)).toDouble();
        return d(a) > d(b) ? a : b;
      });
      final double ux = fx[farthest][1] + 300, uy = fx[farthest][2] + 300;
      final double len = math.sqrt(ux * ux + uy * uy);
      final double ax = -300 + ux / len * 186, ay = -300 + uy / len * 186;
      final List<int> touching = <int>[
        for (final int i in far)
          if (math.sqrt(math.pow(fx[i][1] - ax, 2) + math.pow(fx[i][2] - ay, 2)) <= 100) i,
      ];
      expect(touching, isNotEmpty, reason: 'the bursts do reach that area, so without the hold it would be alerted');
      final List<int> alerted = touching.where((int i) => !held[i]).toList();
      expect(alerted.length, lessThanOrEqualTo(touching.length ~/ 20), reason: 'at most a few stray fixes get through');
    });
  });

  group('StayHold on genuine movement', () {
    double north(double m) => lat0 + m / 111320;
    List<bool> run(StayHold h, Iterable<({double m, int sec})> fixes) => <bool>[for (final f in fixes) h.offer(north(f.m), lng0, 1700000000000 + f.sec * 1000)];

    test('a truck that stays 15 minutes and then drives away is released within two fixes of passing 300 m', () {
      final StayHold h = StayHold();
      final List<bool> stay = run(h, <({double m, int sec})>[for (int s = 0; s <= 900; s += 30) (m: (s % 3) * 2.0, sec: s)]);
      expect(stay.sublist(0, 20).every((b) => !b), isTrue, reason: 'no hold during the first 10 minutes');
      expect(stay.last, isTrue);
      final List<bool> leave = run(h, <({double m, int sec})>[for (int i = 1; i <= 12; i++) (m: i * 50.0, sec: 900 + i * 6)]);
      // inside 300 m (6 fixes) it is still held, then two fixes beyond 300 m release it
      expect(leave.take(6).every((b) => b), isTrue);
      expect(leave.last, isFalse);
      expect(leave.sublist(7).any((b) => b), isFalse, reason: 'released for good once it has left');
    });

    test('a normal collection stop (3 minutes) never holds anything', () {
      final StayHold h = StayHold();
      final List<bool> r = run(h, <({double m, int sec})>[for (int s = 0; s <= 180; s += 20) (m: 0, sec: s), for (int i = 1; i <= 20; i++) (m: i * 20.0, sec: 180 + i * 5)]);
      expect(r.every((b) => !b), isTrue);
    });

    test('driving all day with short stops is never held', () {
      final StayHold h = StayHold();
      final List<({double m, int sec})> fixes = <({double m, int sec})>[];
      double m = 0;
      int sec = 0;
      for (int leg = 0; leg < 10; leg++) {
        for (int i = 0; i < 20; i++) {
          m += 15;
          sec += 5;
          fixes.add((m: m, sec: sec));
        }
        for (int i = 0; i < 6; i++) {
          sec += 30;
          fixes.add((m: m, sec: sec)); // a 3 minute stop
        }
      }
      expect(run(h, fixes).every((b) => !b), isTrue);
    });
  });

  group('the driver app alerts only for the assignment of the day', () {
    final String d = File('lib/screens/driver_dashboard.dart').readAsStringSync();

    test('no assignment, or none read yet: nobody is alerted (only a server without the feature keeps the old rule)', () {
      final RegExp rule = RegExp(r'bool _isAlertableArea\(Map<String, dynamic> p\) \{\s*if \(_assignmentFeatureOff\) return true;\s*final Set<String>\? assigned = _assignedAreaNames;\s*if \(assigned == null\) return false;');
      expect(rule.hasMatch(d), isTrue);
    });

    test('a failed read keeps the known assignment (or the one stored for today) and never alerts every area', () {
      final int from = d.indexOf('Future<void> _loadTodayAssignment()');
      final String body = d.substring(from, d.indexOf('/// true once the assignment of today was read', from));
      final int failBranch = body.indexOf('if (!r.isOk && !featureOff)');
      final int okPath = body.indexOf('_assignmentOk = true;');
      expect(failBranch, greaterThanOrEqualTo(0));
      expect(okPath, greaterThan(failBranch));
      final String failure = body.substring(failBranch, okPath);
      expect(failure.contains('_assignedAreaNames = null'), isFalse);
      expect(failure.contains('_readCachedAssignment'), isTrue);
      expect(failure.contains('return;'), isTrue);
    });

    test('the question is asked again with every heartbeat until the assignment could be read', () {
      expect(d.contains('if (!_assignmentOk) unawaited(_loadTodayAssignment());'), isTrue);
    });

    test('every alert, arrival mark and ETA is behind the assignment check and the stay hold', () {
      expect(RegExp(r'_isAlertableArea\(p\)\) _handleAutoNotifications').hasMatch(d), isTrue);
      expect(RegExp(r'!servedThisTrip && _isAlertableArea\(p\) && \(next == null').hasMatch(d), isTrue);
      expect(d.contains('_stayHold.offer(pos.latitude, pos.longitude, pos.timestamp.millisecondsSinceEpoch)'), isTrue);
    });
  });

  group('the round of a truck', () {
    const int now = 1000000000000;
    Map<String, Object?> node({String status = 'ACTIVE', int gpsAgo = 5000, Object? queue}) => <String, Object?>{
          'status': status,
          'gps_at': now - gpsAgo,
          'lastSeen': now - gpsAgo,
          if (queue != null) AreaEta.queueField: queue,
        };

    test('is read while the truck is collecting with a current position', () {
      expect(AreaEta.queueFromNode(node(queue: <String>['Riverside', 'Paraiso']), nowMs: now), <String>['Riverside', 'Paraiso']);
    });

    test('is empty when the truck is FULL, paused, offline, silent or has none', () {
      for (final String s in <String>['FULL', 'IDLE', 'COMPLETED', 'OFFLINE']) {
        expect(AreaEta.queueFromNode(node(status: s, queue: <String>['Riverside']), nowMs: now), isEmpty, reason: s);
      }
      expect(AreaEta.queueFromNode(node(gpsAgo: 200000, queue: <String>['Riverside']), nowMs: now), isEmpty);
      expect(AreaEta.queueFromNode(node(), nowMs: now), isEmpty);
    });
  });
}
