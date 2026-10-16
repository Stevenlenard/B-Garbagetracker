import '../models/driver_trip.dart';
import 'load_history.dart';

/// Where a "related record" action may lead, decided from the trip itself.
class TripLink {
  const TripLink.available(this.tripId, {this.date})
      : isAvailable = true,
        message = null;

  const TripLink.unavailable(this.tripId, this.message)
      : isAvailable = false,
        date = null;

  final bool isAvailable;
  final String tripId;

  /// Collection date to open the related list on.
  final DateTime? date;

  /// Why the related record does not exist (shown instead of opening something else).
  final String? message;
}

/// Route History <-> Load History navigation. Both directions carry the SAME trip id and
/// never fall back to a different trip.
class TripLinks {
  TripLinks._();

  /// Route History trip -> its Load History record. Only a finalized collection has one.
  static TripLink toLoad(DriverTrip trip) {
    if (trip.tripId.isEmpty) {
      return const TripLink.unavailable('', 'This trip has no identifier.');
    }
    if (!LoadHistory.isLoad(trip)) {
      return TripLink.unavailable(
        trip.tripId,
        trip.isFinalizedCollection
            ? 'This trip has no recorded movement, so no load was recorded for it.'
            : 'No load record yet: the collection has not been marked FULL.',
      );
    }
    return TripLink.available(trip.tripId, date: LoadHistory.eventTime(trip));
  }

  /// Load History record -> its collection route (opens by trip id, never "any trip").
  static TripLink toRoute(DriverTrip trip) {
    if (trip.tripId.isEmpty) {
      return const TripLink.unavailable('', 'This load has no trip identifier.');
    }
    return TripLink.available(trip.tripId, date: LoadHistory.eventTime(trip));
  }
}
