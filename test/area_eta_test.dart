import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'package:garbage_tracking_app/utils/area_eta.dart';
import 'package:garbage_tracking_app/utils/trip_eta.dart';

void main() {
  const int now = 1000000000000;

  Map<String, Object?> node({
    String status = 'ACTIVE',
    int gpsAgoMs = 5000,
    int computedAgoMs = 5000,
    int arriveInMs = 6 * 60000,
    String area = 'Brixton Homes',
    bool withEta = true,
  }) =>
      <String, Object?>{
        'status': status,
        'isOnline': true,
        'gps_at': now - gpsAgoMs,
        'lastSeen': now - gpsAgoMs,
        'current_session': 'trip-1',
        if (withEta)
          AreaEta.field: <String, Object?>{
            'area': area,
            'area_key': 'brixton_homes',
            'minutes': (arriveInMs / 60000).ceil(),
            'arrive_at_ms': now + arriveInMs,
            'computed_at_ms': now - computedAgoMs,
            'method': 'recent_speed_or_model',
          },
      };

  group('one estimate per area, read by everyone', () {
    test('every reader of the same truck node gets the same arrival moment and the same minutes', () {
      final Map<String, Object?> n = node();
      final AreaEta resident1 = AreaEta.fromNode(n, nowMs: now)!;
      final AreaEta resident2 = AreaEta.fromNode(n, nowMs: now + 700)!; // another phone, a moment later
      expect(resident1.arriveAtMs, resident2.arriveAtMs);
      expect(resident1.minutes, resident2.minutes);
      expect(resident1.minutesLeft(now), 6);
    });

    test('the countdown is absolute: reading again later never restarts it', () {
      final AreaEta e = AreaEta.fromNode(node(), nowMs: now)!;
      expect(e.secondsLeft(now), 360);
      expect(e.secondsLeft(now + 60000), 300);
      expect(AreaEta.fromNode(node(), nowMs: now)!.arriveAtMs, e.arriveAtMs);
    });

    test('a due estimate says 0, never negative', () {
      final AreaEta e = AreaEta.fromNode(node(arriveInMs: -30000), nowMs: now)!;
      expect(e.minutesLeft(now), 0);
    });

    test('the residents of an area are matched by area, whatever name variant they registered with', () {
      final AreaEta e = AreaEta.fromNode(node(area: 'Central (Purok 1)'), nowMs: now)!;
      expect(e.isForPurok('Purok 1'), isTrue);
      expect(e.isForPurok('Central (Purok 1)'), isTrue);
      expect(e.isForPurok('Riverside'), isFalse);
      expect(e.isForPurok(null), isFalse);
    });
  });

  group('nothing is shown that cannot be justified', () {
    test('no estimate on the node: none', () => expect(AreaEta.fromNode(node(withEta: false), nowMs: now), isNull));
    test('a truck that is not collecting has none', () {
      for (final String s in <String>['FULL', 'IDLE', 'COMPLETED', 'OFFLINE']) {
        expect(AreaEta.fromNode(node(status: s), nowMs: now), isNull, reason: s);
      }
    });
    test('out-of-date GPS: none', () => expect(AreaEta.fromNode(node(gpsAgoMs: 200000), nowMs: now), isNull));
    test('an estimate that was not renewed within the freshness window: none', () {
      expect(AreaEta.fromNode(node(computedAgoMs: 200000), nowMs: now), isNull);
    });
    test('a damaged record: none', () {
      final Map<String, Object?> n = node();
      (n[AreaEta.field] as Map<String, Object?>).remove('arrive_at_ms');
      expect(AreaEta.fromNode(n, nowMs: now), isNull);
    });
  });

  group('GPS noise does not twitch the countdown', () {
    AreaEta e(int arriveAt, {String key = 'brixton_homes'}) =>
        AreaEta(area: 'Brixton Homes', areaKey: key, minutes: 6, arriveAtMs: arriveAt, computedAtMs: now);

    test('a new estimate within 20 s keeps the published arrival moment', () {
      expect(AreaEta.stabilize(e(now + 360000), e(now + 372000)).arriveAtMs, now + 360000);
    });
    test('a real change is followed, at a bounded rate', () {
      expect(AreaEta.stabilize(e(now + 360000), e(now + 420000)).arriveAtMs, now + 360000 + AreaEta.minShiftMs);
    });
    test('another area, or none before, takes the new estimate as is', () {
      expect(AreaEta.stabilize(e(now + 360000), e(now + 365000, key: 'riverside')).arriveAtMs, now + 365000);
      expect(AreaEta.stabilize(null, e(now + 365000)).arriveAtMs, now + 365000);
    });
  });

  group('fleet cards (Admin, residents\' map)', () {
    test('show the published estimate, not the last alert', () {
      final TripEta? t = TripEta.forTruck(node(), <String, Object?>{
        'a': <String, Object?>{'type': 'auto_approach', 'trip_id': 'trip-1', 'purok': 'Riverside', 'eta_minutes': 15, 'timestamp': now - 120000},
      }, nowMs: now);
      expect(t!.live, isTrue);
      expect(t.area, 'Brixton Homes');
      expect(t.minutesLeft, 6);
      expect(t.sourceText, 'updated');
    });

    test('a driver on an older app (no published estimate) still shows its last alert', () {
      final TripEta? t = TripEta.forTruck(node(withEta: false), <String, Object?>{
        'a': <String, Object?>{'type': 'auto_approach', 'trip_id': 'trip-1', 'purok': 'Riverside', 'eta_minutes': 15, 'timestamp': now - 120000},
      }, nowMs: now);
      expect(t!.live, isFalse);
      expect(t.area, 'Riverside');
      expect(t.sourceText, 'alert sent');
    });

    test('nothing at all: nothing is guessed', () {
      expect(TripEta.forTruck(node(withEta: false), null, nowMs: now), isNull);
    });
  });

  group('steady, never unrealistic', () {
    AreaEta e(int arriveAt, int computedAt, {String key = 'brixton_homes', String trip = 'trip-1'}) => AreaEta(
        area: 'Brixton Homes', areaKey: key, minutes: 6, arriveAtMs: arriveAt, computedAtMs: computedAt, tripId: trip);

    test('a sudden swing of the raw estimate is followed at a bounded rate, not as a jump', () {
      // published: 6 min away; one fix later the raw estimate says 30 min
      AreaEta published = e(now + 360000, now);
      final AreaEta raw = e(now + 2 * 1000 + 1800000, now + 2000);
      published = AreaEta.stabilize(published, raw);
      expect(published.arriveAtMs - (now + 360000), lessThanOrEqualTo(AreaEta.minShiftMs));
      // given a minute of fixes it has followed
      for (int s = 4; s <= 120; s += 2) {
        published = AreaEta.stabilize(published, e(now + s * 1000 + 1800000, now + s * 1000));
      }
      expect((published.arriveAtMs - (now + 120000 + 1800000)).abs(), lessThan(AreaEta.keepWithinMs));
    });

    test('a sudden drop is bounded the same way', () {
      final AreaEta p = AreaEta.stabilize(e(now + 900000, now), e(now + 2000 + 60000, now + 2000));
      expect(p.arriveAtMs, greaterThanOrEqualTo(now + 900000 - AreaEta.minShiftMs));
    });

    test('a stopped truck: the estimate is renewed, so the countdown stays put instead of running out', () {
      // a truck standing still keeps the same remaining time (6 min) at every fix
      AreaEta published = e(now + 360000, now);
      for (int s = 2; s <= 300; s += 2) {
        published = AreaEta.stabilize(published, e(now + s * 1000 + 360000, now + s * 1000));
      }
      final int left = published.secondsLeft(now + 300000);
      expect(left, inInclusiveRange(340, 380)); // ~6 min, not counted down to 1
    });

    test('minutes follow the steady arrival time', () {
      final AreaEta p = AreaEta.stabilize(e(now + 360000, now), e(now + 363000, now + 1000));
      expect(p.minutes, 6);
    });

    test('another area or another trip starts fresh', () {
      expect(AreaEta.stabilize(e(now + 360000, now), e(now + 900000, now + 2000, trip: 'trip-2')).arriveAtMs, now + 900000);
      expect(AreaEta.stabilize(e(now + 360000, now), e(now + 900000, now + 2000, key: 'riverside')).arriveAtMs, now + 900000);
    });
  });

  group('countdown and arrival', () {
    test('reaching zero is not "arrived"', () {
      expect(AreaEta.countdown(0), '< 1 min');
      expect(AreaEta.countdown(-120), '< 1 min');
      expect(AreaEta.countdown(30), '< 1 min');
      expect(AreaEta.countdown(31), '0:31');
      expect(AreaEta.countdown(125), '2:05');
      for (final int s in <int>[-500, 0, 5, 30, 31, 600]) {
        expect(AreaEta.countdown(s).toLowerCase().contains('arriv'), isFalse, reason: '$s');
      }
    });

    test('an overdue estimate that is no longer renewed disappears with the GPS, it is never kept', () {
      expect(AreaEta.fromNode(node(arriveInMs: -400000, computedAgoMs: 190000), nowMs: now), isNull);
    });
  });

  group('trucks and trips cannot overwrite or leak into each other', () {
    test('the estimate lives on its own truck node', () {
      final Map<String, Object?> truckA = node(area: 'Brixton Homes');
      final Map<String, Object?> truckB = node(area: 'Riverside', arriveInMs: 12 * 60000);
      expect(AreaEta.fromNode(truckA, nowMs: now)!.area, 'Brixton Homes');
      expect(AreaEta.fromNode(truckB, nowMs: now)!.area, 'Riverside');
      expect(AreaEta.fromNode(truckA, nowMs: now)!.minutesLeft(now), 6);
      expect(AreaEta.fromNode(truckB, nowMs: now)!.minutesLeft(now), 12);
    });

    test('an estimate left by an earlier trip of the same truck is not shown for the new trip', () {
      final Map<String, Object?> n = node();
      (n[AreaEta.field] as Map<String, Object?>)['trip_id'] = 'old-trip';
      n['current_session'] = 'new-trip';
      expect(AreaEta.fromNode(n, nowMs: now), isNull);
      n['current_session'] = 'old-trip';
      expect(AreaEta.fromNode(n, nowMs: now), isNotNull);
    });

    test('a record without a trip id (older app) is still read', () {
      final Map<String, Object?> n = node();
      (n[AreaEta.field] as Map<String, Object?>).remove('trip_id');
      expect(AreaEta.fromNode(n, nowMs: now), isNotNull);
    });
  });

  group('every screen consumes the same record', () {
    String src(String f) => File(f).readAsStringSync();

    test('resident dashboard, fleet cards and Collection Route Optimization read AreaEta and compute nothing', () {
      for (final String f in <String>[
        'lib/screens/resident_dashboard.dart',
        'lib/utils/trip_eta.dart',
        'lib/screens/collection_route_optimization_screen.dart',
      ]) {
        final String s = src(f);
        expect(s.contains('AreaEta.fromNode'), isTrue, reason: f);
        expect(s.contains('EtaPolicy.evaluate'), isFalse, reason: f);
      }
      for (final String f in <String>[
        'lib/screens/admin_dashboard.dart',
        'lib/screens/track_trucks_screen.dart',
        'lib/screens/resident_track_truck_screen.dart',
      ]) {
        final String s = src(f);
        expect(s.contains('TripEta.forTruck'), isTrue, reason: f);
        expect(s.contains('EtaPolicy.evaluate'), isFalse, reason: f);
      }
    });

    test('the driver computes it once: the alert is built from the published record', () {
      final String d = src('lib/screens/driver_dashboard.dart');
      expect(RegExp(r'EtaPolicy\.evaluate\(').allMatches(d).length, 1);
      expect(d.contains('_maybeNotifyApproach(n.name, n.key, shared)'), isTrue);
      expect(d.contains('AreaEta.field: _areaEta?.toJson()'), isTrue);
    });

    test('the resident dashboard takes no phone location into the estimate', () {
      final String r = src('lib/screens/resident_dashboard.dart');
      final int from = r.indexOf('void _recomputeResidentFleet');
      final int to = r.indexOf('_fetchTotalDriversFromUserManagement', from);
      final String body = r.substring(from, to);
      expect(body.contains('_currentPosition'), isFalse);
      expect(body.contains('distanceBetween'), isFalse);
    });
  });
}
