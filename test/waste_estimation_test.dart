import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/waste_estimation_service.dart';
import 'package:garbage_tracking_app/utils/predictive_models.dart';
import 'package:garbage_tracking_app/utils/waste_estimation.dart';

/// Objective 2.2: area-based waste estimation. Nothing is invented: without a sourced parameter there is no number, and
/// the estimates stay apart from the capacity-equivalent total (5,000 kg per FULL event) and from measured weights.
void main() {
  // ~0.01° × 0.01° box at Balintawak's latitude: 1,111.9 m × 1,079.1 m ≈ 1.2 km².
  final List<List<double>> box = <List<double>>[
    <double>[121.15, 13.95],
    <double>[121.16, 13.95],
    <double>[121.16, 13.96],
    <double>[121.15, 13.96],
    <double>[121.15, 13.95],
  ];

  group('geodesic area', () {
    test('a closed or open ring gives the same area, close to the expected value', () {
      final double closed = WasteEstimation.polygonAreaM2(box);
      final double open = WasteEstimation.polygonAreaM2(box.sublist(0, 4));
      expect(closed, closeTo(open, 1e-6));
      expect(closed, closeTo(1199900, 12000));
    });

    test('winding direction does not matter', () {
      expect(WasteEstimation.polygonAreaM2(box.reversed.toList()), closeTo(WasteEstimation.polygonAreaM2(box), 1e-6));
    });

    test('invalid geometry has no area', () {
      expect(WasteEstimation.polygonAreaM2(<List<double>>[]), 0);
      expect(WasteEstimation.polygonAreaM2(box.sublist(0, 2)), 0);
      expect(WasteEstimation.polygonAreaM2(<List<double>>[<double>[121, 13], <double>[121.1, double.nan], <double>[121.2, 13.1]]), 0);
      expect(WasteEstimation.polygonAreaM2(<List<double>>[<double>[500, 13], <double>[121.1, 13], <double>[121.2, 13.1]]), 0);
      // bow-tie: self-intersecting
      expect(
          WasteEstimation.polygonAreaM2(<List<double>>[
            <double>[121.15, 13.95],
            <double>[121.16, 13.96],
            <double>[121.16, 13.95],
            <double>[121.15, 13.96],
          ]),
          0);
    });

    test('parseRing accepts a ring or a list holding a ring, and rejects malformed data', () {
      expect(WasteEstimation.parseRing(box)!.length, 5);
      expect(WasteEstimation.parseRing(<Object>[box])!.length, 5);
      expect(WasteEstimation.parseRing(null), isNull);
      expect(WasteEstimation.parseRing(<Object>['x', 'y', 'z']), isNull);
      expect(WasteEstimation.parseRing(<Object>[<Object>[1, 2]]), isNull);
    });
  });

  group('area sizes', () {
    test('a polygon size is unverified until an admin verifies it; a placeholder shape gives no size', () {
      final AreaSize s = WasteEstimation.sizeFromGeometry(box, source: 'Firebase puroks/x');
      expect(s.usable, isTrue);
      expect(s.verified, isFalse);
      final AreaSize p = WasteEstimation.sizeFromGeometry(box, placeholder: true);
      expect(p.usable, isFalse);
      expect(p.note, contains('placeholder'));
    });

    test('a manual size needs a positive value and a source', () {
      expect(WasteEstimation.manualSize(10000, '').usable, isFalse);
      expect(WasteEstimation.manualSize(-5, 'doc').usable, isFalse);
      expect(WasteEstimation.manualSize(double.nan, 'doc').usable, isFalse);
      expect(WasteEstimation.manualSize(25000, 'Barangay survey 2026').hectares, 2.5);
    });

    test('the five look-alike stored boxes are detected as placeholders; a distinct polygon is not', () {
      final Set<String> ph = WasteEstimation.placeholderAreas(<String, double>{
        'Brixton Homes': 431979,
        'Purok 2': 431967,
        'Purok 3': 431969,
        'Purok Paraiso': 431995,
        'Riverside': 431995,
        'Central (Purok 1)': 271502,
        'Purok 4': 28118,
      });
      expect(ph, <String>{'Brixton Homes', 'Purok 2', 'Purok 3', 'Purok Paraiso', 'Riverside'});
    });
  });

  group('estimates', () {
    const AreaSize ha10 = AreaSize(m2: 100000, kind: AreaSizeKind.manual, source: 'survey', verified: true);
    const EstimationParams rate30 = EstimationParams(kgPerHectareDay: 30, hectareRateSource: 'doc');

    test('no rate, no number: nothing is invented', () {
      final AreaEstimate e = WasteEstimation.estimate(const AreaConfig(name: 'A', size: ha10), const EstimationParams());
      expect(e.status, EstimateStatus.notConfigured);
      expect(e.kgPerDay, isNull);
      expect(e.hasNumber, isFalse);
      expect(e.reason, contains('no sourced waste rate'));
    });

    test('a rate without a source is not accepted', () {
      final AreaEstimate e = WasteEstimation.estimate(const AreaConfig(name: 'A', size: ha10), const EstimationParams(kgPerHectareDay: 30));
      expect(e.hasNumber, isFalse);
    });

    test('no usable size, no number', () {
      final AreaEstimate e = WasteEstimation.estimate(const AreaConfig(name: 'A'), rate30);
      expect(e.hasNumber, isFalse);
      expect(e.reason, contains('no usable area size'));
    });

    test('area size (ha) x rate (kg/ha/day) x multiplier of the day', () {
      final AreaEstimate e = WasteEstimation.estimate(const AreaConfig(name: 'A', size: ha10), rate30);
      expect(e.status, EstimateStatus.ok);
      expect(e.hectares, closeTo(10, 1e-9));
      expect(e.rate, 30);
      expect(e.multiplierUsed, 1.0);
      expect(e.kgPerDay, closeTo(300, 1e-9));
    });

    test('seasonal multiplier: default 1.0; applies only when active, positive and sourced', () {
      const SeasonalMultiplier off = SeasonalMultiplier(value: 1.15, source: 'doc');
      const SeasonalMultiplier noSource = SeasonalMultiplier(value: 1.15, active: true);
      const SeasonalMultiplier on = SeasonalMultiplier(value: 1.15, source: 'doc', active: true);
      expect(const SeasonalMultiplier().effective, 1.0);
      expect(off.effective, 1.0);
      expect(noSource.effective, 1.0);
      expect(on.effective, 1.15);
    });

    test('the summary adds up the areas with a number and their hectares, and counts the others', () {
      final List<AreaEstimate> list = <AreaEstimate>[
        WasteEstimation.estimate(const AreaConfig(name: 'A', size: ha10), rate30),
        WasteEstimation.estimate(const AreaConfig(name: 'B', size: AreaSize(m2: 50000, kind: AreaSizeKind.manual, source: 's')), rate30),
        WasteEstimation.estimate(const AreaConfig(name: 'C'), rate30),
      ];
      final EstimateSummary t = WasteEstimation.summarize(list);
      expect(t.areaCount, 3);
      expect(t.configuredCount, 2);
      expect(t.estimatedKgPerDay, closeTo(450, 1e-9));
      expect(t.hectares, closeTo(15, 1e-9));
    });
  });

  group('holiday calendar and the multiplier by date', () {
    test('only Christmas and New Year (Dec 24 to Jan 1) carry a documented increase', () {
      for (final DateTime d in <DateTime>[DateTime(2026, 12, 24), DateTime(2026, 12, 25), DateTime(2026, 12, 31), DateTime(2027, 1, 1)]) {
        expect(HolidayCalendar.upliftOn(d)?.id, 'christmas', reason: '$d');
      }
      for (final DateTime d in <DateTime>[DateTime(2026, 12, 23), DateTime(2027, 1, 2), DateTime(2026, 11, 4), DateTime(2026, 6, 1)]) {
        expect(HolidayCalendar.upliftOn(d), isNull, reason: '$d');
      }
      expect(HolidayCalendar.upliftOn(null), isNull);
    });

    test('Undas and the Lipa celebrations are known holidays without a multiplier', () {
      expect(HolidayCalendar.periodOn(DateTime(2026, 11, 1))?.id, 'undas');
      expect(HolidayCalendar.periodOn(DateTime(2026, 1, 20))?.id, 'lipa_festival');
      expect(HolidayCalendar.periodOn(DateTime(2026, 6, 20))?.id, 'lipa_foundation');
      for (final DateTime d in <DateTime>[DateTime(2026, 11, 2), DateTime(2026, 1, 20), DateTime(2026, 6, 20)]) {
        expect(HolidayCalendar.upliftOn(d), isNull);
      }
    });

    test('the multiplier applies on the holiday days only, and only when active and sourced', () {
      const SeasonalMultiplier on = SeasonalMultiplier(value: 1.15, source: 'doc', active: true, holidaysOnly: true);
      expect(on.on(DateTime(2026, 12, 25)), 1.15);
      expect(on.on(DateTime(2026, 11, 4)), 1.0);
      expect(const SeasonalMultiplier(value: 1.15, source: 'doc', active: false, holidaysOnly: true).on(DateTime(2026, 12, 25)), 1.0);
      expect(const SeasonalMultiplier(value: 1.15, source: '', active: true, holidaysOnly: true).on(DateTime(2026, 12, 25)), 1.0);
    });

    test('an estimate follows the day it is for', () {
      const AreaConfig a = AreaConfig(name: 'A', size: AreaSize(m2: 100000, kind: AreaSizeKind.manual, source: 's', verified: true));
      EstimationParams on(DateTime day) => EstimationParams(
          kgPerHectareDay: 30, hectareRateSource: 'doc', seasonal: const SeasonalMultiplier(value: 1.15, source: 'doc', active: true, holidaysOnly: true), day: day);
      final AreaEstimate regular = WasteEstimation.estimate(a, on(DateTime(2026, 11, 4)));
      final AreaEstimate christmas = WasteEstimation.estimate(a, on(DateTime(2026, 12, 25)));
      expect(regular.kgPerDay, closeTo(300, 1e-9));
      expect(christmas.kgPerDay, closeTo(345, 1e-9));
      expect(regular.multiplierUsed, 1.0);
      expect(christmas.multiplierUsed, 1.15);
    });

    test('the total follows the day, and the areas still add up to it', () {
      final Map<String, Object?> body = <String, Object?>{
        'success': true,
        'available': true,
        'settings': <String, Object?>{'kg_per_hectare_day': '30', 'hectare_rate_source': 'doc', 'seasonal_value': '1.15', 'seasonal_source': 'cities', 'seasonal_active': 1},
        'areas': <Object>[
          <String, Object?>{'area_key': 'a', 'size_m2': '100000', 'size_kind': 'manual', 'size_source': 's', 'size_verified': 1},
          <String, Object?>{'area_key': 'b', 'size_m2': '300000', 'size_kind': 'manual', 'size_source': 's', 'size_verified': 1},
        ],
      };
      final Map<String, Object?> puroks = <String, Object?>{'a': <String, Object?>{'name': 'A'}, 'b': <String, Object?>{'name': 'B'}};
      final WasteEstimationData reg = WasteEstimationData.fromRaw((body: body, puroks: puroks), day: DateTime(2026, 11, 4));
      final WasteEstimationData xmas = WasteEstimationData.fromRaw((body: body, puroks: puroks), day: DateTime(2026, 12, 25));
      expect(reg.totalKgPerDay, closeTo(1200, 1e-6)); // 40 ha x 30
      expect(xmas.totalKgPerDay, closeTo(1200 * 1.15, 1e-6));
      expect(xmas.regularDayKg, closeTo(1200, 1e-6));
      expect(xmas.holidayKg(HolidayCalendar.periods.first), closeTo(1380, 1e-6));
      expect(xmas.holidayKg(HolidayCalendar.periods[1]), isNull); // Undas: no multiplier
      final double sum = xmas.estimates.map((AreaEstimate e) => e.kgPerDay!).reduce((double x, double y) => x + y);
      expect(sum, closeTo(xmas.totalKgPerDay!, 1e-6));
    });
  });

  group('existing analytics are unchanged', () {
    test('the seven-day Moving Average and its metrics give the same numbers', () {
      final List<double> series = <double>[5000, 0, 5000, 0, 10000, 5000, 0, 5000, 5000, 0];
      final List<DateTime> days = <DateTime>[for (int i = 0; i < series.length; i++) DateTime.utc(2026, 11, 1 + i)];
      final MovingAverageReport r = MovingAverageForecast.evaluate(days, series);
      expect(r.metrics.n, 3);
      expect(r.metrics.mae, closeTo(2380.952, 0.001));
      expect(r.nextForecast, closeTo(25000 / 7, 1e-9));
    });
  });
}
