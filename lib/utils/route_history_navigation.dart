import '../models/driver_trip.dart';

/// Asks the host (the Admin dashboard shell) to show Route History INSIDE its content
/// area. [tripId] opens that exact trip; [trip] is a fallback record when the persisted
/// one cannot be loaded. Hosts without a shell simply do not provide it and the caller
/// falls back to a normal page route.
typedef OpenRouteHistory = void Function({String? tripId, DriverTrip? trip});

/// Remembers which Admin section Route History was opened from, so Back returns there
/// (not always to the dashboard home). Opening Route History again from Route History
/// itself keeps the original section.
class RouteHistoryReturn {
  RouteHistoryReturn({this.routeHistoryIndex = 7});

  final int routeHistoryIndex;
  int returnIndex = 0;

  /// Call when navigating to Route History from [currentIndex].
  void enter(int currentIndex) {
    if (currentIndex != routeHistoryIndex) returnIndex = currentIndex;
  }

  /// Where Back (screen button or Android system back) goes.
  int get backTarget => returnIndex;
}
