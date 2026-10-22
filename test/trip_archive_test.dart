import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/collection_visits.dart';
import 'package:garbage_tracking_app/utils/trip_archive.dart';

void main() {
  test('an archived trip gives no verified visit; the same trip unarchived does', () {
    const area = AreaGeofence(name: 'Central', lat: 13.9530, lng: 121.1588, radiusM: 100);
    final int t0 = DateTime(2026, 10, 21, 9).millisecondsSinceEpoch;
    Map<String, Object?> trip({bool archived = false}) => <String, Object?>{
          'date': '2026-10-21',
          if (archived) 'archived': true,
          'route': <String, Object?>{
            for (int i = 0; i < 4; i++)
              'p$i': <String, Object?>{'lat': 13.9530, 'lng': 121.1588, 'timestamp': t0 + i * 40000, 'status': 'ACTIVE', 'accuracy': 8},
          },
        };
    VisitSummary run(Map<String, Object?> t) => CollectionVisits.detect(
        trips: <String, Object?>{'t1': t}, areas: const <AreaGeofence>[area], start: DateTime(2026, 10, 21), end: DateTime(2026, 10, 21));
    expect(run(trip()).visits, hasLength(1));
    expect(run(trip(archived: true)).visits, isEmpty);
    expect(TripArchive.isArchived(<String, Object?>{'archived': 'true'}), isTrue);
    expect(TripArchive.isArchived(<String, Object?>{}), isFalse);
  });
}
