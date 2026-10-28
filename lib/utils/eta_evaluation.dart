/// ETA performance: ONE authoritative evaluation of "what the notification predicted" against
/// "when the truck was GPS-confirmed in the area".
///
/// Pure (no Firebase, no UI, no clock unless supplied) so the Analytics summary card and the
/// ETA Performance details are the same numbers by construction.
///
/// Definitions
///  * Prediction  - one persisted approach notification: it states N minutes at `timestamp`.
///                  predicted arrival = sent time + N minutes. Nothing is defaulted: a
///                  notification that states no estimate is not a prediction.
///  * Arrival     - one persisted `auto_arrival` record, which the driver app writes only after
///                  consecutive in-area GPS fixes. Its persisted timestamp is the actual arrival.
///                  A predicted time is never used as an arrival.
///  * Visit       - one truck trip entering one area. Several staged alerts (15/10/5 min) for the
///                  same visit are ONE visit: the visit is judged on its FIRST notified ETA
///                  ("first notified ETA"), and the later stages are listed under it.
///  * Metrics     - per visit: average absolute error, share within +/-5 min, evaluated visits.
///                  The per-prediction figures are exposed separately and never mixed in.
///  * Error       - actual - predicted, in minutes (positive = later than predicted), rounded to
///                  0.1 min, identical in summary and details.
///
/// Matching
///  * An approach with a trip id only matches an arrival with the SAME trip id, same area and
///    (when both name a truck) the same truck, at or after the time it was sent.
///  * A legacy approach (no trip id) matches only an arrival that also has no trip id, with the
///    same truck AND area, at or after it was sent and within [legacyMaxGapMinutes]. Without a
///    truck on both sides there is no match: the record stays unmatched rather than guessed.
///  * Dates are Asia/Manila (UTC+8) calendar days of the notification SENT time.
enum EtaVisitStatus {
  /// Arrival recorded; error available.
  evaluated,

  /// No GPS-confirmed arrival yet and the prediction is still recent.
  awaiting,

  /// No GPS-confirmed arrival was recorded for an old prediction.
  noArrival,

  /// The visit was withdrawn (trip ended FULL/COMPLETED, or explicitly withdrawn) before arrival.
  withdrawn,

  /// The notification carried no ETA minutes, so there is nothing to evaluate.
  noEstimate,
}

class EtaPrediction {
  const EtaPrediction({
    required this.notificationKey,
    required this.type,
    required this.source,
    required this.stage,
    required this.sentMs,
    required this.predictedMinutes,
    required this.minutesFromMessage,
    this.signedErrorMin,
  });

  final String notificationKey;
  final String type;
  final String source; // Auto | Manual
  final String stage; // approach_15 ... or '' for older records
  final int sentMs;

  /// Minutes the notification stated, or null when it stated none.
  final int? predictedMinutes;

  /// true when the minutes were read from message text (older records without `eta_minutes`).
  final bool minutesFromMessage;

  /// actual - predicted (minutes, 0.1 resolution); null while there is no valid arrival.
  final double? signedErrorMin;

  int? get predictedArrivalMs =>
      predictedMinutes == null ? null : sentMs + predictedMinutes! * 60000;
  double? get absErrorMin => signedErrorMin?.abs();

  EtaPrediction _withError(double? e) => EtaPrediction(
        notificationKey: notificationKey,
        type: type,
        source: source,
        stage: stage,
        sentMs: sentMs,
        predictedMinutes: predictedMinutes,
        minutesFromMessage: minutesFromMessage,
        signedErrorMin: e,
      );
}

class EtaVisit {
  const EtaVisit({
    required this.visitKey,
    required this.areaKey,
    required this.area,
    required this.truckId,
    required this.tripId,
    required this.predictions,
    required this.status,
    this.truckIds = const <String>[],
    this.arrivalMs,
    this.arrivalKey,
    this.legacyMatch = false,
    this.withdrawnReason,
  });

  final String visitKey;
  final String areaKey;
  final String area;
  final String truckId; // '' when the record names none
  /// Every distinct truck label seen on this visit's records (usually one).
  final List<String> truckIds;
  bool get truckLabelsDiffer => truckIds.length > 1;
  final String? tripId; // null for records written before trip ids existed
  final List<EtaPrediction> predictions; // sent-time order, never empty
  final EtaVisitStatus status;
  final int? arrivalMs;
  final String? arrivalKey;
  final bool legacyMatch;
  final String? withdrawnReason;

  /// The prediction the visit is judged on.
  EtaPrediction get first => predictions.first;
  String get source => first.source;
  int get sentMs => first.sentMs;
  int? get predictedMinutes => first.predictedMinutes;
  int? get predictedArrivalMs => first.predictedArrivalMs;
  double? get signedErrorMin => status == EtaVisitStatus.evaluated ? first.signedErrorMin : null;
  double? get absErrorMin => signedErrorMin?.abs();
  bool get isEvaluated => status == EtaVisitStatus.evaluated && signedErrorMin != null;
}

class EtaSummary {
  const EtaSummary({
    required this.visits,
    required this.evaluatedVisits,
    required this.awaitingVisits,
    required this.noArrivalVisits,
    required this.withdrawnVisits,
    required this.noEstimateVisits,
    required this.avgAbsErrorMin,
    required this.within5Count,
    required this.avgSignedErrorMin,
    required this.predictionsEvaluated,
    required this.avgPredictionAbsErrorMin,
  });

  final int visits;
  final int evaluatedVisits;
  final int awaitingVisits;
  final int noArrivalVisits;
  final int withdrawnVisits;
  final int noEstimateVisits;

  /// null when no visit was evaluated (never 0 / a default).
  final double? avgAbsErrorMin;
  final int within5Count;
  final double? avgSignedErrorMin;

  /// Per-prediction view: every evaluated stage of every evaluated visit.
  final int predictionsEvaluated;
  final double? avgPredictionAbsErrorMin;

  bool get hasEvaluated => evaluatedVisits > 0;

  /// null when nothing was evaluated.
  int? get within5Pct =>
      evaluatedVisits == 0 ? null : ((within5Count / evaluatedVisits) * 100).round();
}

class EtaEvaluation {
  EtaEvaluation._();

  static const int legacyMaxGapMinutes = 120;
  static const int staleAfterMinutes = 6 * 60;
  static const double withinToleranceMin = 5.0;
  static const Duration manilaOffset = Duration(hours: 8);

  /// Epoch ms from a stored value (seconds or ms); null when absent/invalid.
  static int? normalizeMs(Object? raw) {
    final num? n = raw is num ? raw : num.tryParse(raw?.toString() ?? '');
    if (n == null || n <= 0) return null;
    final int v = n.toInt();
    return v < 10000000000 ? v * 1000 : v;
  }

  /// Wall-clock in Asia/Manila as a UTC-flagged DateTime (format its fields directly).
  static DateTime manila(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).add(manilaOffset);

  static String _norm(String s) => s.trim().toLowerCase();

  static String _str(Object? v) => (v ?? '').toString().trim();

  /// Builds the visits from the raw `notifications` map.
  ///
  /// [canonicalize] maps an area label to its canonical name (identity by default).
  /// [closedTripIds] are trips known to have ended (FULL/COMPLETED); a visit of such a trip with
  /// no arrival is "withdrawn".
  /// [requiredMethod], when given, keeps only approach alerts stamped with that `eta_method`
  /// (alerts from an earlier, superseded method are not evaluated). Arrivals are unaffected.
  static List<EtaVisit> build(
    Object? rawNotifications, {
    required int nowMs,
    String? Function(String raw)? canonicalize,
    Set<String> closedTripIds = const <String>{},
    String? requiredMethod,
  }) {
    if (rawNotifications is! Map) return const <EtaVisit>[];
    String canon(String raw) => (canonicalize?.call(raw) ?? raw).trim();

    final List<_Rec> approaches = <_Rec>[];
    final List<_Rec> arrivals = <_Rec>[];

    rawNotifications.forEach((Object? key, Object? val) {
      if (val is! Map) return;
      final String type = _str(val['type'] ?? val['category']);
      final String upperType = type.toUpperCase();
      if (upperType == 'TRUCK_PROXIMITY') return; // legacy resident broadcast: no truck/trip identity
      final String areaRaw = _str(val['purok'] ?? val['area'] ?? val['location']);
      if (areaRaw.isEmpty) return;
      final String msg = _str(val['message'] ?? val['description']);
      final int? ts = normalizeMs(val['timestamp']);
      if (ts == null) return; // never substitute "now" for a missing time

      final bool isArrival = type == 'auto_arrival';
      final bool isManual = type.toLowerCase().contains('manual');
      final String lower = msg.toLowerCase();
      final bool isApproach = type == 'auto_approach' ||
          (!isArrival && (lower.contains('approaching') || lower.contains('on the way')));
      if (!isArrival && !isApproach) return;
      if (isApproach && requiredMethod != null && _str(val['eta_method']) != requiredMethod) return;

      final String area = canon(areaRaw);
      String truck = _cleanTruck(_str(val['truck_id']));
      if (truck.isEmpty) truck = _cleanTruck(_truckFromMessage(msg));
      final String trip = _str(val['trip_id']);

      final _Rec r = _Rec(
        key: key.toString(),
        type: type,
        area: area,
        areaKey: _norm(area),
        truck: truck,
        trip: trip.isEmpty ? null : trip,
        ts: ts,
        stage: _str(val['stage']),
        source: isManual ? 'Manual' : 'Auto',
        withdrawn: _isWithdrawn(val, upperType),
      );
      if (isArrival) {
        arrivals.add(r);
      } else {
        final Object? em = val['eta_minutes'];
        int? minutes;
        bool fromMsg = false;
        final num? n = em is num ? em : num.tryParse(em?.toString() ?? '');
        if (n != null && n > 0) {
          minutes = n.round();
        } else {
          minutes = _minutesFromMessage(msg);
          fromMsg = minutes != null;
        }
        r.minutes = minutes;
        r.minutesFromMessage = fromMsg;
        approaches.add(r);
      }
    });

    int byTs(_Rec a, _Rec b) {
      final int c = a.ts.compareTo(b.ts);
      return c != 0 ? c : a.key.compareTo(b.key);
    }

    approaches.sort(byTs);
    arrivals.sort(byTs);

    // Group predictions into visits.
    final Map<String, _Group> groups = <String, _Group>{};
    final List<_Group> ordered = <_Group>[];
    final Map<String, _Group> openLegacy = <String, _Group>{}; // truck|area -> latest unmatched group
    final int gapMs = legacyMaxGapMinutes * 60000;

    for (final _Rec p in approaches) {
      _Rec? arrival;
      bool legacy = false;
      String groupKey;
      _Group? g;

      if (p.trip != null) {
        // The trip id is the identity of the visit (one driver session). Truck labels are
        // attributes only: the same trip may carry different truck labels over time
        // (profile vs registry vs plate) and must still be one visit.
        arrival = _firstWhere(arrivals, (_Rec a) =>
            a.trip == p.trip && a.areaKey == p.areaKey && a.ts >= p.ts);
        groupKey = 'trip|${p.trip}|${p.areaKey}';
        g = groups[groupKey];
      } else {
        legacy = true;
        if (p.truck.isNotEmpty) {
          arrival = _firstWhere(arrivals, (_Rec a) =>
              a.trip == null &&
              a.areaKey == p.areaKey &&
              a.truck.isNotEmpty &&
              a.truck == p.truck &&
              a.ts >= p.ts &&
              a.ts - p.ts <= gapMs);
        }
        if (arrival != null) {
          groupKey = 'legacy|${p.truck}|${p.areaKey}|arr:${arrival.key}';
          g = groups[groupKey];
        } else {
          final String slot = '${p.truck}|${p.areaKey}';
          final _Group? open = openLegacy[slot];
          if (open != null && p.ts - open.recs.first.ts <= gapMs) {
            g = open;
            groupKey = open.key;
          } else {
            groupKey = 'legacy|$slot|sent:${p.key}';
            g = null;
          }
        }
      }

      if (g == null) {
        g = _Group(groupKey, p.trip, legacy);
        groups[groupKey] = g;
        ordered.add(g);
        if (legacy && arrival == null) openLegacy['${p.truck}|${p.areaKey}'] = g;
      }
      g.recs.add(p);
      g.arrival ??= arrival;
    }

    final List<EtaVisit> visits = <EtaVisit>[];
    for (final _Group g in ordered) {
      final _Rec head = g.recs.first;
      final _Rec? arr = g.arrival;

      final List<EtaPrediction> predictions = g.recs.map((_Rec r) {
        double? err;
        if (arr != null && r.minutes != null && arr.ts >= r.ts) {
          final int predictedMs = r.ts + r.minutes! * 60000;
          err = _round1((arr.ts - predictedMs) / 60000.0);
        }
        return EtaPrediction(
          notificationKey: r.key,
          type: r.type,
          source: r.source,
          stage: r.stage,
          sentMs: r.ts,
          predictedMinutes: r.minutes,
          minutesFromMessage: r.minutesFromMessage,
        )._withError(err);
      }).toList();

      EtaVisitStatus status;
      String? reason;
      final bool explicitlyWithdrawn = g.recs.any((_Rec r) => r.withdrawn);
      if (predictions.first.predictedMinutes == null) {
        status = EtaVisitStatus.noEstimate;
      } else if (arr != null && predictions.first.signedErrorMin != null) {
        status = EtaVisitStatus.evaluated;
      } else if (explicitlyWithdrawn) {
        status = EtaVisitStatus.withdrawn;
        reason = 'Notification was withdrawn before arrival.';
      } else if (g.trip != null && closedTripIds.contains(g.trip)) {
        status = EtaVisitStatus.withdrawn;
        reason = 'The trip ended (FULL/COMPLETED) before arrival in this area.';
      } else if (nowMs - head.ts > staleAfterMinutes * 60000) {
        status = EtaVisitStatus.noArrival;
      } else {
        status = EtaVisitStatus.awaiting;
      }

      visits.add(EtaVisit(
        visitKey: g.key,
        areaKey: head.areaKey,
        area: head.area,
        truckId: head.truck.isNotEmpty
            ? head.truck
            : g.recs.map((_Rec r) => r.truck).firstWhere((String t) => t.isNotEmpty, orElse: () => (status == EtaVisitStatus.evaluated ? arr?.truck : null) ?? ''),
        truckIds: <String>{
          ...g.recs.map((_Rec r) => r.truck),
          if (arr != null) arr.truck,
        }.where((String t) => t.isNotEmpty).toList(),
        tripId: g.trip,
        predictions: predictions,
        status: status,
        arrivalMs: status == EtaVisitStatus.evaluated ? arr!.ts : null,
        arrivalKey: status == EtaVisitStatus.evaluated ? arr!.key : null,
        legacyMatch: g.legacy && status == EtaVisitStatus.evaluated,
        withdrawnReason: reason,
      ));
    }

    visits.sort((EtaVisit a, EtaVisit b) => b.sentMs.compareTo(a.sentMs)); // newest first
    return visits;
  }

  /// Area / source / Asia-Manila date filter on the notification SENT time of the visit's first
  /// prediction. [area] null or "All areas" = all. Both views call exactly this.
  static List<EtaVisit> filter(
    List<EtaVisit> visits, {
    String? area,
    String? source,
    DateTime? start,
    DateTime? end,
  }) {
    final String a = _norm(area ?? '');
    final bool allAreas = a.isEmpty || a == 'all areas';
    final String s = _norm(source ?? '');
    final bool allSources = s.isEmpty || s == 'all sources';
    final int? startKey = start == null ? null : start.year * 10000 + start.month * 100 + start.day;
    final int? endKey = end == null ? null : end.year * 10000 + end.month * 100 + end.day;
    return visits.where((EtaVisit v) {
      if (!allAreas && v.areaKey != a) return false;
      if (!allSources && _norm(v.source) != s) return false;
      final DateTime d = manila(v.sentMs);
      final int dayKey = d.year * 10000 + d.month * 100 + d.day;
      if (startKey != null && dayKey < startKey) return false;
      if (endKey != null && dayKey > endKey) return false;
      return true;
    }).toList();
  }

  static EtaSummary summarize(List<EtaVisit> visits) {
    int evaluated = 0, awaiting = 0, noArrival = 0, withdrawn = 0, noEstimate = 0, within5 = 0;
    double absSum = 0, signedSum = 0;
    int predictionCount = 0;
    double predAbsSum = 0;
    for (final EtaVisit v in visits) {
      switch (v.status) {
        case EtaVisitStatus.evaluated:
          if (v.signedErrorMin == null) break;
          evaluated++;
          absSum += v.absErrorMin!;
          signedSum += v.signedErrorMin!;
          if (v.absErrorMin! <= withinToleranceMin) within5++;
          for (final EtaPrediction p in v.predictions) {
            if (p.signedErrorMin == null) continue;
            predictionCount++;
            predAbsSum += p.absErrorMin!;
          }
          break;
        case EtaVisitStatus.awaiting:
          awaiting++;
          break;
        case EtaVisitStatus.noArrival:
          noArrival++;
          break;
        case EtaVisitStatus.withdrawn:
          withdrawn++;
          break;
        case EtaVisitStatus.noEstimate:
          noEstimate++;
          break;
      }
    }
    return EtaSummary(
      visits: visits.length,
      evaluatedVisits: evaluated,
      awaitingVisits: awaiting,
      noArrivalVisits: noArrival,
      withdrawnVisits: withdrawn,
      noEstimateVisits: noEstimate,
      avgAbsErrorMin: evaluated == 0 ? null : _round1(absSum / evaluated),
      within5Count: within5,
      avgSignedErrorMin: evaluated == 0 ? null : _round1(signedSum / evaluated),
      predictionsEvaluated: predictionCount,
      avgPredictionAbsErrorMin: predictionCount == 0 ? null : _round1(predAbsSum / predictionCount),
    );
  }

  // ---- helpers -------------------------------------------------------------------------

  static double _round1(double v) => (v * 10).roundToDouble() / 10;

  static _Rec? _firstWhere(List<_Rec> list, bool Function(_Rec) test) {
    for (final _Rec r in list) {
      if (test(r)) return r;
    }
    return null;
  }

  static int? _minutesFromMessage(String msg) {
    final RegExpMatch? m = RegExp(r'(\d+)\s*min', caseSensitive: false).firstMatch(msg);
    final int? v = m == null ? null : int.tryParse(m.group(1) ?? '');
    return (v != null && v > 0) ? v : null;
  }

  static String _truckFromMessage(String msg) {
    final RegExpMatch? a = RegExp(r'^Truck\s+(\S+)\s+is on the way', caseSensitive: false).firstMatch(msg);
    if (a != null) return a.group(1) ?? '';
    final RegExpMatch? b = RegExp(r'garbage truck\s*\(([^)]+)\)', caseSensitive: false).firstMatch(msg);
    return b?.group(1)?.trim() ?? '';
  }

  /// "Unknown"/"null" are placeholders written when a profile had no truck, not identities.
  static String _cleanTruck(String v) {
    final String l = v.trim().toLowerCase();
    return (l.isEmpty || l == 'unknown' || l == 'null' || l == 'none' || l == 'n/a') ? '' : v.trim();
  }

  static bool _isWithdrawn(Map<dynamic, dynamic> val, String upperType) {
    if (upperType.contains('WITHDRAWN') || upperType.contains('CANCEL')) return true;
    final String status = _str(val['eta_status'] ?? val['status']).toLowerCase();
    return status == 'withdrawn' || status == 'cancelled';
  }
}

class _Rec {
  _Rec({
    required this.key,
    required this.type,
    required this.area,
    required this.areaKey,
    required this.truck,
    required this.trip,
    required this.ts,
    required this.stage,
    required this.source,
    required this.withdrawn,
  });

  final String key;
  final String type;
  final String area;
  final String areaKey;
  final String truck;
  final String? trip;
  final int ts;
  final String stage;
  final String source;
  final bool withdrawn;
  int? minutes;
  bool minutesFromMessage = false;
}

class _Group {
  _Group(this.key, this.trip, this.legacy);
  final String key;
  final String? trip;
  final bool legacy;
  final List<_Rec> recs = <_Rec>[];
  _Rec? arrival;
}

/// One page of a list (1-based [page], clamped into range).
class EtaPage<T> {
  const EtaPage({
    required this.items,
    required this.page,
    required this.pageCount,
    required this.total,
    required this.firstShown,
    required this.lastShown,
  });

  final List<T> items;
  final int page;
  final int pageCount;
  final int total;

  /// 1-based positions for "Showing X-Y of Z" (both 0 when empty).
  final int firstShown;
  final int lastShown;

  bool get hasPrevious => page > 1;
  bool get hasNext => page < pageCount;

  static const int defaultPageSize = 30;

  static EtaPage<T> of<T>(List<T> all, int page, {int pageSize = defaultPageSize}) {
    final int total = all.length;
    final int pages = total == 0 ? 1 : ((total + pageSize - 1) ~/ pageSize);
    final int p = page < 1 ? 1 : (page > pages ? pages : page);
    final int start = (p - 1) * pageSize;
    final int end = start + pageSize > total ? total : start + pageSize;
    return EtaPage<T>(
      items: total == 0 ? <T>[] : all.sublist(start, end),
      page: p,
      pageCount: pages,
      total: total,
      firstShown: total == 0 ? 0 : start + 1,
      lastShown: total == 0 ? 0 : end,
    );
  }
}
