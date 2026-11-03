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

    test('no rate, no number: nothing is invented', () {
      final AreaEstimate e = WasteEstimation.estimate(const AreaConfig(name: 'A', size: ha10), const EstimationParams());
      expect(e.status, EstimateStatus.notConfigured);
      expect(e.kgPerDay, isNull);
      expect(e.limitations.single, contains('Not configured'));
    });

    test('a rate without a source is not accepted', () {
      final AreaEstimate e = WasteEstimation.estimate(const AreaConfig(name: 'A', size: ha10), const EstimationParams(kgPerHectareDay: 30));
      expect(e.hasNumber, isFalse);
    });

    test('per-hectare: hectares × sourced rate, neutral multiplier', () {
      final AreaEstimate e = WasteEstimation.estimate(
          const AreaConfig(name: 'A', size: ha10), const EstimationParams(kgPerHectareDay: 30, hectareRateSource: 'doc X'));
      expect(e.method, EstimateMethod.perHectare);
      expect(e.kgPerDay, 300);
      expect(e.multiplierUsed, 1.0);
      expect(e.confidence, 'Medium');
      expect(e.breakdown.last, '= 300 kg/day');
    });

    test('unverified size lowers the confidence', () {
      final AreaEstimate e = WasteEstimation.estimate(
          const AreaConfig(name: 'A', size: AreaSize(m2: 100000, kind: AreaSizeKind.polygon)),
          const EstimationParams(kgPerHectareDay: 30, hectareRateSource: 'doc X'));
      expect(e.confidence, 'Low');
      expect(e.limitations.join(' '), contains('not verified'));
    });

    test('per-capita is preferred over per-hectare when both are available', () {
      final AreaEstimate e = WasteEstimation.estimate(
          const AreaConfig(name: 'A', size: ha10, population: 1000, populationSource: 'PSA', populationYear: 2020),
          const EstimationParams(kgPerCapitaDay: 0.5, rateSource: 'NSWMC', kgPerHectareDay: 30, hectareRateSource: 'doc X'));
      expect(e.method, EstimateMethod.perCapita);
      expect(e.kgPerDay, 500);
    });

    test('population without a source is ignored', () {
      final AreaEstimate e = WasteEstimation.estimate(
          const AreaConfig(name: 'A', population: 1000), const EstimationParams(kgPerCapitaDay: 0.5, rateSource: 'NSWMC'));
      expect(e.hasNumber, isFalse);
    });

    test('seasonal multiplier: default 1.0; applies only when active, positive and sourced', () {
      const AreaConfig a = AreaConfig(name: 'A', size: ha10);
      EstimationParams p(SeasonalMultiplier s) => EstimationParams(kgPerHectareDay: 30, hectareRateSource: 'doc X', seasonal: s);
      expect(WasteEstimation.estimate(a, p(const SeasonalMultiplier())).kgPerDay, 300);
      expect(WasteEstimation.estimate(a, p(const SeasonalMultiplier(value: 1.2, active: true))).kgPerDay, 300, reason: 'no source');
      expect(WasteEstimation.estimate(a, p(const SeasonalMultiplier(value: 1.2, source: 'doc', active: false))).kgPerDay, 300);
      expect(WasteEstimation.estimate(a, p(const SeasonalMultiplier(value: -1, source: 'doc', active: true))).kgPerDay, 300);
      final AreaEstimate on = WasteEstimation.estimate(a, p(const SeasonalMultiplier(value: 1.2, source: 'doc', active: true)));
      expect(on.kgPerDay, closeTo(360, 1e-9));
      expect(on.breakdown.join(' '), contains('not validated'));
    });

    test('a measured weight for exactly this area wins and is not multiplied', () {
      final AreaEstimate e = WasteEstimation.estimate(
          const AreaConfig(name: 'A', size: ha10, measuredKg: 1234),
          const EstimationParams(kgPerHectareDay: 30, hectareRateSource: 'x', seasonal: SeasonalMultiplier(value: 2, source: 's', active: true)));
      expect(e.isMeasured, isTrue);
      expect(e.kgPerDay, 1234);
      expect(WasteEstimation.estimate(const AreaConfig(name: 'A', measuredKg: -1), const EstimationParams()).status, EstimateStatus.invalidInput);
    });

    test('summary keeps proxy estimates and measured weights apart and counts unconfigured areas', () {
      const EstimationParams params = EstimationParams(kgPerHectareDay: 30, hectareRateSource: 'x');
      final EstimateSummary s = WasteEstimation.summarize(<AreaEstimate>[
        WasteEstimation.estimate(const AreaConfig(name: 'A', size: ha10), params),
        WasteEstimation.estimate(const AreaConfig(name: 'B', measuredKg: 800), params),
        WasteEstimation.estimate(const AreaConfig(name: 'C'), params),
      ]);
      expect(s.areaCount, 3);
      expect(s.configuredCount, 2);
      expect(s.estimatedKgPerDay, 300);
      expect(s.measuredKg, 800);
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
      expect(christmas.breakdown.join(' '), contains('Christmas and New Year'));
      expect(regular.breakdown.join(' '), contains('regular day'));
    });

    test('the barangay figure and the area shares follow the day, and the shares still add up to it', () {
      final Map<String, Object?> body = <String, Object?>{
        'success': true,
        'available': true,
        'settings': <String, Object?>{'kg_per_capita_day': '0.5', 'rate_source': 'NSWMC', 'seasonal_value': '1.15', 'seasonal_source': 'cities', 'seasonal_active': 1},
        'areas': <Object>[
          <String, Object?>{'area_key': 'barangay_total', 'population': 19278, 'population_source': 'PSA', 'population_year': 2020},
          <String, Object?>{'area_key': 'a', 'size_m2': '100000', 'size_kind': 'manual', 'size_source': 's', 'size_verified': 1},
          <String, Object?>{'area_key': 'b', 'size_m2': '300000', 'size_kind': 'manual', 'size_source': 's', 'size_verified': 1},
        ],
      };
      final Map<String, Object?> puroks = <String, Object?>{'a': <String, Object?>{'name': 'A'}, 'b': <String, Object?>{'name': 'B'}};
      final WasteEstimationData reg = WasteEstimationData.fromRaw((body: body, puroks: puroks), day: DateTime(2026, 11, 4));
      final WasteEstimationData xmas = WasteEstimationData.fromRaw((body: body, puroks: puroks), day: DateTime(2026, 12, 25));
      expect(reg.whole.kgPerDay, closeTo(9639, 1e-6));
      expect(xmas.whole.kgPerDay, closeTo(9639 * 1.15, 1e-6));
      expect(xmas.regularDayBarangayKg, closeTo(9639, 1e-6));
      expect(reg.barangayTruckloads, closeTo(9639 / 5000, 1e-9));
      final double sum = xmas.estimates.map((AreaEstimate e) => e.kgPerDay!).reduce((double x, double y) => x + y);
      expect(sum, closeTo(xmas.whole.kgPerDay!, 1e-6));
      expect(xmas.holidayBarangayKg(HolidayCalendar.periods.first), closeTo(9639 * 1.15, 1e-6));
      expect(xmas.holidayBarangayKg(HolidayCalendar.periods[1]), isNull); // Undas: no multiplier
    });
  });

  group('area share of the barangay estimate', () {
    const AreaShareBasis basis = AreaShareBasis(barangayKgPerDay: 4000, totalSizedM2: 400000, sizedCount: 2, barangayBasis: '8,000 people × 0.50 kg/person/day');
    const EstimationParams noRates = EstimationParams();
    AreaConfig sized(String n, double m2, {bool verified = true}) => AreaConfig(name: n, size: AreaSize(m2: m2, kind: AreaSizeKind.polygon, source: 'sketch', verified: verified));

    test('each sized area takes its proportion of the barangay figure, and the shares add up to it', () {
      final AreaEstimate a = WasteEstimation.estimate(sized('A', 100000), noRates, share: basis);
      final AreaEstimate b = WasteEstimation.estimate(sized('B', 300000), noRates, share: basis);
      expect(a.method, EstimateMethod.areaShare);
      expect(a.kgPerDay, closeTo(1000, 1e-9));
      expect(b.kgPerDay, closeTo(3000, 1e-9));
      expect(a.kgPerDay! + b.kgPerDay!, closeTo(4000, 1e-9));
      expect(a.confidence, 'Low');
      expect(a.breakdown.join(' '), contains('25.0%'));
      expect(a.limitations.join(' '), contains('same waste per hectare'));
    });

    test('an unverified size is said to be unverified', () {
      final AreaEstimate a = WasteEstimation.estimate(sized('A', 100000, verified: false), noRates, share: basis);
      expect(a.limitations.join(' '), contains('not verified'));
    });

    test('no size, no share; no barangay figure or fewer than two sized areas, no basis', () {
      expect(WasteEstimation.estimate(const AreaConfig(name: 'X'), noRates, share: basis).hasNumber, isFalse);
      expect(WasteEstimation.estimate(sized('A', 100000), noRates).hasNumber, isFalse);
      const AreaShareBasis one = AreaShareBasis(barangayKgPerDay: 4000, totalSizedM2: 100000, sizedCount: 1, barangayBasis: 'x');
      const AreaShareBasis zero = AreaShareBasis(barangayKgPerDay: 0, totalSizedM2: 400000, sizedCount: 2, barangayBasis: 'x');
      expect(one.usable, isFalse);
      expect(zero.usable, isFalse);
      expect(WasteEstimation.estimate(sized('A', 100000), noRates, share: one).hasNumber, isFalse);
    });

    test('an area with its own sourced rate, population or a measured weight does not use the share', () {
      final AreaEstimate perHa = WasteEstimation.estimate(sized('A', 100000), const EstimationParams(kgPerHectareDay: 30, hectareRateSource: 'doc'), share: basis);
      expect(perHa.method, EstimateMethod.perHectare);
      final AreaEstimate perCap = WasteEstimation.estimate(
          const AreaConfig(name: 'A', population: 1000, populationSource: 'PSA'), const EstimationParams(kgPerCapitaDay: 0.5, rateSource: 'NSWMC'), share: basis);
      expect(perCap.method, EstimateMethod.perCapita);
      final AreaEstimate measured = WasteEstimation.estimate(
          const AreaConfig(name: 'A', size: AreaSize(m2: 100000, kind: AreaSizeKind.polygon, source: 's'), measuredKg: 700), noRates, share: basis);
      expect(measured.method, EstimateMethod.measured);
      expect(measured.kgPerDay, 700);
    });

    test('shares are estimates: they go to the estimated total, not to the measured weights', () {
      final EstimateSummary s = WasteEstimation.summarize(<AreaEstimate>[
        WasteEstimation.estimate(sized('A', 100000), noRates, share: basis),
        WasteEstimation.estimate(sized('B', 300000), noRates, share: basis),
      ]);
      expect(s.estimatedKgPerDay, closeTo(4000, 1e-9));
      expect(s.measuredKg, 0);
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
