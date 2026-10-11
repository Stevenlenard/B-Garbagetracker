import 'dart:math' as math;
import 'package:intl/intl.dart';

class GpsPoint {
  final double latitude;
  final double longitude;
  final double speedKmh;
  final double heading;
  final double accuracyM;
  final String status;
  final DateTime timestamp;
  final bool isGapStart;

  GpsPoint({
    required this.latitude,
    required this.longitude,
    this.speedKmh = 0.0,
    this.heading = 0.0,
    this.accuracyM = 0.0,
    this.status = "ACTIVE",
    required this.timestamp,
    this.isGapStart = false,
  });

  factory GpsPoint.fromJson(Map<String, dynamic> json) {
    double lat = double.tryParse((json['latitude'] ?? json['lat'] ?? 0).toString()) ?? 0.0;
    double lng = double.tryParse((json['longitude'] ?? json['lng'] ?? 0).toString()) ?? 0.0;
    double spd = double.tryParse((json['speed_kmh'] ?? json['speed'] ?? 0).toString()) ?? 0.0;
    double hdg = double.tryParse((json['heading'] ?? 0).toString()) ?? 0.0;
    double acc = double.tryParse((json['accuracy_m'] ?? json['accuracy'] ?? 0).toString()) ?? 0.0;
    String st = (json['status'] ?? "ACTIVE").toString();

    DateTime ts;
    if (json['recorded_at'] != null) {
      ts = DateTime.tryParse(json['recorded_at'].toString()) ?? DateTime.now();
    } else if (json['timestamp'] != null) {
      final rawTs = int.tryParse(json['timestamp'].toString());
      ts = rawTs != null ? DateTime.fromMillisecondsSinceEpoch(rawTs) : DateTime.now();
    } else {
      ts = DateTime.now();
    }

    return GpsPoint(
      latitude: lat,
      longitude: lng,
      speedKmh: spd,
      heading: hdg,
      accuracyM: acc,
      status: st,
      timestamp: ts,
      isGapStart: json['isGapStart'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'speed_kmh': speedKmh,
      'heading': heading,
      'accuracy_m': accuracyM,
      'status': status,
      'recorded_at': timestamp.toIso8601String(),
      'isGapStart': isGapStart,
    };
  }

  GpsPoint copyWith({
    double? latitude,
    double? longitude,
    double? speedKmh,
    double? heading,
    double? accuracyM,
    String? status,
    DateTime? timestamp,
    bool? isGapStart,
  }) {
    return GpsPoint(
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      speedKmh: speedKmh ?? this.speedKmh,
      heading: heading ?? this.heading,
      accuracyM: accuracyM ?? this.accuracyM,
      status: status ?? this.status,
      timestamp: timestamp ?? this.timestamp,
      isGapStart: isGapStart ?? this.isGapStart,
    );
  }
}

class TripEvent {
  final String eventType;
  final String description;
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;

  TripEvent({
    required this.eventType,
    required this.description,
    required this.timestamp,
    this.latitude,
    this.longitude,
  });

  factory TripEvent.fromJson(Map<String, dynamic> json) {
    DateTime ts;
    if (json['recorded_at'] != null) {
      ts = DateTime.tryParse(json['recorded_at'].toString()) ?? DateTime.now();
    } else if (json['timestamp'] != null) {
      final rawTs = int.tryParse(json['timestamp'].toString());
      ts = rawTs != null ? DateTime.fromMillisecondsSinceEpoch(rawTs) : DateTime.now();
    } else {
      ts = DateTime.now();
    }

    return TripEvent(
      eventType: (json['event_type'] ?? json['type'] ?? json['status'] ?? "ACTIVE").toString(),
      description: (json['description'] ?? json['message'] ?? "").toString(),
      timestamp: ts,
      latitude: json['latitude'] != null ? double.tryParse(json['latitude'].toString()) : null,
      longitude: json['longitude'] != null ? double.tryParse(json['longitude'].toString()) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'event_type': eventType,
      'description': description,
      'recorded_at': timestamp.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
    };
  }
}

class DetectedStop {
  final double latitude;
  final double longitude;
  final DateTime startTime;
  final DateTime endTime;
  final int durationSeconds;
  final String label;

  DetectedStop({
    required this.latitude,
    required this.longitude,
    required this.startTime,
    required this.endTime,
    required this.durationSeconds,
    required this.label,
  });
}

class DataGap {
  final DateTime startTime;
  final DateTime endTime;
  final int gapDurationSeconds;
  final double distanceJumpMeters;
  final String reason;

  DataGap({
    required this.startTime,
    required this.endTime,
    required this.gapDurationSeconds,
    required this.distanceJumpMeters,
    required this.reason,
  });
}

class DriverTrip {
  final String tripId;
  final String tripNumber;
  final dynamic driverId;
  final String driverName;
  final String truckId;
  final String routeName;
  final String routeStatus;
  final DateTime startTime;
  final DateTime? endTime;
  final double startLat;
  final double startLng;
  final double? finishLat;
  final double? finishLng;
  final double totalDistanceKm;
  final int movingTimeSeconds;
  final int stoppedTimeSeconds;
  final int detectedStopsCount;
  final List<String> visitedAreas;
  final bool isDelayed;
  final String? delayReason;
  final DateTime? delayTimestamp;
  final List<GpsPoint> points;
  final List<TripEvent> events;
  final List<DetectedStop> detectedStops;
  final List<DataGap> dataGaps;
  final double weightKg;
  final String weightType;
  final DateTime? fullTime;
  final bool hasRecordedStartTime;
  final String durationDisplay;
  final String distanceDisplay;

  bool get isMeasured => weightType.toUpperCase() == 'MEASURED';
  double get weightTons => weightKg / 1000.0;

  String get fullDate {
    final DateTime target = fullTime ?? endTime ?? startTime;
    return DateFormat('MMM d, yyyy').format(target);
  }

  String get fullTimeDisplay {
    final DateTime? target = fullTime ?? endTime;
    if (target == null) return "Not recorded";
    return DateFormat('g:i A').format(target);
  }

  String get visitedAreasDisplay {
    if (visitedAreas.isEmpty) return routeName.isNotEmpty && routeName != "Collection Route" ? routeName : "Not recorded";
    return visitedAreas.join(' · ');
  }

  DriverTrip({
    required this.tripId,
    String? tripNumber,
    required this.driverId,
    this.driverName = "Driver",
    this.truckId = "Truck not recorded",
    this.routeName = "Collection Route",
    this.routeStatus = "ACTIVE",
    required this.startTime,
    this.endTime,
    this.startLat = 0.0,
    this.startLng = 0.0,
    this.finishLat,
    this.finishLng,
    this.totalDistanceKm = 0.0,
    this.movingTimeSeconds = 0,
    this.stoppedTimeSeconds = 0,
    this.detectedStopsCount = 0,
    this.visitedAreas = const [],
    this.isDelayed = false,
    this.delayReason,
    this.delayTimestamp,
    this.points = const [],
    this.events = const [],
    this.detectedStops = const [],
    this.dataGaps = const [],
    this.weightKg = 5000.0,
    this.weightType = "ESTIMATED",
    this.fullTime,
    this.hasRecordedStartTime = true,
    this.durationDisplay = "Not recorded",
    this.distanceDisplay = "Unavailable",
  }) : tripNumber = tripNumber ?? (tripId.startsWith("#") ? tripId : "#$tripId");

  DriverTrip copyWith({
    String? tripId,
    String? tripNumber,
    dynamic driverId,
    String? driverName,
    String? truckId,
    String? routeName,
    String? routeStatus,
    DateTime? startTime,
    DateTime? endTime,
    double? startLat,
    double? startLng,
    double? finishLat,
    double? finishLng,
    double? totalDistanceKm,
    int? movingTimeSeconds,
    int? stoppedTimeSeconds,
    int? detectedStopsCount,
    List<String>? visitedAreas,
    bool? isDelayed,
    String? delayReason,
    DateTime? delayTimestamp,
    List<GpsPoint>? points,
    List<TripEvent>? events,
    List<DetectedStop>? detectedStops,
    List<DataGap>? dataGaps,
    double? weightKg,
    String? weightType,
    DateTime? fullTime,
  }) {
    return DriverTrip(
      tripId: tripId ?? this.tripId,
      tripNumber: tripNumber ?? this.tripNumber,
      driverId: driverId ?? this.driverId,
      driverName: driverName ?? this.driverName,
      truckId: truckId ?? this.truckId,
      routeName: routeName ?? this.routeName,
      routeStatus: routeStatus ?? this.routeStatus,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      startLat: startLat ?? this.startLat,
      startLng: startLng ?? this.startLng,
      finishLat: finishLat ?? this.finishLat,
      finishLng: finishLng ?? this.finishLng,
      totalDistanceKm: totalDistanceKm ?? this.totalDistanceKm,
      movingTimeSeconds: movingTimeSeconds ?? this.movingTimeSeconds,
      stoppedTimeSeconds: stoppedTimeSeconds ?? this.stoppedTimeSeconds,
      detectedStopsCount: detectedStopsCount ?? this.detectedStopsCount,
      visitedAreas: visitedAreas ?? this.visitedAreas,
      isDelayed: isDelayed ?? this.isDelayed,
      delayReason: delayReason ?? this.delayReason,
      delayTimestamp: delayTimestamp ?? this.delayTimestamp,
      points: points ?? this.points,
      events: events ?? this.events,
      detectedStops: detectedStops ?? this.detectedStops,
      dataGaps: dataGaps ?? this.dataGaps,
      weightKg: weightKg ?? this.weightKg,
      weightType: weightType ?? this.weightType,
      fullTime: fullTime ?? this.fullTime,
    );
  }

  String get formattedVisitedAreas {
    if (visitedAreas.isEmpty) {
      return routeName.isNotEmpty ? routeName : "Collection Route";
    }
    if (visitedAreas.length <= 2) {
      return visitedAreas.join(" • ");
    }
    return "${visitedAreas.take(2).join(" • ")} +${visitedAreas.length - 2} areas";
  }

  String get formattedDuration {
    final DateTime end = endTime ?? (points.isNotEmpty ? points.last.timestamp : DateTime.now());
    final int minutes = end.difference(startTime).inMinutes;
    if (minutes < 60) {
      return "$minutes min";
    }
    final int hours = minutes ~/ 60;
    final int mins = minutes % 60;
    return mins == 0 ? "$hours hr" : "$hours hr $mins min";
  }

  int get unclassifiedTimeSeconds {
    final DateTime end = endTime ?? (points.isNotEmpty ? points.last.timestamp : DateTime.now());
    final int totalSec = end.difference(startTime).inSeconds;
    final int unclassified = totalSec - (movingTimeSeconds + stoppedTimeSeconds);
    return unclassified > 0 ? unclassified : 0;
  }

  factory DriverTrip.fromJson(Map<String, dynamic> json, {List<GpsPoint>? pointsList, List<TripEvent>? eventsList}) {
    final List<GpsPoint> pts = pointsList ?? [];

    DateTime st;
    if (pts.isNotEmpty) {
      st = pts.first.timestamp;
    } else if (json['start_time'] != null) {
      st = DateTime.tryParse(json['start_time'].toString()) ?? DateTime.now();
    } else if (json['server_start_time'] != null) {
      final raw = int.tryParse(json['server_start_time'].toString());
      st = raw != null ? DateTime.fromMillisecondsSinceEpoch(raw) : DateTime.now();
    } else if (json['created_at'] != null) {
      st = DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now();
    } else {
      st = DateTime.now();
    }

    final String statusStr = (json['route_status'] ?? json['status'] ?? "ACTIVE").toString().toUpperCase();

    DateTime? et;
    if (pts.isNotEmpty && statusStr == 'COMPLETED') {
      et = pts.last.timestamp;
    } else if (json['end_time'] != null) {
      et = DateTime.tryParse(json['end_time'].toString());
    } else if (json['finished_at'] != null) {
      et = DateTime.tryParse(json['finished_at'].toString());
    } else if (json['completed_at'] != null) {
      et = DateTime.tryParse(json['completed_at'].toString());
    } else if (json['finishTime'] != null) {
      final raw = int.tryParse(json['finishTime'].toString());
      if (raw != null) et = DateTime.fromMillisecondsSinceEpoch(raw);
    } else if (json['server_end_time'] != null) {
      final raw = int.tryParse(json['server_end_time'].toString());
      if (raw != null) et = DateTime.fromMillisecondsSinceEpoch(raw);
    }

    if (et == null && (statusStr == 'COMPLETED' || statusStr == 'FINISHED')) {
      et = pts.isNotEmpty ? pts.last.timestamp : st.add(const Duration(minutes: 24));
    }

    final String idRaw = (json['trip_id'] ?? json['route_id'] ?? json['key'] ?? "100").toString();
    String tNum = json['trip_number']?.toString() ?? "";
    if (tNum.isEmpty) {
      if (idRaw.length > 8 || idRaw.startsWith('-')) {
        final int hash = idRaw.hashCode.abs() % 900 + 100;
        tNum = "#$hash";
      } else {
        tNum = idRaw.startsWith('#') ? idRaw : "#$idRaw";
      }
    }

    String tId = "Truck not recorded";
    final String rawTruck = (json['truck_id'] ?? json['truckId'] ?? '').toString().trim();
    if (rawTruck.isNotEmpty && rawTruck.toLowerCase() != 'unknown') {
      tId = rawTruck;
    } else if (json['preferred_truck'] != null && json['preferred_truck'].toString().trim().isNotEmpty) {
      tId = json['preferred_truck'].toString().trim();
    }

    List<String> areas = [];
    if (json['visited_areas'] is List) {
      areas = (json['visited_areas'] as List).map((e) => e.toString()).toList();
    } else if (json['visited_areas'] != null) {
      areas = json['visited_areas'].toString().split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    } else if (json['purok'] != null) {
      areas = [json['purok'].toString()];
    }

    // Calculate actual distance from points when available
    double calcDist = 0.0;
    if (pts.length >= 2) {
      for (int i = 1; i < pts.length; i++) {
        calcDist += DriverTrip.haversineDistance(
          pts[i - 1].latitude, pts[i - 1].longitude,
          pts[i].latitude, pts[i].longitude,
        );
      }
    } else {
      calcDist = double.tryParse((json['total_distance_km'] ?? json['total_distance'] ?? 0).toString()) ?? 0.0;
    }

    final double weightVal = double.tryParse((json['weight_kg'] ?? json['weightKg'] ?? 5000.0).toString()) ?? 5000.0;
    final String weightTypeVal = (json['weight_type'] ?? json['weightType'] ?? "ESTIMATED").toString().toUpperCase();

    DateTime? fTime;
    if (json['full_time'] != null) {
      fTime = DateTime.tryParse(json['full_time'].toString());
    } else if (json['full_date'] != null && json['full_time'] != null) {
      fTime = DateTime.tryParse("${json['full_date']} ${json['full_time']}");
    } else if (json['raw_full_time'] != null) {
      fTime = DateTime.tryParse(json['raw_full_time'].toString());
    } else {
      fTime = et;
    }

    final bool hasStart = json['start_time'] != null && json['start_time'].toString().isNotEmpty && !json['start_time'].toString().startsWith("0000");
    final String durDisp = (json['duration'] ?? json['duration_display'])?.toString() ?? (hasStart ? "" : "Not recorded");
    final String distDisp = (json['distance_display'])?.toString() ?? (calcDist > 0.01 ? "${calcDist.toStringAsFixed(1)} km" : "Unavailable");

    return DriverTrip(
      tripId: idRaw,
      tripNumber: tNum,
      driverId: json['driver_id'] ?? json['driverId'] ?? 0,
      driverName: (json['driver_name'] ?? json['driverName'] ?? "Driver").toString(),
      truckId: tId,
      routeName: (json['route_name'] ?? json['routeName'] ?? "Collection Route").toString(),
      routeStatus: statusStr,
      startTime: st,
      endTime: et,
      startLat: double.tryParse((json['start_lat'] ?? 0).toString()) ?? (pts.isNotEmpty ? pts.first.latitude : 0.0),
      startLng: double.tryParse((json['start_lng'] ?? 0).toString()) ?? (pts.isNotEmpty ? pts.first.longitude : 0.0),
      finishLat: json['finish_lat'] != null ? double.tryParse(json['finish_lat'].toString()) : (pts.isNotEmpty ? pts.last.latitude : null),
      finishLng: json['finish_lng'] != null ? double.tryParse(json['finish_lng'].toString()) : (pts.isNotEmpty ? pts.last.longitude : null),
      totalDistanceKm: calcDist,
      movingTimeSeconds: int.tryParse((json['moving_time_seconds'] ?? 0).toString()) ?? 960,
      stoppedTimeSeconds: int.tryParse((json['stopped_time_seconds'] ?? 0).toString()) ?? 480,
      detectedStopsCount: int.tryParse((json['detected_stops_count'] ?? json['total_stops'] ?? 0).toString()) ?? 2,
      visitedAreas: areas,
      isDelayed: json['is_delayed'] == true || json['isDelayed'] == true,
      delayReason: json['delay_reason']?.toString(),
      delayTimestamp: json['delay_timestamp'] != null ? DateTime.tryParse(json['delay_timestamp'].toString()) : null,
      points: pts,
      events: eventsList ?? [],
      weightKg: weightVal,
      weightType: weightTypeVal,
      fullTime: fTime,
      hasRecordedStartTime: hasStart,
      durationDisplay: durDisp,
      distanceDisplay: distDisp,
    );
  }

  // Calculate distance between two GPS positions using Haversine formula
  static double haversineDistance(double lat1, double lon1, double lat2, double lon2) {
    const double p = 0.017453292519943295; // pi / 180
    final double a = 0.5 -
        math.cos((lat2 - lat1) * p) / 2 +
        math.cos(lat1 * p) * math.cos(lat2 * p) * (1 - math.cos((lon2 - lon1) * p)) / 2;
    return 12742 * math.asin(math.sqrt(a)); // 2 * R; R = 6371 km
  }
}
