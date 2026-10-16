import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/analytics_recommendations.dart';

RecommendationInput input({
  Map<String, int> complaints = const <String, int>{},
  int pending = 0,
  int total = 0,
  Map<String, int> visits = const <String, int>{},
  int trips = 0,
  int noEvidence = 0,
  int completed = 0,
  int measured = 0,
  bool collectionOk = true,
}) =>
    RecommendationInput(
      periodLabel: '2026-10-01 to 2026-10-13',
      area: 'All Areas',
      residentComplaintsByArea: complaints,
      pendingResidentComplaints: pending,
      totalResidentComplaints: total,
      visitsByArea: visits,
      truckStopAreas: const <String>['Area A', 'Area B'],
      unconfirmedPasses: const <String, int>{},
      tripsConsidered: trips,
      tripsWithoutEvidence: noEvidence,
      completedTrips: completed,
      measuredWeightTrips: measured,
      collectionDataAvailable: collectionOk,
    );

String all(List<Recommendation> r) => AnalyticsRecommendations.asText(r).toLowerCase();

void main() {
  test('no data -> a single "insufficient data" recommendation, no invented claims', () {
    final List<Recommendation> r = AnalyticsRecommendations.build(input());
    expect(r.length, 1);
    expect(all(r), contains('not enough data'));
    expect(all(r), isNot(contains('satisf')));
  });

  test('zero complaints is never reported as satisfaction', () {
    final String t = all(AnalyticsRecommendations.build(input(trips: 2, visits: <String, int>{'Area A': 2, 'Area B': 1})));
    expect(t, contains('no resident complaints were filed'));
    expect(t, contains('does not measure resident satisfaction'));
    expect(t, isNot(contains('high satisfaction')));
  });

  test('no idle-truck reassignment and no unlabeled capacity claims', () {
    final String t = all(AnalyticsRecommendations.build(input(trips: 3, completed: 3, visits: <String, int>{'Area A': 1, 'Area B': 1})));
    expect(t, isNot(contains('idle')));
    expect(t, contains('estimate'));
    expect(t, contains('not verified truck data'));
  });

  test('complaints in an area without verified visits are flagged with the numbers', () {
    final String t = all(AnalyticsRecommendations.build(input(
      complaints: <String, int>{'Area B': 3},
      pending: 3,
      total: 3,
      trips: 2,
      visits: <String, int>{'Area A': 2},
    )));
    expect(t, contains('3 resident complaint(s) are still unresolved'));
    expect(t, contains('area b (3)'));
    expect(t, contains('no verified visit: area b'));
  });

  test('trips without GPS evidence produce a data-quality recommendation', () {
    final String t = all(AnalyticsRecommendations.build(input(trips: 4, noEvidence: 2, visits: <String, int>{'Area A': 1, 'Area B': 1})));
    expect(t, contains('2 of 4 trip(s) have no usable gps points'));
  });

  test('all weights measured -> no estimate warning', () {
    final String t = all(AnalyticsRecommendations.build(input(trips: 2, completed: 2, measured: 2, visits: <String, int>{'Area A': 1, 'Area B': 1})));
    expect(t, isNot(contains('5,000 kg')));
  });

  test('collection data unavailable is stated, not treated as zero', () {
    final String t = all(AnalyticsRecommendations.build(input(collectionOk: false)));
    expect(t, contains('could not be loaded'));
  });
}
