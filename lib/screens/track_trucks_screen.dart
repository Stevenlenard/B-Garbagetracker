// Fleet Tracking Screen for Garbage Tracker
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size, Visibility;
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:geolocator/geolocator.dart' as geo;
import '../utils/app_theme.dart';
import '../widgets/fade_slide_entrance.dart';
import '../utils/custom_notification.dart';
import '../utils/prediction_engine.dart';
import '../services/truck_assignment_service.dart';
import '../api/api_service.dart';
import '../models/driver_trip.dart';
import '../services/driver_route_history_service.dart';
import '../utils/session_manager.dart';
import '../models/user.dart';

class TrackTrucksScreen extends StatefulWidget {
  final bool isEmbedded;
  final VoidCallback? onBack;
  const TrackTrucksScreen({super.key, this.isEmbedded = false, this.onBack});

  @override
  State<TrackTrucksScreen> createState() => _TrackTrucksScreenState();
}

class _TrackTrucksScreenState extends State<TrackTrucksScreen> with TickerProviderStateMixin {
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  MapboxMap? mapboxMap;
  List<Map<dynamic, dynamic>> _trucks = [];
  Map<String, dynamic> _allTrucksRegistry = {};
  
  Map<String, dynamic> _firebaseLocations = {};
  Map<String, dynamic> _phpLocations = {};
  
  String? _followedTruckId;
  Timer? _phpSyncTimer;
  final ApiService _apiService = ApiService();

  final Map<String, StreamSubscription> _sharedRouteSubscriptions = {};
  final Map<String, String> _truckPlates = {}; // Cache for plate numbers
  final Map<String, String> _driverCurrentTrucks = {}; // driverId -> truckId
  final Map<String, String> _userNamesById = {}; // userId -> official name
  final Set<String> _archivedDriverIds = {};
  final Set<String> _archivedDriverNames = {};
  final Set<String> _validDriverIds = {};
  final Set<String> _validDriverNames = {};
  final Set<String> _genuinelyOnlineDriverIds = {};
  final Set<String> _genuinelyOnlineDriverNamesUpper = {};
  StreamSubscription? _trucksMetaSubscription;
  StreamSubscription? _usersSubscription;

  final Map<String, List<Map<dynamic, dynamic>>> _lastRoutePoints = {}; 
  final Set<String> _visiblePaths = {};
  final Map<String, Position?> _sessionStartPoints = {};

  bool _isFollowLocked = false;
  bool _isMapActive = false;
  bool _isTargetActive = false;
  bool _isFleetPanelVisible = true;
  bool _isScanning = true;
  bool _isUpdatingMarkers = false;
  final Position _balintawakCenter = Position(121.1620, 13.9565);

  // Animation for Refresh Button
  late AnimationController _refreshRotationController;
  bool _isRefreshing = false;

  // --- MAP MODE STATE ('LIVE' or 'HISTORY') ---
  String _mapMode = "LIVE";

  // History Mode State
  UserData? _currentUser;
  List<DriverTrip> _historyTrips = [];
  DriverTrip? _selectedHistoryTrip;
  DriverTrip? _analyzedHistoryTrip;

  DateTime? _historyStartDate = DateTime.now().subtract(const Duration(days: 7));
  DateTime? _historyEndDate = DateTime.now();
  String _historyDriverId = "all";
  String _historyTruckId = "all";
  String _historyArea = "all";
  String _historyStatus = "all";

  List<Map<String, String>> _historyDriverOptions = [
    {"id": "all", "name": "All Drivers"}
  ];
  List<Map<String, String>> _historyTruckOptions = [
    {"id": "all", "name": "All Trucks"}
  ];
  final List<String> _historyAreaOptions = [
    "all", "Purok 1", "Purok 2", "Purok 3", "Purok 4", "Purok 5", "Purok 6", "Purok 7", "San Nicolas"
  ];
  final List<String> _historyStatusOptions = [
    "all", "COMPLETED", "ACTIVE", "PAUSED"
  ];

  bool _isLoadingHistory = false;

  // Replay Control State for History Mode
  bool _isReplayingHistory = false;
  double _replayProgress = 0.0;
  int _replaySpeedMultiplier = 1;
  Timer? _replayTimer;

  int get _activeHistoryFilterCount {
    int count = 0;
    if (_historyDriverId != "all") count++;
    if (_historyTruckId != "all") count++;
    if (_historyArea != "all") count++;
    if (_historyStatus != "all") count++;
    return count;
  }

  void _handleManualRefresh() async {
    if (_isRefreshing) return;
    
    setState(() => _isRefreshing = true);
    _refreshRotationController.repeat();
    
    try {
      if (_mapMode == "HISTORY") {
        await _loadHistoryModeData();
      } else {
        // 1. Refresh Base Data from Firebase (Force update)
        final trucksSnapshot = await _database.ref('trucks').get();
        if (trucksSnapshot.exists) {
          _allTrucksRegistry = Map<String, dynamic>.from(trucksSnapshot.value as Map);
        }

        final locationsSnapshot = await _database.ref('truck_locations').get();
        if (locationsSnapshot.exists && locationsSnapshot.value != null) {
          _firebaseLocations = Map<String, dynamic>.from(locationsSnapshot.value as Map);
        }

        final usersSnapshot = await _database.ref('users').get();
        if (usersSnapshot.exists) {
          final Map data = usersSnapshot.value as Map;
          final Map<String, String> currentAssignments = {};
          data.forEach((key, value) {
            if (value is Map && value['role'] == 'driver') {
              final String? truckId = value['preferred_truck']?.toString();
              if (truckId != null) currentAssignments[key.toString()] = truckId;
            }
          });
          _driverCurrentTrucks.clear();
          _driverCurrentTrucks.addAll(currentAssignments);
        }

        // Also trigger PHP location sync
        _syncPhpLocations();

        // 2. Reprocess merged data
        _processMergedTrucks();
      }
      
      // 3. UI Feedback (Centered White Box)
      if (mounted) {
        showDialog(
          context: context,
          barrierColor: Colors.black.withValues(alpha: 0.1),
          barrierDismissible: false,
          builder: (context) {
            Future.delayed(const Duration(milliseconds: 1500), () {
              if (Navigator.canPop(context)) Navigator.pop(context);
            });
            return Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 15, offset: const Offset(0, 5))
                  ],
                ),
                child: const Material(
                  color: Colors.transparent,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_rounded, color: Colors.green, size: 20),
                      SizedBox(width: 12),
                      Text("Map data refreshed", style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: Color(0xFF1A1A1A))),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      }
    } catch (e) {
      debugPrint("Refresh error: $e");
    } finally {
      if (mounted) {
        _refreshRotationController.stop();
        _refreshRotationController.reset();
        setState(() => _isRefreshing = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _loadCurrentUser();
    _listenToTrucks();
    _listenToTruckMeta();
    _listenToUsers();
    _syncPhpLocations();
    _phpSyncTimer = Timer.periodic(const Duration(seconds: 3), (_) => _syncPhpLocations());
    _refreshRotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _isScanning = false);
    });
  }

  Future<void> _loadCurrentUser() async {
    final user = await SessionManager.getUser();
    if (mounted) {
      setState(() {
        _currentUser = user;
      });
      _loadHistoryFilterOptions();
    }
  }

  Future<void> _loadHistoryFilterOptions() async {
    try {
      final response = await _apiService.getUsers();
      if (response.data['success'] == true) {
        final List rawUsers = response.data['users'] ?? [];
        final List<Map<String, String>> drivers = [
          {"id": "all", "name": "All Drivers"}
        ];
        final List<Map<String, String>> trucks = [
          {"id": "all", "name": "All Trucks"}
        ];
        final Set<String> seenTrucks = {};

        for (var u in rawUsers) {
          if (u is Map) {
            final String role = (u['role'] ?? '').toString().toLowerCase();
            final String accountStatus = (u['account_status'] ?? '').toString().toLowerCase();
            final String isArchivedStr = (u['is_archived'] ?? '0').toString();
            final bool isArchived = accountStatus == 'archived' || isArchivedStr == '1' || isArchivedStr == 'true';

            final String uid = (u['user_id'] ?? u['id'] ?? '').toString();
            final String name = (u['name'] ?? u['username'] ?? '').toString().toUpperCase();

            if (isArchived) {
              if (uid.isNotEmpty) _archivedDriverIds.add(uid);
              if (name.isNotEmpty) _archivedDriverNames.add(name);
              continue; // Exclude archived users
            }

            if (role == 'driver') {
              if (uid.isNotEmpty) _validDriverIds.add(uid);
              if (name.isNotEmpty) _validDriverNames.add(name);

              drivers.add({
                "id": uid,
                "name": (u['name'] ?? u['username'] ?? 'Driver').toString(),
              });
              final String t = (u['preferred_truck'] ?? '').toString();
              if (t.isNotEmpty && !seenTrucks.contains(t)) {
                seenTrucks.add(t);
                trucks.add({"id": t, "name": t});
              }
            }
          }
        }
        if (mounted) {
          setState(() {
            _historyDriverOptions = drivers;
            _historyTruckOptions = trucks;
          });
        }
      }
    } catch (e) {
      debugPrint("[MAP HISTORY] Error loading filter options: $e");
    }
  }

  Future<void> _loadHistoryModeData() async {
    if (_currentUser == null) {
      _currentUser = await SessionManager.getUser();
    }
    if (_currentUser == null || _currentUser!.role.toLowerCase() == 'resident') return;

    setState(() => _isLoadingHistory = true);

    try {
      final trips = await DriverRouteHistoryService.fetchRouteHistory(
        currentUser: _currentUser!,
        startDate: _historyStartDate,
        endDate: _historyEndDate,
        selectedDriverId: _historyDriverId,
        selectedTruckId: _historyTruckId,
        selectedArea: _historyArea,
        selectedStatus: _historyStatus,
      );

      if (mounted) {
        setState(() {
          _historyTrips = trips;
          _isLoadingHistory = false;
          if (_historyTrips.isNotEmpty) {
            _selectHistoryTrip(_historyTrips.first);
          } else {
            _selectedHistoryTrip = null;
            _analyzedHistoryTrip = null;
          }
        });
      }
    } catch (e) {
      debugPrint("[MAP TRACKING HISTORY] Error loading trips: $e");
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  void _selectHistoryTrip(DriverTrip trip) {
    _replayTimer?.cancel();
    final analyzed = DriverRouteHistoryService.analyzeTrip(trip);
    setState(() {
      _selectedHistoryTrip = trip;
      _analyzedHistoryTrip = analyzed;
      _isReplayingHistory = false;
      _replayProgress = 0.0;
    });
    _drawHistoryPolyline(analyzed);
  }

  void _clearHistoryFilters() {
    setState(() {
      _historyStartDate = DateTime.now();
      _historyEndDate = DateTime.now();
      _historyDriverId = "all";
      _historyTruckId = "all";
      _historyArea = "all";
      _historyStatus = "all";
    });
    _loadHistoryModeData();
  }

  void _toggleHistoryReplay() {
    if (_analyzedHistoryTrip == null || _analyzedHistoryTrip!.points.isEmpty) return;

    if (_isReplayingHistory) {
      _replayTimer?.cancel();
      setState(() => _isReplayingHistory = false);
    } else {
      setState(() => _isReplayingHistory = true);
      const intervalMs = 100;
      _replayTimer?.cancel();
      _replayTimer = Timer.periodic(const Duration(milliseconds: intervalMs), (timer) {
        if (!mounted || _analyzedHistoryTrip == null || _analyzedHistoryTrip!.points.isEmpty) {
          timer.cancel();
          return;
        }
        setState(() {
          _replayProgress += (0.005 * _replaySpeedMultiplier);
          if (_replayProgress >= 1.0) {
            _replayProgress = 1.0;
            _isReplayingHistory = false;
            timer.cancel();
          }
        });
        _updateReplayMapPosition();
      });
    }
  }

  void _updateReplayMapPosition() async {
    if (mapboxMap == null || _analyzedHistoryTrip == null || _analyzedHistoryTrip!.points.isEmpty) return;
    final points = _analyzedHistoryTrip!.points;
    final int idx = ((points.length - 1) * _replayProgress).clamp(0, points.length - 1).toInt();
    final currentP = points[idx];

    try {
      mapboxMap!.setCamera(CameraOptions(
        center: Point(coordinates: Position(currentP.longitude, currentP.latitude)),
        zoom: 15.0,
      ));
    } catch (_) {}
  }

  void _togglePathComparison(String truckId) {
    setState(() {
      if (_visiblePaths.contains(truckId)) {
        _visiblePaths.remove(truckId);
      } else {
        _visiblePaths.add(truckId);
      }
    });
  }

  Future<void> _drawHistoryPolyline(DriverTrip trip) async {
    if (mapboxMap == null) return;
    try {
      final style = mapboxMap!.style;
      const String sourceId = "map-history-route-source";
      const String layerId = "map-history-route-layer";

      final List<Map<String, dynamic>> features = [];
      final points = trip.points;

      if (points.length >= 2) {
        List<List<double>> currentSegment = [];
        String currentColor = "#6A1B9A";

        for (int i = 0; i < points.length; i++) {
          final p = points[i];
          final colorHex = p.status == "PAUSED" || p.status == "IDLE"
              ? "#FFC107"
              : (p.status == "FULL" ? "#2196F3" : "#6A1B9A");

          if (p.isGapStart && currentSegment.length >= 2) {
            features.add({
              "type": "Feature",
              "geometry": {
                "type": "LineString",
                "coordinates": List<List<double>>.from(currentSegment)
              },
              "properties": {"color": currentColor}
            });
            currentSegment = [[p.longitude, p.latitude]];
            currentColor = colorHex;
          } else {
            currentSegment.add([p.longitude, p.latitude]);
            currentColor = colorHex;
          }
        }

        if (currentSegment.length >= 2) {
          features.add({
            "type": "Feature",
            "geometry": {
              "type": "LineString",
              "coordinates": List<List<double>>.from(currentSegment)
            },
            "properties": {"color": currentColor}
          });
        }
      }

      final featureCollection = {"type": "FeatureCollection", "features": features};

      if (await style.styleSourceExists(sourceId)) {
        await style.setStyleSourceProperty(sourceId, "data", jsonEncode(featureCollection));
      } else {
        await style.addSource(GeoJsonSource(id: sourceId, data: jsonEncode(featureCollection)));
        if (!(await style.styleLayerExists(layerId))) {
          await style.addLayer(LineLayer(
            id: layerId,
            sourceId: sourceId,
            lineColor: Colors.purple.toARGB32(),
            lineWidth: 6.0,
            lineOpacity: 0.95,
            lineCap: LineCap.ROUND,
            lineJoin: LineJoin.ROUND,
          ));
        }
      }

      if (points.isNotEmpty) {
        mapboxMap?.setCamera(CameraOptions(
          center: Point(coordinates: Position(points.first.longitude, points.first.latitude)),
          zoom: 14.5,
        ));
      }
    } catch (e) {
      debugPrint("[MAP HISTORY] Error drawing history polyline: $e");
    }
  }

  void _syncPhpLocations() async {
    try {
      final response = await _apiService.getLocations();
      final dynamic rawData = response.data;
      List? phpLocations;
      if (rawData is Map) {
        phpLocations = (rawData['locations'] ?? rawData['data']) as List?;
      } else if (rawData is List) {
        phpLocations = rawData;
      }

      if (phpLocations != null && mounted) {
        final Map<String, dynamic> phpMap = {};
        final int now = DateTime.now().millisecondsSinceEpoch;

        for (var loc in phpLocations) {
          if (loc == null || loc is! Map) continue;
          final String tid = (loc['truck_id'] ?? loc['truckId'] ?? loc['id'] ?? '').toString().toUpperCase().trim();
          final String driverName = (loc['driver_name'] ?? loc['driverName'] ?? loc['full_name'] ?? '').toString();

          final double lat = double.tryParse(loc['latitude']?.toString() ?? loc['lat']?.toString() ?? '0') ?? 0.0;
          final double lng = double.tryParse(loc['longitude']?.toString() ?? loc['lng']?.toString() ?? '0') ?? 0.0;
          final String status = (loc['status'] ?? 'ACTIVE').toString().toUpperCase();
          
          final dynamic rawTime = loc['updated_at'] ?? loc['updatedAt'] ?? loc['lastSeen'] ?? loc['last_seen'];
          int timestampMs = 0;
          if (rawTime is num) {
            timestampMs = rawTime.toInt();
          } else if (rawTime != null) {
            String str = rawTime.toString().trim();
            if (str.contains(' ')) str = str.replaceAll(' ', 'T');
            final parsed = DateTime.tryParse(str);
            if (parsed != null) timestampMs = parsed.millisecondsSinceEpoch;
          }

          final dynamic secondsAgoRaw = loc['seconds_ago'] ?? loc['secondsAgo'];
          final int secondsAgo = secondsAgoRaw is num ? secondsAgoRaw.toInt() : (timestampMs > 0 ? ((now - timestampMs) / 1000).abs().toInt() : 0);

          final bool isPhpOnline = (status != 'OFFLINE') &&
              (loc['is_online'] == true || loc['isOnline'] == true || loc['is_online'] == 1 || (secondsAgo <= 180 && secondsAgo >= 0));

          if (tid.isNotEmpty && lat != 0.0 && lng != 0.0) {
            phpMap[tid] = {
              'truck_id': tid,
              'driver_id': loc['driver_id'] ?? loc['driverId'] ?? loc['user_id'],
              'driver_name': driverName.isEmpty ? 'Driver' : driverName,
              'plate_number': loc['plate_number'] ?? loc['plateNumber'] ?? 'N/A',
              'latitude': lat,
              'longitude': lng,
              'lat': lat,
              'lng': lng,
              'speed': double.tryParse(loc['speed']?.toString() ?? '0') ?? 0.0,
              'status': status,
              'isOnline': isPhpOnline,
              'lastSeen': timestampMs > 0 ? timestampMs : now,
              'updatedAt': '$secondsAgo secs ago',
              'seconds_ago': secondsAgo,
            };
          }
        }
        _phpLocations = phpMap;
        _processMergedTrucks();
      }
    } catch (e) {
      debugPrint("PHP locations sync error: $e");
    }
  }

  @override
  void dispose() {
    _replayTimer?.cancel();
    for (final sub in _sharedRouteSubscriptions.values) {
      sub.cancel();
    }
    _trucksMetaSubscription?.cancel();
    _usersSubscription?.cancel();
    _phpSyncTimer?.cancel();
    _refreshRotationController.dispose();
    super.dispose();
  }

  void _listenToTruckMeta() {
    _trucksMetaSubscription?.cancel();
    _trucksMetaSubscription = _database.ref('trucks').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        final Map<String, String> newPlates = {};
        data.forEach((key, value) {
          if (value is Map && value['plateNumber'] != null) {
            newPlates[key.toString().toUpperCase()] = value['plateNumber'].toString();
          }
        });
        if (mounted) setState(() => _truckPlates.addAll(newPlates));
      }
    });
  }

  void _listenToUsers() {
    _usersSubscription?.cancel();
    _usersSubscription = _database.ref('users').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        final Map data = event.snapshot.value as Map;
        final Map<String, String> currentAssignments = {};
        final Map<String, String> userNames = {};
        final Set<String> archivedIds = {};
        final Set<String> archivedNames = {};
        final Set<String> validDriverIds = {};
        final Set<String> validDriverNames = {};
        final Set<String> genuinelyOnlineDriverIds = {};
        final Set<String> genuinelyOnlineDriverNamesUpper = {};
        final int now = DateTime.now().millisecondsSinceEpoch;

        data.forEach((key, value) {
          if (value is Map) {
            final String role = (value['role'] ?? '').toString().toLowerCase();
            final String uId = key.toString();
            final String rawName = (value['name'] ?? value['username'] ?? '').toString();
            final String name = rawName.toUpperCase();
            final String status = (value['account_status'] ?? '').toString().toLowerCase();
            final dynamic isArchivedRaw = value['is_archived'] ?? value['isArchived'];
            final bool isArchived = status == 'archived' ||
                isArchivedRaw == 1 ||
                isArchivedRaw == '1' ||
                isArchivedRaw == true ||
                isArchivedRaw == 'true';

            if (isArchived) {
              archivedIds.add(uId);
              if (name.isNotEmpty) archivedNames.add(name);
            } else if (role == 'driver') {
              validDriverIds.add(uId);
              if (name.isNotEmpty) validDriverNames.add(name);
              if (rawName.isNotEmpty) userNames[uId] = rawName;

              final String? truckId = value['preferred_truck']?.toString();
              if (truckId != null) currentAssignments[uId] = truckId;

              final bool isUserOnline = value['isOnline'] == true;
              final String userStatus = (value['status'] ?? '').toString().toUpperCase();
              final dynamic lastSeenRaw = value['lastSeen'];
              final int lastSeen = lastSeenRaw is num ? lastSeenRaw.toInt() : 0;
              final bool isFresh = lastSeen == 0 || (now - lastSeen).abs() < 180000;

              if (isUserOnline && userStatus != 'OFFLINE' && userStatus != 'COMPLETED' && userStatus != 'FINISHED' && isFresh) {
                genuinelyOnlineDriverIds.add(uId);
                if (name.isNotEmpty) genuinelyOnlineDriverNamesUpper.add(name);
              }
            }
          }
        });

        if (mounted) {
          setState(() {
            _userNamesById.clear();
            _userNamesById.addAll(userNames);
            _driverCurrentTrucks.clear();
            _driverCurrentTrucks.addAll(currentAssignments);
            _archivedDriverIds.clear();
            _archivedDriverIds.addAll(archivedIds);
            _archivedDriverNames.clear();
            _archivedDriverNames.addAll(archivedNames);
            _validDriverIds.clear();
            _validDriverIds.addAll(validDriverIds);
            _validDriverNames.clear();
            _validDriverNames.addAll(validDriverNames);
            _genuinelyOnlineDriverIds.clear();
            _genuinelyOnlineDriverIds.addAll(genuinelyOnlineDriverIds);
            _genuinelyOnlineDriverNamesUpper.clear();
            _genuinelyOnlineDriverNamesUpper.addAll(genuinelyOnlineDriverNamesUpper);
          });
          _processMergedTrucks();
        }
      }
    });

    _fetchTotalDriversFromUserManagement();
  }

  Future<void> _fetchTotalDriversFromUserManagement() async {
    try {
      final response = await _apiService.getUsers();
      if (response.data != null && response.data['success'] == true) {
        final List users = response.data['users'] ?? [];
        final List residents = response.data['residents'] ?? [];
        final allList = [...users, ...residents];

        final Set<String> driverIds = {};
        final Set<String> driverNames = {};

        for (var user in allList) {
          if (user is Map) {
            final String uId = (user['user_id'] ?? user['id'] ?? '').toString();
            final String role = (user['role'] ?? '').toString().toLowerCase().trim();
            final String name = (user['name'] ?? user['username'] ?? '').toString().trim().toUpperCase();
            final String status = (user['account_status'] ?? user['status'] ?? '').toString().toLowerCase();
            final dynamic isArchivedRaw = user['is_archived'] ?? user['isArchived'];
            final bool isArchived = status == 'archived' ||
                isArchivedRaw == 1 ||
                isArchivedRaw == '1' ||
                isArchivedRaw == true ||
                isArchivedRaw == 'true';

            if (role == 'driver' && !isArchived) {
              if (uId.isNotEmpty) driverIds.add(uId);
              if (name.isNotEmpty) driverNames.add(name);
            }
          }
        }
        if (mounted && driverIds.isNotEmpty) {
          setState(() {
            _validDriverIds.addAll(driverIds);
            _validDriverNames.addAll(driverNames);
          });
        }
      }
    } catch (e) {
      debugPrint("Error fetching driver count from User Management API: $e");
    }
  }

  void _listenToTrucks() {
    _database.ref('truck_locations').onValue.listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null) {
        _firebaseLocations = Map<String, dynamic>.from(event.snapshot.value as Map);
      } else {
        _firebaseLocations = {};
      }
      _processMergedTrucks();
    });
  }

  void _processMergedTrucks() {
    if (!mounted || _mapMode == "HISTORY") return;

    final int now = DateTime.now().millisecondsSinceEpoch;
    final Map<String, Map<String, dynamic>> driverToLatestTruck = {};

    void processLocationNode(String nodeKey, Map liveData) {
      final Map<String, dynamic> value = Map<String, dynamic>.from(liveData);
      final String nodeTid = (value['truck_id'] ?? value['truckId'] ?? nodeKey).toString().toUpperCase().trim();
      final String driverName = (value['driver_name'] ?? value['driverName'] ?? 'Driver').toString().trim();
      final String driverIdStr = (value['driver_id'] ?? value['driverId'] ?? '').toString().trim();
      final String driverNameUpper = driverName.toUpperCase();

      final String role = (value['role'] ?? '').toString().toLowerCase();
      final bool isExplicitNonDriver = (role == 'resident' || role == 'admin' || role == 'administrator');

      // Check if driver is archived or test account or non-driver
      final String accountStatus = (value['account_status'] ?? value['status'] ?? '').toString().toLowerCase();
      final dynamic isArchivedRaw = value['is_archived'] ?? value['isArchived'];
      final bool isNodeArchived = accountStatus == 'archived' ||
          isArchivedRaw == 1 ||
          isArchivedRaw == '1' ||
          isArchivedRaw == true ||
          isArchivedRaw == 'true';

      // Verify driver_id or driver_name belongs to a valid driver with role == 'driver'
      final bool isDriverIdValid = driverIdStr.isEmpty || _validDriverIds.isEmpty || _validDriverIds.contains(driverIdStr);
      final bool isDriverNameValid = _validDriverNames.isEmpty || _validDriverNames.contains(driverNameUpper);

      if (isExplicitNonDriver ||
          isNodeArchived ||
          !isDriverIdValid ||
          !isDriverNameValid ||
          (driverIdStr.isNotEmpty && _archivedDriverIds.contains(driverIdStr)) ||
          _archivedDriverNames.contains(driverNameUpper) ||
          nodeTid.contains("ADMIN") ||
          nodeTid.contains("SYSTEM") ||
          nodeTid.contains("USER")) {
        return; // REJECT NON-DRIVERS, RESIDENTS, ADMINS, AND ARCHIVED ACCOUNTS!
      }

      final bool isOnlineField = value['isOnline'] == true || value['is_online'] == true || value['is_online'] == 1;
      final String status = (value['status'] ?? 'ACTIVE').toString().toUpperCase();
      final double lat = double.tryParse(value['latitude']?.toString() ?? value['lat']?.toString() ?? '0') ?? 0.0;
      final double lng = double.tryParse(value['longitude']?.toString() ?? value['lng']?.toString() ?? '0') ?? 0.0;
      final bool hasValidCoords = (lat != 0.0 && lng != 0.0);

      final dynamic lastSeenRaw = value['lastSeen'] ?? value['last_seen'];
      int lastSeen = 0;
      if (lastSeenRaw is num) {
        lastSeen = lastSeenRaw.toInt();
      } else if (lastSeenRaw != null) {
        final parsed = DateTime.tryParse(lastSeenRaw.toString().replaceAll(' ', 'T'));
        if (parsed != null) lastSeen = parsed.millisecondsSinceEpoch;
      }

      final dynamic loginTimeRaw = value['login_time'] ?? value['loginTime'];
      int loginTime = 0;
      if (loginTimeRaw is num) {
        loginTime = loginTimeRaw.toInt();
      }

      // Session Limit: 12 Hours (43,200,000 ms) since login
      final bool isSessionValid = loginTime == 0 || (now - loginTime) < 43200000;

      // Telemetry freshness check:
      // A truck is genuinely live online ONLY if its last GPS telemetry ping was within the last 3 minutes (180,000 ms) and user account is genuinely online
      final bool isFresh = lastSeen > 0 && (now - lastSeen).abs() < 180000;
      final bool isUserAccountOnline = (driverIdStr.isNotEmpty && _genuinelyOnlineDriverIds.contains(driverIdStr)) ||
          _genuinelyOnlineDriverNamesUpper.contains(driverNameUpper);

      // Driver stays visible during ACTIVE, COLLECTING, IDLE, PAUSED, FULL while logged in
      // Excluded from Active Collection Fleet once trip is COMPLETED / FINISHED or OFFLINE
      final bool isGenuinelyOnline = isOnlineField &&
          status != 'OFFLINE' &&
          status != 'COMPLETED' &&
          status != 'FINISHED' &&
          hasValidCoords &&
          isSessionValid &&
          isFresh &&
          isUserAccountOnline;

      if (isGenuinelyOnline) {
        final resolved = TruckAssignmentService.resolveFleetNode(
          nodeKey: nodeKey,
          liveData: value,
          trucksRegistry: _allTrucksRegistry,
        );

        String officialDriverName = resolved.driverName;
        if (resolved.driverId > 0 && _userNamesById.containsKey(resolved.driverId.toString())) {
          officialDriverName = _userNamesById[resolved.driverId.toString()]!;
        } else if (driverIdStr.isNotEmpty && _userNamesById.containsKey(driverIdStr)) {
          officialDriverName = _userNamesById[driverIdStr]!;
        }

        final Map<String, dynamic> item = {
          ...Map<String, dynamic>.from(_allTrucksRegistry[resolved.truckId] as Map? ?? _allTrucksRegistry[nodeKey] as Map? ?? {}),
          ...value,
          'truck_id': resolved.truckId,
          'truckNumber': resolved.truckNumber,
          'plate_number': resolved.plateNumber,
          'driver_name': officialDriverName,
          'driver_id': resolved.driverId > 0 ? resolved.driverId : (driverIdStr.isNotEmpty && driverIdStr != 'null' ? driverIdStr : officialDriverName),
          'latitude': lat,
          'longitude': lng,
          'isOnline': true,
          'status': status,
          'lastSeen': lastSeen > 0 ? lastSeen : now,
        };

        // Deduplicate by driver key (driver_id or driver_name)
        final String driverKey = (resolved.driverId > 0
                ? resolved.driverId.toString()
                : (driverIdStr.isNotEmpty && driverIdStr != 'null' ? driverIdStr : officialDriverName))
            .toUpperCase();

        if (!driverToLatestTruck.containsKey(driverKey)) {
          driverToLatestTruck[driverKey] = item;
        } else {
          final existing = driverToLatestTruck[driverKey]!;
          final int existingSeen = (existing['lastSeen'] ?? 0) as int;
          if (lastSeen >= existingSeen) {
            driverToLatestTruck[driverKey] = item;
          }
        }
      }
    }

    _firebaseLocations.forEach((key, value) {
      if (value is Map) processLocationNode(key, value);
    });

    _phpLocations.forEach((key, value) {
      if (value is Map) processLocationNode(key, value);
    });

    final List<Map<dynamic, dynamic>> mergedList = driverToLatestTruck.values.toList();

    setState(() {
      _trucks = mergedList;
    });

    _syncRouteSubscriptions();
    _updateTruckMarkers();
  }

  void _updateTruckMarkers() async {
    if (mapboxMap == null || _isUpdatingMarkers) return;
    try {
      final style = mapboxMap!.style;
      if (!await style.isStyleLoaded()) return;
      _isUpdatingMarkers = true;

      final String sourceId = "trucks-admin-live-source";
      final List<Map<String, dynamic>> features = _trucks
          .where((t) => t['isOnline'] == true && (t['latitude'] ?? 0) != 0 && (t['longitude'] ?? 0) != 0)
          .map((truck) {
        final double lat = (truck['latitude'] ?? 0.0).toDouble();
        final double lng = (truck['longitude'] ?? 0.0).toDouble();
        final String tid = (truck['truck_id'] ?? truck['truckNumber'] ?? 'Truck').toString();
        final String status = (truck['status'] ?? "ACTIVE").toString().toUpperCase();
        return {
          "type": "Feature",
          "geometry": {"type": "Point", "coordinates": [lng, lat]},
          "properties": {
            "truckId": tid,
            "status": status,
            "label": "🚛 $tid\n$status"
          }
        };
      }).toList();

      final geoJsonData = jsonEncode({"type": "FeatureCollection", "features": features});

      if (!(await style.styleSourceExists(sourceId))) {
        await style.addSource(GeoJsonSource(id: sourceId, data: geoJsonData));
      } else {
        await style.setStyleSourceProperty(sourceId, "data", geoJsonData);
      }

      final statusColorExpr = [
        "match", ["get", "status"],
        "IDLE", Colors.orange.toARGB32(),
        "PAUSED", Colors.orange.toARGB32(),
        "STOP", Colors.red.toARGB32(),
        "FULL", Colors.red.toARGB32(),
        "COMPLETED", Colors.blue.toARGB32(),
        "FINISHED", Colors.blue.toARGB32(),
        Colors.green.toARGB32()
      ];

      if (!(await style.styleLayerExists("admin-trucks-circle"))) {
        try { await style.removeStyleLayer("admin-trucks-pulse"); } catch (_) {}
        try { await style.removeStyleLayer("admin-trucks-circle"); } catch (_) {}
        try { await style.removeStyleLayer("admin-trucks-inner-dot"); } catch (_) {}
        try { await style.removeStyleLayer("admin-trucks-label"); } catch (_) {}

        // 1. Pulse Layer
        await style.addLayer(CircleLayer(
          id: "admin-trucks-pulse",
          sourceId: sourceId,
          circleRadius: 16.0,
          circleColor: Colors.green.toARGB32(),
          circleOpacity: 0.35,
        ));
        await style.setStyleLayerProperty("admin-trucks-pulse", "circle-color", statusColorExpr);

        // 2. Main Circle Marker
        await style.addLayer(CircleLayer(
          id: "admin-trucks-circle",
          sourceId: sourceId,
          circleRadius: 10.0,
          circleColor: Colors.green.toARGB32(),
          circleStrokeWidth: 3.5,
          circleStrokeColor: Colors.white.toARGB32(),
        ));
        await style.setStyleLayerProperty("admin-trucks-circle", "circle-color", statusColorExpr);

        // 3. Inner Dot
        await style.addLayer(CircleLayer(
          id: "admin-trucks-inner-dot",
          sourceId: sourceId,
          circleRadius: 3.5,
          circleColor: Colors.white.toARGB32(),
        ));

        // 4. Text Label
        await style.addLayer(SymbolLayer(
          id: "admin-trucks-label",
          sourceId: sourceId,
          textSize: 12.0,
          textColor: Colors.green.toARGB32(),
          textHaloColor: Colors.white.toARGB32(),
          textHaloWidth: 3.0,
          textAnchor: TextAnchor.BOTTOM,
          textOffset: [0.0, -2.0],
          symbolSortKey: 100.0,
          textAllowOverlap: true,
          textJustify: TextJustify.CENTER,
        ));
        await style.setStyleLayerProperty("admin-trucks-label", "text-field", ["get", "label"]);
        await style.setStyleLayerProperty("admin-trucks-label", "text-color", statusColorExpr);
      } else {
        await style.setStyleLayerProperty("admin-trucks-pulse", "circle-color", statusColorExpr);
        await style.setStyleLayerProperty("admin-trucks-circle", "circle-color", statusColorExpr);
        await style.setStyleLayerProperty("admin-trucks-label", "text-color", statusColorExpr);
      }
    } catch (e) {
      if (!e.toString().contains("Style is not done loading")) {
        debugPrint("[ADMIN MAP MARKER ERROR] $e");
      }
    } finally {
      _isUpdatingMarkers = false;
    }
  }

  void _syncRouteSubscriptions() {
    final Set<String> activeIds = _trucks.map((t) => (t['truck_id'] ?? t['truckId'] ?? '').toString()).toSet();

    _sharedRouteSubscriptions.removeWhere((tid, sub) {
      if (!activeIds.contains(tid)) {
        sub.cancel();
        _lastRoutePoints.remove(tid);
        _visiblePaths.remove(tid);
        return true;
      }
      return false;
    });

    for (var truck in _trucks) {
      final String tid = (truck['truck_id'] ?? truck['truckId'] ?? '').toString();
      final String session = (truck['current_session'] ?? truck['sessionId'] ?? '').toString();

      if (session.isNotEmpty && !_sharedRouteSubscriptions.containsKey(tid)) {
        _sharedRouteSubscriptions[tid] = _database.ref('driver_routes/$session/route').onValue.listen((event) {
          if (event.snapshot.exists && event.snapshot.value is Map) {
            final Map rawPoints = event.snapshot.value as Map;
            final List<Map<dynamic, dynamic>> pointsList = [];
            rawPoints.forEach((k, v) {
              if (v is Map) pointsList.add(Map<dynamic, dynamic>.from(v));
            });
            pointsList.sort((a, b) => (a['timestamp'] ?? 0).compareTo(b['timestamp'] ?? 0));

            if (mounted) {
              setState(() {
                _lastRoutePoints[tid] = pointsList;
                _visiblePaths.add(tid);
              });
            }
          }
        });
      }
    }
  }

  void _onMapCreated(MapboxMap map) {
    mapboxMap = map;
    _isMapActive = true;
    if (_mapMode == "HISTORY" && _analyzedHistoryTrip != null) {
      _drawHistoryPolyline(_analyzedHistoryTrip!);
    }
  }

  void _onStyleLoaded(StyleLoadedEventData event) {
    debugPrint("[MAPBOX] Style loaded.");
    _updateTruckMarkers();
  }

  double _getResponsiveZoom(BuildContext context) {
    final double width = MediaQuery.of(context).size.width;
    if (width < 600) return 13.5;
    if (width < 1024) return 14.0;
    return 14.5;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final bool isDesktop = constraints.maxWidth >= 900;
      return FadeSlideEntrance(
        child: Scaffold(
          backgroundColor: Colors.white, 
          body: isDesktop ? _buildDesktopLayout() : _buildMobileLayout(), 
        ),
      );
    });
  }

  Widget _buildDesktopLayout() {
    return Container(
      margin: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(40),
        boxShadow: AppTheme.balancedDeepShadow,
        border: Border.all(color: const Color(0xFFE0E0E0), width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: MapWidget(
              gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
                Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
              },
              onMapCreated: _onMapCreated,
              onStyleLoadedListener: _onStyleLoaded,
              viewport: CameraViewportState(
                center: Point(coordinates: _balintawakCenter),
                zoom: _getResponsiveZoom(context),
              ),
            ),
          ),
          _buildCornerHeader(),
          _buildMapControls(bottom: 32),
          _buildDebugOverlay(),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeInOutQuart,
            top: 24, bottom: 24,
            right: _isFleetPanelVisible ? 24 : -450,
            child: PointerInterceptor(
              child: Container(
                width: 420,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(32),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 30, spreadRadius: 5, offset: const Offset(-10, 0))],
                  border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1.5),
                ),
                child: Column(children: [
                  _buildFixedPanelHeader(),
                  const Divider(height: 1),
                  Expanded(child: ClipRRect(borderRadius: const BorderRadius.vertical(bottom: Radius.circular(32)), child: _buildFleetStatusContent(null))),
                ]),
              ),
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeInOutQuart,
            top: 0, bottom: 0,
            right: _isFleetPanelVisible ? 444 : 0,
            child: Center(
              child: PointerInterceptor(
                child: GestureDetector(
                  onTap: () => setState(() => _isFleetPanelVisible = !_isFleetPanelVisible),
                  child: Container(
                    width: 24, height: 80,
                    decoration: BoxDecoration(
                      color: const Color(0xFF00695C), 
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        bottomLeft: Radius.circular(16),
                      ), 
                      boxShadow: AppTheme.pulidongShadow,
                    ),
                    child: Icon(_isFleetPanelVisible ? Icons.keyboard_arrow_right_rounded : Icons.keyboard_arrow_left_rounded, size: 18, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileLayout() {
    final activeTrucks = _trucks.where((t) => t['isOnline'] == true).toList();
    final bool hasActiveTrucks = activeTrucks.isNotEmpty;
    final int count = activeTrucks.length;

    final double minSize = 0.18;
    final double initialSize = !hasActiveTrucks
        ? 0.18
        : (count <= 2 ? 0.22 : 0.26);
    final double maxSize = !hasActiveTrucks
        ? 0.35
        : (count <= 2 ? 0.70 : 0.92);
    final List<double> snapSizes = !hasActiveTrucks
        ? [0.18, 0.35]
        : (count <= 2 ? [0.18, 0.45, 0.70] : [0.18, 0.55, 0.92]);

    final double controlsBottom = !hasActiveTrucks
        ? 175.0
        : (count <= 2 ? 210.0 : 245.0);

    return Stack(children: [
      Positioned.fill(
        child: Stack(children: [
          Positioned.fill(
            child: MapWidget(
              gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
                Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
              },
              onMapCreated: _onMapCreated,
              onStyleLoadedListener: _onStyleLoaded,
              viewport: CameraViewportState(
                center: Point(coordinates: _balintawakCenter),
                zoom: _getResponsiveZoom(context),
              ),
            ),
          ),
          _buildMapControls(bottom: controlsBottom),
        ]),
      ),
      _buildFloatingHeader(),
      _buildDebugOverlay(),
      Positioned.fill(
        child: DraggableScrollableSheet(
          initialChildSize: initialSize,
          minChildSize: minSize,
          maxChildSize: maxSize,
          snap: true,
          snapSizes: snapSizes,
          builder: (context, scrollController) => PointerInterceptor(
            child: _buildFleetStatusContent(scrollController, isMobile: true),
          ),
        ),
      ),
    ]);
  }

  Widget _buildCornerHeader() {
    final double width = MediaQuery.of(context).size.width;
    final bool isMobile = width < 600;
    final bool isTablet = width >= 600 && width < 1024;

    return Positioned(
      top: isMobile ? 12 : (isTablet ? 16 : 24),
      left: isMobile ? 12 : (isTablet ? 16 : 24),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 12 : (isTablet ? 18 : 24),
          vertical: isMobile ? 8 : (isTablet ? 12 : 16),
        ),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(isMobile ? 16 : 24),
          boxShadow: AppTheme.pulidongShadow,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "Fleet GIS Tracking",
                  style: TextStyle(
                    fontSize: isMobile ? 14.5 : (isTablet ? 17 : 20),
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(width: 16),
                _buildMapModeToggleSwitch(),
              ],
            ),
            const SizedBox(height: 3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: _mapMode == "LIVE" ? Colors.greenAccent : Colors.purpleAccent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _mapMode == "LIVE" ? "Real-time telemetry and monitoring" : "Historical route review & GPS tracks",
                  style: TextStyle(
                    color: Colors.grey,
                    fontSize: isMobile ? 10 : 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMapModeToggleSwitch() {
    return Container(
      height: 32,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F4F8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () {
              setState(() => _mapMode = "LIVE");
              _processMergedTrucks();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _mapMode == "LIVE" ? const Color(0xFF00796B) : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(Icons.sensors_rounded, size: 12, color: _mapMode == "LIVE" ? Colors.white : Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    "Live",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: _mapMode == "LIVE" ? Colors.white : const Color(0xFF455A64),
                    ),
                  ),
                ],
              ),
            ),
          ),
          GestureDetector(
            onTap: () {
              setState(() => _mapMode = "HISTORY");
              _loadHistoryModeData();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _mapMode == "HISTORY" ? const Color(0xFF6A1B9A) : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(Icons.history_rounded, size: 12, color: _mapMode == "HISTORY" ? Colors.white : Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    "History",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: _mapMode == "HISTORY" ? Colors.white : const Color(0xFF455A64),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFixedPanelHeader() {
    final bool isHistory = _mapMode == "HISTORY";
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              isHistory ? "Route History" : "Active Fleet Status",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: isHistory ? const Color(0xFF6A1B9A) : const Color(0xFF00796B)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isHistory ? const Color(0xFFF3E5F5) : const Color(0xFFE0F2F1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                isHistory ? "HISTORICAL TRIP" : "LIVE TELEMETRY",
                style: TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: isHistory ? const Color(0xFF6A1B9A) : const Color(0xFF00796B)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          isHistory ? "Select a trip to render actual GPS route" : "Live collection unit updates",
          style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500),
        ),
      ]),
    );
  }

  Widget _buildDebugOverlay() {
    final active = _trucks.where((t) => t['isOnline'] == true).toList();
    final double width = MediaQuery.of(context).size.width;
    final double topSafeArea = MediaQuery.of(context).padding.top;
    
    final bool isMobile = width < 600;
    final bool isTablet = width >= 600 && width < 900;
    final bool isDesktop = width >= 900;

    final double btnSize = (width * 0.12).clamp(44.0, 50.0);
    final double floatingHeaderBottom = topSafeArea + 12.0 + btnSize;

    final double topOffset = isDesktop
        ? 125.0 
        : (floatingHeaderBottom + (isMobile ? 8.0 : 12.0));
    final double leftOffset = isMobile ? 16.0 : (isTablet ? 20.0 : 24.0);

    final int totalFleetUnits = math.max(_validDriverIds.length, _allTrucksRegistry.length);

    return Positioned(
      top: topOffset,
      left: leftOffset,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 12 : 14,
          vertical: isMobile ? 6 : 8,
        ),
        decoration: BoxDecoration(
          color: Colors.white, 
          borderRadius: BorderRadius.circular(16), 
          boxShadow: AppTheme.pulidongShadow, 
          border: Border.all(color: Colors.white, width: 1.5)
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min, 
          children: [
            _buildHUDSeparator("MODE", _mapMode, isGreen: _mapMode == "LIVE"),
            const SizedBox(width: 10),
            Container(width: 1.5, height: 14, color: Colors.grey.shade300),
            const SizedBox(width: 10),
            _buildHUDSeparator("TOTAL UNITS", "$totalFleetUnits"),
            const SizedBox(width: 10),
            Container(width: 1.5, height: 14, color: Colors.grey.shade300),
            const SizedBox(width: 10),
            _buildHUDSeparator("ONLINE", "${active.length}", isGreen: true),
          ],
        ),
      ),
    );
  }

  Widget _buildHUDSeparator(String label, String value, {bool isGreen = false}) {
    return Row(children: [
      Text("$label: ", style: TextStyle(color: Colors.grey.shade600, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
      Text(value, style: TextStyle(color: isGreen ? const Color(0xFF00796B) : const Color(0xFF6A1B9A), fontSize: 12, fontWeight: FontWeight.w900)),
    ]);
  }

  Widget _buildFloatingHeader() {
    final double screenWidth = MediaQuery.of(context).size.width;
    final double btnSize = (screenWidth * 0.12).clamp(44.0, 50.0);
    final bool isMobile = screenWidth < 900;

    return Positioned(
      top: 12, left: 16, right: 16,
      child: SafeArea(
        child: Row(children: [
          _TrackHoverZoomCard(
            onTap: () {
              if (isMobile) {
                Scaffold.of(context).openDrawer();
              } else if (widget.onBack != null) {
                widget.onBack!();
              }
            },
            child: Container(
              width: btnSize, 
              height: btnSize, 
              decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: AppTheme.pulidongShadow), 
              child: Icon(
                isMobile ? Icons.menu_rounded : Icons.arrow_back_ios_new_rounded, 
                color: const Color(0xFF1A1A1A), 
                size: isMobile ? 22 : 20
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              height: btnSize,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(25),
                boxShadow: AppTheme.pulidongShadow,
              ),
              child: Row(
                children: [
                  const Text("Map Tracking", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Color(0xFF1A1A1A))),
                  const Spacer(),
                  _buildMapModeToggleSwitch(),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildFleetStatusContent(ScrollController? scrollController, {bool isMobile = false}) {
    if (_mapMode == "HISTORY") {
      return _buildHistoryModeContent(scrollController, isMobile: isMobile);
    }

    final List sortedTrucks = List.from(_trucks);
    sortedTrucks.sort((a, b) {
      final bool aOnline = a['isOnline'] == true;
      final bool bOnline = b['isOnline'] == true;
      if (aOnline && !bOnline) return -1;
      if (!aOnline && bOnline) return 1;
      return 0;
    });

    final List activeTrucks = sortedTrucks.where((t) => t['isOnline'] == true).toList();

    List<Widget> items;
    if (_isScanning && activeTrucks.isEmpty) {
      items = [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Color(0xFF00796B),
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  "Scanning for active unit...",
                  style: TextStyle(color: Colors.grey, fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ];
    } else if (activeTrucks.isEmpty) {
      items = [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: Text(
              "No online active truck",
              style: TextStyle(color: Colors.grey, fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ];
    } else {
      items = activeTrucks.map<Widget>((truck) => _buildOrganizedTruckCard(truck)).toList();
    }
    
    if (isMobile) {
      return Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(40)),
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 25, spreadRadius: 5, offset: Offset(0, -5))],
        ),
        clipBehavior: Clip.antiAlias,
        child: CustomScrollView(
          controller: scrollController,
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          slivers: [
            SliverPersistentHeader(
              pinned: true,
              delegate: _StickyHeaderDelegate(
                minHeight: 88,
                maxHeight: 88,
                child: Container(
                  color: Colors.white,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.center,
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade300,
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Active Fleet Status", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
                            SizedBox(height: 2),
                            Text("Real-time updates on active units", style: TextStyle(fontSize: 11.5, color: Colors.grey, fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Divider(height: 1, thickness: 1, color: Color(0xFFF5F5F5)),
                    ],
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.only(top: 8, bottom: 120),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => items[index],
                  childCount: items.length,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      itemCount: items.length,
      itemBuilder: (context, index) => items[index],
    );
  }

  // --- HISTORY MODE CONTENT PANEL ---
  Widget _buildHistoryModeContent(ScrollController? scrollController, {bool isMobile = false}) {
    if (_isLoadingHistory) {
      return const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator(color: Color(0xFF6A1B9A))));
    }

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
      children: [
        // Simplified History Filters (ONLY TWO FILTERS: Date & Driver)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF3E5F5),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE1BEE7)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("History Filters", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF6A1B9A))),
                  if (_historyDriverId != "all" || (_historyStartDate != null && !DateUtils.isSameDay(_historyStartDate, DateTime.now())))
                    GestureDetector(
                      onTap: _clearHistoryFilters,
                      child: const Text("Reset Filters", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.redAccent)),
                    ),
                ],
              ),
              const SizedBox(height: 10),

              // TWO FILTERS ROW: Date (Single-day) & Driver Selector
              Row(
                children: [
                  Expanded(child: _buildDateSelectorButton(context)),
                  const SizedBox(width: 8),
                  Expanded(child: _buildDriverDropdown()),
                ],
              ),

              const SizedBox(height: 12),

              // DIRECTED LINK TO FULL DRIVER ROUTE HISTORY PAGE
              _buildViewFullRouteHistoryButton(context),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Selected Trip Details & Replay Controls (if selected)
        if (_analyzedHistoryTrip != null) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF6A1B9A), width: 2),
              boxShadow: AppTheme.balancedPulidongShadow,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_analyzedHistoryTrip!.driverName, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1A1A1A))),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(6)),
                      child: Text(_analyzedHistoryTrip!.routeStatus, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.green)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text("Truck: ${_analyzedHistoryTrip!.truckId} | ${_analyzedHistoryTrip!.totalDistanceKm.toStringAsFixed(1)} km", style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w600)),
                const Divider(height: 20),

                // Replay Slider
                if (_analyzedHistoryTrip!.points.isNotEmpty) ...[
                  Row(
                    children: [
                      IconButton(
                        onPressed: _toggleHistoryReplay,
                        icon: Icon(_isReplayingHistory ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded, color: const Color(0xFF6A1B9A), size: 28),
                      ),
                      Expanded(
                        child: Slider(
                          value: _replayProgress,
                          activeColor: const Color(0xFF6A1B9A),
                          onChanged: (val) {
                            setState(() => _replayProgress = val);
                            _updateReplayMapPosition();
                          },
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text("No saved route history points recorded for this trip.", style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        const Text("Matching Saved Trips", style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
        const SizedBox(height: 8),

        if (_historyTrips.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text("No saved trips match the selected filters.", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold))),
          )
        else
          ..._historyTrips.map((trip) {
            final bool isSelected = _selectedHistoryTrip?.tripId == trip.tripId;
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              elevation: isSelected ? 3 : 1,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: isSelected ? const Color(0xFF6A1B9A) : Colors.grey.shade200, width: isSelected ? 2 : 1),
              ),
              child: InkWell(
                onTap: () => _selectHistoryTrip(trip),
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: isSelected ? const Color(0xFFF3E5F5) : const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(12)),
                        child: Icon(Icons.route_rounded, color: isSelected ? const Color(0xFF6A1B9A) : Colors.grey, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(trip.driverName, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
                            Text("Truck: ${trip.truckId} | Area: ${trip.routeName}", style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w600)),
                            Text(DateFormat('MMM d, yyyy | h:mm a').format(trip.startTime), style: const TextStyle(fontSize: 10, color: Color(0xFF6A1B9A), fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                      if (isSelected)
                        const Icon(Icons.check_circle_rounded, color: Color(0xFF6A1B9A), size: 20),
                    ],
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }

  Future<void> _selectSingleHistoryDate(BuildContext context) async {
    final DateTime initialDate = _historyStartDate ?? DateTime.now();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2023, 1, 1),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF6A1B9A),
              onPrimary: Colors.white,
              onSurface: Color(0xFF1A1A1A),
            ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      setState(() {
        _historyStartDate = DateTime(picked.year, picked.month, picked.day, 0, 0, 0);
        _historyEndDate = DateTime(picked.year, picked.month, picked.day, 23, 59, 59);
      });
      _loadHistoryModeData();
    }
  }

  Widget _buildDateSelectorButton(BuildContext context) {
    final String formattedDate = DateFormat('MMM d, yyyy').format(_historyStartDate ?? DateTime.now());
    return InkWell(
      onTap: () => _selectSingleHistoryDate(context),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFCE93D8)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Row(
                children: [
                  const Icon(Icons.calendar_today_rounded, size: 12, color: Color(0xFF6A1B9A)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      formattedDate,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF1A1A1A)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_drop_down_rounded, color: Color(0xFF6A1B9A), size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildDriverDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFCE93D8)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _historyDriverId,
          isExpanded: true,
          items: _historyDriverOptions.map((d) {
            return DropdownMenuItem<String>(
              value: d['id'],
              child: Text(
                d['name']!,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF1A1A1A)),
                overflow: TextOverflow.ellipsis,
              ),
            );
          }).toList(),
          onChanged: (val) {
            if (val != null) {
              setState(() => _historyDriverId = val);
              _loadHistoryModeData();
            }
          },
        ),
      ),
    );
  }

  Widget _buildViewFullRouteHistoryButton(BuildContext context) {
    return InkWell(
      onTap: () {
        Navigator.pushNamed(context, '/route_history');
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF6A1B9A).withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF6A1B9A).withOpacity(0.3)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.open_in_new_rounded, size: 13, color: Color(0xFF6A1B9A)),
            SizedBox(width: 6),
            Text(
              "View Full Route History",
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, color: Color(0xFF6A1B9A)),
            ),
          ],
        ),
      ),
    );
  }

  void _recenterToBalintawak() {
    mapboxMap?.setCamera(CameraOptions(
      center: Point(coordinates: _balintawakCenter),
      zoom: _getResponsiveZoom(context),
    ));
  }

  Widget _buildMapControls({double bottom = 240}) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isDesktop = screenWidth >= 900;
    final double btnSize = isDesktop ? 56.0 : (screenWidth * 0.15).clamp(48.0, 60.0);
    final double iconSize = isDesktop ? 24.0 : (screenWidth * 0.065).clamp(22.0, 26.0);

    final double effectiveBottom = bottom;
    final double? effectiveLeft = isDesktop ? 24 : null;
    final double? effectiveRight = isDesktop ? null : 16;

    return Positioned(
      bottom: effectiveBottom,
      left: effectiveLeft,
      right: effectiveRight,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // TARGET / GPS LOCATION BUTTON
          _buildMapControlButton(
            icon: Icons.gps_fixed_rounded,
            isActive: _isTargetActive,
            size: btnSize,
            iconSize: iconSize,
            onTap: () {
              setState(() => _isTargetActive = true);
              final activeTrucks = _trucks.where((t) => t['isOnline'] == true && (t['latitude'] ?? 0) != 0).toList();
              if (activeTrucks.isNotEmpty) {
                _focusOnTruck(activeTrucks.first, zoom: 16.5);
              } else {
                _recenterToBalintawak();
              }
              Future.delayed(const Duration(seconds: 2), () {
                if (mounted) setState(() => _isTargetActive = false);
              });
            },
          ),
          const SizedBox(height: 12),
          // RECENTER TO BALINTAWAK (MAP ICON)
          _buildMapControlButton(
            icon: Icons.map_outlined,
            isActive: _isMapActive,
            size: btnSize,
            iconSize: iconSize,
            onTap: () {
              setState(() => _isMapActive = true);
              _recenterToBalintawak();
              Future.delayed(const Duration(seconds: 2), () {
                if (mounted) setState(() => _isMapActive = false);
              });
            },
          ),
          const SizedBox(height: 12),
          // GUIDE ICON
          _buildMapControlButton(
            icon: Icons.description_outlined,
            isActive: false,
            size: btnSize,
            iconSize: iconSize,
            onTap: _showTrackingGuide,
          ),
          const SizedBox(height: 12),
          // REFRESH BUTTON
          RotationTransition(
            turns: _refreshRotationController,
            child: _buildMapControlButton(
              icon: Icons.refresh_rounded,
              isActive: _isRefreshing,
              size: btnSize,
              iconSize: iconSize,
              onTap: _handleManualRefresh,
            ),
          ),
          const SizedBox(height: 12),
          // ZOOM IN
          _buildMapControlButton(
            icon: Icons.add_rounded,
            isActive: false,
            size: btnSize,
            iconSize: iconSize,
            onTap: () async {
              try {
                final state = await mapboxMap?.getCameraState();
                if (state != null) {
                  mapboxMap?.easeTo(
                    CameraOptions(zoom: state.zoom + 1),
                    MapAnimationOptions(duration: 300),
                  );
                }
              } catch (_) {}
            },
          ),
          const SizedBox(height: 8),
          // ZOOM OUT
          _buildMapControlButton(
            icon: Icons.remove_rounded,
            isActive: false,
            size: btnSize,
            iconSize: iconSize,
            onTap: () async {
              try {
                final state = await mapboxMap?.getCameraState();
                if (state != null) {
                  mapboxMap?.easeTo(
                    CameraOptions(zoom: state.zoom - 1),
                    MapAnimationOptions(duration: 300),
                  );
                }
              } catch (_) {}
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMapControlButton({
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
    double size = 44,
    double iconSize = 20,
  }) {
    bool isHovered = false;
    return StatefulBuilder(builder: (context, setInnerState) {
      return MouseRegion(
        onEnter: (_) => setInnerState(() => isHovered = true),
        onExit: (_) => setInnerState(() => isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: isActive ? const Color(0xFF00796B) : (isHovered ? const Color(0xFFE0F2F1) : Colors.white),
              shape: BoxShape.circle,
              boxShadow: AppTheme.pulidongShadow,
              border: Border.all(color: isActive ? const Color(0xFF00796B) : (isHovered ? const Color(0xFF00796B).withValues(alpha: 0.3) : Colors.transparent), width: 1.5),
            ),
            child: Icon(icon, color: isActive ? Colors.white : (isHovered ? const Color(0xFF00796B) : const Color(0xFF1A1A1A)), size: iconSize),
          ),
        ),
      );
    });
  }

  void _showTrackingGuide() {
    final bool isDesktop = MediaQuery.of(context).size.width >= 900;
    bool isLoading = true;
    bool isExpanded = false;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          if (isLoading) {
            Future.delayed(const Duration(milliseconds: 500), () {
              if (context.mounted) {
                setState(() {
                  isLoading = false;
                  Future.delayed(const Duration(milliseconds: 50), () => setState(() => isExpanded = true));
                });
              }
            });
          }

          Widget header = Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  "GIS Tracking Guide",
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Color(0xFF00796B)),
                ),
              ),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded))
            ],
          );

          Widget content = SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isDesktop)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _buildGuideSection(
                          "Telemetry Status",
                          [
                            _buildGuideItem(Icons.circle, "Active: Collection", color: Colors.green),
                            _buildGuideItem(Icons.circle, "Idle / Collection Stop (3-5 min)", color: Colors.orange),
                            _buildGuideItem(Icons.circle, "Full: High Load", color: Colors.blue),
                          ],
                          hasShadow: false,
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        child: _buildGuideSection(
                          "Map Controls",
                          [
                            _buildGuideItem(Icons.gps_fixed_rounded, "Lock/Follow", color: Colors.blue),
                            _buildGuideItem(Icons.map_outlined, "Recenter Map", color: Colors.blue),
                          ],
                          hasShadow: false,
                        ),
                      ),
                    ],
                  )
                else
                  Column(
                    children: [
                      _buildGuideSection(
                        "Telemetry Status",
                        [
                          _buildGuideItem(Icons.circle, "Active: Collection", color: Colors.green),
                          _buildGuideItem(Icons.circle, "Idle / Collection Stop (3-5 min)", color: Colors.orange),
                          _buildGuideItem(Icons.circle, "Full: High Load", color: Colors.blue),
                        ],
                        hasShadow: false,
                      ),
                      const SizedBox(height: 16),
                      _buildGuideSection(
                        "Map Controls",
                        [
                          _buildGuideItem(Icons.gps_fixed_rounded, "Lock/Follow", color: Colors.blue),
                          _buildGuideItem(Icons.map_outlined, "Recenter Map", color: Colors.blue),
                        ],
                        hasShadow: false,
                      ),
                    ],
                  ),
                const SizedBox(height: 20),
                _buildGuideSection(
                  "Advanced Features",
                  [
                    _buildGuideText("• Smart Paths: View AI-optimized collection routes."),
                    _buildGuideText("• Live Pulse: Indicators show unit connection health."),
                    _buildGuideText("• Fleet Intel: Access driver data in the side panel."),
                  ],
                  hasShadow: false,
                ),
              ],
            ),
          );

          return Dialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeInOutCubic,
              width: isDesktop ? 550 : MediaQuery.of(context).size.width * 0.9,
              constraints: BoxConstraints(
                maxHeight: isLoading ? 350 : MediaQuery.of(context).size.height * 0.85,
              ),
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  header,
                  const SizedBox(height: 12),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "Comprehensive guide to real-time fleet telemetry and map interactions.",
                      style: TextStyle(color: Colors.grey, fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                  ),
                  const Divider(height: 48),
                  if (isLoading)
                    const Expanded(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: Color(0xFF00796B)),
                            SizedBox(height: 16),
                            Text("Preparing GIS guide...",
                                style: TextStyle(color: Colors.grey, fontSize: 14, fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 300),
                        opacity: isExpanded ? 1.0 : 0.0,
                        child: content,
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildGuideSection(String title, List<Widget> items, {bool hasShadow = true}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: hasShadow ? AppTheme.pulidongShadow : null,
        border: Border.all(color: Colors.grey.shade300, width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontWeight: FontWeight.w900, fontSize: 15, color: Color(0xFF1A1A1A))),
          const SizedBox(height: 16),
          ...items,
        ],
      ),
    );
  }

  Widget _buildGuideItem(IconData icon, String text, {required Color color}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, color: Colors.grey, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGuideText(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: const TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w600)),
    );
  }

  void _focusOnTruck(Map<dynamic, dynamic> truck, {double zoom = 17.5}) {
    double lat = (truck['latitude'] ?? truck['lat'] ?? 0.0).toDouble();
    double lng = (truck['longitude'] ?? truck['lng'] ?? 0.0).toDouble();
    if (lat == 0 || lng == 0) {
      _recenterToBalintawak();
      return;
    }

    // Sanitize foreign IP geolocation (e.g., San Jose, CA) back to Barangay Balintawak,
    // but keep any valid Philippines GPS coordinates so the map goes to where the driver actually is.
    if (lat < 4.0 || lat > 21.0 || lng < 116.0 || lng > 127.0) {
      lat = _balintawakCenter.lat.toDouble();
      lng = _balintawakCenter.lng.toDouble();
    }
    mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: Position(lng, lat)), zoom: zoom));
  }

  void _toggleFollowTruck(String truckId, Map<dynamic, dynamic> truck) {
    setState(() {
      final String canonicalId = truckId.toUpperCase();
      if (_followedTruckId?.toUpperCase() == canonicalId && _isFollowLocked) {
        _followedTruckId = null;
        _isFollowLocked = false;
        CustomNotification.showTopNotification(context, "Stopped tracking unit $truckId", false);
      } else {
        _followedTruckId = canonicalId;
        _isFollowLocked = true;
        _focusOnTruck(truck, zoom: 17.5);
        CustomNotification.showTopNotification(context, "Now tracking live location of unit $truckId", false);
      }
    });
  }

  Color _getFleetStatusColor(String status) {
    switch (status.toUpperCase()) {
      case 'IDLE':
        return const Color(0xFFED6C02);
      case 'ACTIVE':
      case 'COLLECTING':
      case 'MOVING':
      case 'EN_ROUTE':
      case 'IN_PROGRESS':
        return const Color(0xFF00796B);
      case 'FULL':
      case 'TRUCK_FULL':
      case 'CAPACITY_FULL':
        return const Color(0xFF0288D1);
      case 'PAUSED':
      case 'INTERRUPTED':
      case 'ON_HOLD':
      case 'STOPPED':
        return const Color(0xFFD84315);
      case 'COMPLETED':
      case 'FINISHED':
        return const Color(0xFF2E7D32);
      case 'MAINTENANCE':
      case 'ISSUE':
      case 'BREAKDOWN':
        return const Color(0xFFC62828);
      case 'DELAYED':
        return const Color(0xFFF57F17);
      case 'OFFLINE':
      default:
        return const Color(0xFF616161);
    }
  }

  Color _getFleetStatusBgColor(String status) {
    switch (status.toUpperCase()) {
      case 'IDLE':
        return const Color(0xFFFFF3E0);
      case 'ACTIVE':
      case 'COLLECTING':
      case 'MOVING':
      case 'EN_ROUTE':
      case 'IN_PROGRESS':
        return const Color(0xFFE0F2F1);
      case 'FULL':
      case 'TRUCK_FULL':
      case 'CAPACITY_FULL':
        return const Color(0xFFE1F5FE);
      case 'PAUSED':
      case 'INTERRUPTED':
      case 'ON_HOLD':
      case 'STOPPED':
        return const Color(0xFFFBE9E7);
      case 'COMPLETED':
      case 'FINISHED':
        return const Color(0xFFE8F5E9);
      case 'MAINTENANCE':
      case 'ISSUE':
      case 'BREAKDOWN':
        return const Color(0xFFFFEBEE);
      case 'DELAYED':
        return const Color(0xFFFFF8E1);
      case 'OFFLINE':
      default:
        return const Color(0xFFF5F5F5);
    }
  }

  Widget _buildOrganizedTruckCard(Map<dynamic, dynamic> truck) {
    final String tid = (truck['truckNumber'] ?? truck['truck_id'] ?? truck['truckId'] ?? 'GT-007').toString();
    final String license = (truck['plate_number'] ?? truck['plateNumber'] ?? truck['license_number'] ?? _truckPlates[tid.toUpperCase()] ?? '').toString();
    final String driver = (truck['driver_name'] ?? truck['driverName'] ?? 'Driver').toString();
    final String status = (truck['status'] ?? 'IDLE').toString().toUpperCase();
    final bool isActive = status == 'ACTIVE' || status == 'COLLECTING';
    final Color statusColor = _getFleetStatusColor(status);
    final Color statusBgColor = _getFleetStatusBgColor(status);

    final double speed = double.tryParse(truck['speed']?.toString() ?? '0') ?? 0.0;
    final double dist = double.tryParse(truck['total_distance']?.toString() ?? truck['total_distance_km']?.toString() ?? '0') ?? 0.0;
    final double fuel = double.tryParse((truck['fuel'] ?? truck['fuel_level'] ?? 0.0).toString()) ?? 0.0;
    final int stops = int.tryParse((truck['detected_stops_count'] ?? truck['stops_count'] ?? truck['total_stops'] ?? 0).toString()) ?? 0;
    final String area = (truck['current_purok'] ?? truck['location'] ?? truck['area'] ?? truck['purok'] ?? "Balintawak").toString();

    final double etaMins = PredictionEngine.estimateArrivalTime(dist > 0 ? dist : 2.5, [speed > 5 ? speed : 15.0]);
    final String eta = isActive ? "${etaMins.toStringAsFixed(0)} mins" : "--";
    String lastUpdate = truck['updatedAt'] != null || truck['lastSeen'] != null ? "just now" : "Offline";

    final bool isBeingFollowed = _isFollowLocked && _followedTruckId?.toUpperCase() == tid.toUpperCase();

    return _TrackHoverZoomCard(
      onTap: () => _focusOnTruck(truck),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(32),
            boxShadow: [
              BoxShadow(
                color: isBeingFollowed ? const Color(0xFF00796B).withOpacity(0.25) : Colors.black.withOpacity(0.12),
                blurRadius: isBeingFollowed ? 25 : 20,
                offset: const Offset(0, 0),
                spreadRadius: isBeingFollowed ? 3 : 2,
              ),
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 10,
                offset: const Offset(0, 4),
                spreadRadius: 0,
              ),
            ],
            border: Border.all(
              color: isBeingFollowed ? const Color(0xFF00796B) : Colors.grey.shade100,
              width: isBeingFollowed ? 2.5 : 1
            )),
        child: Column(children: [
          // Top Row: Icon, Name/License, Status & TRACKING badge
          Row(children: [
            Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: isBeingFollowed ? const Color(0xFFE0F2F1) : const Color(0xFFE3F2FD),
                    borderRadius: BorderRadius.circular(16)),
                child: Icon(
                  Icons.local_shipping_rounded,
                  color: isBeingFollowed ? const Color(0xFF00796B) : const Color(0xFF2196F3),
                  size: 28
                )),
            const SizedBox(width: 16),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(driver,
                  style: const TextStyle(
                      fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF1A1A1A))),
              Text("$tid | $license",
                  style: const TextStyle(
                      color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w600))
            ])),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                        color: statusBgColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: statusColor.withOpacity(0.3))),
                    child: Text(status,
                        style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.w900))),
                if (isBeingFollowed) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00796B),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.gps_fixed_rounded, color: Colors.white, size: 10),
                        SizedBox(width: 4),
                        Text("TRACKING", style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.w900)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ]),

          const SizedBox(height: 24),

          // Middle Info: Location, Speed, Driver
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            _buildMetricsInfo(Icons.location_on_rounded, Colors.redAccent, "Location", area),
            _buildMetricsInfo(Icons.speed_rounded, Colors.blueAccent, "Speed", "${speed.toStringAsFixed(0)} km/h"),
            _buildMetricsInfo(Icons.person_rounded, Colors.indigoAccent, "Driver", driver),
          ]),

          const SizedBox(height: 20),

          // Metrics Pill Row
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
                color: const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                    spreadRadius: 0,
                  ),
                ],
                border: Border.all(color: Colors.grey.shade100)),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _buildPillMetric(Icons.straighten_rounded, Colors.green, "DISTANCE", "${dist.toStringAsFixed(1)} km"),
              Container(width: 1, height: 20, color: Colors.grey.shade300),
              _buildPillMetric(Icons.local_gas_station_rounded, Colors.orange, "FUEL", "${fuel.toStringAsFixed(1)} L"),
              Container(width: 1, height: 20, color: Colors.grey.shade300),
              _buildPillMetric(Icons.pause_circle_filled_rounded, Colors.red, "STOPS", "$stops"),
            ]),
          ),

          const SizedBox(height: 20),

          // Action Buttons
          Row(children: [
            Expanded(
              child: _buildSecondaryButton(
                  "HISTORY", Icons.history_rounded, () => _showHistoryOverlay(context, tid)),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: _buildPrimaryButton(
                  _visiblePaths.contains(tid) ? "HIDE PATH" : "COMPARE PATH",
                  Icons.near_me_rounded,
                  _visiblePaths.contains(tid) ? Colors.orange : const Color(0xFF00796B),
                  () => _togglePathComparison(tid)),
            ),
            const SizedBox(width: 12),
            _buildTargetButton(
              isBeingFollowed: isBeingFollowed,
              onTap: () => _toggleFollowTruck(tid, truck),
            ),
          ]),

          const SizedBox(height: 20),

          // Footer
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            _buildFooterInfo(Icons.access_time_rounded, "Last Update: $lastUpdate"),
            _buildFooterInfo(null, "Start: --:--"),
            _buildFooterInfo(null, "ETA: $eta", isTeal: true),
          ]),
        ])),
    );
  }

  Widget _buildMetricsInfo(IconData icon, Color color, String label, String value) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w700)),
      ]),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: Color(0xFF1A1A1A))),
    ]);
  }

  Widget _buildPillMetric(IconData icon, Color color, String label, String value) {
    return Column(children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 10, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 8, color: Colors.grey, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
      ]),
      const SizedBox(height: 2),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF2196F3))),
    ]);
  }

  Widget _buildFooterInfo(IconData? icon, String text, {bool isTeal = false}) {
    return Row(children: [
      if (icon != null) ...[Icon(icon, size: 12, color: Colors.grey), const SizedBox(width: 4)],
      Text(text, style: TextStyle(
        fontSize: 10,
        color: isTeal ? const Color(0xFF00796B) : Colors.grey,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.2
      )),
    ]);
  }

  Widget _buildSecondaryButton(String label, IconData icon, VoidCallback onTap) {
    return _TrackHoverZoomLink(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F2F5),
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.center,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: const Color(0xFF1A1A1A), size: 16),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Color(0xFF1A1A1A), fontWeight: FontWeight.w900, fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _buildPrimaryButton(String label, IconData icon, Color color, VoidCallback onTap) {
    bool isOrange = label.contains("HIDE");
    return _TrackHoverZoomLink(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: isOrange
              ? [const Color(0xFFFF9800), const Color(0xFFE65100)]
              : [AppColors.loginButtonStart, AppColors.loginButtonEnd],
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: (isOrange ? const Color(0xFFE65100) : AppColors.loginButtonEnd).withAlpha(60),
              blurRadius: 10,
              offset: const Offset(0, 4)
            )
          ],
        ),
        alignment: Alignment.center,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _buildTargetButton({required bool isBeingFollowed, required VoidCallback onTap}) {
    final Color btnColor = isBeingFollowed ? const Color(0xFF004D40) : const Color(0xFF00796B);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: btnColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: btnColor.withAlpha(60),
              blurRadius: 10,
              offset: const Offset(0, 4),
            )
          ],
          border: isBeingFollowed
              ? Border.all(color: Colors.tealAccent, width: 2)
              : null,
        ),
        alignment: Alignment.center,
        child: Icon(
          isBeingFollowed ? Icons.gps_fixed_rounded : Icons.my_location_rounded,
          color: Colors.white,
          size: 20,
        ),
      ),
    );
  }

  void _showHistoryOverlay(BuildContext context, String truckId) {
    final List<Map<dynamic, dynamic>> history = _lastRoutePoints[truckId] ?? [];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("Activity History - $truckId", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF00796B))),
                IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
              ],
            ),
            const Divider(height: 20),
            if (history.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: Text("No live route history points recorded yet.", style: TextStyle(color: Colors.grey))))
            else
              ListView.builder(
                shrinkWrap: true,
                itemCount: history.length > 10 ? 10 : history.length,
                itemBuilder: (context, index) {
                  final point = history.reversed.toList()[index];
                  final double pLat = (point['lat'] ?? point['latitude'] ?? 0.0).toDouble();
                  final double pLng = (point['lng'] ?? point['longitude'] ?? 0.0).toDouble();
                  return ListTile(
                    leading: const Icon(Icons.location_on_rounded, color: Color(0xFF00796B), size: 18),
                    title: Text("${pLat.toStringAsFixed(5)}, ${pLng.toStringAsFixed(5)}", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    subtitle: Text("Timestamp: ${point['timestamp'] ?? 'N/A'}", style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _TrackHoverZoomCard extends StatefulWidget {
  final Widget child; final VoidCallback? onTap; final double scale;
  const _TrackHoverZoomCard({required this.child, this.onTap, this.scale = 1.02});
  @override
  State<_TrackHoverZoomCard> createState() => _TrackHoverZoomCardState();
}
class _TrackHoverZoomCardState extends State<_TrackHoverZoomCard> {
  bool _active = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(onEnter: (_) => setState(() => _active = true), onExit: (_) => setState(() => _active = false), cursor: SystemMouseCursors.click, child: GestureDetector(onTap: widget.onTap, onTapDown: (_) => setState(() => _active = true), onTapUp: (_) => setState(() => _active = false), child: AnimatedScale(scale: _active ? widget.scale : 1.0, duration: const Duration(milliseconds: 200), child: widget.child)));
  }
}

class _TrackHoverZoomLink extends StatefulWidget {
  final Widget child; final VoidCallback onTap;
  const _TrackHoverZoomLink({required this.child, required this.onTap});
  @override
  State<_TrackHoverZoomLink> createState() => _TrackHoverZoomLinkState();
}
class _TrackHoverZoomLinkState extends State<_TrackHoverZoomLink> {
  bool _active = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(onEnter: (_) => setState(() => _active = true), onExit: (_) => setState(() => _active = false), cursor: SystemMouseCursors.click, child: GestureDetector(onTap: widget.onTap, onTapDown: (_) => setState(() => _active = true), onTapUp: (_) => setState(() => _active = false), onTapCancel: () => setState(() => _active = false), child: AnimatedScale(scale: _active ? 1.05 : 1.0, duration: const Duration(milliseconds: 200), child: widget.child)));
  }
}

class _StickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double minHeight;
  final double maxHeight;
  final Widget child;

  _StickyHeaderDelegate({
    required this.minHeight,
    required this.maxHeight,
    required this.child,
  });

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return SizedBox.expand(child: child);
  }

  @override
  double get maxExtent => maxHeight;

  @override
  double get minExtent => minHeight;

  @override
  bool shouldRebuild(_StickyHeaderDelegate oldDelegate) {
    return maxHeight != oldDelegate.maxHeight ||
        minHeight != oldDelegate.minHeight ||
        child != oldDelegate.child;
  }
}
