/// Archived trips stay in `driver_routes` (nothing is deleted, so an archive can be undone by
/// removing the flag) but are left out of Route History, Load History, verified visits, the
/// predictive models and every analytics figure.
///
/// Used for stale records: trips that were started, never finished (no FULL/COMPLETED) and have
/// had no activity for more than 12 hours, typically early tests and phones that died.
class TripArchive {
  TripArchive._();

  static bool isArchived(Object? trip) => trip is Map && (trip['archived'] == true || trip['archived'] == 'true');
}

/// Archived complaints (test or invalid records) stay in MySQL and in the admin's complaint
/// records, but are left out of the Analytics figures and the dashboard counts.
class ComplaintArchive {
  ComplaintArchive._();

  static bool isArchived(Object? complaint) {
    if (complaint is! Map) return false;
    final Object? v = complaint['is_archived'];
    return v == true || v == 1 || v == '1' || v == 'true';
  }
}
