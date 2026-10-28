import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/collection_visits.dart';
import 'package:garbage_tracking_app/utils/trip_activity_log.dart';

const List<AreaGeofence> areas = <AreaGeofence>[
  AreaGeofence(name: 'Central (Purok 1)', lat: 13.953, lng: 121.1588, radiusM: 100, isTruckStop: true),
  AreaGeofence(name: 'Brixton Homes', lat: 13.9551652, lng: 121.1567505, radiusM: 100, isTruckStop: true),
];

Map<String, Object?> p(int s, double lat, double lng, {String status = 'ACTIVE'}) =>
    <String, Object?>{'lat': lat, 'lng': lng, 'status': status, 'timestamp': 1793183000000 + s * 1000};

void main() {
  test('real areas and times instead of a fixed "Balintawak"', () {
    final List<TripActivity> log = TripActivityLog.build(<Map>[
      p(0, 13.9500, 121.1600), // outside every area
      p(60, 13.9530, 121.1588), // Central
      p(65, 13.9530, 121.1589), // still Central: not repeated
      p(300, 13.9551, 121.1567), // Brixton
      p(400, 13.9552, 121.1567, status: 'FULL'),
      p(500, 13.9600, 121.1500, status: 'FULL'), // between areas
    ], areas);
    expect(log.map((TripActivity a) => a.title).toList(), <String>[
      'Latest position: between areas',
      'Marked FULL (no more collection)',
      'Entered Brixton Homes',
      'Entered Central (Purok 1)',
      'Trip started',
    ]);
    expect(log.first.full, isTrue);
    expect(log.last.ms, 1793183000000);
  });

  test('no points, no entries', () {
    expect(TripActivityLog.build(<Map>[], areas), isEmpty);
  });

  test('re-entering an area after leaving it is listed again', () {
    final List<TripActivity> log = TripActivityLog.build(<Map>[
      p(0, 13.9530, 121.1588),
      p(60, 13.9600, 121.1500),
      p(120, 13.9530, 121.1588),
    ], areas);
    expect(log.where((TripActivity a) => a.title == 'Entered Central (Purok 1)').length, 2);
  });
}
