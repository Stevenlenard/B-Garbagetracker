import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_database/firebase_database.dart';
import '../api/api_service.dart';
import '../models/driver_trip.dart';
import '../utils/gps_quality.dart';
import '../utils/gps_smoothing.dart';
import '../models/user.dart';
import '../utils/history_playback.dart';
import '../utils/trip_archive.dart';

/// Result of loading route history: the trips AND whether the sources answered, so a
/// failed request is never presented as an empty (successful) history.
class RouteHistoryResult {
  const RouteHistoryResult({required this.trips, required this.failedSources, required this.totalSources});

  final List<DriverTrip> trips;
  final List<String> failedSources;
  final int totalSources;

  /// Every source failed: the list says nothing about whether routes exist.
  bool get isError => failedSources.length >= totalSources;

  /// Some sources failed: the list may be incomplete.
  bool get isPartial => failedSources.isNotEmpty && !isError;
}

class DriverRouteHistoryService {
  /// What a Resident may see of a trip: the truck, route, date, distance, duration, status
  /// and the driver's display NAME (the same name residents already see on the live map
  /// label) - never the driver's internal account id.
  static DriverTrip redactForResident(DriverTrip t) => t.copyWith(
        driverName: t.driverName.trim().isEmpty || t.driverName.trim().toLowerCase() == 'unknown'
            ? 'Collection crew'
            : t.driverName,
        driverId: 0,
      );

  static final ApiService _apiService = ApiService();
  static final FirebaseDatabase _database = FirebaseDatabase.instance;

  /// Loads exactly one trip by its id from the persisted Firebase record (frozen
  /// collection data + recorded GPS points). Returns null when no such trip exists:
  /// callers must show "unavailable", never a different trip.
  static Future<DriverTrip?> fetchTripById(String tripId) async {
    if (tripId.isEmpty) return null;
    try {
      final DataSnapshot snap = await _database.ref('driver_routes/$tripId').get();
      if (!snap.exists || snap.value is! Map) return null;
      final Map value = snap.value as Map;
      if (value['is_simulation'] == true || value['isSimulation'] == true) return null;

      final List<GpsPoint> points = <GpsPoint>[];
      if (value['route'] is Map) {
        (value['route'] as Map).forEach((_, pVal) {
          if (pVal is Map) {
            final GpsPoint pt = GpsPoint.fromJson(Map<String, dynamic>.from(pVal));
            if (pt.latitude != 0.0 && pt.longitude != 0.0 && (pt.accuracyM == 0.0 || pt.accuracyM <= 50.0)) {
              points.add(pt);
            }
          }
        });
        points.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        final List<GpsPoint> settled = RouteJitter.collapse(points);
        points
          ..clear()
          ..addAll(settled);
      }
      final Map<String, dynamic> json = Map<String, dynamic>.from(value);
      json['trip_id'] = tripId;
      return DriverTrip.fromJson(json, pointsList: points);
    } catch (e) {
      debugPrint("[ROUTE HISTORY SERVICE] fetchTripById error: $e");
      return null;
    }
  }

  /// Route history list with role scoping (compat wrapper; failures are not reported).
  static Future<List<DriverTrip>> fetchRouteHistory({
    required UserData currentUser,
    DateTime? startDate,
    DateTime? endDate,
    String? selectedDriverId,
    String? selectedTruckId,
    String? selectedArea,
    String? selectedStatus,
    bool includeAllTrips = false,
  }) async {
    final RouteHistoryResult r = await fetchRouteHistoryResult(
      currentUser: currentUser,
      startDate: startDate,
      endDate: endDate,
      selectedDriverId: selectedDriverId,
      selectedTruckId: selectedTruckId,
      selectedArea: selectedArea,
      selectedStatus: selectedStatus,
      includeAllTrips: includeAllTrips,
    );
    return r.trips;
  }

  /// Fetches route history with security role scoping and per-source health.
  static Future<RouteHistoryResult> fetchRouteHistoryResult({
    required UserData currentUser,
    DateTime? startDate,
    DateTime? endDate,
    String? selectedDriverId,
    String? selectedTruckId,
    String? selectedArea,
    String? selectedStatus,
    bool includeAllTrips = false,
    bool scopeFirebaseByDate = false,
  }) async {
    final String role = currentUser.role.toLowerCase();
    final bool isResident = role == 'resident';
    bool firebaseOk = true;
    bool mysqlOk = true;

    // Role Scoping: Drivers can view ONLY their own history. Residents see the collection
    // history of every truck (read-only) but cannot filter or identify drivers.
    String? effectiveDriverId = selectedDriverId;
    if (role == 'driver') {
      effectiveDriverId = currentUser.userId.toString();
    } else if (isResident) {
      effectiveDriverId = null;
    }

    final String startDateStr = startDate != null ? "${startDate.year}-${startDate.month.toString().padLeft(2, '0')}-${startDate.day.toString().padLeft(2, '0')}" : "";
    final String endDateStr = endDate != null ? "${endDate.year}-${endDate.month.toString().padLeft(2, '0')}-${endDate.day.toString().padLeft(2, '0')}" : "";

    final List<DriverTrip> tripsList = [];
    final Set<String> seenTripIds = {};

    // 1. Fetch from Firebase Realtime Database (`driver_routes` node)
    try {
      // With [scopeFirebaseByDate], only trips whose push key (creation time) can fall in the
      // selected days are downloaded, instead of the whole node.
      final Query query = scopeFirebaseByDate && startDate != null && endDate != null
          ? (() {
              final (String from, String to) = HistoryDates.firebaseKeyBounds(startDate, endDate);
              return _database.ref('driver_routes').orderByKey().startAt(from).endAt(to);
            })()
          : _database.ref('driver_routes');
      final DataSnapshot snapshot = await query.get();
      if (snapshot.exists && snapshot.value is Map) {
        final Map routesData = snapshot.value as Map;
        routesData.forEach((key, value) {
          if (value is Map) {
            final String tripId = key.toString();
            // 1. ISOLATE SIMULATION SESSIONS
            if (value['is_simulation'] == true || value['isSimulation'] == true || TripArchive.isArchived(value)) {
              return;
            }

            final String dId = (value['driver_id'] ?? value['driverId'] ?? '').toString();
            final String tId = (value['truck_id'] ?? value['truckId'] ?? '').toString();
            final String rName = (value['route_name'] ?? value['routeName'] ?? '').toString();
            final String status = (value['route_status'] ?? value['status'] ?? '').toString().toUpperCase();

            // Permissions filter
            if (currentUser.role.toLowerCase() == 'driver' && dId != effectiveDriverId) {
              return;
            }
            if (effectiveDriverId != null && effectiveDriverId.isNotEmpty && effectiveDriverId != 'all' && dId != effectiveDriverId) {
              return;
            }
            if (selectedTruckId != null && selectedTruckId.isNotEmpty && selectedTruckId != 'all' && tId != selectedTruckId) {
              return;
            }
            if (selectedStatus != null && selectedStatus.isNotEmpty && selectedStatus != 'all' && status != selectedStatus.toUpperCase()) {
              return;
            }

            final List<GpsPoint> points = [];
            if (value['route'] is Map) {
              final Map routeMap = value['route'] as Map;
              routeMap.forEach((_, pVal) {
                if (pVal is Map) {
                  final pt = GpsPoint.fromJson(Map<String, dynamic>.from(pVal));
                  // Exclude invalid coordinates (0,0) or accuracy > 50m
                  if (pt.latitude != 0.0 && pt.longitude != 0.0 && (pt.accuracyM == 0.0 || pt.accuracyM <= 50.0)) {
                    points.add(pt);
                  }
                }
              });
              points.sort((a, b) => a.timestamp.compareTo(b.timestamp));
              final List<GpsPoint> settled = RouteJitter.collapse(points);
              points
                ..clear()
                ..addAll(settled);
            }

            // Accurate tripDate determination from recorded GPS points or timestamp
            DateTime tripDate;
            if (points.isNotEmpty) {
              tripDate = points.first.timestamp;
            } else if (value['server_start_time'] != null) {
              final raw = int.tryParse(value['server_start_time'].toString());
              tripDate = raw != null ? DateTime.fromMillisecondsSinceEpoch(raw) : DateTime.now();
            } else if (value['date'] != null || value['route_date'] != null) {
              final dStr = (value['date'] ?? value['route_date']).toString();
              tripDate = HistoryDates.parseRecordedDate(dStr) ?? DateTime.now();
            } else if (value['start_time'] != null) {
              final stStr = value['start_time'].toString();
              tripDate = DateTime.tryParse(stStr) ?? DateTime.now();
            } else {
              tripDate = DateTime.now();
            }

            // Date filtering on Asia/Manila calendar days (independent of the device time zone).
            if (!HistoryDates.inRange(tripDate, startDate, endDate)) return;

            final Map<String, dynamic> jsonMap = Map<String, dynamic>.from(value);
            jsonMap['trip_id'] = tripId;

            // Calculate accumulated valid distance across consecutive points
            double accumulatedMeters = 0.0;
            for (int i = 1; i < points.length; i++) {
              final dM = DriverTrip.haversineDistance(
                points[i - 1].latitude, points[i - 1].longitude,
                points[i].latitude, points[i].longitude,
              ) * 1000;
              // Reject stationary jitter (< 3m within < 5s)
              final dtSec = points[i].timestamp.difference(points[i - 1].timestamp).inSeconds;
              if (dM >= 3.0 || dtSec >= 5) {
                accumulatedMeters += dM;
              }
            }

            // REJECT NO-MOVEMENT SESSION STUBS UNLESS includeAllTrips IS TRUE
            if (!includeAllTrips && points.length < 2 && accumulatedMeters < 15.0) {
              debugPrint("[ROUTE HISTORY] Excluded zero-movement session stub $tripId (Distance: ${accumulatedMeters.toStringAsFixed(1)}m, Points: ${points.length})");
              return;
            }

            final trip = DriverTrip.fromJson(jsonMap, pointsList: points);

            // Area / Purok Filter
            if (selectedArea != null && selectedArea.isNotEmpty && selectedArea != 'all') {
              final String searchArea = selectedArea.toLowerCase();
              final bool matchesRouteName = trip.routeName.toLowerCase().contains(searchArea);
              final bool matchesVisitedAreas = trip.visitedAreas.any((a) => a.toLowerCase().contains(searchArea));
              final bool matchesPurok = (jsonMap['purok'] ?? '').toString().toLowerCase().contains(searchArea);

              if (!matchesRouteName && !matchesVisitedAreas && !matchesPurok) {
                return;
              }
            }

            tripsList.add(trip);
            seenTripIds.add(tripId);
          }
        });
      }
    } catch (e) {
      firebaseOk = false;
      debugPrint("[ROUTE HISTORY SERVICE] Firebase fetch error: $e");
    }

    // 2. Fetch from PHP / MySQL API
    try {
      final response = await _apiService.getDriverRouteHistory(
        startDate: startDateStr,
        endDate: endDateStr,
        driverId: effectiveDriverId,
        truckId: selectedTruckId,
        area: selectedArea,
        status: selectedStatus,
      );

      if (response.data['success'] != true) mysqlOk = false;
      if (response.data['success'] == true && response.data['trips'] is List) {
        final List rawTrips = response.data['trips'];
        for (var t in rawTrips) {
          if (t is Map) {
            final String tId = (t['trip_id'] ?? t['route_id'] ?? '').toString();
            final double distKm = double.tryParse((t['total_distance_km'] ?? t['total_distance'] ?? 0).toString()) ?? 0.0;

            // Exclude zero-distance records unless includeAllTrips is true
            if (!includeAllTrips && distKm < 0.015) {
              continue;
            }

            if (!seenTripIds.contains(tId)) {
              tripsList.add(DriverTrip.fromJson(Map<String, dynamic>.from(t)));
              seenTripIds.add(tId);
            } else {
              // If trip was already added from RTDB, merge measured weight from MySQL if available
              final idx = tripsList.indexWhere((existing) => existing.tripId == tId);
              if (idx != -1 && (t['weight_type']?.toString().toUpperCase() == 'MEASURED' || t['weightType']?.toString().toUpperCase() == 'MEASURED')) {
                final double? w = double.tryParse((t['weight_kg'] ?? t['weightKg'] ?? '').toString());
                if (w != null && w >= 0) {
                  tripsList[idx] = tripsList[idx].copyWith(
                    weightKg: w,
                    weightType: 'MEASURED',
                  );
                }
              }
            }
          }
        }
      }
    } catch (e) {
      mysqlOk = false;
      debugPrint("[ROUTE HISTORY SERVICE] MySQL API fetch error: $e");
    }

    // Auto-resolve missing "Truck not recorded" values using driver preferred_truck mapping
    // (not for residents: that lookup uses the full user list).
    if (!isResident) try {
      final userResp = await _apiService.getUsers();
      if (userResp.data['success'] == true && userResp.data['users'] is List) {
        final Map<String, String> driverTruckMap = {};
        for (var u in userResp.data['users']) {
          if (u is Map) {
            final String uId = (u['user_id'] ?? '').toString();
            final String uName = (u['name'] ?? u['username'] ?? '').toString().trim().toLowerCase();
            final String prefTruck = (u['preferred_truck'] ?? '').toString().trim();
            if (prefTruck.isNotEmpty && prefTruck.toLowerCase() != 'unknown') {
              if (uId.isNotEmpty) driverTruckMap[uId] = prefTruck;
              if (uName.isNotEmpty) driverTruckMap[uName] = prefTruck;
            }
          }
        }

        for (int i = 0; i < tripsList.length; i++) {
          final t = tripsList[i];
          if (t.truckId == "Truck not recorded" || t.truckId.isEmpty) {
            final resolvedTruck = driverTruckMap[t.driverId.toString()] ?? driverTruckMap[t.driverName.trim().toLowerCase()];
            if (resolvedTruck != null && resolvedTruck.isNotEmpty) {
              tripsList[i] = t.copyWith(truckId: resolvedTruck);
            }
          }
        }
      }
    } catch (e) {
      debugPrint("[ROUTE HISTORY SERVICE] Driver truck auto-resolution error: $e");
    }

    // Merge custom weights from Firebase Realtime Database `load_history` node
    try {
      final loadSnap = await _database.ref('load_history').get();
      if (loadSnap.exists && loadSnap.value is Map) {
        final Map loadMap = loadSnap.value as Map;
        final Map<String, Map> weightMap = {};
        loadMap.forEach((key, val) {
          if (val is Map) {
            final String normKey = key.toString().replaceAll('#', '').trim().toLowerCase();
            weightMap[normKey] = val;
            weightMap[key.toString()] = val;
          }
        });

        for (int i = 0; i < tripsList.length; i++) {
          final t = tripsList[i];
          final String normId = t.tripId.replaceAll('#', '').trim().toLowerCase();
          final wData = weightMap[normId] ?? weightMap[t.tripId];
          if (wData != null) {
            final double? wKg = double.tryParse((wData['weight_kg'] ?? wData['weightKg'] ?? '').toString());
            final String? wType = wData['weight_type']?.toString();
            if (wKg != null && wKg >= 0) {
              tripsList[i] = t.copyWith(
                weightKg: wKg,
                weightType: wType ?? 'MEASURED',
              );
            }
          }
        }
      }
    } catch (e) {
      debugPrint("[ROUTE HISTORY SERVICE] Error merging load_history weights: $e");
    }

    // Sort trips descending by start time
    tripsList.sort((a, b) => b.startTime.compareTo(a.startTime));

    final List<DriverTrip> visible = isResident ? tripsList.map(redactForResident).toList() : tripsList;
    final List<String> failed = <String>[if (!firebaseOk) 'firebase', if (!mysqlOk) 'mysql'];
    return RouteHistoryResult(trips: visible, failedSources: failed, totalSources: 2);
  }

  static String formatDurationShort(int seconds) {
    if (seconds < 60) return "${seconds}s";
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    return secs == 0 ? "${mins}m" : "${mins}m ${secs}s";
  }

  /// Points to DRAW for a trip: unusable fixes and short GPS spikes dropped, positions smoothed by the Kalman filter
  /// ([GpsSmoothing]), then standing-still jitter removed ([filterStationaryGpsJitter]). Display only:
  /// distance, stops, visits and analytics use the recorded points.
  static List<GpsPoint> smoothForDisplay(List<GpsPoint> inputPoints) {
    final List<GpsPoint> valid =
        inputPoints.where((p) => !(p.latitude == 0.0 && p.longitude == 0.0) && p.accuracyM <= 100.0).toList();
    GpsSample sample(GpsPoint p) => GpsSample(
          lat: p.latitude,
          lng: p.longitude,
          accuracyM: p.accuracyM,
          timestampMs: p.timestamp.millisecondsSinceEpoch,
          speedMps: p.speedKmh / 3.6,
        );
    final List<GpsPoint> usable = <GpsPoint>[for (final int i in GpsSmoothing.withoutSpikes(valid.map(sample).toList())) valid[i]];
    if (usable.length <= 2) return filterStationaryGpsJitter(inputPoints);
    final List<List<double>> smooth = GpsSmoothing.kalman(usable.map(sample).toList());
    final List<GpsPoint> smoothed = <GpsPoint>[
      for (int i = 0; i < usable.length; i++)
        GpsPoint(
          latitude: smooth[i][0],
          longitude: smooth[i][1],
          speedKmh: usable[i].speedKmh,
          heading: usable[i].heading,
          accuracyM: usable[i].accuracyM,
          status: usable[i].status,
          timestamp: usable[i].timestamp,
          isGapStart: usable[i].isGapStart,
        ),
    ];
    return filterStationaryGpsJitter(smoothed);
  }

  /// Filters out small GPS drift noise (< 7m movement while slow) during extended stops
  /// to prevent drawing zig-zag spiderweb lines over building roofs.
  static List<GpsPoint> filterStationaryGpsJitter(List<GpsPoint> inputPoints) {
    if (inputPoints.length <= 2) return inputPoints;

    final List<GpsPoint> filtered = [];
    GpsPoint? lastAnchor;

    for (var p in inputPoints) {
      if (p.latitude == 0.0 && p.longitude == 0.0) continue;
      if (p.accuracyM > 100.0) continue;

      if (lastAnchor == null) {
        filtered.add(p);
        lastAnchor = p;
        continue;
      }

      final distM = DriverTrip.haversineDistance(
        lastAnchor.latitude, lastAnchor.longitude,
        p.latitude, p.longitude,
      ) * 1000;

      // Keep points that represent actual travel movement (>= 7.0m or speed >= 3.5 km/h) or gap starts
      if (distM >= 7.0 || p.speedKmh >= 3.5 || p.isGapStart) {
        filtered.add(p);
        lastAnchor = p;
      }
    }

    if (filtered.isNotEmpty && inputPoints.isNotEmpty && filtered.last != inputPoints.last) {
      filtered.add(inputPoints.last);
    }

    return filtered.isNotEmpty ? filtered : inputPoints;
  }

  /// A route line is cut only when GPS was missing for minutes, or the position jumped farther than any vehicle
  /// could travel in that time. A short signal drop at normal speed (30 s at 36 km/h is 330 m) is travel, so the
  /// line stays connected instead of breaking at every weak-signal moment.
  static bool isRouteBreak(int dtSec, double distM) {
    if (dtSec > 180) return true;
    if (distM <= 300.0) return false;
    return dtSec <= 0 || distM / dtSec > 40.0; // 40 m/s = 144 km/h
  }

  /// Analyzes trip GPS points, detects data gaps, stops, and compiles event timeline.
  static DriverTrip analyzeTrip(DriverTrip trip) {
    final List<GpsPoint> rawPoints = List.from(trip.points);
    rawPoints.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // Deduplicate and filter stale/invalid points (accuracy > 100m or 0,0 coords)
    final List<GpsPoint> cleanPoints = [];
    GpsPoint? prev;

    for (var p in rawPoints) {
      if (p.latitude == 0.0 && p.longitude == 0.0) continue;
      if (p.accuracyM > 100.0) continue;

      if (prev != null) {
        final dist = DriverTrip.haversineDistance(
          prev.latitude, prev.longitude, p.latitude, p.longitude,
        ) * 1000;
        final dtSec = p.timestamp.difference(prev.timestamp).inSeconds;

        if (dtSec <= 2 && dist < 1.0) continue;
      }
      cleanPoints.add(p);
      prev = p;
    }

    if (cleanPoints.isEmpty) return trip;
    final List<GpsPoint> settledPoints = RouteJitter.collapse(cleanPoints);
    cleanPoints
      ..clear()
      ..addAll(settledPoints);

    // Detect Data Gaps (> 3 mins or > 300m jump)
    final List<DataGap> gaps = [];
    final List<GpsPoint> processedPoints = [];

    for (int i = 0; i < cleanPoints.length; i++) {
      final curr = cleanPoints[i];
      if (i > 0) {
        final prevP = cleanPoints[i - 1];
        final dtSec = curr.timestamp.difference(prevP.timestamp).inSeconds;
        final distM = DriverTrip.haversineDistance(
          prevP.latitude, prevP.longitude, curr.latitude, curr.longitude,
        ) * 1000;

        if (isRouteBreak(dtSec, distM)) {
          gaps.add(DataGap(
            startTime: prevP.timestamp,
            endTime: curr.timestamp,
            gapDurationSeconds: dtSec,
            distanceJumpMeters: distM,
            reason: dtSec > 180 ? "Missing GPS signal interval (${(dtSec/60).toStringAsFixed(1)}m)" : "Large location jump (${distM.toStringAsFixed(0)}m)",
          ));
          processedPoints.add(curr.copyWith(isGapStart: true));
        } else {
          processedPoints.add(curr);
        }
      } else {
        processedPoints.add(curr);
      }
    }

    // Detect Stops (≥ 30s idle/slow points labeled as "Possible stop • duration")
    final List<DetectedStop> stops = [];
    int movingSeconds = 0;
    int stoppedSeconds = 0;
    double calcDistanceKm = 0.0;

    DateTime? stopStart;
    GpsPoint? stopAnchor;

    for (int i = 0; i < processedPoints.length; i++) {
      final p = processedPoints[i];
      if (i > 0) {
        final prevP = processedPoints[i - 1];
        final distM = DriverTrip.haversineDistance(
          prevP.latitude, prevP.longitude, p.latitude, p.longitude,
        ) * 1000;
        final dtSec = p.timestamp.difference(prevP.timestamp).inSeconds;

        if (dtSec > 0 && dtSec < 180) {
          calcDistanceKm += (distM / 1000.0);
          if (p.speedKmh < 3.0 || distM < 5.0) {
            stoppedSeconds += dtSec;
            stopAnchor ??= p;
            stopStart ??= prevP.timestamp;
          } else {
            movingSeconds += dtSec;
            if (stopStart != null && stopAnchor != null) {
              final stopDurSec = p.timestamp.difference(stopStart).inSeconds;
              if (stopDurSec >= 30) {
                final String stopTypeLabel = stopDurSec >= 120 && stopDurSec <= 600
                    ? "Collection stop • ${formatDurationShort(stopDurSec)}"
                    : (stopDurSec > 600 ? "Extended stop • ${formatDurationShort(stopDurSec)}" : "Collection stop • ${formatDurationShort(stopDurSec)}");
                stops.add(DetectedStop(
                  latitude: stopAnchor.latitude,
                  longitude: stopAnchor.longitude,
                  startTime: stopStart,
                  endTime: p.timestamp,
                  durationSeconds: stopDurSec,
                  label: stopTypeLabel,
                ));
              }
              stopStart = null;
              stopAnchor = null;
            }
          }
        }
      }
    }

    // Close remaining open stop
    if (stopStart != null && stopAnchor != null && processedPoints.isNotEmpty) {
      final stopDurSec = processedPoints.last.timestamp.difference(stopStart).inSeconds;
      if (stopDurSec >= 30) {
        final String stopTypeLabel = stopDurSec >= 120 && stopDurSec <= 600
            ? "Collection stop • ${formatDurationShort(stopDurSec)}"
            : (stopDurSec > 600 ? "Extended stop • ${formatDurationShort(stopDurSec)}" : "Collection stop • ${formatDurationShort(stopDurSec)}");
        stops.add(DetectedStop(
          latitude: stopAnchor.latitude,
          longitude: stopAnchor.longitude,
          startTime: stopStart,
          endTime: processedPoints.last.timestamp,
          durationSeconds: stopDurSec,
          label: stopTypeLabel,
        ));
      }
    }

    // Compile Events Timeline (chronological order matching reference design)
    final List<TripEvent> eventTimeline = [];

    final DateTime tripStartTime = processedPoints.first.timestamp;
    final DateTime tripEndTime = trip.endTime ?? processedPoints.last.timestamp;

    // 1. Start trip
    eventTimeline.add(TripEvent(
      eventType: "ACTIVE",
      description: "Start trip",
      timestamp: tripStartTime,
      latitude: processedPoints.first.latitude,
      longitude: processedPoints.first.longitude,
    ));

    // 2. Add detected stops and resumption of movement
    for (var stop in stops) {
      eventTimeline.add(TripEvent(
        eventType: "IDLE",
        description: stop.label,
        timestamp: stop.startTime,
        latitude: stop.latitude,
        longitude: stop.longitude,
      ));
      eventTimeline.add(TripEvent(
        eventType: "ACTIVE",
        description: "Moving",
        timestamp: stop.endTime,
        latitude: stop.latitude,
        longitude: stop.longitude,
      ));
    }

    // 3. End trip (or In Progress)
    if (trip.routeStatus == 'FULL') {
      eventTimeline.add(TripEvent(
        eventType: "FULL",
        description: "Truck full - collection ended",
        timestamp: tripEndTime,
        latitude: processedPoints.last.latitude,
        longitude: processedPoints.last.longitude,
      ));
    } else if (trip.routeStatus == 'COMPLETED') {
      eventTimeline.add(TripEvent(
        eventType: "COMPLETED",
        description: "End trip",
        timestamp: tripEndTime,
        latitude: processedPoints.last.latitude,
        longitude: processedPoints.last.longitude,
      ));
    }

    // Sort timeline chronologically
    eventTimeline.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final List<String> areas = trip.visitedAreas;

    return DriverTrip(
      tripId: trip.tripId,
      tripNumber: trip.tripNumber,
      driverId: trip.driverId,
      driverName: trip.driverName,
      truckId: trip.truckId,
      routeName: trip.routeName,
      routeStatus: trip.routeStatus,
      startTime: tripStartTime,
      endTime: tripEndTime,
      startLat: processedPoints.first.latitude,
      startLng: processedPoints.first.longitude,
      finishLat: processedPoints.last.latitude,
      finishLng: processedPoints.last.longitude,
      totalDistanceKm: trip.totalDistanceKm > 0 ? trip.totalDistanceKm : calcDistanceKm,
      // Measured from the recorded points only; never a made-up default.
      movingTimeSeconds: movingSeconds,
      stoppedTimeSeconds: stoppedSeconds,
      detectedStopsCount: stops.length > 0 ? stops.length : trip.detectedStopsCount,
      visitedAreas: areas,
      isDelayed: trip.isDelayed,
      delayReason: trip.delayReason,
      delayTimestamp: trip.delayTimestamp,
      points: processedPoints,
      events: eventTimeline,
      detectedStops: stops,
      dataGaps: gaps,
    );
  }

  /// Deletes a GPS route trace record from Firebase driver_routes node while preserving official Load History waste data.
  static Future<bool> deleteTrip(String tripId) async {
    bool success = false;
    // 1. Delete GPS route trace from Firebase Realtime Database (`driver_routes`)
    try {
      await _database.ref('driver_routes').child(tripId).remove();
      success = true;
    } catch (e) {
      debugPrint("[ROUTE HISTORY SERVICE] Firebase delete error: $e");
    }

    // Official Load History records (waste tonnage logs) are permanently preserved in load_history for annual reporting.
    return success;
  }
}
