import 'dart:math' as math;

/// Area-based waste ESTIMATION (Objective 2.2). Pure Dart, shared by Admin Web and Admin Mobile.
///
/// Simple on purpose: estimate (kg/day) = area size (ha) x waste rate (kg/ha/day) x holiday multiplier of the day.
/// It never touches the capacity-equivalent total (5,000 kg per FULL event), measured weights, Load History or the forecast.
/// The waste rate is entered by an admin together with its source; nothing is invented here (no default rate, no default
/// area). Without a sourced rate or a usable size the result is [EstimateStatus.notConfigured] and carries no number.

/// Where an area's size came from.
enum AreaSizeKind { polygon, manual, none }

/// Why an estimate has no number, or how it was obtained.
enum EstimateStatus { ok, notConfigured, invalidInput }

class AreaSize {
  const AreaSize({required this.m2, required this.kind, this.source = '', this.verified = false, this.note = ''});

  const AreaSize.none() : this(m2: 0, kind: AreaSizeKind.none);

  final double m2;
  final AreaSizeKind kind;

  /// Who/what says this is the size (document, GIS layer, field survey + date). Required for a manual size.
  final String source;

  /// True only when an admin confirmed the size against the real collection area.
  final bool verified;
  final String note;

  double get hectares => m2 / 10000.0;
  double get km2 => m2 / 1000000.0;
  bool get usable => kind != AreaSizeKind.none && m2.isFinite && m2 > 0;
}

/// A holiday or celebration period (every year). Only a period with documented waste figures carries a multiplier
/// ([uplift]); the others are listed so that nothing is applied to them without evidence.
class HolidayPeriod {
  const HolidayPeriod({
    required this.id,
    required this.name,
    required this.fromMonth,
    required this.fromDay,
    required this.toMonth,
    required this.toDay,
    required this.uplift,
    required this.note,
    this.source = '',
  });

  final String id;
  final String name;
  final int fromMonth, fromDay, toMonth, toDay;

  /// true: documented increase of waste; the admin-set multiplier applies on these days.
  final bool uplift;
  final String note;
  final String source;

  static int _key(int m, int d) => m * 100 + d;

  /// Whether [day] falls in the period (it may wrap over New Year).
  bool contains(DateTime day) {
    final int k = _key(day.month, day.day), a = _key(fromMonth, fromDay), b = _key(toMonth, toDay);
    return a <= b ? (k >= a && k <= b) : (k >= a || k <= b);
  }

  static const List<String> _months = <String>['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  String get dates => (fromMonth == toMonth && fromDay == toDay)
      ? '${_months[fromMonth - 1]} $fromDay'
      : '${_months[fromMonth - 1]} $fromDay to ${_months[toMonth - 1]} $toDay';
}

/// The national and Lipa holidays considered for the seasonal multiplier. Facts as found on 2026-11-04.
class HolidayCalendar {
  HolidayCalendar._();

  static const List<HolidayPeriod> periods = <HolidayPeriod>[
    HolidayPeriod(
      id: 'christmas',
      name: 'Christmas and New Year',
      fromMonth: 12,
      fromDay: 24,
      toMonth: 1,
      toDay: 1,
      uplift: true,
      note: 'Waste rose 10 to 20 percent in Philippine provincial cities during the holiday season.',
      source: 'Iloilo City CENRO: holiday waste up 10-20 % (425 t on Dec 18-25 against 370 t before; New Year 440 t against 400 t), reported by Panay News, January 2025; Cagayan de Oro: 480 t/day against 400 t, Dec 24 to Jan 1 (PNA-based report). Other Philippine cities, not measured in Lipa.',
    ),
    HolidayPeriod(
      id: 'undas',
      name: 'All Saints and All Souls (Undas)',
      fromMonth: 11,
      fromDay: 1,
      toMonth: 11,
      toDay: 2,
      uplift: false,
      note: 'The documented increase is cemetery waste (DENR: over 1,000 tons collected nationwide after Undas 2024), not household waste. No multiplier.',
    ),
    HolidayPeriod(
      id: 'lipa_festival',
      name: 'Lipa Coffee Festival / Feast of St. Sebastian',
      fromMonth: 1,
      fromDay: 20,
      toMonth: 1,
      toDay: 20,
      uplift: false,
      note: 'A special non-working day in Lipa City (proclaimed each year). No waste figures found, so no multiplier.',
    ),
    HolidayPeriod(
      id: 'lipa_foundation',
      name: 'Lipa City Foundation Day',
      fromMonth: 6,
      fromDay: 20,
      toMonth: 6,
      toDay: 20,
      uplift: false,
      note: 'Celebrated on June 20 (a special non-working day in Lipa City). No waste figures found, so no multiplier.',
    ),
  ];

  static HolidayPeriod? periodOn(DateTime day) {
    for (final HolidayPeriod p in periods) {
      if (p.contains(day)) return p;
    }
    return null;
  }

  /// The period (with a documented increase) that [day] belongs to, or null.
  static HolidayPeriod? upliftOn(DateTime? day) {
    if (day == null) return null;
    final HolidayPeriod? p = periodOn(day);
    return (p != null && p.uplift) ? p : null;
  }
}

/// Seasonal/holiday multiplier. Neutral (1.0, inactive) unless an admin supplies a value WITH a source.
/// With [holidaysOnly] it is applied only on the days of a period that has a documented increase (see [HolidayCalendar]);
/// every other day is 1.0.
class SeasonalMultiplier {
  const SeasonalMultiplier({this.value = 1.0, this.source = '', this.validated = false, this.active = false, this.appliesTo = '', this.holidaysOnly = false});

  final bool holidaysOnly;

  final double value;
  final String source;

  /// Only true when evidence for the value is on file; the UI must never show it as validated otherwise.
  final bool validated;
  final bool active;
  final String appliesTo;

  /// The factor actually used: 1.0 unless active, finite, positive and sourced.
  double get effective => (active && value.isFinite && value > 0 && source.trim().isNotEmpty) ? value : 1.0;
  bool get applied => effective != 1.0;

  /// The factor for [day]: [effective] on the days it applies to, otherwise 1.0.
  double on(DateTime? day) => holidaysOnly ? (HolidayCalendar.upliftOn(day) != null ? effective : 1.0) : effective;
}

/// The three things an estimate is made of: the waste rate per hectare per day (with its source), the holiday multiplier of
/// the day, and (per area) the size. Estimate = area size (ha) x waste rate (kg/ha/day) x holiday multiplier.
class EstimationParams {
  const EstimationParams({
    this.kgPerHectareDay,
    this.hectareRateSource = '',
    this.seasonal = const SeasonalMultiplier(),
    this.day,
  });

  /// The day the estimate is for (null: no holiday logic, the multiplier applies as configured).
  final DateTime? day;

  /// The seasonal factor used for [day].
  double get multiplier => seasonal.on(day);

  /// kg of waste generated per hectare per day, with the document or reasoning it comes from.
  final double? kgPerHectareDay;
  final String hectareRateSource;
  final SeasonalMultiplier seasonal;

  bool get hasRate => kgPerHectareDay != null && kgPerHectareDay!.isFinite && kgPerHectareDay! > 0 && hectareRateSource.trim().isNotEmpty;
}

/// What is known of one collection area: its name and size.
class AreaConfig {
  const AreaConfig({required this.name, this.size = const AreaSize.none()});

  final String name;
  final AreaSize size;
}

class AreaEstimate {
  const AreaEstimate({
    required this.name,
    required this.status,
    this.kgPerDay,
    this.size = const AreaSize.none(),
    this.rate,
    this.multiplierUsed = 1.0,
    this.reason = '',
  });

  final String name;
  final EstimateStatus status;

  /// Estimated kg generated per day; null when [status] is not ok.
  final double? kgPerDay;
  final AreaSize size;

  /// The kg/ha/day used.
  final double? rate;
  final double multiplierUsed;

  /// Why there is no number (only when [status] is not ok).
  final String reason;

  double get hectares => size.hectares;

  bool get hasNumber => status == EstimateStatus.ok && kgPerDay != null;
}

class WasteEstimation {
  WasteEstimation._();

  static const double _earthRadiusM = 6371008.8;

  /// Geodesic area (m²) of a ring of `[lng, lat]` vertices (open or closed). Returns 0 for fewer than 3 distinct
  /// vertices, non-finite or out-of-range coordinates, or a self-intersecting ring.
  static double polygonAreaM2(List<List<double>> ring) {
    final List<List<double>> pts = _open(ring);
    if (pts.length < 3) return 0;
    for (final List<double> p in pts) {
      if (p.length < 2 || !p[0].isFinite || !p[1].isFinite || p[0].abs() > 180 || p[1].abs() > 90) return 0;
    }
    if (_selfIntersects(pts)) return 0;
    double sum = 0;
    for (int i = 0; i < pts.length; i++) {
      final List<double> a = pts[i], b = pts[(i + 1) % pts.length];
      sum += _rad(b[0] - a[0]) * (2 + math.sin(_rad(a[1])) + math.sin(_rad(b[1])));
    }
    return (sum * _earthRadiusM * _earthRadiusM / 2).abs();
  }

  /// Parses Firebase `boundaryGeometry` (a ring, or a list holding one ring, of `[lng, lat]`) into a ring, or null.
  static List<List<double>>? parseRing(Object? geometry) {
    if (geometry is! List || geometry.isEmpty) return null;
    Object? first = geometry.first;
    final List<dynamic> ringRaw = (first is List && first.isNotEmpty && first.first is List) ? first : geometry;
    final List<List<double>> ring = <List<double>>[];
    for (final dynamic p in ringRaw) {
      if (p is! List || p.length < 2 || p[0] is! num || p[1] is! num) return null;
      ring.add(<double>[(p[0] as num).toDouble(), (p[1] as num).toDouble()]);
    }
    return ring.length >= 3 ? ring : null;
  }

  /// Size from a stored boundary. A boundary is NOT a size of the real collection area unless an admin verified it
  /// (the stored `verificationStatus` is not trusted for that); [placeholder] marks look-alike boxes as unusable.
  static AreaSize sizeFromGeometry(Object? geometry, {String source = '', bool placeholder = false, bool verified = false}) {
    final List<List<double>>? ring = parseRing(geometry);
    if (ring == null) return const AreaSize.none();
    if (placeholder) {
      return const AreaSize(m2: 0, kind: AreaSizeKind.none, note: 'Stored boundary is a placeholder shape; not a measured area.');
    }
    final double a = polygonAreaM2(ring);
    if (a <= 0) return const AreaSize(m2: 0, kind: AreaSizeKind.none, note: 'Stored boundary is invalid (too few points or self-intersecting).');
    return AreaSize(m2: a, kind: AreaSizeKind.polygon, source: source, verified: verified);
  }

  /// A manual size needs a positive finite value and a source.
  static AreaSize manualSize(double m2, String source, {bool verified = false}) {
    if (!m2.isFinite || m2 <= 0 || source.trim().isEmpty) return const AreaSize.none();
    return AreaSize(m2: m2, kind: AreaSizeKind.manual, source: source.trim(), verified: verified);
  }

  /// Names of areas whose stored polygons are look-alike boxes (areas within [tolerance] of each other, three or more),
  /// which is the signature of a placeholder, not of surveyed boundaries.
  static Set<String> placeholderAreas(Map<String, double> areaM2ByName, {double tolerance = 0.005, int minGroup = 3}) {
    final Set<String> out = <String>{};
    final List<MapEntry<String, double>> e = areaM2ByName.entries.where((MapEntry<String, double> x) => x.value > 0).toList();
    for (final MapEntry<String, double> a in e) {
      final List<String> group = <String>[
        for (final MapEntry<String, double> b in e)
          if ((b.value - a.value).abs() <= a.value * tolerance) b.key
      ];
      if (group.length >= minGroup) out.addAll(group);
    }
    return out;
  }

  /// Estimate for one area: size (ha) x waste rate (kg/ha/day) x holiday multiplier of the day. Without a usable size or a
  /// sourced rate there is no number (never a guessed fallback).
  static AreaEstimate estimate(AreaConfig area, EstimationParams params) {
    if (area.size.usable && params.hasRate) {
      final double m = params.multiplier;
      return AreaEstimate(
        name: area.name,
        status: EstimateStatus.ok,
        kgPerDay: area.size.hectares * params.kgPerHectareDay! * m,
        size: area.size,
        rate: params.kgPerHectareDay,
        multiplierUsed: m,
      );
    }
    final List<String> missing = <String>[
      if (!area.size.usable) 'no usable area size',
      if (!params.hasRate) 'no sourced waste rate',
    ];
    return AreaEstimate(name: area.name, status: EstimateStatus.notConfigured, size: area.size, reason: 'Not configured: ${missing.join(' and ')}.');
  }

  /// Totals over [estimates].
  static EstimateSummary summarize(List<AreaEstimate> estimates) {
    double kg = 0, ha = 0;
    int withNumber = 0;
    for (final AreaEstimate e in estimates) {
      if (!e.hasNumber) continue;
      withNumber++;
      kg += e.kgPerDay!;
      ha += e.hectares;
    }
    return EstimateSummary(areaCount: estimates.length, configuredCount: withNumber, estimatedKgPerDay: kg, hectares: ha);
  }

  static double _rad(double d) => d * math.pi / 180.0;

  static List<List<double>> _open(List<List<double>> ring) {
    if (ring.length > 1 && ring.first.length >= 2 && ring.last.length >= 2 && ring.first[0] == ring.last[0] && ring.first[1] == ring.last[1]) {
      return ring.sublist(0, ring.length - 1);
    }
    return ring;
  }

  static bool _selfIntersects(List<List<double>> p) {
    final int n = p.length;
    for (int i = 0; i < n; i++) {
      for (int j = i + 1; j < n; j++) {
        if ((j == i + 1) || (i == 0 && j == n - 1)) continue;
        if (_segmentsCross(p[i], p[(i + 1) % n], p[j], p[(j + 1) % n])) return true;
      }
    }
    return false;
  }

  static double _cross(List<double> o, List<double> a, List<double> b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);

  static bool _segmentsCross(List<double> a, List<double> b, List<double> c, List<double> d) {
    final double d1 = _cross(c, d, a), d2 = _cross(c, d, b), d3 = _cross(a, b, c), d4 = _cross(a, b, d);
    return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
  }
}

class EstimateSummary {
  const EstimateSummary({required this.areaCount, required this.configuredCount, required this.estimatedKgPerDay, required this.hectares});

  final int areaCount;
  final int configuredCount;

  /// Sum of the area estimates (kg/day of waste generated).
  final double estimatedKgPerDay;

  /// Sum of the sizes of the areas that have an estimate.
  final double hectares;
}
