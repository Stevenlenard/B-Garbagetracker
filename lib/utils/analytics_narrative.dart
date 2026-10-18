/// Deterministic wording for the Analytics screen.
///
/// Every sentence is built from a figure the dashboard already shows for the SAME area and period, and each
/// possible outcome has its own wording: nothing recorded, collection only, complaints only, everything
/// resolved, work pending, missed areas, estimated weights, a period that includes today, and data that
/// could not be loaded. Nothing is inferred that the data cannot support: no satisfaction claim from an
/// absence of complaints, no trend claim, no cause for a complaint.
library;

String plural(int n, String one, [String? many]) => '$n ${n == 1 ? one : (many ?? '${one}s')}';

String _list(List<String> items) {
  if (items.isEmpty) return '';
  if (items.length == 1) return items.first;
  if (items.length == 2) return '${items[0]} and ${items[1]}';
  return '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
}

class NarrativeInput {
  const NarrativeInput({
    required this.area,
    required this.periodLabel,
    this.periodIncludesToday = false,
    this.loadTrips = 0,
    this.measuredLoads = 0,
    this.pending = 0,
    this.inProgress = 0,
    this.resolved = 0,
    this.expectedAreas = 0,
    this.visitedAreas = 0,
    this.verifiedVisits = 0,
    this.tripsConsidered = 0,
    this.tripsWithoutEvidence = 0,
    this.collectionDataAvailable = true,
    this.complaintDataAvailable = true,
    this.complaintNoun = 'resident complaint',
    this.complaintNounPlural = 'resident complaints',
  });

  final String area;
  final String periodLabel;
  final bool periodIncludesToday;

  /// Full loads recorded (completed collections).
  final int loadTrips;

  /// Of those, loads with a recorded scale weight.
  final int measuredLoads;
  final int pending;
  final int inProgress;
  final int resolved;

  /// Collection areas the trucks are expected to serve, and how many had a verified visit.
  final int expectedAreas;
  final int visitedAreas;
  final int verifiedVisits;
  final int tripsConsidered;
  final int tripsWithoutEvidence;
  final bool collectionDataAvailable;
  final bool complaintDataAvailable;

  /// What the counts are called: resident complaints only, or complaints and driver issues together.
  final String complaintNoun;
  final String complaintNounPlural;

  int get unresolved => pending + inProgress;
  int get totalComplaints => unresolved + resolved;
  bool get isAllAreas => area == 'All Areas';
  String get scope => isAllAreas ? 'all areas' : area;
}

class NarrativeCheck {
  const NarrativeCheck(this.title, this.subtitle);
  final String title;
  final String subtitle;
}

class AnalyticsNarrative {
  AnalyticsNarrative._();

  // ---------------------------------------------------------------- operational summary

  static String operationalSummary(NarrativeInput i) {
    final List<String> s = <String>[];
    final String where = i.isAllAreas ? 'all areas' : i.area;

    // 1. Collection.
    if (!i.collectionDataAvailable) {
      s.add('Collection records for $where could not be loaded for ${i.periodLabel}, so collection figures are left out.');
    } else if (i.loadTrips == 0) {
      s.add(i.totalComplaints == 0
          ? 'No full loads and no ${i.complaintNounPlural} were recorded for $where in ${i.periodLabel}.'
          : 'No full loads were recorded for $where in ${i.periodLabel}.');
    } else {
      s.add('${plural(i.loadTrips, 'full load')} ${i.loadTrips == 1 ? 'was' : 'were'} recorded for $where in ${i.periodLabel}.');
      s.add(_weightBasis(i));
    }

    // 2. Complaints.
    if (!i.complaintDataAvailable) {
      s.add('Complaint records could not be loaded, so complaint figures are left out.');
    } else if (i.totalComplaints == 0) {
      if (!(i.collectionDataAvailable && i.loadTrips == 0)) {
        s.add('No ${i.complaintNounPlural} were filed in the period; this does not measure resident satisfaction.');
      }
    } else if (i.unresolved == 0) {
      s.add('All ${plural(i.totalComplaints, i.complaintNoun, i.complaintNounPlural)} filed in the period ${i.totalComplaints == 1 ? 'is' : 'are'} resolved.');
    } else {
      final List<String> parts = <String>[
        if (i.pending > 0) '${i.pending} pending',
        if (i.inProgress > 0) '${i.inProgress} in progress',
      ];
      s.add('${i.unresolved} of ${plural(i.totalComplaints, i.complaintNoun, i.complaintNounPlural)} ${i.unresolved == 1 ? 'is' : 'are'} unresolved '
          '(${_list(parts)}) and ${i.resolved} ${i.resolved == 1 ? 'is' : 'are'} resolved.');
    }

    // 3. Coverage.
    if (i.collectionDataAvailable && i.expectedAreas > 0 && i.tripsConsidered > 0) {
      if (i.visitedAreas >= i.expectedAreas) {
        s.add('Every one of the ${plural(i.expectedAreas, 'collection area')} has a verified visit (${plural(i.verifiedVisits, 'visit')}).');
      } else if (i.visitedAreas == 0) {
        s.add('None of the ${plural(i.expectedAreas, 'collection area')} has a verified visit yet.');
      } else {
        s.add('${i.visitedAreas} of ${plural(i.expectedAreas, 'collection area')} have a verified visit '
            '(${plural(i.verifiedVisits, 'visit')} in total).');
      }
      if (i.tripsWithoutEvidence > 0) {
        s.add('${i.tripsWithoutEvidence} of ${plural(i.tripsConsidered, 'trip')} had no usable GPS points, so ${i.tripsWithoutEvidence == 1 ? 'its' : 'their'} visits cannot be verified.');
      }
    }

    // 4. The empty case gets guidance, not just a statement.
    if (i.collectionDataAvailable && i.loadTrips == 0 && i.totalComplaints == 0 && i.complaintDataAvailable) {
      s.add('Either no collection took place, or drivers were not signed in and recording GPS. Verify the collection logs.');
    } else if (i.collectionDataAvailable && i.loadTrips == 0 && i.totalComplaints > 0) {
      s.add('Verify the collection logs for the period.');
    }

    if (i.periodIncludesToday) s.add('The period includes today, so these figures may still change.');
    return s.join(' ');
  }

  static String _weightBasis(NarrativeInput i) {
    if (i.measuredLoads <= 0) {
      return 'Waste volume is an estimate: none of these loads has a recorded scale weight.';
    }
    if (i.measuredLoads >= i.loadTrips) {
      return 'Every load has a recorded scale weight, so waste totals are based on measured weights.';
    }
    return '${i.measuredLoads} of ${plural(i.loadTrips, 'load')} ${i.measuredLoads == 1 ? 'has' : 'have'} a recorded scale weight; the rest are estimated.';
  }

  // ---------------------------------------------------------------- recommended checks

  /// Up to three checks, most important first. Never empty.
  static List<NarrativeCheck> recommendedChecks(NarrativeInput i) {
    final List<NarrativeCheck> c = <NarrativeCheck>[];
    final String where = i.isAllAreas ? 'any area' : i.area;

    if (i.complaintDataAvailable && i.pending > 0) {
      c.add(NarrativeCheck('Review ${plural(i.pending, 'pending complaint')}', 'Check the category and location in ${i.scope}, then assign or resolve.'));
    }
    if (i.complaintDataAvailable && i.inProgress > 0) {
      c.add(NarrativeCheck('Follow up ${plural(i.inProgress, 'complaint')} in progress', 'Confirm whether the work is finished and mark each one resolved.'));
    }
    if (!i.collectionDataAvailable) {
      c.add(const NarrativeCheck('Reload the collection records', 'They could not be loaded; check the connection and select the period again.'));
    } else if (i.loadTrips == 0) {
      c.add(NarrativeCheck('Verify collection logs', 'No full load is recorded for ${i.scope} in this period; confirm that trips were made and drivers recorded GPS.'));
    }
    if (i.collectionDataAvailable && i.expectedAreas > 0 && i.tripsConsidered > 0 && i.visitedAreas < i.expectedAreas) {
      final int missed = i.expectedAreas - i.visitedAreas;
      c.add(NarrativeCheck('Confirm collection in ${plural(missed, 'area')} with no verified visit',
          'A missing visit does not prove the area was missed; check with the assigned driver.'));
    }
    if (i.collectionDataAvailable && i.tripsWithoutEvidence > 0) {
      c.add(NarrativeCheck('Check GPS settings with drivers',
          '${plural(i.tripsWithoutEvidence, 'trip')} had no usable GPS points; location must stay on, at high accuracy, while collecting.'));
    }
    if (i.collectionDataAvailable && i.loadTrips > 0 && i.measuredLoads < i.loadTrips) {
      c.add(NarrativeCheck('Record scale weights', '${plural(i.loadTrips - i.measuredLoads, 'full load')} still use the estimated weight.'));
    }
    if (c.isEmpty) {
      c.add(NarrativeCheck('No action needed for $where', 'Complaints are resolved, areas are covered and weights are recorded for this period.'));
      c.add(const NarrativeCheck('Keep the routine check', 'Review the dashboard again after the next collection.'));
    }
    if (c.length == 1 && i.pending == 0 && i.inProgress == 0 && i.collectionDataAvailable && i.loadTrips > 0) {
      c.add(NarrativeCheck('Monitor the collection pace', '${plural(i.loadTrips, 'full load')} recorded in ${i.periodLabel}.'));
    }
    return c.take(3).toList();
  }

  // ---------------------------------------------------------------- area summary panel

  /// The one-paragraph summary above the area table.
  static String areaSummary({
    required String area,
    required int visits,
    required int complaints,
    required String needsReviewArea,
    required int needsReviewComplaints,
    required int needsReviewVisits,
    int zeroVisitAreas = 0,
    int activeAreas = 0,
  }) {
    final bool all = area == 'All Areas';
    final String lead;
    if (visits == 0 && complaints == 0) {
      lead = '$area: no verified collection visit and no resident complaint was recorded in the selected period.';
    } else if (complaints == 0) {
      lead = '$area: ${plural(visits, 'verified collection visit')} and no resident complaints in the selected period.';
    } else if (visits == 0) {
      lead = '$area: ${plural(complaints, 'resident complaint')} but no verified collection visit in the selected period.';
    } else {
      lead = '$area: ${plural(visits, 'verified collection visit')} and ${plural(complaints, 'resident complaint')} in the selected period.';
    }
    final StringBuffer b = StringBuffer(lead);
    if (needsReviewArea.isNotEmpty) {
      b.write(' $needsReviewArea has the most complaints ($needsReviewComplaints) with ${plural(needsReviewVisits, 'verified visit')}.');
    } else if (complaints > 0) {
      b.write(all ? ' No area has more than 2 complaints.' : ' That is no more than 2 complaints.');
    }
    if (visits == 0 && complaints > 0) {
      b.write(' A missing visit does not prove the area was missed.');
    }
    if (all && zeroVisitAreas == 0 && activeAreas > 0 && visits > 0) {
      b.write(' Every active area has a recorded visit.');
    }
    return b.toString();
  }

  /// Bullet lines for the limitations box.
  static List<String> limitationLines({
    required String area,
    required int activeAreas,
    required int zeroVisitAreas,
  }) {
    final bool all = area == 'All Areas';
    return <String>[
      '• Telemetry aggregates coverage across ${plural(activeAreas, 'active sector')} in $area.',
      if (all) '• San Nicolas operates as a stationary sweeping area (tracked independently from mobile truck routes).',
      zeroVisitAreas > 0
          ? '• ${plural(zeroVisitAreas, 'sector')} report${zeroVisitAreas == 1 ? 's' : ''} zero visits; zero records do not inherently confirm missed service.'
          : (activeAreas == 0 ? '• No active sector has data for this selection.' : '• All active sectors report recorded collection visits during the selected timeframe.'),
      '• Area complaint counts include resident complaints only; driver truck issues are reported separately.',
    ];
  }
}
