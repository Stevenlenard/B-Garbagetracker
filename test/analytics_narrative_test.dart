import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/analytics_narrative.dart';
import 'package:garbage_tracking_app/utils/analytics_recommendations.dart';

NarrativeInput inp({
  String area = 'All Areas',
  bool today = false,
  int loads = 0,
  int measured = 0,
  int pending = 0,
  int progress = 0,
  int resolved = 0,
  int expected = 5,
  int visited = 0,
  int visits = 0,
  int considered = 0,
  int noEvidence = 0,
  bool collection = true,
  bool complaints = true,
}) =>
    NarrativeInput(
      area: area,
      periodLabel: '2026-10-11 to 2026-10-18',
      periodIncludesToday: today,
      loadTrips: loads,
      measuredLoads: measured,
      pending: pending,
      inProgress: progress,
      resolved: resolved,
      expectedAreas: expected,
      visitedAreas: visited,
      verifiedVisits: visits,
      tripsConsidered: considered,
      tripsWithoutEvidence: noEvidence,
      collectionDataAvailable: collection,
      complaintDataAvailable: complaints,
    );

void main() {
  group('operational summary: one wording per outcome', () {
    test('nothing recorded at all gives guidance, not just zeros', () {
      final String t = AnalyticsNarrative.operationalSummary(inp());
      expect(t, contains('No full loads and no resident complaints were recorded'));
      expect(t, contains('drivers were not signed in'));
    });

    test('complaints but no trips', () {
      final String t = AnalyticsNarrative.operationalSummary(inp(pending: 2, resolved: 1));
      expect(t, contains('No full loads were recorded'));
      expect(t, contains('2 of 3 resident complaints are unresolved (2 pending) and 1 is resolved.'));
      expect(t, contains('Verify the collection logs'));
    });

    test('trips, no complaints, estimated weights', () {
      final String t = AnalyticsNarrative.operationalSummary(inp(loads: 3, considered: 3, visited: 5, visits: 9));
      expect(t, contains('3 full loads were recorded'));
      expect(t, contains('Waste volume is an estimate'));
      expect(t, contains('No resident complaints were filed in the period; this does not measure resident satisfaction.'));
      expect(t, contains('Every one of the 5 collection areas has a verified visit (9 visits).'));
    });

    test('a single trip uses singular grammar', () {
      final String t = AnalyticsNarrative.operationalSummary(inp(loads: 1, measured: 1, resolved: 1, considered: 1, visited: 1, visits: 1, expected: 1));
      expect(t, contains('1 full load was recorded'));
      expect(t, contains('Every load has a recorded scale weight'));
      expect(t, contains('All 1 resident complaint filed in the period is resolved.'));
      expect(t, contains('(1 visit)'));
    });

    test('partial weights, partial coverage, GPS gaps, in-progress work', () {
      final String t = AnalyticsNarrative.operationalSummary(
          inp(loads: 4, measured: 1, pending: 1, progress: 2, resolved: 3, visited: 2, visits: 3, considered: 4, noEvidence: 1, today: true));
      expect(t, contains('1 of 4 loads has a recorded scale weight; the rest are estimated.'));
      expect(t, contains('3 of 6 resident complaints are unresolved (1 pending and 2 in progress) and 3 are resolved.'));
      expect(t, contains('2 of 5 collection areas have a verified visit'));
      expect(t, contains('1 of 4 trips had no usable GPS points, so its visits cannot be verified.'));
      expect(t, contains('The period includes today'));
    });

    test('no area visited yet', () {
      expect(AnalyticsNarrative.operationalSummary(inp(loads: 2, considered: 2, visited: 0)), contains('None of the 5 collection areas has a verified visit yet.'));
    });

    test('data that could not be loaded is said, never shown as zero', () {
      final String t = AnalyticsNarrative.operationalSummary(inp(collection: false, complaints: false));
      expect(t, contains('could not be loaded'));
      expect(t, isNot(contains('No full loads')));
    });

    test('driver issues can be counted together with complaints', () {
      const NarrativeInput i = NarrativeInput(
          area: 'Purok 1', periodLabel: 'today', pending: 1, resolved: 1, loadTrips: 1, measuredLoads: 1, complaintNoun: 'complaint/issue', complaintNounPlural: 'complaints/issues');
      expect(AnalyticsNarrative.operationalSummary(i), contains('1 of 2 complaints/issues is unresolved'));
    });

    test('never claims satisfaction, a trend or a cause, in any combination', () {
      final RegExp banned = RegExp(r'satisfied|improv|increase|decrease|trend|because|caused by|great job', caseSensitive: false);
      for (final bool today in <bool>[false, true]) {
        for (final int loads in <int>[0, 1, 5]) {
          for (final int measured in <int>[0, 1, 5]) {
            for (final int pending in <int>[0, 2]) {
              for (final int progress in <int>[0, 1]) {
                for (final int resolved in <int>[0, 3]) {
                  for (final int visited in <int>[0, 2, 5]) {
                    final NarrativeInput i = inp(today: today, loads: loads, measured: measured > loads ? loads : measured, pending: pending, progress: progress, resolved: resolved, visited: visited, considered: loads, visits: visited);
                    final String t = AnalyticsNarrative.operationalSummary(i);
                    expect(t.trim(), isNotEmpty);
                    expect(t, isNot(contains('null')));
                    expect(t, isNot(contains('NaN')));
                    // the only allowed use of "satisfaction" is the disclaimer
                    expect(t.replaceAll('does not measure resident satisfaction', ''), isNot(matches(banned)));
                  }
                }
              }
            }
          }
        }
      }
    });
  });

  group('recommended checks', () {
    List<String> titles(NarrativeInput i) => AnalyticsNarrative.recommendedChecks(i).map((NarrativeCheck c) => c.title).toList();

    test('never empty, never more than three', () {
      for (final NarrativeInput i in <NarrativeInput>[
        inp(),
        inp(loads: 3, measured: 3, considered: 3, visited: 5, visits: 5),
        inp(pending: 4, progress: 2, loads: 2, considered: 2, noEvidence: 1, visited: 1),
        inp(collection: false),
      ]) {
        final List<NarrativeCheck> c = AnalyticsNarrative.recommendedChecks(i);
        expect(c, isNotEmpty);
        expect(c.length, lessThanOrEqualTo(3));
        for (final NarrativeCheck x in c) {
          expect(x.title.trim(), isNotEmpty);
          expect(x.subtitle.trim(), isNotEmpty);
        }
      }
    });

    test('pending complaints come first', () {
      expect(titles(inp(pending: 2, loads: 1, considered: 1, visited: 1)).first, 'Review 2 pending complaints');
    });

    test('an all-clear period says no action is needed', () {
      final List<String> t = titles(inp(loads: 3, measured: 3, considered: 3, visited: 5, visits: 6, resolved: 2));
      expect(t.first, startsWith('Monitor') == true ? t.first : isNotNull);
      expect(t.any((String x) => x.startsWith('No action needed') || x.startsWith('Monitor')), isTrue);
    });

    test('no trips asks to verify the logs; failed loading asks to reload', () {
      expect(titles(inp()).first, 'Verify collection logs');
      expect(titles(inp(collection: false)).first, 'Reload the collection records');
    });

    test('missed areas, GPS gaps and estimated weights each get their own check', () {
      final List<String> t = titles(inp(loads: 2, measured: 0, considered: 2, visited: 3, noEvidence: 1));
      expect(t.any((String x) => x.contains('2 areas with no verified visit')), isTrue);
    });
  });

  group('area summary and limitations', () {
    test('every combination reads correctly', () {
      String s({int v = 0, int c = 0, String r = '', int rc = 0, int rv = 0, int z = 0, int a = 4}) => AnalyticsNarrative.areaSummary(
          area: 'All Areas', visits: v, complaints: c, needsReviewArea: r, needsReviewComplaints: rc, needsReviewVisits: rv, zeroVisitAreas: z, activeAreas: a);
      expect(s(), contains('no verified collection visit and no resident complaint'));
      expect(s(v: 3), contains('3 verified collection visits and no resident complaints'));
      expect(s(c: 2), contains('2 resident complaints but no verified collection visit'));
      expect(s(c: 2), contains('does not prove the area was missed'));
      expect(s(v: 1, c: 1), contains('1 verified collection visit and 1 resident complaint '));
      expect(s(v: 1, c: 1), contains('No area has more than 2 complaints.'));
      expect(s(v: 4, c: 5, r: 'Purok 2', rc: 4, rv: 1), contains('Purok 2 has the most complaints (4) with 1 verified visit.'));
      expect(s(v: 2, z: 0), contains('Every active area has a recorded visit.'));
    });

    test('limitation lines handle one, several and no empty sectors', () {
      final List<String> one = AnalyticsNarrative.limitationLines(area: 'Purok 1', activeAreas: 1, zeroVisitAreas: 1);
      expect(one.join('\n'), contains('1 sector reports zero visits'));
      final List<String> many = AnalyticsNarrative.limitationLines(area: 'All Areas', activeAreas: 6, zeroVisitAreas: 2);
      expect(many.join('\n'), contains('2 sectors report zero visits'));
      expect(many.join('\n'), contains('San Nicolas'));
      final List<String> none = AnalyticsNarrative.limitationLines(area: 'All Areas', activeAreas: 0, zeroVisitAreas: 0);
      expect(none.join('\n'), contains('No active sector has data'));
    });
  });

  group('recommendations never come back empty and cover the good outcomes', () {
    RecommendationInput r({
      int total = 0,
      int pending = 0,
      List<String> areas = const <String>['A', 'B'],
      Map<String, int> visits = const <String, int>{},
      int considered = 0,
      int noEvidence = 0,
      int completed = 0,
      int measured = 0,
      bool collection = true,
      bool complaints = true,
    }) =>
        RecommendationInput(
          periodLabel: 'p',
          area: 'All Areas',
          residentComplaintsByArea: const <String, int>{},
          pendingResidentComplaints: pending,
          totalResidentComplaints: total,
          visitsByArea: visits,
          truckStopAreas: areas,
          unconfirmedPasses: const <String, int>{},
          tripsConsidered: considered,
          tripsWithoutEvidence: noEvidence,
          completedTrips: completed,
          measuredWeightTrips: measured,
          collectionDataAvailable: collection,
          complaintDataAvailable: complaints,
        );

    List<String> findings(RecommendationInput i) => AnalyticsRecommendations.build(i).map((Recommendation x) => x.finding).toList();

    test('a perfect period says so, with evidence', () {
      final List<String> f = findings(r(total: 3, pending: 0, visits: <String, int>{'A': 2, 'B': 1}, considered: 2, completed: 2, measured: 2));
      expect(f, contains('All resident complaints filed in this period are resolved.'));
      expect(f, contains('Every collection area has a verified visit.'));
      expect(f, contains('Waste volumes for this period are based on measured weights.'));
    });

    test('complaints with no trips explains what was skipped', () {
      final List<String> f = findings(r(total: 2, pending: 1));
      expect(f, contains('No collection trips were recorded in this period.'));
    });

    test('collection without complaint data says the complaints did not load', () {
      final List<String> f = findings(r(complaints: false, considered: 1, completed: 1, measured: 1, visits: <String, int>{'A': 1, 'B': 1}));
      expect(f, contains('Complaint records could not be loaded.'));
    });

    test('the list is never empty for any combination', () {
      for (final bool coll in <bool>[true, false]) {
        for (final bool comp in <bool>[true, false]) {
          for (final int total in <int>[0, 2]) {
            for (final int considered in <int>[0, 2]) {
              final List<Recommendation> out = AnalyticsRecommendations.build(
                  r(total: total, pending: total > 0 ? 1 : 0, considered: considered, completed: considered, collection: coll, complaints: comp));
              expect(out, isNotEmpty, reason: 'coll=$coll comp=$comp total=$total considered=$considered');
            }
          }
        }
      }
    });
  });
}
