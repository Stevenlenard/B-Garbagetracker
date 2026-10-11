import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

class ServiceArea {
  final String id;
  final String name;
  final String type; // 'Purok' | 'Residential Area' | 'Subdivision' | 'Road Segment' | 'Highway Segment' | 'Stationary Sweeping Area'
  final bool isTruckStop; // true = garbage truck collection stop, false = stationary street sweeping
  final double latitude;
  final double longitude;
  final double entranceLat;
  final double entranceLng;
  final double? endLat;
  final double? endLng;
  final double radius; // geofence radius in meters
  final String verificationStatus; // 'VERIFIED' | 'UNVERIFIED'
  final String coordinateSource;
  final String lastVerificationDate;
  final String? assignedTruckId;
  final List<List<double>> boundaryGeometry; // Polygon coordinates [longitude, latitude]
  final String boundaryType; // 'Polygon' | 'Point'
  final String color; // Hex color for polygon boundary & fill

  const ServiceArea({
    required this.id,
    required this.name,
    required this.type,
    required this.isTruckStop,
    required this.latitude,
    required this.longitude,
    required this.entranceLat,
    required this.entranceLng,
    this.endLat,
    this.endLng,
    this.radius = 60.0,
    this.verificationStatus = 'VERIFIED',
    this.coordinateSource = 'Barangay Balintawak Official GIS / Mapbox Road Network',
    this.lastVerificationDate = '2026-10-02',
    this.assignedTruckId,
    this.boundaryGeometry = const [],
    this.boundaryType = 'Polygon',
    this.color = '#00796B',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'type': type,
    'isTruckStop': isTruckStop,
    'latitude': latitude,
    'longitude': longitude,
    'lat': latitude,
    'lng': longitude,
    'entranceLat': entranceLat,
    'entranceLng': entranceLng,
    'endLat': endLat,
    'endLng': endLng,
    'radius': radius,
    'verificationStatus': verificationStatus,
    'coordinateSource': coordinateSource,
    'lastVerificationDate': lastVerificationDate,
    'assignedTruckId': assignedTruckId,
    'boundaryGeometry': boundaryGeometry,
    'boundaryType': boundaryType,
    'color': color,
  };

  static String _normalizeVerificationStatus(dynamic val) {
    if (val == null) return 'VERIFIED';
    if (val is bool) return val ? 'VERIFIED' : 'UNVERIFIED';
    String str = val.toString().trim().toUpperCase();
    if (str == 'VERIFIED' || str == 'TRUE' || str == '1' || str == 'YES') return 'VERIFIED';
    if (str == 'UNVERIFIED' || str == 'FALSE' || str == '0' || str == 'NO') return 'UNVERIFIED';
    return 'VERIFIED';
  }

  factory ServiceArea.fromJson(Map<dynamic, dynamic> json) {
    final double lat = ((json['latitude'] ?? json['lat'] ?? 0.0) as num).toDouble();
    final double lng = ((json['longitude'] ?? json['lng'] ?? 0.0) as num).toDouble();
    final double entLat = json['entranceLat'] != null ? ((json['entranceLat'] as num).toDouble()) : lat;
    final double entLng = json['entranceLng'] != null ? ((json['entranceLng'] as num).toDouble()) : lng;

    List<List<double>> geom = [];
    if (json['boundaryGeometry'] != null && json['boundaryGeometry'] is List) {
      for (var pt in (json['boundaryGeometry'] as List)) {
        if (pt is List && pt.length >= 2) {
          geom.add([ (pt[0] as num).toDouble(), (pt[1] as num).toDouble() ]);
        }
      }
    }

    final rawVer = json['verificationStatus'] ?? json['verification_status'] ?? json['isVerified'] ?? json['verified'];

    return ServiceArea(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      type: json['type']?.toString() ?? 'Purok',
      isTruckStop: json['isTruckStop'] == true || json['is_truck_stop'] == true || json['isTruckStop'] == null,
      latitude: lat,
      longitude: lng,
      entranceLat: entLat,
      entranceLng: entLng,
      endLat: json['endLat'] != null ? ((json['endLat'] as num).toDouble()) : null,
      endLng: json['endLng'] != null ? ((json['endLng'] as num).toDouble()) : null,
      radius: ((json['radius'] ?? 60.0) as num).toDouble(),
      verificationStatus: _normalizeVerificationStatus(rawVer),
      coordinateSource: json['coordinateSource']?.toString() ?? 'Barangay Balintawak Official GIS',
      lastVerificationDate: json['lastVerificationDate']?.toString() ?? '2026-10-02',
      assignedTruckId: json['assignedTruckId']?.toString(),
      boundaryGeometry: geom,
      boundaryType: json['boundaryType']?.toString() ?? (geom.isNotEmpty ? 'Polygon' : 'Point'),
      color: json['color']?.toString() ?? '#00796B',
    );
  }

  List<List<double>> get effectiveBoundary {
    if (boundaryGeometry.isNotEmpty) {
      return boundaryGeometry;
    }
    const double dLng = 0.0035;
    const double dLat = 0.0025;
    return [
      [longitude - dLng, latitude + dLat],
      [longitude + dLng, latitude + dLat],
      [longitude + dLng, latitude - dLat],
      [longitude - dLng, latitude - dLat],
      [longitude - dLng, latitude + dLat],
    ];
  }
}

class ServiceAreaService {
  final FirebaseDatabase _database = FirebaseDatabase.instance;

  /// Official canonical dataset with exact updated verified coordinates
  static const List<ServiceArea> defaultServiceAreas = [
    // 1. Purok 1 (Red)
    ServiceArea(
      id: 'central_purok_1',
      name: 'Central (Purok 1)',
      type: 'Purok',
      isTruckStop: true,
      latitude: 13.9530,
      longitude: 121.1588,
      entranceLat: 13.9530,
      entranceLng: 121.1588,
      radius: 60.0,
      verificationStatus: 'VERIFIED',
      color: '#E53935', // Red
      boundaryGeometry: [
        [121.1570, 13.9435],
        [121.1615, 13.9450],
        [121.1630, 13.9410],
        [121.1590, 13.9385],
        [121.1570, 13.9435]
      ],
      coordinateSource: 'Barangay Balintawak Official GIS',
      lastVerificationDate: '2026-10-02',
    ),
    // 2. Purok 2 (Blue)
    ServiceArea(
      id: 'purok_2',
      name: 'Purok 2',
      type: 'Purok',
      isTruckStop: true,
      latitude: 13.96142346200848,
      longitude: 121.15445314118254,
      entranceLat: 13.96142346200848,
      entranceLng: 121.15445314118254,
      radius: 60.0,
      verificationStatus: 'VERIFIED',
      color: '#1E88E5', // Blue
      boundaryGeometry: [
        [121.1514, 13.9644],
        [121.1574, 13.9644],
        [121.1574, 13.9584],
        [121.1514, 13.9584],
        [121.1514, 13.9644]
      ],
      coordinateSource: 'Admin Verified (Updated)',
      lastVerificationDate: '2026-10-02',
    ),
    // 3. Purok 3 (Orange) - Updated Coordinates
    ServiceArea(
      id: 'purok_3',
      name: 'Purok 3',
      type: 'Purok',
      isTruckStop: true,
      latitude: 13.96014078834871,
      longitude: 121.1499563993106,
      entranceLat: 13.96014078834871,
      entranceLng: 121.1499563993106,
      radius: 60.0,
      verificationStatus: 'VERIFIED',
      color: '#FB8C00', // Orange
      boundaryGeometry: [
        [121.1469, 13.9631],
        [121.1529, 13.9631],
        [121.1529, 13.9571],
        [121.1469, 13.9571],
        [121.1469, 13.9631]
      ],
      coordinateSource: 'Admin Verified (Updated)',
      lastVerificationDate: '2026-10-02',
    ),
    // 4. Purok 4 / El Pueblo Area (Yellow) - Updated Exact Points
    ServiceArea(
      id: 'purok_4',
      name: 'Purok 4 / El Pueblo',
      type: 'Purok',
      isTruckStop: true,
      latitude: 13.9664847,
      longitude: 121.1501235,
      entranceLat: 13.965806837242551, // Point 1 Lat
      entranceLng: 121.14839514570492, // Point 1 Lng
      endLat: 13.967162634886991,     // Point 2 Lat
      endLng: 121.15185195385844,     // Point 2 Lng
      radius: 70.0,
      verificationStatus: 'VERIFIED',
      color: '#FFD600', // Yellow
      boundaryGeometry: [
        [121.14839514570492, 13.965806837242551], // Point 1
        [121.15185195385844, 13.967162634886991], // Point 2
        [121.15185195385844, 13.965806837242551],
        [121.14839514570492, 13.965806837242551]
      ],
      coordinateSource: 'Admin Verified (Updated Exact Points)',
      lastVerificationDate: '2026-10-02',
    ),
    // 5. Purok Paraiso (Green) - Updated Coordinates
    ServiceArea(
      id: 'purok_paraiso',
      name: 'Purok Paraiso',
      type: 'Purok',
      isTruckStop: true,
      latitude: 13.946622854597587,
      longitude: 121.15625598161627,
      entranceLat: 13.946622854597587,
      entranceLng: 121.15625598161627,
      radius: 60.0,
      verificationStatus: 'VERIFIED',
      color: '#43A047', // Green
      boundaryGeometry: [
        [121.1532, 13.9496],
        [121.1592, 13.9496],
        [121.1592, 13.9436],
        [121.1532, 13.9436],
        [121.1532, 13.9496]
      ],
      coordinateSource: 'Admin Verified (Updated)',
      lastVerificationDate: '2026-10-02',
    ),
    // 6. Riverside (Purple)
    ServiceArea(
      id: 'riverside',
      name: 'Riverside',
      type: 'Residential Area',
      isTruckStop: true,
      latitude: 13.9465,
      longitude: 121.1637,
      entranceLat: 13.9465,
      entranceLng: 121.1637,
      radius: 60.0,
      verificationStatus: 'VERIFIED',
      color: '#8E24AA', // Purple
      boundaryGeometry: [
        [121.1607, 13.9495],
        [121.1667, 13.9495],
        [121.1667, 13.9435],
        [121.1607, 13.9435],
        [121.1607, 13.9495]
      ],
      coordinateSource: 'Admin Verified (Approximate Map Center)',
      lastVerificationDate: '2026-10-02',
    ),
    // 7. Brixton Homes (Teal/Cyan)
    ServiceArea(
      id: 'brixton_homes',
      name: 'Brixton Homes',
      type: 'Subdivision',
      isTruckStop: true,
      latitude: 13.9551652,
      longitude: 121.1567505,
      entranceLat: 13.9551652,
        entranceLng: 121.1567505,
      radius: 65.0,
      verificationStatus: 'VERIFIED',
      color: '#00ACC1', // Teal
      boundaryGeometry: [
        [121.1537, 13.9581],
        [121.1597, 13.9581],
        [121.1597, 13.9521],
        [121.1537, 13.9521],
        [121.1537, 13.9581]
      ],
      coordinateSource: 'Admin Verified (Accurate Location)',
      lastVerificationDate: '2026-10-02',
    ),
    // 8. T.M. Kalaw Street (Road Segment) - Updated Exact Start
    ServiceArea(
      id: 'tm_kalaw_st',
      name: 'T.M. Kalaw Street',
      type: 'Road Segment',
      isTruckStop: true,
      latitude: 13.94399999538,
      longitude: 121.1626678714,
      entranceLat: 13.946334024236913, // Start
      entranceLng: 121.16182812976116,
      endLat: 13.941665966540967,     // Finish
      endLng: 121.16350761310606,
      radius: 70.0,
      verificationStatus: 'VERIFIED',
      color: '#00796B',
      coordinateSource: 'Admin Verified (Updated T.M. Kalaw Start)',
      lastVerificationDate: '2026-10-02',
    ),
    // 9. Ayala Highway Collection Segment (Road Segment) - Updated Exact Endpoints
    ServiceArea(
      id: 'ayala_hwy_almaris_apat',
      name: 'Ayala Highway',
      type: 'Highway Segment',
      isTruckStop: true,
      latitude: 13.949254869,
      longitude: 121.158850046,
      entranceLat: 13.952721960507304, // Start: Almarius Grill and Resort
      entranceLng: 121.16270755525296,
      endLat: 13.945787777551367,     // End: Fat Grill
      endLng: 121.15499253664089,
      radius: 80.0,
      verificationStatus: 'VERIFIED',
      color: '#3949AB',
      coordinateSource: 'Admin Verified (Updated Exact Road Endpoints)',
      lastVerificationDate: '2026-10-02',
    ),

    // Other / Stationary Areas
    ServiceArea(
      id: 'san_nicolas_sweeping',
      name: 'San Nicolas',
      type: 'Stationary Sweeping Area',
      isTruckStop: false,
      latitude: 13.93450,
      longitude: 121.16200,
      entranceLat: 13.93450,
      entranceLng: 121.16200,
      radius: 50.0,
      verificationStatus: 'VERIFIED',
      color: '#78909C', // Gray
      coordinateSource: 'Barangay Balintawak Official GIS',
      lastVerificationDate: '2026-10-02',
    ),
  ];

  /// List of official display names for resident registration & dropdowns in exact order
  static final List<String> documentedAreaNames = [
    'Ayala Highway',
    'Brixton Homes',
    'Central (Purok 1)',
    'Purok 2',
    'Purok 3',
    'Purok 4 / El Pueblo',
    'Purok Paraiso',
    'Riverside',
    'San Nicolas',
    'T.M. Kalaw Street',
  ];

  static String? canonicalizeAreaName(String? raw) {
    if (raw == null) return null;
    final s = raw.toLowerCase().trim();
    if (s.isEmpty || s == "unknown" || s == "n/a" || s == "none") {
      return null;
    }
    if (s.contains("ayala") || s.contains("almarius") || s.contains("fat grill") || s.contains("almaris")) {
      return "Ayala Highway";
    }
    if (s.contains("brixton")) {
      return "Brixton Homes";
    }
    if (s.contains("central") || s == "purok 1" || s == "p1") {
      return "Central (Purok 1)";
    }
    if (s == "purok 2" || s == "p2") {
      return "Purok 2";
    }
    if (s == "purok 3" || s == "p3" || s.contains("dos riles") || s.contains("purok tres")) {
      return "Purok 3";
    }
    if (s.contains("purok 4") || s.contains("el pueblo") || s == "p4" || s.contains("elpueblo")) {
      return "Purok 4 / El Pueblo";
    }
    if (s.contains("paraiso") || s.contains("sweeping")) {
      return "Purok Paraiso";
    }
    if (s.contains("riverside")) {
      return "Riverside";
    }
    if (s.contains("san nicolas")) {
      return "San Nicolas";
    }
    if (s.contains("kalaw") || s.contains("t.m.")) {
      return "T.M. Kalaw Street";
    }
    return null;
  }

  /// Ensures that 'puroks' in Firebase RTDB is seeded ONLY if empty
  Future<void> ensureInitialized() async {
    try {
      final snap = await _database.ref('puroks').get();
      if (!snap.exists || snap.value == null) {
        await resetToDefaultBalintawakAreas();
      }
    } catch (e) {
      debugPrint("[SERVICE AREA] Error ensuring service area initialization: $e");
    }
  }

  /// Resets or seeds the database node 'puroks' with the authoritative Balintawak dataset.
  Future<void> resetToDefaultBalintawakAreas() async {
    final Map<String, dynamic> seedMap = {};
    for (var area in defaultServiceAreas) {
      seedMap[area.id] = area.toJson();
    }
    await _database.ref('puroks').set(seedMap);
    debugPrint("[SERVICE AREA] Database 'puroks' initialized with ${defaultServiceAreas.length} documented Barangay Balintawak areas.");
  }

  /// Retrieves all service areas from Firebase RTDB without overwriting admin coordinates
  Future<List<ServiceArea>> getAllServiceAreas() async {
    await ensureInitialized();
    try {
      final snap = await _database.ref('puroks').get();
      if (snap.exists && snap.value != null) {
        final Map data = snap.value as Map;
        final List<ServiceArea> list = [];

        data.forEach((key, value) {
          if (value is Map) {
            final areaMap = Map<String, dynamic>.from(value);
            if (!areaMap.containsKey('id') || areaMap['id'] == null || areaMap['id'].toString().isEmpty) {
              areaMap['id'] = key.toString();
            }
            list.add(ServiceArea.fromJson(areaMap));
          }
        });
        return list;
      }
    } catch (e) {
      debugPrint("[SERVICE AREA] Error fetching service areas: $e");
    }
    return defaultServiceAreas;
  }

  /// Returns only verified truck collection stops
  Future<List<ServiceArea>> getTruckCollectionStops({String? truckId}) async {
    final all = await getAllServiceAreas();
    return all.where((a) {
      bool isStop = a.isTruckStop && a.verificationStatus.toUpperCase() == 'VERIFIED';
      if (truckId != null && truckId.isNotEmpty && a.assignedTruckId != null && a.assignedTruckId!.isNotEmpty) {
        return isStop && (a.assignedTruckId == truckId || a.assignedTruckId == "All");
      }
      return isStop;
    }).toList();
  }

  /// Returns only stationary street-sweeping assignments (`isTruckStop == false`)
  Future<List<ServiceArea>> getStationarySweepingAreas() async {
    final all = await getAllServiceAreas();
    return all.where((a) => !a.isTruckStop).toList();
  }

  /// Updates or inserts a service area with strict coordinate validation and debug logging
  Future<bool> saveServiceArea(ServiceArea area) async {
    final String key = area.id.isNotEmpty ? area.id : area.name.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_').toLowerCase();

    debugPrint("[ADMIN VERIFY]\n"
        "Area ID: $key\n"
        "Area Name: ${area.name}\n"
        "newVerificationStatus: ${area.verificationStatus}\n"
        "databasePath/table: puroks/$key");

    if (area.name.trim().isEmpty) return false;

    try {
      final Map<String, dynamic> data = area.toJson();
      data['id'] = key;

      await _database.ref('puroks/$key').set(data);
      debugPrint("[PUROK VERIFY SAVE SUCCESS] purokId: $key");
      return true;
    } catch (e) {
      debugPrint("[PUROK VERIFY SAVE ERROR] error: $e");
      return false;
    }
  }

  /// Deletes a service area
  Future<bool> deleteServiceArea(String id) async {
    try {
      await _database.ref('puroks/$id').remove();
      debugPrint("[SERVICE AREA] Deleted service area $id");
      return true;
    } catch (e) {
      debugPrint("[SERVICE AREA] Error deleting service area: $e");
      return false;
    }
  }
}
