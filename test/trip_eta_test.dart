import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/arrival_notifications.dart';
import 'package:garbage_tracking_app/utils/collection_visits.dart';
import 'package:garbage_tracking_app/utils/eta_evaluation.dart';
import 'package:garbage_tracking_app/utils/trip_eta.dart';
import 'package:garbage_tracking_app/utils/verified_eta.dart';

import 'support/fake_rtdb.dart';

const int t0 = 1793183000000; // a fixed "now" base

Map<String, Object?> approach(String area, int sentMs, int minutes, {String trip = 'trip-1'}) => <String, Object?>{
      'type': 'auto_approach',
      'purok': area,
      'trip_id': trip,
      'eta_minutes': minutes,
      'timestamp': sentMs,
    };

void main() {
  group('TripEta (fleet card ETA)', () {
    test('latest alert of the trip, counted down from when it was sent', () {
      final Map<String, Object?> n = <String, Object?>{
        'a': approach('Purok 2', t0, 15),
        'b': approach('Brixton Homes', t0 + 60000, 4),
      };
      final TripEta? e = TripEta.latest(n, 'trip-1', nowMs: t0 + 2 * 60000);
      expect(e!.area, 'Brixton Homes');
      expect(e.minutesLeft, 3);
      expect(e.etaMinutes, 4);
    });

    test('an area already reached is skipped', () {
      final Map<String, Object?> n = <String, Object?>{
        'a': approach('Purok 2', t0, 15),
        'b': approach('Brixton Homes', t0 + 60000, 4),
        'c': <String, Object?>{'type': 'auto_arrival', 'purok': 'Brixton Homes', 'trip_id': 'trip-1', 'timestamp': t0 + 300000},
      };
      final TripEta? e = TripEta.latest(n, 'trip-1', nowMs: t0 + 360000);
      expect(e!.area, 'Purok 2');
      expect(e.minutesLeft, 9);
    });

    test('other trips, missing minutes and long-overdue estimates show nothing', () {
      expect(TripEta.latest(<String, Object?>{'a': approach('Purok 2', t0, 5, trip: 'other')}, 'trip-1', nowMs: t0), isNull);
      expect(TripEta.latest(<String, Object?>{'a': <String, Object?>{'type': 'auto_approach', 'purok': 'Purok 2', 'trip_id': 'trip-1', 'timestamp': t0}}, 'trip-1', nowMs: t0), isNull);
      expect(TripEta.latest(<String, Object?>{'a': approach('Purok 2', t0, 5)}, 'trip-1', nowMs: t0 + 16 * 60000), isNull);
      expect(TripEta.latest(null, 'trip-1', nowMs: t0), isNull);
    });

    test('a due estimate reads "due now"', () {
      final TripEta? e = TripEta.latest(<String, Object?>{'a': approach('Purok 2', t0, 2)}, 'trip-1', nowMs: t0 + 3 * 60000);
      expect(e!.minutesLeft, 0);
      expect(e.label, 'Purok 2: due now');
    });
  });

  group('VerifiedEta (Analytics and Collection Route Optimization)', () {
    test('an alert is compared with the verified visit of the same trip and area', () {
      const AreaGeofence area = AreaGeofence(name: 'Brixton Homes', lat: 13.9551652, lng: 121.1567505, radiusM: 100, isTruckStop: true);
      const int arrive = t0 + 5 * 60000;
      final Map trips = <String, Object?>{
        'trip-1': <String, Object?>{
          'route_status': 'ACTIVE',
          'route': <String, Object?>{
            'p1': <String, Object?>{'lat': 13.9551652, 'lng': 121.1567505, 'status': 'ACTIVE', 'accuracy': 5, 'timestamp': arrive},
            'p2': <String, Object?>{'lat': 13.9551700, 'lng': 121.1567500, 'status': 'ACTIVE', 'accuracy': 5, 'timestamp': arrive + 45000},
          },
        },
      };
      final List<EtaVisit> v = VerifiedEta.visits(
        <String, Object?>{'a': approach('Brixton Homes', t0, 4)},
        trips: trips,
        areas: const <AreaGeofence>[area],
        nowMs: arrive + 60000,
      );
      expect(v, hasLength(1));
      expect(v.single.isEvaluated, isTrue);
      expect(v.single.arrivalMs, arrive);
      expect(v.single.signedErrorMin, closeTo(1.0, 0.05)); // 5 min actual - 4 min stated
    });
  });

  group('approach stages never go back to a less urgent one', () {
    Future<bool> send(FakeRtdb db, String stage) => ArrivalNotifications.publishOnce(
          db: db,
          stage: stage,
          tripId: 'trip-1',
          areaKey: 'purok_3',
          nowMs: t0,
          skipIfPublished: ArrivalNotifications.moreUrgentThan(stage),
          payload: <String, Object?>{'type': 'auto_approach', 'purok': 'Purok 3'},
        );

    test('15 after 10 is not sent; 5 after 10 is', () async {
      final FakeRtdb db = FakeRtdb();
      expect(await send(db, 'approach_10'), isTrue);
      expect(await send(db, 'approach_15'), isFalse);
      expect(await send(db, 'approach_5'), isTrue);
      expect(await send(db, 'approach_10'), isFalse);
      expect((db.read('notifications') as Map).length, 2);
    });
  });
}
