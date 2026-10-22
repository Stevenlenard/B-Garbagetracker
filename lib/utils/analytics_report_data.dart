/// One immutable snapshot of everything the Analytics PDF reports.
///
/// The screen fills it once, at export time, from the SAME state the dashboard cards use
/// (period loads, filtered ETA visits, complaint counts...). The PDF builder only formats it,
/// so tables, charts, legends and summary sentences cannot disagree. Every section carries an
/// explicit `available`/reason: a missing source is reported as unavailable, never as 0.
///
/// All text is ASCII (the PDF uses the built-in Helvetica font).
class ReportMeta {
  const ReportMeta({
    required this.start,
    required this.end,
    required this.area,
    required this.generatedAtManila,
  });

  final DateTime start; // calendar dates as selected in Analytics (Asia/Manila)
  final DateTime end;
  final String area;
  final DateTime generatedAtManila; // UTC-flagged, fields are Manila wall-clock

  bool get isAllAreas => area.trim().isEmpty || area.trim().toLowerCase() == 'all areas';
}

class ReportFleet {
  const ReportFleet.available(this.counts)
      : available = true,
        reason = null;
  const ReportFleet.unavailable(this.reason)
      : available = false,
        counts = const <String, int>{};

  final bool available;
  final String? reason;

  /// Ordered: Active, Paused, Full, Completed, Offline.
  final Map<String, int> counts;

  int get total => counts.values.fold(0, (int a, int b) => a + b);
  int get connected => total - (counts['Offline'] ?? 0);
}

class ReportLoadRow {
  const ReportLoadRow({
    required this.tripId,
    required this.driver,
    required this.truck,
    required this.fullAtManila,
    required this.kg,
    required this.measured,
    required this.status,
    this.timeRecorded = true,
  });

  final String tripId;
  final String driver;
  final String truck;
  final DateTime fullAtManila;
  final double kg;
  final bool measured;
  final String status;

  /// False for legacy records that carry no time at all (their [fullAtManila] is only the
  /// moment they were loaded); reports show "Not recorded" instead of that time.
  final bool timeRecorded;
}

class ReportWaste {
  const ReportWaste.available({
    required this.rows,
    required this.partial,
    required this.ongoingUnfinished,
    required this.staleUnfinished,
    this.perTripEstimateKg = 5000.0,
  })  : available = true,
        reason = null;

  const ReportWaste.unavailable(this.reason)
      : available = false,
        rows = const <ReportLoadRow>[],
        partial = false,
        ongoingUnfinished = 0,
        staleUnfinished = 0,
        perTripEstimateKg = 5000.0;

  final bool available;
  final String? reason;
  final List<ReportLoadRow> rows; // one per trip id, newest first
  final bool partial; // some collection sources could not be reached
  final int ongoingUnfinished;
  final int staleUnfinished;
  final double perTripEstimateKg;

  int get trips => rows.length;
  double get totalKg => rows.fold(0.0, (double a, ReportLoadRow r) => a + r.kg);
  double get totalTons => totalKg / 1000.0;
  int get measuredCount => rows.where((ReportLoadRow r) => r.measured).length;
  int get estimatedCount => trips - measuredCount;
  bool get isEstimate => estimatedCount > 0;

  /// Trips whose record carries no time (left out of [byDate]).
  int get untimedCount => rows.where((ReportLoadRow r) => !r.timeRecorded).length;

  /// FULL trips per Manila calendar day (yyyy-MM-dd), oldest first. Trips without a recorded
  /// time are left out (see [untimedCount]) instead of being placed on the day of the report.
  Map<String, int> get byDate {
    final Map<String, int> out = <String, int>{};
    for (final ReportLoadRow r in rows.where((ReportLoadRow r) => r.timeRecorded)) {
      final String k = '${r.fullAtManila.year.toString().padLeft(4, '0')}-'
          '${r.fullAtManila.month.toString().padLeft(2, '0')}-'
          '${r.fullAtManila.day.toString().padLeft(2, '0')}';
      out[k] = (out[k] ?? 0) + 1;
    }
    final List<String> keys = out.keys.toList()..sort();
    return <String, int>{for (final String k in keys) k: out[k]!};
  }

  /// FULL trips per driver, most first.
  Map<String, int> get byDriver {
    final Map<String, int> out = <String, int>{};
    for (final ReportLoadRow r in rows) {
      final String k = r.driver.trim().isEmpty ? 'Not recorded' : r.driver.trim();
      out[k] = (out[k] ?? 0) + 1;
    }
    final List<MapEntry<String, int>> e = out.entries.toList()
      ..sort((MapEntry<String, int> a, MapEntry<String, int> b) => b.value.compareTo(a.value));
    return <String, int>{for (final MapEntry<String, int> x in e) x.key: x.value};
  }
}

class ReportCoverageRow {
  const ReportCoverageRow({required this.area, required this.visits, this.unconfirmed = 0});
  final String area;
  final int visits; // verified collection visits (one per trip and area) in the period
  final int unconfirmed; // trips that entered the area without meeting the visit policy
}

/// Verified collection visits per area (GPS evidence, see utils/collection_visits.dart).
/// There is no schedule data, so no completion percentage is reported.
class ReportCoverage {
  const ReportCoverage.available({
    required this.rows,
    required this.areasVisited,
    required this.expectedAreas,
    this.tripsWithoutEvidence = 0,
  })  : available = true,
        reason = null;
  const ReportCoverage.unavailable(this.reason)
      : available = false,
        rows = const <ReportCoverageRow>[],
        areasVisited = 0,
        expectedAreas = 0,
        tripsWithoutEvidence = 0;

  final bool available;
  final String? reason;
  final List<ReportCoverageRow> rows;
  final int areasVisited;
  final int expectedAreas;
  final int tripsWithoutEvidence;

  int get totalVisits => rows.fold(0, (int a, ReportCoverageRow r) => a + r.visits);
}

class ReportEtaRow {
  const ReportEtaRow({
    required this.area,
    required this.truck,
    required this.tripId,
    required this.sentAt,
    required this.etaMinutes,
    required this.predictedAt,
    required this.actualAt,
    required this.signedErrorMin,
    required this.status,
  });

  final String area;
  final String truck;
  final String tripId;
  final DateTime sentAt; // Manila wall-clock
  final int? etaMinutes;
  final DateTime? predictedAt;
  final DateTime? actualAt; // null = no GPS-confirmed arrival
  final double? signedErrorMin;
  final String status;
}

class ReportEta {
  const ReportEta.available({
    required this.rows,
    required this.evaluated,
    required this.awaiting,
    required this.noArrival,
    required this.withdrawn,
    required this.noEstimate,
    required this.avgAbsErrorMin,
    required this.within5Pct,
    required this.totalVisits,
  })  : available = true,
        reason = null;
  const ReportEta.unavailable(this.reason)
      : available = false,
        rows = const <ReportEtaRow>[],
        evaluated = 0,
        awaiting = 0,
        noArrival = 0,
        withdrawn = 0,
        noEstimate = 0,
        avgAbsErrorMin = null,
        within5Pct = null,
        totalVisits = 0;

  final bool available;
  final String? reason;
  final List<ReportEtaRow> rows; // newest first
  final int totalVisits;
  final int evaluated;
  final int awaiting;
  final int noArrival;
  final int withdrawn;
  final int noEstimate;
  final double? avgAbsErrorMin;
  final int? within5Pct;
}

class ReportComplaints {
  const ReportComplaints.available({required this.counts, required this.byArea})
      : available = true,
        reason = null;
  const ReportComplaints.unavailable(this.reason)
      : available = false,
        counts = const <String, int>{},
        byArea = const <String, int>{};

  final bool available;
  final String? reason;
  final Map<String, int> counts; // Pending, In Progress, Resolved
  final Map<String, int> byArea;

  int get total => counts.values.fold(0, (int a, int b) => a + b);
}

class ReportForecast {
  const ReportForecast.available({
    required this.tomorrowKg,
    required this.weeklyKg,
    required this.samples,
  })  : available = true,
        reason = null;
  const ReportForecast.unavailable(this.reason)
      : available = false,
        tomorrowKg = 0,
        weeklyKg = 0,
        samples = 0;

  final bool available;
  final String? reason;
  final double tomorrowKg;
  final double weeklyKg;

  /// Number of recorded collection weights the baseline was derived from.
  final int samples;
}

/// Operational figures shown on the Analytics page (null = not computed for this selection).
class ReportOperations {
  const ReportOperations({this.distanceKm, this.stopsPerRoute, this.avgCollectionHours, this.missedPickups, this.missedPending, this.missedResolved});
  static const ReportOperations none = ReportOperations();

  final double? distanceKm;
  final int? stopsPerRoute;
  final double? avgCollectionHours;

  /// Resident reports of uncollected garbage in the period.
  final int? missedPickups;
  final int? missedPending;
  final int? missedResolved;
}

/// Scheduled routes (Route Assignments) in the period, with the same rules as the dashboard card.
class ReportAssignments {
  const ReportAssignments.available({
    required this.total,
    required this.pending,
    required this.inProgress,
    required this.completed,
    required this.missed,
    required this.cancelled,
    required this.due,
    required this.completionRate,
    required this.assignedAreas,
    required this.verifiedAreas,
  })  : available = true,
        reason = null;
  const ReportAssignments.unavailable(this.reason)
      : available = false,
        total = 0,
        pending = 0,
        inProgress = 0,
        completed = 0,
        missed = 0,
        cancelled = 0,
        due = 0,
        completionRate = null,
        assignedAreas = 0,
        verifiedAreas = 0;

  final bool available;
  final String? reason;
  final int total;
  final int pending;
  final int inProgress;
  final int completed;
  final int missed;
  final int cancelled;
  final int due;
  final double? completionRate; // percent
  final int assignedAreas;
  final int verifiedAreas;

  double? get coveragePercent => assignedAreas == 0 ? null : verifiedAreas * 100.0 / assignedAreas;
}

/// One evaluated predictive model (or baseline): sample size and error metrics.
class ReportModelMetric {
  const ReportModelMetric({required this.label, required this.n, required this.mae, required this.rmse, required this.r2, required this.unit});
  final String label;
  final int n;
  final double? mae;
  final double? rmse;
  final double? r2;
  final String unit; // 'min' or 'kg'
}

/// Objective 3: the arrival-time linear regression and the moving-average forecast of the daily load.
class ReportPredictive {
  const ReportPredictive.available({
    required this.samples,
    required this.trips,
    required this.intercept,
    required this.slope,
    required this.method,
    required this.metrics,
    required this.maWindow,
    required this.maDays,
    required this.maNextKg,
    required this.recent,
  })  : available = true,
        reason = null;
  const ReportPredictive.unavailable(this.reason)
      : available = false,
        samples = 0,
        trips = 0,
        intercept = null,
        slope = null,
        method = '',
        metrics = const <ReportModelMetric>[],
        maWindow = 7,
        maDays = 0,
        maNextKg = null,
        recent = const <(DateTime, double, double)>[];

  final bool available;
  final String? reason;
  final int samples; // arrival samples extracted from recorded trips
  final int trips;
  final double? intercept; // minutes
  final double? slope; // minutes per km
  final String method; // how the samples were split for testing
  final List<ReportModelMetric> metrics; // regression, live rule, notified estimates, moving average
  final int maWindow;
  final int maDays;
  final double? maNextKg;

  /// Last days of the moving-average backtest: (day, actual kg, forecast kg).
  final List<(DateTime, double, double)> recent;
}

class AnalyticsReportData {
  const AnalyticsReportData({
    required this.meta,
    required this.fleet,
    required this.waste,
    required this.coverage,
    required this.eta,
    required this.complaints,
    required this.forecast,
    this.aiNarrative,
    this.operations = ReportOperations.none,
    this.assignments = const ReportAssignments.unavailable('scheduled routes were not loaded'),
    this.predictive = const ReportPredictive.unavailable('the predictive models were not computed'),
  });

  final ReportOperations operations;
  final ReportAssignments assignments;
  final ReportPredictive predictive;

  final ReportMeta meta;
  final ReportFleet fleet;
  final ReportWaste waste;
  final ReportCoverage coverage;
  final ReportEta eta;
  final ReportComplaints complaints;
  final ReportForecast forecast;

  /// Optional AI-written text. Only used when it is real text (placeholders are dropped).
  final String? aiNarrative;

  // ---- deterministic text ------------------------------------------------------------

  static bool isPlaceholder(String? t) {
    if (t == null) return true;
    final String s = t.trim().toLowerCase();
    if (s.isEmpty) return true;
    const List<String> bad = <String>[
      'analyzing', 'evaluating', 'reviewing', 'loading', 'calculating',
      'unable to generate', 'rule-based', 'system performing normally',
    ];
    return bad.any(s.contains);
  }

  String? get usableNarrative => isPlaceholder(aiNarrative) ? null : aiNarrative!.trim();

  static String tons(double kg) {
    final double t = kg / 1000.0;
    return t == t.roundToDouble() ? t.toStringAsFixed(0) : t.toStringAsFixed(1);
  }

  /// Key indicators for the executive summary (label, value, note). Unavailable data is
  /// stated as unavailable, never as 0.
  List<List<String>> get keyIndicators {
    final List<List<String>> k = <List<String>>[];
    if (waste.available) {
      k.add(<String>['Finalized FULL collection trips', '${waste.trips}', 'Counted once per trip id']);
      final String basis = waste.measuredCount == 0
          ? 'Hypothetical: ${tons(waste.perTripEstimateKg)} tons per FULL trip, not measured'
          : '${waste.measuredCount} measured, ${waste.estimatedCount} hypothetical estimate(s)';
      k.add(<String>['Estimated waste volume', '${tons(waste.totalKg)} tons', basis]);
    } else {
      k.add(<String>['Finalized FULL collection trips', 'Unavailable', waste.reason ?? 'Source not reachable']);
      k.add(<String>['Estimated waste volume', 'Unavailable', 'Depends on collection trips']);
    }
    if (fleet.available) {
      k.add(<String>[
        'Fleet (current snapshot)',
        '${fleet.connected} of ${fleet.total} trucks connected',
        'Active ${fleet.counts['Active']}, Paused ${fleet.counts['Paused']}, Full ${fleet.counts['Full']}, '
            'Completed ${fleet.counts['Completed']}, Offline ${fleet.counts['Offline']}',
      ]);
    } else {
      k.add(<String>['Fleet (current snapshot)', 'Unavailable', fleet.reason ?? '']);
    }
    if (complaints.available) {
      k.add(<String>[
        'Resident complaints',
        '${complaints.total}',
        'Pending ${complaints.counts['Pending'] ?? 0}, In Progress ${complaints.counts['In Progress'] ?? 0}, '
            'Resolved ${complaints.counts['Resolved'] ?? 0}',
      ]);
    } else {
      k.add(<String>['Resident complaints', 'Unavailable', complaints.reason ?? '']);
    }
    if (coverage.available) {
      k.add(<String>[
        'Areas with a verified visit',
        '${coverage.areasVisited} of ${coverage.expectedAreas}',
        '${coverage.totalVisits} verified visit(s) from GPS evidence; no schedule data, so no completion rate',
      ]);
    } else {
      k.add(<String>['Areas with a verified visit', 'Unavailable', coverage.reason ?? '']);
    }
    if (eta.available && eta.evaluated > 0) {
      k.add(<String>[
        'ETA accuracy',
        '${eta.avgAbsErrorMin!.toStringAsFixed(1)} min average error',
        '${eta.within5Pct}% within +/-5 min over ${eta.evaluated} evaluated visit(s)',
      ]);
    } else {
      k.add(<String>[
        'ETA accuracy',
        'Not available',
        eta.available ? 'No GPS-confirmed arrivals to evaluate in this period' : (eta.reason ?? ''),
      ]);
    }
    return k;
  }

  /// Observations derived only from the metrics above.
  List<String> get insights {
    final List<String> out = <String>[];
    if (waste.available) {
      if (waste.trips == 0) {
        out.add('No FULL collection trips were finalized in this period for the selected area.');
      } else {
        final Map<String, int> d = waste.byDate;
        final MapEntry<String, int> peak =
            d.entries.reduce((MapEntry<String, int> a, MapEntry<String, int> b) => b.value > a.value ? b : a);
        out.add('${waste.trips} FULL trip(s) across ${d.length} collection day(s); the busiest day was '
            '${peak.key} with ${peak.value} trip(s).');
      }
      if (waste.staleUnfinished > 0) {
        out.add('${waste.staleUnfinished} unfinished trip record(s) have no recent activity and no FULL '
            'event; they are excluded from all totals.');
      }
      if (waste.partial) {
        out.add('Some collection sources could not be reached; collection totals may be incomplete.');
      }
    }
    if (complaints.available && complaints.total > 0) {
      final int pending = complaints.counts['Pending'] ?? 0;
      final int resolved = complaints.counts['Resolved'] ?? 0;
      out.add('$pending of ${complaints.total} complaint(s) are pending and $resolved are resolved.');
    }
    if (coverage.available && coverage.rows.isNotEmpty) {
      final List<String> none =
          coverage.rows.where((ReportCoverageRow r) => r.visits == 0).map((ReportCoverageRow r) => r.area).toList();
      if (none.isNotEmpty) out.add('No verified collection visit was recorded for: ${none.join(', ')}.');
      if (coverage.tripsWithoutEvidence > 0) {
        out.add('${coverage.tripsWithoutEvidence} trip(s) had no usable GPS points, so their visits cannot be verified.');
      }
    }
    if (eta.available && eta.awaiting + eta.noArrival > 0) {
      out.add('${eta.awaiting + eta.noArrival} ETA visit(s) have no GPS-confirmed arrival and are not '
          'part of the accuracy figures.');
    }
    if (out.isEmpty) out.add('No verified activity was recorded for the selected period and area.');
    return out;
  }

  /// Follow-up points that only restate gaps visible in the data.
  List<String> get recommendations {
    final List<String> out = <String>[];
    if (complaints.available && (complaints.counts['Pending'] ?? 0) > 0) {
      out.add('Review the ${complaints.counts['Pending']} pending complaint(s) in the Resident Complaints queue.');
    }
    if (waste.available && waste.staleUnfinished > 0) {
      out.add('Close or archive the ${waste.staleUnfinished} stale unfinished trip record(s) so that '
          'collection history is unambiguous.');
    }
    if (waste.available && waste.estimatedCount > 0) {
      out.add('Record measured weights at the landfill to replace the hypothetical '
          '${tons(waste.perTripEstimateKg)}-ton estimate.');
    }
    if (eta.available && eta.noArrival > 0) {
      out.add('${eta.noArrival} ETA visit(s) recorded no GPS-confirmed arrival; check GPS coverage on those routes.');
    }
    if (out.isEmpty) out.add('No follow-up actions are indicated by the recorded data for this period.');
    return out;
  }

  String get conclusion {
    final StringBuffer b = StringBuffer();
    if (waste.available) {
      b.write('During the selected period the system recorded ${waste.trips} finalized FULL collection trip(s)');
      b.write(waste.trips == 0 ? '. ' : ', an estimated ${tons(waste.totalKg)} tons'
          '${waste.isEstimate ? ' (hypothetical, not measured)' : ''}. ');
    } else {
      b.write('Collection totals were unavailable for this report. ');
    }
    if (coverage.available) {
      b.write('${coverage.areasVisited} of ${coverage.expectedAreas} collection area(s) had a verified visit. ');
    }
    if (complaints.available) {
      b.write('${complaints.total} complaint(s) were recorded. ');
    }
    if (eta.available && eta.evaluated > 0) {
      b.write('ETA notifications were on average ${eta.avgAbsErrorMin!.toStringAsFixed(1)} minutes from the '
          'GPS-confirmed arrival.');
    } else {
      b.write('ETA accuracy could not be evaluated for this period.');
    }
    return b.toString().trim();
  }
}
