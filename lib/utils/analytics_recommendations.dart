/// Deterministic, evidence-based Analytics recommendations.
///
/// Every recommendation is derived from a metric the dashboard already shows for the SAME
/// date range and area, and states that metric as its evidence. Nothing is inferred that the
/// data cannot support:
///  * no complaints is reported as "no complaints filed", never as resident satisfaction;
///  * live truck status is a snapshot of "now" and is not used for period recommendations
///    (an idle truck is not evidence of spare capacity);
///  * waste weights are only quoted as measured when scale weights were recorded; the
///    per-trip capacity figure is a hypothetical estimate;
///  * no forecast accuracy or confidence is claimed.
library;

class Recommendation {
  const Recommendation({
    required this.finding,
    required this.evidence,
    required this.action,
    required this.scope,
    this.limitation,
  });

  final String finding;
  final String evidence;
  final String action;

  /// Area / truck / period the finding applies to.
  final String scope;
  final String? limitation;

  String toBullet() {
    final StringBuffer b = StringBuffer('• $finding\n  Evidence: $evidence\n  Action: $action');
    if (limitation != null && limitation!.isNotEmpty) b.write('\n  Limitation: $limitation');
    return b.toString();
  }
}

class RecommendationInput {
  const RecommendationInput({
    required this.periodLabel,
    required this.area,
    required this.residentComplaintsByArea,
    required this.pendingResidentComplaints,
    required this.totalResidentComplaints,
    required this.visitsByArea,
    required this.truckStopAreas,
    required this.unconfirmedPasses,
    required this.tripsConsidered,
    required this.tripsWithoutEvidence,
    required this.completedTrips,
    required this.measuredWeightTrips,
    this.collectionDataAvailable = true,
    this.complaintDataAvailable = true,
  });

  final String periodLabel;
  final String area;
  final Map<String, int> residentComplaintsByArea;
  final int pendingResidentComplaints;
  final int totalResidentComplaints;
  final Map<String, int> visitsByArea;

  /// Areas the trucks are expected to serve (stationary sweeping areas excluded), already
  /// narrowed to the selected area.
  final List<String> truckStopAreas;
  final Map<String, int> unconfirmedPasses;
  final int tripsConsidered;
  final int tripsWithoutEvidence;
  final int completedTrips;
  final int measuredWeightTrips;
  final bool collectionDataAvailable;
  final bool complaintDataAvailable;
}

class AnalyticsRecommendations {
  AnalyticsRecommendations._();

  static List<Recommendation> build(RecommendationInput i) {
    final List<Recommendation> out = <Recommendation>[];
    final String scope = '${i.area}, ${i.periodLabel}';

    final bool noCollection = !i.collectionDataAvailable || i.tripsConsidered == 0;
    final bool noComplaints = !i.complaintDataAvailable || i.totalResidentComplaints == 0;
    if (noCollection && noComplaints) {
      out.add(Recommendation(
        finding: 'Not enough data for recommendations in this period.',
        evidence: i.collectionDataAvailable ? 'No collection trips and no resident complaints were recorded.' : 'Collection data could not be loaded.',
        action: 'Select a period with recorded trips, or confirm that drivers are signed in and recording GPS during collection.',
        scope: scope,
      ));
      return out;
    }

    // 1. Resident complaints (MySQL, resident-filed only).
    if (i.complaintDataAvailable) {
      if (i.pendingResidentComplaints > 0) {
        final List<MapEntry<String, int>> top = i.residentComplaintsByArea.entries.where((MapEntry<String, int> e) => e.value > 0).toList()
          ..sort((MapEntry<String, int> a, MapEntry<String, int> b) => b.value.compareTo(a.value));
        final String where = top.isEmpty ? '' : ' Most reports: ${top.take(3).map((MapEntry<String, int> e) => '${e.key} (${e.value})').join(', ')}.';
        out.add(Recommendation(
          finding: '${i.pendingResidentComplaints} resident complaint(s) are still unresolved.',
          evidence: '${i.pendingResidentComplaints} of ${i.totalResidentComplaints} complaint(s) filed in the period are pending or in progress.$where',
          action: 'Review and resolve the pending complaints, starting with the areas that have the most reports.',
          scope: scope,
        ));
      } else if (i.totalResidentComplaints == 0) {
        out.add(Recommendation(
          finding: 'No resident complaints were filed in this period.',
          evidence: '0 complaints in the complaints records for the selected period and area.',
          action: 'No complaint follow-up is needed.',
          scope: scope,
          limitation: 'The absence of complaints does not measure resident satisfaction.',
        ));
      }
    }

    if (i.collectionDataAvailable && i.tripsConsidered > 0) {
      // 2. Complaints in areas with no verified visit.
      final List<String> complaintNoVisit = i.residentComplaintsByArea.entries
          .where((MapEntry<String, int> e) => e.value > 0 && i.truckStopAreas.contains(e.key) && (i.visitsByArea[e.key] ?? 0) == 0)
          .map((MapEntry<String, int> e) => '${e.key} (${e.value})')
          .toList();
      if (complaintNoVisit.isNotEmpty) {
        out.add(Recommendation(
          finding: 'Complaints were filed in areas with no verified collection visit.',
          evidence: 'Complaints with 0 verified visits: ${complaintNoVisit.join(', ')}.',
          action: 'Check with the assigned driver whether these areas were collected, and schedule a collection if they were missed.',
          scope: scope,
          limitation: 'A visit is only verified when the truck recorded enough GPS fixes inside the area while collecting.',
        ));
      }

      // 3. Expected areas without a verified visit.
      final List<String> unvisited = i.truckStopAreas.where((String a) => (i.visitsByArea[a] ?? 0) == 0).toList();
      if (unvisited.isNotEmpty) {
        final List<String> passes = unvisited.where((String a) => (i.unconfirmedPasses[a] ?? 0) > 0).toList();
        out.add(Recommendation(
          finding: '${unvisited.length} of ${i.truckStopAreas.length} collection area(s) have no verified visit.',
          evidence: 'No verified visit: ${unvisited.join(', ')}.${passes.isEmpty ? '' : ' Trucks passed through without stopping in: ${passes.join(', ')}.'}',
          action: 'Confirm whether these areas were due for collection in this period.',
          scope: scope,
          limitation: 'There is no schedule data, so it is not known whether these areas were due.',
        ));
      }

      // 4. GPS evidence quality.
      if (i.tripsWithoutEvidence > 0) {
        out.add(Recommendation(
          finding: '${i.tripsWithoutEvidence} of ${i.tripsConsidered} trip(s) have no usable GPS points.',
          evidence: 'No accurate GPS fixes were recorded while these trips were collecting, so their visits cannot be verified.',
          action: 'Ask drivers to keep location services on, at high accuracy, while collecting.',
          scope: scope,
        ));
      }

      // 5. Weight basis.
      if (i.completedTrips > 0 && i.measuredWeightTrips < i.completedTrips) {
        final int estimated = i.completedTrips - i.measuredWeightTrips;
        out.add(Recommendation(
          finding: i.measuredWeightTrips == 0
              ? 'Waste volumes for this period are estimates, not measured weights.'
              : 'Some waste volumes for this period are estimates.',
          evidence: '$estimated of ${i.completedTrips} full load(s) have no recorded scale weight and use the 5,000 kg per full-load estimate.',
          action: 'Record the scale weight for each full load so waste totals are based on measured weights.',
          scope: scope,
          limitation: 'The 5,000 kg capacity figure is an estimate, not verified truck data.',
        ));
      }
    }

    return out;
  }

  static String asText(List<Recommendation> recs) => recs.map((Recommendation r) => r.toBullet()).join('\n\n');
}
