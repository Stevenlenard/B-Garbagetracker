import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/screens/collection_route_optimization_screen.dart';
import 'package:garbage_tracking_app/services/usual_collection_time_service.dart';
import 'package:garbage_tracking_app/utils/collection_visits.dart';
import 'package:garbage_tracking_app/utils/usual_collection_time.dart';

/// The resident's card: usual days and a time RANGE from verified visits of the last 28 days. Synthetic geometry only.
const AreaGeofence mine = AreaGeofence(name: 'Area A', lat: 10.0, lng: 120.0, radiusM: 60);
const AreaGeofence other = AreaGeofence(name: 'Area B', lat: 10.01, lng: 120.01, radiusM: 60);

/// A trip with three ACTIVE fixes a minute apart inside [lat],[lng], starting at Manila local time [y]-[m]-[d] [h]:[min].
Map<String, Object?> tripAt(int y, int m, int d, int h, int min, {double lat = 10.0, double lng = 120.0}) {
  final int t = DateTime.utc(y, m, d, h, min).subtract(const Duration(hours: 8)).millisecondsSinceEpoch;
  return <String, Object?>{
    'date': '$y-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}',
    'truck_id': 'GT-001',
    'route': <String, Object?>{
      for (int i = 0; i < 3; i++)
        'p$i': <String, Object?>{'latitude': lat, 'longitude': lng, 'status': 'ACTIVE', 'accuracy': 8, 'fix_time': t + i * 60000, 'timestamp': t + i * 60000 + 300},
    },
  };
}

CollectionData data(List<Map<String, Object?>> trips) => CollectionData(
      areas: const <AreaGeofence>[mine, other],
      trips: <String, Object?>{for (int i = 0; i < trips.length; i++) 't$i': trips[i]},
      weeklyProgress: null,
    );

// 2026-11-05 is a Thursday; the 28-day window starts on 2026-10-09.
final DateTime today = DateTime(2026, 11, 5);

void main() {
  group('derivation', () {
    final List<Map<String, Object?>> trips = <Map<String, Object?>>[
      tripAt(2026, 10, 13, 7, 10), tripAt(2026, 10, 20, 7, 40), tripAt(2026, 10, 27, 8, 5), tripAt(2026, 11, 3, 7, 20), // Tuesdays
      tripAt(2026, 10, 16, 9, 0), tripAt(2026, 10, 23, 9, 20), tripAt(2026, 10, 30, 8, 50), // Fridays
      tripAt(2026, 10, 18, 14, 0), // one Sunday only: not a usual day
      tripAt(2026, 10, 14, 13, 0, lat: 10.01, lng: 120.01), // another area: ignored
      tripAt(2026, 9, 1, 6, 0), tripAt(2026, 9, 8, 6, 0), // older than 28 days: ignored
    ];

    test('usual days and an outward-rounded time range', () {
      final UsualCollectionTimes r = UsualCollectionTimeService.fromData(data(trips), 'Area A', today);
      expect(r.hasPattern, isTrue);
      expect(r.days.map((UsualDay d) => d.weekday), <int>[DateTime.tuesday, DateTime.friday]);
      expect(r.daysLabel, 'Tue & Fri');
      expect(r.rangeLabel, '7:00 – 9:30 AM');
      expect(r.varies, isFalse);
      expect(r.visitCount, 8);
      expect(r.basisLabel, 'Based on 8 verified visits in the last 28 days');
    });

    test('a single visit on a weekday is not a usual day', () {
      final UsualCollectionTimes r = UsualCollectionTimeService.fromData(data(<Map<String, Object?>>[tripAt(2026, 10, 13, 7, 10), tripAt(2026, 10, 14, 7, 10)]), 'Area A', today);
      expect(r.hasPattern, isFalse);
    });

    test('no records, an unknown area or no purok: no pattern, nothing invented', () {
      expect(UsualCollectionTimeService.fromData(data(<Map<String, Object?>>[]), 'Area A', today).hasPattern, isFalse);
      expect(UsualCollectionTimeService.fromData(data(trips), 'Nowhere', today).hasPattern, isFalse);
      expect(UsualCollectionTimeService.fromData(data(trips), null, today).hasPattern, isFalse);
    });

    test('the other area has its own pattern', () {
      final UsualCollectionTimes r = UsualCollectionTimeService.fromData(
          data(<Map<String, Object?>>[tripAt(2026, 10, 14, 13, 0, lat: 10.01, lng: 120.01), tripAt(2026, 10, 21, 13, 30, lat: 10.01, lng: 120.01)]), 'Area B', today);
      expect(r.daysLabel, 'Wed');
      expect(r.rangeLabel, '1:00 – 1:30 PM');
    });
  });

  group('range', () {
    CollectionVisit v(int h, int m, {int day = 13}) => CollectionVisit(
        tripId: 't$h$m$day', area: 'Area A', firstFixMs: DateTime.utc(2026, 10, day, h, m).subtract(const Duration(hours: 8)).millisecondsSinceEpoch, lastFixMs: 0, fixes: 3);

    test('a wide spread is reported as varying; the range crosses noon with both labels', () {
      final UsualCollectionTimes r = UsualCollectionTime.compute(<CollectionVisit>[v(6, 30), v(13, 10, day: 21)]);
      expect(r.hasPattern, isFalse); // different weekdays, one visit each

      final UsualCollectionTimes w = UsualCollectionTime.compute(<CollectionVisit>[v(10, 30), v(13, 40, day: 20), v(11, 0, day: 27), v(12, 40, day: 6)]); // four Tuesdays
      expect(w.hasPattern, isTrue);
      expect(w.rangeLabel, '10:30 AM – 1:45 PM');
      expect(w.varies, isTrue);
      expect(w.basisLabel, endsWith('· time varies'));
    });

    test('six or more visits on a day: the earliest and the latest are left out', () {
      final List<CollectionVisit> vs = <CollectionVisit>[
        v(5, 0, day: 6), v(7, 0, day: 13), v(7, 10, day: 20), v(7, 20, day: 27), v(7, 30, day: 6 + 28), v(11, 0, day: 6 + 35),
      ];
      // 6 Tuesdays: 6 Oct, 13, 20, 27, 3 Nov, 10 Nov (the days are only weekdays for grouping)
      final UsualCollectionTimes r = UsualCollectionTime.compute(vs);
      expect(r.days.single.visits, 6);
      expect(r.rangeLabel, '7:00 – 7:30 AM');
    });

    test('simulated visits are never used', () {
      final CollectionVisit sim = CollectionVisit(tripId: 's', area: 'Area A', firstFixMs: 1, lastFixMs: 2, fixes: 2, simulated: true);
      expect(UsualCollectionTime.compute(<CollectionVisit>[sim, sim, sim]).hasPattern, isFalse);
    });

    test('formatting', () {
      expect(UsualCollectionTime.formatRange(450, 450), '7:30 AM');
      expect(UsualCollectionTime.formatRange(0, 60), '12:00 – 1:00 AM');
      expect(UsualCollectionTime.formatRange(690, 750), '11:30 AM – 12:30 PM');
    });
  });
}
