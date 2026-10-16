import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/collection_visits.dart';

// Synthetic geometry only (not real coordinates): a circular area and a square polygon area.
const AreaGeofence circleA = AreaGeofence(name: 'Area A', lat: 10.0, lng: 120.0, radiusM: 60);
const AreaGeofence squareB = AreaGeofence(
  name: 'Area B',
  lat: 10.01,
  lng: 120.01,
  radiusM: 60,
  polygon: <List<double>>[
    <double>[120.009, 10.011],
    <double>[120.011, 10.011],
    <double>[120.011, 10.009],
    <double>[120.009, 10.009],
    <double>[120.009, 10.011],
  ],
);
const AreaGeofence sweeping = AreaGeofence(name: 'Sweep', lat: 10.02, lng: 120.02, radiusM: 50, isTruckStop: false);
final List<AreaGeofence> areas = <AreaGeofence>[circleA, squareB, sweeping];

// 2026-10-12 08:00 Asia/Manila.
final int t0 = DateTime.utc(2026, 10, 12, 0, 0).millisecondsSinceEpoch;
final DateTime day = DateTime(2026, 10, 12);

Map<String, Object?> pt(int sec, double lat, double lng, {String status = 'ACTIVE', double? acc = 8, bool sim = false}) =>
    <String, Object?>{
      'latitude': lat,
      'longitude': lng,
      'status': status,
      if (acc != null) 'accuracy': acc,
      'fix_time': t0 + sec * 1000,
      'timestamp': t0 + sec * 1000 + 300,
      if (sim) 'is_simulation': true,
    };

Map<String, Object?> trip(List<Map<String, Object?>> points, {String date = '2026-10-12', Map<String, Object?>? extra}) =>
    <String, Object?>{
      'date': date,
      'truck_id': 'GT-001',
      'driver_id': '7',
      'route': <String, Object?>{for (int i = 0; i < points.length; i++) 'p$i': points[i]},
      ...?extra,
    };

const double aLat = 10.0, aLng = 120.0; // inside Area A
const double outLat = 10.005, outLng = 120.005; // outside every area

VisitSummary run(Map<String, Object?> trips, {String? area}) =>
    CollectionVisits.detect(trips: trips, areas: areas, start: day, end: day, areaFilter: area);

void main() {
  test('repeated GPS updates during one stay = one visit', () {
    final List<Map<String, Object?>> pts = <Map<String, Object?>>[
      for (int s = 0; s <= 300; s += 5) pt(s, aLat, aLng),
    ];
    final VisitSummary r = run(<String, Object?>{'t1': trip(pts)});
    expect(r.visits.length, 1);
    expect(r.countByArea(), <String, int>{'Area A': 1});
  });

  test('quick pass-through is not a visit (reported as unconfirmed)', () {
    final VisitSummary r = run(<String, Object?>{
      't1': trip(<Map<String, Object?>>[pt(0, outLat, outLng), pt(10, aLat, aLng), pt(20, aLat, aLng), pt(30, aLat, aLng), pt(40, outLat, outLng)]),
    });
    expect(r.visits, isEmpty);
    expect(r.unconfirmedPasses['Area A'], 1);
  });

  test('boundary jitter (one stray outside fix) does not split or cancel the stay', () {
    final VisitSummary r = run(<String, Object?>{
      't1': trip(<Map<String, Object?>>[pt(0, aLat, aLng), pt(30, aLat, aLng), pt(45, outLat, outLng), pt(60, aLat, aLng), pt(90, aLat, aLng)]),
    });
    expect(r.visits.length, 1);
    expect(r.visits.single.dwellMs, 90000);
  });

  test('leaving and re-entering in the same trip is still one visit', () {
    final VisitSummary r = run(<String, Object?>{
      't1': trip(<Map<String, Object?>>[
        for (int s = 0; s <= 90; s += 15) pt(s, aLat, aLng),
        pt(120, outLat, outLng), pt(150, outLat, outLng), pt(180, outLat, outLng),
        for (int s = 210; s <= 330; s += 15) pt(s, aLat, aLng),
      ]),
    });
    expect(r.visits.length, 1);
  });

  test('separate trips to the same area are separate visits', () {
    final List<Map<String, Object?>> stay = <Map<String, Object?>>[for (int s = 0; s <= 120; s += 20) pt(s, aLat, aLng)];
    final VisitSummary r = run(<String, Object?>{'t1': trip(stay), 't2': trip(stay)});
    expect(r.countByArea()['Area A'], 2);
  });

  test('IDLE/PAUSED, FULL and COMPLETED travel is not collection', () {
    for (final String status in <String>['IDLE', 'PAUSED', 'FULL', 'COMPLETED', 'FINISHED']) {
      final VisitSummary r = run(<String, Object?>{
        't1': trip(<Map<String, Object?>>[for (int s = 0; s <= 300; s += 10) pt(s, aLat, aLng, status: status)]),
      });
      expect(r.visits, isEmpty, reason: status);
      expect(r.tripsWithoutEvidence, 1, reason: status);
    }
  });

  test('pause in the middle: ACTIVE parts on each side are judged separately', () {
    final VisitSummary r = run(<String, Object?>{
      't1': trip(<Map<String, Object?>>[
        pt(0, aLat, aLng), pt(20, aLat, aLng), // 20 s active
        for (int s = 30; s <= 600; s += 30) pt(s, aLat, aLng, status: 'PAUSED'),
        pt(610, aLat, aLng), pt(640, aLat, aLng), pt(680, aLat, aLng), // 70 s active after resume
      ]),
    });
    expect(r.visits.length, 1);
    expect(r.visits.single.firstFixMs, t0 + 610000);
  });

  test('points after the collection was finalized are excluded', () {
    final VisitSummary r = run(<String, Object?>{
      't1': trip(<Map<String, Object?>>[for (int s = 0; s <= 300; s += 10) pt(s, aLat, aLng)],
          extra: <String, Object?>{'collection': <String, Object?>{'finalized_at_ms': t0 + 20000}}),
    });
    expect(r.visits, isEmpty);
  });

  test('poor accuracy and simulation points are rejected; missing accuracy is accepted', () {
    final VisitSummary bad = run(<String, Object?>{
      't1': trip(<Map<String, Object?>>[for (int s = 0; s <= 300; s += 10) pt(s, aLat, aLng, acc: 85)]),
      't2': trip(<Map<String, Object?>>[for (int s = 0; s <= 300; s += 10) pt(s, aLat, aLng, sim: true)]),
    });
    expect(bad.visits, isEmpty);
    final VisitSummary legacy = run(<String, Object?>{
      't1': trip(<Map<String, Object?>>[for (int s = 0; s <= 300; s += 10) pt(s, aLat, aLng, acc: null)]),
    });
    expect(legacy.visits.length, 1);
  });

  test('trips without route points are counted as unprovable, never as visits', () {
    final VisitSummary r = run(<String, Object?>{'t1': trip(<Map<String, Object?>>[])});
    expect(r.visits, isEmpty);
    expect(r.tripsConsidered, 1);
    expect(r.tripsWithoutEvidence, 1);
  });

  test('polygon boundary is used when present; sweeping area is never visited', () {
    final VisitSummary r = run(<String, Object?>{
      't1': trip(<Map<String, Object?>>[for (int s = 0; s <= 120; s += 20) pt(s, 10.0105, 120.0105)]),
      't2': trip(<Map<String, Object?>>[for (int s = 0; s <= 300; s += 20) pt(s, 10.02, 120.02)]),
    });
    expect(r.countByArea(), <String, int>{'Area B': 1});
  });

  test('date range uses the Asia/Manila day of the visit; area filter applies', () {
    final List<Map<String, Object?>> stay = <Map<String, Object?>>[for (int s = 0; s <= 120; s += 20) pt(s, aLat, aLng)];
    final VisitSummary other = CollectionVisits.detect(
        trips: <String, Object?>{'t1': trip(stay)}, areas: areas, start: DateTime(2026, 10, 13), end: DateTime(2026, 10, 13));
    expect(other.visits, isEmpty);
    expect(run(<String, Object?>{'t1': trip(stay)}, area: 'Area B').visits, isEmpty);
    expect(run(<String, Object?>{'t1': trip(stay)}, area: 'Area A').visits.length, 1);
  });
}
