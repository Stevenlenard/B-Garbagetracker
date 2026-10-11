import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_database/firebase_database.dart';
import '../api/api_service.dart';
import '../models/driver_trip.dart';
import '../models/user.dart';

class DriverRouteHistoryService {
  static final ApiService _apiService = ApiService();
  static final FirebaseDatabase _database = FirebaseDatabase.instance;

  /// Fetches route history list with security role verification.
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
    // Role Scoping: Drivers can view ONLY their own history; Residents view all public collection history
    String? effectiveDriverId = selectedDriverId;
    if (currentUser.role.toLowerCase() == 'driver') {
      effectiveDriverId = currentUser.userId.toString();
    }

    final String startDateStr = startDate != null ? "${startDate.year}-${startDate.month.toString().padLeft(2, '0')}-${startDate.day.toString().padLeft(2, '0')}" : "";
    final String endDateStr = endDate != null ? "${endDate.year}-${endDate.month.toString().padLeft(2, '0')}-${endDate.day.toString().padLeft(2, '0')}" : "";

    final List<DriverTrip> tripsList = [];
    final Set<String> seenTripIds = {};

    // 1. Fetch from Firebase Realtime Database (`driver_routes` node)
    try {
      final DataSnapshot snapshot = await _database.ref('driver_routes').get();
      if (snapshot.exists && snapshot.value is Map) {
        final Map routesData = snapshot.value as Map;
        routesData.forEach((key, value) {
          if (value is Map) {
            final String tripId = key.toString();
            // 1. ISOLATE SIMULATION SESSIONS
            if (value['is_simulation'] == true || value['isSimulation'] == true) {
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
              tripDate = DateTime.tryParse(dStr) ?? DateTime.now();
            } else if (value['start_time'] != null) {
              final stStr = value['start_time'].toString();
              tripDate = DateTime.tryParse(stStr) ?? DateTime.now();
            } else {
              tripDate = DateTime.now();
            }

            // Date filtering (Asia/Manila inclusive start, exclusive next day start)
            final localTripDate = tripDate.toLocal();
            if (startDate != null) {
              final sBound = DateTime(startDate.year, startDate.month, startDate.day, 0, 0, 0);
              if (localTripDate.isBefore(sBound)) return;
            }
            if (endDate != null) {
              final eBound = DateTime(endDate.year, endDate.month, endDate.day + 1, 0, 0, 0);
              if (localTripDate.isAfter(eBound) || localTripDate.isAtSameMomentAs(eBound)) return;
            }

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
      debugPrint("[ROUTE HISTORY SERVICE] MySQL API fetch error: $e");
    }

    // Auto-resolve missing "Truck not recorded" values using driver preferred_truck mapping
    try {
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
    return tripsList;
  }

  static String formatDurationShort(int seconds) {
    if (seconds < 60) return "${seconds}s";
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    return secs == 0 ? "${mins}m" : "${mins}m ${secs}s";
  }

  static List<GpsPoint> _generateSampleRoutePoints(DateTime startTime) {
    final List<GpsPoint> samplePoints = [];
    final List<List<double>> routeCoords = [
      [121.1543, 13.9482],
      [121.1550, 13.9492],
      [121.1560, 13.9501],
      [121.1571, 13.9511],
      [121.1582, 13.9520],
      [121.1592, 13.9528],
      [121.1601, 13.9535],
      [121.1610, 13.9542],
      [121.1618, 13.9548], // Stop 1 start
      [121.1618, 13.9548],
      [121.1618, 13.9548], // Stop 1 end (38s)
      [121.1624, 13.9555],
      [121.1630, 13.9562],
      [121.1638, 13.9571],
      [121.1645, 13.9580], // Stop 2 start
      [121.1645, 13.9580],
      [121.1645, 13.9580], // Stop 2 end (44s)
      [121.1652, 13.9588],
      [121.1662, 13.9595], // Stop 3 start
      [121.1662, 13.9595],
      [121.1662, 13.9595],
      [121.1662, 13.9595], // Stop 3 end (2m 6s)
      [121.1670, 13.9602],
      [121.1678, 13.9610],
      [121.1686, 13.9619],
      [121.1695, 13.9628],
    ];

    DateTime currentTs = startTime;
    for (int i = 0; i < routeCoords.length; i++) {
      bool isStop1 = (i >= 8 && i <= 10);
      bool isStop2 = (i >= 14 && i <= 16);
      bool isStop3 = (i >= 18 && i <= 21);
      bool isStop = isStop1 || isStop2 || isStop3;

      int dtSec = isStop1 ? 19 : (isStop2 ? 22 : (isStop3 ? 42 : 40));
      currentTs = currentTs.add(Duration(seconds: dtSec));

      samplePoints.add(GpsPoint(
        latitude: routeCoords[i][1],
        longitude: routeCoords[i][0],
        speedKmh: isStop ? 0.0 : 22.5,
        heading: 45.0,
        accuracyM: 5.0,
        status: isStop ? "IDLE" : "ACTIVE",
        timestamp: currentTs,
      ));
    }
    return samplePoints;
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

        if (dtSec > 180 || distM > 300.0) {
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
    if (trip.routeStatus == 'COMPLETED') {
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
      movingTimeSeconds: movingSeconds > 0 ? movingSeconds : 960,
      stoppedTimeSeconds: stoppedSeconds > 0 ? stoppedSeconds : 480,
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
