import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/eta_evaluation.dart';

// Manila wall-clock -> epoch ms.
int manilaMs(int y, int mo, int d, int h, int mi, [int s = 0]) =>
    DateTime.utc(y, mo, d, h, mi, s).millisecondsSinceEpoch - 8 * 3600 * 1000;

Map<String, Object?> approach({
  required int ts,
  required int minutes,
  String area = 'Purok 2',
  String? truck = 'TRK-1',
  String? trip,
  String? stage,
  bool etaField = true,
}) =>
    <String, Object?>{
      'type': 'auto_approach',
      'purok': area,
      'message': 'Truck ${truck ?? 'X'} is on the way to $area. Estimated arrival: $minutes min.',
      if (truck != null) 'truck_id': truck,
      if (etaField) 'eta_minutes': minutes,
      if (trip != null) 'trip_id': trip,
      if (stage != null) 'stage': stage,
      'timestamp': ts,
    };

Map<String, Object?> arrival({
  required int ts,
  String area = 'Purok 2',
  String? truck = 'TRK-1',
  String? trip,
}) =>
    <String, Object?>{
      'type': 'auto_arrival',
      'purok': area,
      'message': 'The garbage truck (${truck ?? 'X'}) has arrived in $area.',
      if (truck != null) 'truck_id': truck,
      if (trip != null) 'trip_id': trip,
      'timestamp': ts,
    };

List<EtaVisit> build(Map<String, Object?> m, {int? nowMs, Set<String> closed = const <String>{}}) =>
    EtaEvaluation.build(m, nowMs: nowMs ?? manilaMs(2026, 10, 13, 23, 0), closedTripIds: closed);

void main() {
  final int t0 = manilaMs(2026, 10, 13, 8, 0);
  const int min = 60000;

  group('matching and error', () {
    test('predicted vs actual: late arrival is positive, early is negative', () {
      final List<EtaVisit> v = build({
        'a1': approach(ts: t0, minutes: 10, trip: 'T1'),
        'r1': arrival(ts: t0 + 14 * min, trip: 'T1'),
        'a2': approach(ts: t0, minutes: 10, area: 'Purok 3', trip: 'T2'),
        'r2': arrival(ts: t0 + 7 * min, area: 'Purok 3', trip: 'T2'),
      });
      final EtaVisit late = v.firstWhere((e) => e.tripId == 'T1');
      final EtaVisit early = v.firstWhere((e) => e.tripId == 'T2');
      expect(late.status, EtaVisitStatus.evaluated);
      expect(late.signedErrorMin, 4.0);
      expect(late.absErrorMin, 4.0);
      expect(early.signedErrorMin, -3.0);
      expect(early.absErrorMin, 3.0);
      expect(late.predictedArrivalMs, t0 + 10 * min);
      expect(late.arrivalMs, t0 + 14 * min);
    });

    test('no arrival: awaiting, never an invented arrival or error', () {
      final List<EtaVisit> v = build({'a1': approach(ts: t0, minutes: 10, trip: 'T1')},
          nowMs: t0 + 30 * min);
      expect(v.single.status, EtaVisitStatus.awaiting);
      expect(v.single.arrivalMs, isNull);
      expect(v.single.signedErrorMin, isNull);
      final EtaSummary s = EtaEvaluation.summarize(v);
      expect(s.evaluatedVisits, 0);
      expect(s.avgAbsErrorMin, isNull);
      expect(s.within5Pct, isNull);
      expect(s.awaitingVisits, 1);
    });

    test('old prediction without arrival is "no arrival recorded", not evaluated', () {
      final List<EtaVisit> v = build({'a1': approach(ts: t0, minutes: 10, trip: 'T1')},
          nowMs: t0 + 8 * 60 * min);
      expect(v.single.status, EtaVisitStatus.noArrival);
      expect(EtaEvaluation.summarize(v).awaitingVisits, 0);
    });

    test('very late arrival keeps its real error (no modulo normalisation)', () {
      final List<EtaVisit> v = build({
        'a1': approach(ts: t0, minutes: 10, trip: 'T1'),
        'r1': arrival(ts: t0 + 25 * 60 * min, trip: 'T1'),
      });
      expect(v.single.signedErrorMin, 25 * 60 - 10.0);
    });

    test('different trucks / trips for the same area never cross-match', () {
      final List<EtaVisit> v = build({
        'a1': approach(ts: t0, minutes: 10, truck: 'TRK-1', trip: 'T1'),
        // arrival of ANOTHER trip/truck in the same area
        'r1': arrival(ts: t0 + 9 * min, truck: 'TRK-2', trip: 'T9'),
        // same trip id but a different area
        'r2': arrival(ts: t0 + 9 * min, area: 'Purok 3', truck: 'TRK-1', trip: 'T1'),
      }, nowMs: t0 + 20 * min);
      expect(v.single.status, EtaVisitStatus.awaiting);
      expect(v.single.arrivalMs, isNull);
    });

    test('truck is an attribute: the same trip with different truck labels is ONE visit', () {
      final List<EtaVisit> v = build({
        'a1': approach(ts: t0, minutes: 10, truck: 'GT-007', trip: 'T1'),
        'r1': arrival(ts: t0 + 9 * min, truck: 'TR-005', trip: 'T1'),
      });
      expect(v.length, 1);
      expect(v.single.status, EtaVisitStatus.evaluated);
      expect(v.single.tripId, 'T1');
      expect(v.single.truckLabelsDiffer, isTrue);
      expect(v.single.truckIds, containsAll(['GT-007', 'TR-005']));
    });

    test('"Unknown" is a placeholder, not a truck identity', () {
      final List<EtaVisit> v = build({
        'a1': approach(ts: t0, minutes: 10, truck: 'Unknown', trip: 'T1'),
        'r1': arrival(ts: t0 + 9 * min, truck: 'GT-007', trip: 'T1'),
      });
      expect(v.single.truckId, 'GT-007');
      expect(v.single.truckIds, ['GT-007']);
      // legacy record whose only truck is "Unknown" can never be matched by truck
      final List<EtaVisit> legacy = build({
        'a1': approach(ts: t0, minutes: 10, truck: 'Unknown'),
        'r1': arrival(ts: t0 + 9 * min, truck: 'Unknown'),
      }, nowMs: t0 + 20 * min);
      expect(legacy.single.status, EtaVisitStatus.awaiting);
    });

    test('different trips visiting the same area are separate visits', () {
      final List<EtaVisit> v = build({
        'a1': approach(ts: t0, minutes: 10, trip: 'T1', stage: 'approach_10'),
        'a2': approach(ts: t0 + 60 * min, minutes: 10, trip: 'T2', stage: 'approach_10'),
        'r1': arrival(ts: t0 + 10 * min, trip: 'T1'),
      }, nowMs: t0 + 90 * min);
      expect(v.length, 2);
      expect(v.firstWhere((e) => e.tripId == 'T1').status, EtaVisitStatus.evaluated);
      expect(v.firstWhere((e) => e.tripId == 'T2').status, EtaVisitStatus.awaiting);
    });

    test('arrival before the notification was sent is not a match', () {
      final List<EtaVisit> v = build({
        'r0': arrival(ts: t0 - 5 * min, trip: 'T1'),
        'a1': approach(ts: t0, minutes: 10, trip: 'T1'),
      }, nowMs: t0 + 20 * min);
      expect(v.single.status, EtaVisitStatus.awaiting);
    });

    test('a later cycle does not borrow the previous cycle arrival', () {
      final int d2 = t0 + 24 * 60 * min;
      final List<EtaVisit> v = build({
        'a1': approach(ts: t0, minutes: 10, trip: 'T1'),
        'r1': arrival(ts: t0 + 10 * min, trip: 'T1'),
        'a2': approach(ts: d2, minutes: 10, trip: 'T2'),
      }, nowMs: d2 + 5 * min);
      final EtaVisit second = v.firstWhere((e) => e.tripId == 'T2');
      expect(second.status, EtaVisitStatus.awaiting);
      expect(second.arrivalMs, isNull);
    });
  });

  group('per-visit counting', () {
    test('repeated 15/10/5 predictions of one visit count once, judged on the first', () {
      final List<EtaVisit> v = build({
        'a15': approach(ts: t0, minutes: 15, trip: 'T1', stage: 'approach_15'),
        'a10': approach(ts: t0 + 5 * min, minutes: 10, trip: 'T1', stage: 'approach_10'),
        'a5': approach(ts: t0 + 10 * min, minutes: 5, trip: 'T1', stage: 'approach_5'),
        'r1': arrival(ts: t0 + 18 * min, trip: 'T1'),
      });
      expect(v.length, 1);
      final EtaVisit visit = v.single;
      expect(visit.predictions.length, 3);
      expect(visit.first.predictedMinutes, 15);
      expect(visit.signedErrorMin, 3.0); // 18 - 15
      final EtaSummary s = EtaEvaluation.summarize(v);
      expect(s.evaluatedVisits, 1);
      expect(s.predictionsEvaluated, 3);
      // per-prediction errors: +3, +3, +3
      expect(s.avgPredictionAbsErrorMin, 3.0);
      expect(s.avgAbsErrorMin, 3.0);
    });

    test('two visits of the same truck and area are two visits', () {
      final List<EtaVisit> v = build({
        'a1': approach(ts: t0, minutes: 10, trip: 'T1'),
        'r1': arrival(ts: t0 + 10 * min, trip: 'T1'),
        'a2': approach(ts: t0 + 3 * 60 * min, minutes: 10, trip: 'T2'),
        'r2': arrival(ts: t0 + 3 * 60 * min + 20 * min, trip: 'T2'),
      });
      expect(EtaEvaluation.summarize(v).evaluatedVisits, 2);
    });
  });

  group('legacy records (no trip id)', () {
    test('match by truck + area within the gap', () {
      final List<EtaVisit> v = build({
        'a1': approach(ts: t0, minutes: 10, etaField: false),
        'r1': arrival(ts: t0 + 12 * min),
      });
      expect(v.single.status, EtaVisitStatus.evaluated);
      expect(v.single.legacyMatch, isTrue);
      expect(v.single.signedErrorMin, 2.0);
      expect(v.single.first.minutesFromMessage, isTrue);
    });

    test('no truck on the approach: not matched', () {
      final List<EtaVisit> v = build({
        'a1': <String, Object?>{
          'type': 'auto_approach',
          'purok': 'Purok 2',
          'message': 'The truck is approaching Purok 2. Estimated arrival: 10 min.',
          'timestamp': t0,
        },
        'r1': arrival(ts: t0 + 12 * min),
      }, nowMs: t0 + 30 * min);
      expect(v.single.status, EtaVisitStatus.awaiting);
    });

    test('arrival far outside the gap is not matched', () {
      final List<EtaVisit> v = build({
        'a1': approach(ts: t0, minutes: 10),
        'r1': arrival(ts: t0 + 5 * 60 * min),
      }, nowMs: t0 + 30 * min);
      expect(v.single.status, EtaVisitStatus.awaiting);
    });

    test('repeated legacy alerts for one arrival are one visit', () {
      final List<EtaVisit> v = build({
        'a1': approach(ts: t0, minutes: 10),
        'a2': approach(ts: t0 + 2 * min, minutes: 8),
        'r1': arrival(ts: t0 + 11 * min),
      });
      expect(v.length, 1);
      expect(EtaEvaluation.summarize(v).evaluatedVisits, 1);
    });
  });

  group('unusable records', () {
    test('notification without an ETA is not evaluated and not defaulted', () {
      final List<EtaVisit> v = build({
        'a1': <String, Object?>{
          'type': 'auto_approach',
          'purok': 'Purok 2',
          'message': 'Truck TRK-1 is on the way to Purok 2.',
          'truck_id': 'TRK-1',
          'trip_id': 'T1',
          'timestamp': t0,
        },
        'r1': arrival(ts: t0 + 10 * min, trip: 'T1'),
      });
      expect(v.single.status, EtaVisitStatus.noEstimate);
      expect(EtaEvaluation.summarize(v).evaluatedVisits, 0);
    });

    test('missing timestamp is skipped, not replaced by "now"', () {
      final Map<String, Object?> a = approach(ts: t0, minutes: 10, trip: 'T1')..remove('timestamp');
      expect(build({'a1': a}), isEmpty);
    });

    test('legacy resident TRUCK_PROXIMITY broadcast is not a prediction', () {
      final List<EtaVisit> v = build({
        'p': <String, Object?>{
          'type': 'TRUCK_PROXIMITY',
          'purok': 'Purok 2',
          'message': 'Truck is Arriving! approximately 0 minutes away',
          'timestamp': t0,
        },
      });
      expect(v, isEmpty);
    });

    test('manual alert saying "arrived" is not a GPS arrival', () {
      final List<EtaVisit> v = build({
        'a1': approach(ts: t0, minutes: 10, trip: 'T1'),
        'm': <String, Object?>{
          'type': 'manual_alert',
          'purok': 'Purok 2',
          'message': 'Truck has arrived',
          'trip_id': 'T1',
          'truck_id': 'TRK-1',
          'timestamp': t0 + 5 * min,
        },
      }, nowMs: t0 + 20 * min);
      expect(v.single.status, EtaVisitStatus.awaiting);
    });
  });

  group('withdrawn', () {
    test('trip ended before arrival is withdrawn and not evaluated', () {
      final List<EtaVisit> v = build({'a1': approach(ts: t0, minutes: 10, trip: 'T1')},
          closed: {'T1'}, nowMs: t0 + 30 * min);
      expect(v.single.status, EtaVisitStatus.withdrawn);
      expect(v.single.withdrawnReason, isNotEmpty);
      final EtaSummary s = EtaEvaluation.summarize(v);
      expect(s.withdrawnVisits, 1);
      expect(s.evaluatedVisits, 0);
    });

    test('a closed trip that DID arrive is still evaluated', () {
      final List<EtaVisit> v = build({
        'a1': approach(ts: t0, minutes: 10, trip: 'T1'),
        'r1': arrival(ts: t0 + 10 * min, trip: 'T1'),
      }, closed: {'T1'});
      expect(v.single.status, EtaVisitStatus.evaluated);
    });
  });

  group('date filter (Asia/Manila) and consistency', () {
    test('Manila calendar day of the SENT time, across the UTC boundary', () {
      // 00:30 Manila Oct 13 == 16:30 UTC Oct 12
      final int justAfterMidnight = manilaMs(2026, 10, 13, 0, 30);
      final int lateOct12 = manilaMs(2026, 10, 12, 23, 30);
      final List<EtaVisit> v = build({
        'a1': approach(ts: justAfterMidnight, minutes: 10, trip: 'T1'),
        'a2': approach(ts: lateOct12, minutes: 10, area: 'Purok 3', trip: 'T2'),
      });
      final DateTime day = DateTime(2026, 10, 13);
      final List<EtaVisit> oct13 = EtaEvaluation.filter(v, start: day, end: day);
      expect(oct13.map((e) => e.tripId), ['T1']);
      final DateTime d12 = DateTime(2026, 10, 12);
      expect(EtaEvaluation.filter(v, start: d12, end: d12).map((e) => e.tripId), ['T2']);
      expect(EtaEvaluation.filter(v, start: d12, end: day).length, 2);
    });

    test('area and source filters; All areas keeps everything', () {
      final List<EtaVisit> v = build({
        'a1': approach(ts: t0, minutes: 10, trip: 'T1'),
        'a2': approach(ts: t0, minutes: 10, area: 'Purok 3', trip: 'T2'),
      });
      expect(EtaEvaluation.filter(v, area: 'All areas').length, 2);
      expect(EtaEvaluation.filter(v, area: 'All Areas').length, 2);
      expect(EtaEvaluation.filter(v, area: 'purok 3').single.tripId, 'T2');
      expect(EtaEvaluation.filter(v, source: 'Manual'), isEmpty);
      expect(EtaEvaluation.filter(v, source: 'Auto').length, 2);
    });

    test('card and details agree: same filter + summarize over one dataset', () {
      final Map<String, Object?> raw = {
        'a1': approach(ts: t0, minutes: 10, trip: 'T1'),
        'r1': arrival(ts: t0 + 13 * min, trip: 'T1'),
        'a2': approach(ts: t0, minutes: 10, area: 'Purok 3', truck: 'TRK-2', trip: 'T2'),
        'r2': arrival(ts: t0 + 4 * min, area: 'Purok 3', truck: 'TRK-2', trip: 'T2'),
        'a3': approach(ts: t0, minutes: 10, area: 'Purok 4', truck: 'TRK-3', trip: 'T3'),
      };
      final DateTime day = DateTime(2026, 10, 13);
      final List<EtaVisit> visits = build(raw, nowMs: t0 + 30 * min);
      final EtaSummary card =
          EtaEvaluation.summarize(EtaEvaluation.filter(visits, area: 'All Areas', start: day, end: day));
      final EtaSummary details = EtaEvaluation.summarize(
          EtaEvaluation.filter(visits, area: 'All areas', source: 'All sources', start: day, end: day));
      expect(card.evaluatedVisits, details.evaluatedVisits);
      expect(card.avgAbsErrorMin, details.avgAbsErrorMin);
      expect(card.within5Pct, details.within5Pct);
      expect(card.evaluatedVisits, 2);
      expect(card.avgAbsErrorMin, 4.5); // (3 + 6) / 2 using |+3| and |-6|
      expect(card.within5Pct, 50);
      expect(card.awaitingVisits, 1);
      // every counted visit has the details a row must show
      for (final EtaVisit v in visits.where((e) => e.isEvaluated)) {
        expect(v.truckId, isNotEmpty);
        expect(v.tripId, isNotNull);
        expect(v.arrivalMs, isNotNull);
        expect(v.predictedArrivalMs, isNotNull);
        expect(v.signedErrorMin, isNotNull);
      }
    });

    test('empty input is "unavailable", never zero/defaults', () {
      final EtaSummary s = EtaEvaluation.summarize(const <EtaVisit>[]);
      expect(s.hasEvaluated, isFalse);
      expect(s.avgAbsErrorMin, isNull);
      expect(s.within5Pct, isNull);
      expect(s.evaluatedVisits, 0);
      expect(EtaEvaluation.build(null, nowMs: 0), isEmpty);
    });

    test('timestamps in seconds are normalised, invalid ones rejected', () {
      expect(EtaEvaluation.normalizeMs(1760000000), 1760000000000);
      expect(EtaEvaluation.normalizeMs(1760000000000), 1760000000000);
      expect(EtaEvaluation.normalizeMs(0), isNull);
      expect(EtaEvaluation.normalizeMs('x'), isNull);
    });
  });

  group('pagination (30 per page, after filtering)', () {
    List<int> items(int n) => List<int>.generate(n, (i) => i);

    test('0, 30, 31 and 61 records', () {
      final e = EtaPage.of(items(0), 1);
      expect([e.total, e.pageCount, e.firstShown, e.lastShown, e.hasPrevious, e.hasNext],
          [0, 1, 0, 0, false, false]);
      final p30 = EtaPage.of(items(30), 1);
      expect([p30.pageCount, p30.items.length, p30.firstShown, p30.lastShown, p30.hasNext], [1, 30, 1, 30, false]);
      final p31a = EtaPage.of(items(31), 1);
      final p31b = EtaPage.of(items(31), 2);
      expect([p31a.pageCount, p31a.items.length, p31a.hasNext, p31a.hasPrevious], [2, 30, true, false]);
      expect([p31b.items.length, p31b.firstShown, p31b.lastShown, p31b.hasNext, p31b.hasPrevious],
          [1, 31, 31, false, true]);
      final p61 = EtaPage.of(items(61), 3);
      expect([p61.pageCount, p61.items.length, p61.firstShown, p61.lastShown], [3, 1, 61, 61]);
    });

    test('page is clamped (filter shrinks the list while on a later page)', () {
      expect(EtaPage.of(items(10), 5).page, 1);
      expect(EtaPage.of(items(61), 0).page, 1);
    });

    test('newest first, filters apply before paging, page 1 shows the newest', () {
      final Map<String, Object?> raw = {};
      for (int i = 0; i < 35; i++) {
        raw['a$i'] = approach(ts: t0 + i * 3 * 60 * min, minutes: 10, trip: 'T$i');
      }
      raw['other'] = approach(ts: t0, minutes: 10, area: 'Purok 3', trip: 'TX');
      final visits = build(raw, nowMs: t0 + 40 * 24 * 60 * min);
      final filtered = EtaEvaluation.filter(visits, area: 'Purok 2');
      expect(filtered.length, 35);
      expect(filtered.first.tripId, 'T34'); // newest sent first
      final p1 = EtaPage.of(filtered, 1);
      final p2 = EtaPage.of(filtered, 2);
      expect(p1.items.length, 30);
      expect(p2.items.length, 5);
      expect(p1.items.map((e) => e.tripId).toSet().intersection(p2.items.map((e) => e.tripId).toSet()), isEmpty);
      // a different area filter yields a different, shorter list (UI resets to page 1)
      expect(EtaPage.of(EtaEvaluation.filter(visits, area: 'Purok 3'), 1).total, 1);
    });
  });
}
