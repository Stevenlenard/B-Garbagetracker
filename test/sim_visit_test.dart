import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/collection_visits.dart';

void main() {
  const area = AreaGeofence(name: 'Central (Purok 1)', lat: 13.953, lng: 121.1588, radiusM: 60);
  final int t0 = DateTime.utc(2026, 10, 21, 2).millisecondsSinceEpoch;
  Map<String, Object?> p(double lat, int s) =>
      {'lat': lat, 'lng': 121.1588, 'status': 'ACTIVE', 'accuracy': 5, 'timestamp': t0 + s * 1000, 'is_simulation': true};
  final trips = {
    'sim1': {
      'date': '2026-10-21',
      'route': {'a': p(13.9520, 0), 'b': p(13.9529, 5), 'c': p(13.9531, 10), 'd': p(13.9545, 15)},
    }
  };

  test('a simulated drive-by is a (labelled) visit on the collection-status screen', () {
    final v = CollectionVisits.detect(
        trips: trips, areas: const [area], start: DateTime(2026, 10, 21), end: DateTime(2026, 10, 21), includeSimulated: true);
    expect(v.visits, hasLength(1));
    expect(v.visits.single.simulated, isTrue);
  });

  test('analytics (default) never counts a simulation', () {
    final v = CollectionVisits.detect(trips: trips, areas: const [area], start: DateTime(2026, 10, 21), end: DateTime(2026, 10, 21));
    expect(v.visits, isEmpty);
  });
}
