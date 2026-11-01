import 'package:flutter_test/flutter_test.dart';
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
    test('a real change replaces it', () {
      expect(AreaEta.stabilize(e(now + 360000), e(now + 420000)).arriveAtMs, now + 420000);
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
}
