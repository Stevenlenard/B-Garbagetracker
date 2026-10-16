import '../utils/truck_identity.dart';
import '../utils/route_history_navigation.dart';
import 'analytics_screen.dart' show showLoadHistoryDialog;
import '../utils/load_history.dart';
import '../utils/trip_links.dart';
import '../utils/route_geometry.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size, Visibility;
import '../utils/session_manager.dart';
import '../models/user.dart';
import '../models/driver_trip.dart';
import '../services/driver_route_history_service.dart';
import '../services/service_area_service.dart';
import '../utils/responsive.dart';
import '../utils/route_export_manager.dart';
import '../widgets/custom_snackbar.dart';
import '../api/api_service.dart';
import '../widgets/map_style_toggle.dart';
import '../widgets/mapbox_gate.dart';
import '../utils/map_colors.dart';
import '../widgets/app_date_range_picker.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import '../utils/collection_visits.dart';
import '../utils/route_areas.dart';
import 'collection_route_optimization_screen.dart' show FirebaseCollectionDataSource;

class RouteHistoryScreen extends StatefulWidget {
  final bool isEmbedded;
  final VoidCallback? onBack;
  final String? initialTripId;
  final DriverTrip? initialTrip;

  const RouteHistoryScreen({
    super.key,
    this.isEmbedded = false,
    this.onBack,
    this.initialTripId,
    this.initialTrip,
  });

  @override
  State<RouteHistoryScreen> createState() => _RouteHistoryScreenState();
}

class _RouteHistoryScreenState extends State<RouteHistoryScreen> with TickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  UserData? _currentUser;
  bool _isLoadingUser = true;
  bool _isLoadingTrips = false;
  String? _loadError; // set when the history could not be loaded (never shown as "empty")
  bool _loadPartial = false;

  /// Residents get read-only access: no export, delete, driver identity or load analytics.
  bool get _isResident => (_currentUser?.role ?? '').toLowerCase() == 'resident';
  /// Drivers always see only their own trips (enforced in the service), so no driver filter.
  bool get _isDriver => (_currentUser?.role ?? '').toLowerCase() == 'driver';

  List<DriverTrip> _trips = [];
  DriverTrip? _selectedTrip;
  DriverTrip? _analyzedTrip;

  // Filter state
  DateTime? _startDate;
  DateTime? _endDate;
  String _selectedDriverId = "all";
  String _selectedTruckId = "all";
  String _selectedArea = "all";
  String _selectedStatus = "all";

  // Dropdown options
  List<Map<String, String>> _driverOptions = [
    {"id": "all", "name": "All Drivers"}
  ];
  List<Map<String, String>> _truckOptions = [
    {"id": "all", "name": "All Trucks"}
  ];
  List<String> _areaOptions = [
    "all",
    "Ayala Highway",
    "Brixton Homes",
    "Central (Purok 1)",
    "Purok 2",
    "Purok 3",
    "Purok 4 / El Pueblo",
    "Purok Paraiso",
    "Riverside",
    "San Nicolas",
    "T.M. Kalaw Street",
  ];
  final List<String> _statusOptions = [
    "all", "COMPLETED", "IN_PROGRESS", "INTERRUPTED"
  ];

  // Mapbox controller state
  MapboxMap? _mapboxMap;
  bool _isMapReady = false;
  bool _isUpdatingPolyline = false;
  DriverTrip? _pendingMapTrip; // latest trip requested while a redraw was running
  String? _routeNotice; // honest status when a requested trip has no record
  String _selectedMapStyle = 'map'; // 'map' or 'satellite'
  bool _isMapExpanded = false; // Expand Map Mode toggle
  bool? _showTimeline; // desktop timeline panel: null = automatic (shown on wide screens)

  // Purok boundaries (for "passed through" areas) and the resident's area view.
  List<AreaGeofence> _geofences = const <AreaGeofence>[];
  final Map<String, Set<String>> _tripAreaCache = <String, Set<String>>{};
  String? _residentHomeArea; // the resident's own purok, when it matches a boundary
  String _residentAreaView = 'all'; // area name or 'all'
  bool _residentAreaChosen = false; // the resident picked an area themselves

  // Replay Control state
  bool _isReplaying = false;
  double _replayProgress = 0.0; // 0.0 to 1.0
  double _replaySpeedMultiplier = 0.5; // 0.25x, 0.5x, 1x, 2x, 5x
  Timer? _replayTimer;

  bool _argsProcessed = false;
  String? _effectiveInitialTripId;
  DriverTrip? _effectiveInitialTrip;

  int get _activeFilterCount {
    int count = 0;
    if (_selectedDriverId != "all") count++;
    return count;
  }

  @override
  void initState() {
    super.initState();
    _effectiveInitialTripId = widget.initialTripId;
    _effectiveInitialTrip = widget.initialTrip;

    if (_effectiveInitialTrip != null || _effectiveInitialTripId != null) {
      final DateTime targetDate = (_effectiveInitialTrip?.fullTime ?? _effectiveInitialTrip?.startTime) ?? DateTime.now();
      _startDate = DateTime(targetDate.year, targetDate.month, targetDate.day, 0, 0, 0);
      _endDate = DateTime(targetDate.year, targetDate.month, targetDate.day, 23, 59, 59);
      _selectedDriverId = "all";
      _selectedTruckId = "all";
      _selectedArea = "all";
      _selectedStatus = "all";
    } else {
      _startDate = DateTime.now().subtract(const Duration(days: 7));
      _endDate = DateTime.now();
    }
    _loadUserAndData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_argsProcessed) {
      _argsProcessed = true;
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map) {
        _effectiveInitialTripId ??= args['initialTripId']?.toString();
        _effectiveInitialTrip ??= args['initialTrip'] as DriverTrip?;
      } else if (args is DriverTrip) {
        _effectiveInitialTrip ??= args;
        _effectiveInitialTripId ??= args.tripId;
      }

      if (_effectiveInitialTrip != null || _effectiveInitialTripId != null) {
        final DateTime targetDate = (_effectiveInitialTrip?.fullTime ?? _effectiveInitialTrip?.startTime) ?? DateTime.now();
        _startDate = DateTime(targetDate.year, targetDate.month, targetDate.day, 0, 0, 0);
        _endDate = DateTime(targetDate.year, targetDate.month, targetDate.day, 23, 59, 59);
        _selectedDriverId = "all";
        _selectedTruckId = "all";
        _selectedArea = "all";
        _selectedStatus = "all";
        if (!_isLoadingUser && _currentUser != null) {
          _fetchTrips();
        }
      }
    }
  }

  @override
  void dispose() {
    _replayTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadUserAndData() async {
    setState(() => _isLoadingUser = true);
    final user = await SessionManager.getUser();
    if (mounted) {
      setState(() {
        _currentUser = user;
        _isLoadingUser = false;
      });
      if (_currentUser != null) {
        _loadFilterOptions();
        _fetchTrips();
      }
    }
  }

  Future<void> _loadFilterOptions() async {
    try {
      final ServiceAreaService serviceAreaService = ServiceAreaService();
      final List<ServiceArea> areas = await serviceAreaService.getAllServiceAreas();
      final List<String> dynamicAreaNames = ["all"];
      for (var a in areas) {
        if (a.name.isNotEmpty && !dynamicAreaNames.contains(a.name)) {
          dynamicAreaNames.add(a.name);
        }
      }

      final List<AreaGeofence> fences = areas.map(FirebaseCollectionDataSource.toGeofence).toList();
      if (mounted) {
        setState(() {
          _geofences = fences;
          _tripAreaCache.clear();
          if (_isResident) {
            final String raw = (_currentUser?.purok ?? '').trim();
            final String? home = raw.isEmpty ? null : (ServiceAreaService.canonicalizeAreaName(raw) ?? raw);
            _residentHomeArea = fences.any((AreaGeofence g) => g.name == home) ? home : null;
            if (_residentHomeArea != null && !_residentAreaChosen) _residentAreaView = _residentHomeArea!;
            _ensureSelectionVisible();
          }
        });
      }

      // Residents never request the account list; their truck filter is built from the
      // trips they are allowed to see (see _fetchTrips).
      if (_isResident) {
        if (mounted) setState(() => _areaOptions = dynamicAreaNames);
        return;
      }

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
            if (role == 'driver') {
              drivers.add({
                "id": u['user_id'].toString(),
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
            _driverOptions = drivers;
            _truckOptions = trucks;
            _areaOptions = dynamicAreaNames;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _areaOptions = dynamicAreaNames;
          });
        }
      }
    } catch (e) {
      debugPrint("[ROUTE HISTORY] Error loading filter options: $e");
    }
  }

  Future<void> _fetchTrips() async {
    if (_currentUser == null) return;
    setState(() => _isLoadingTrips = true);

    final RouteHistoryResult result = await DriverRouteHistoryService.fetchRouteHistoryResult(
      currentUser: _currentUser!,
      startDate: _startDate,
      endDate: _endDate,
      selectedDriverId: _selectedDriverId,
      selectedTruckId: _selectedTruckId,
      selectedArea: _selectedArea,
      selectedStatus: _selectedStatus,
    );
    if (result.isError) {
      // Every source failed: report it, never present it as "no history".
      if (mounted) {
        setState(() {
          _isLoadingTrips = false;
          _loadError = "Collection route history could not be loaded. Check the connection and try again.";
          _loadPartial = false;
        });
      }
      return;
    }
    final List<DriverTrip> trips = List<DriverTrip>.from(result.trips);

    // A trip requested by id (e.g. from Load History) is resolved from its persisted
    // record even when the date/status filters would hide it, so the exact trip opens.
    DriverTrip? requested;
    String? notice;
    final String? wantId = _effectiveInitialTripId;
    if (wantId != null && wantId.isNotEmpty) {
      final int idx = trips.indexWhere((t) => t.tripId == wantId);
      if (idx != -1 && trips[idx].points.length >= 2) {
        requested = trips[idx];
      } else {
        DriverTrip? fetched = await DriverRouteHistoryService.fetchTripById(wantId);
        if (fetched != null && _isResident) fetched = DriverRouteHistoryService.redactForResident(fetched);
        requested = fetched ?? (idx != -1 ? trips[idx] : _effectiveInitialTrip);
        if (requested == null) {
          notice = "The requested trip ($wantId) has no recorded route.";
        }
      }
    }

    if (mounted) {
      setState(() {
        _trips = trips;
        _tripAreaCache.clear();
        _isLoadingTrips = false;
        _loadError = null;
        _loadPartial = result.isPartial;
        _routeNotice = notice;
        if (_isResident) {
          // Truck filter for residents comes from the visible trips only.
          final Set<String> trucks = trips.map((t) => t.truckId).where((t) => t.isNotEmpty && t != 'Truck not recorded').toSet();
          _truckOptions = <Map<String, String>>[
            {"id": "all", "name": "All Trucks"},
            ...(trucks.toList()..sort()).map((t) => {"id": t, "name": t}),
          ];
        }

        DriverTrip? targetTrip;
        if (requested != null) {
          final int at = _trips.indexWhere((t) => t.tripId == requested!.tripId);
          if (at != -1) {
            _trips[at] = requested;
          } else {
            _trips.insert(0, requested);
          }
          targetTrip = requested;
        }

        if (targetTrip != null) {
          _selectTrip(targetTrip);
        } else if (_visibleTrips.isNotEmpty) {
          _selectTrip(_visibleTrips.first);
        } else {
          _selectedTrip = null;
          _analyzedTrip = null;
        }
      });
    }
  }

  void _clearFilters() {
    setState(() {
      _startDate = DateTime.now().subtract(const Duration(days: 7));
      _endDate = DateTime.now();
      _selectedDriverId = "all";
      _selectedTruckId = "all";
      _selectedArea = "all";
      _selectedStatus = "all";
      _residentAreaChosen = false;
      if (_residentHomeArea != null) _residentAreaView = _residentHomeArea!;
    });
    _fetchTrips();
  }

  /// Puroks a trip passed through, from its recorded GPS points and the purok boundaries.
  Set<String> _areasOfTrip(DriverTrip t) {
    if (_geofences.isEmpty || t.points.isEmpty) return const <String>{};
    return _tripAreaCache.putIfAbsent(
        t.tripId, () => RouteAreas.passedThrough(t.points.map((p) => <double>[p.latitude, p.longitude]).toList(), _geofences));
  }

  String _areasLabel(DriverTrip t) {
    final List<String> a = _areasOfTrip(t).toList()..sort();
    if (a.isEmpty) return t.formattedVisitedAreas;
    if (a.length <= 2) return a.join(' • ');
    return "${a.take(2).join(' • ')} +${a.length - 2} more";
  }

  /// Residents see trips through their own purok by default ("All areas" on request).
  List<DriverTrip> get _visibleTrips {
    if (!_isResident || _residentAreaView == 'all') return _trips;
    return _trips.where((DriverTrip t) => _areasOfTrip(t).contains(_residentAreaView)).toList();
  }

  void _setResidentAreaView(String v) {
    setState(() {
      _residentAreaView = v;
      _residentAreaChosen = true;
      _ensureSelectionVisible();
    });
  }

  void _ensureSelectionVisible() {
    final List<DriverTrip> vis = _visibleTrips;
    if (_selectedTrip != null && vis.any((DriverTrip t) => t.tripId == _selectedTrip!.tripId)) return;
    if (vis.isNotEmpty) {
      _selectTrip(vis.first);
    } else {
      _selectedTrip = null;
      _analyzedTrip = null;
    }
  }

  /// Opens a trip (from the Load History dialog) in THIS screen: filters, map and
  /// playback stay as they are; the trip is loaded by id from its persisted record.
  Future<void> _openTripInPlace({String? tripId, DriverTrip? trip}) async {
    final String? id = tripId ?? trip?.tripId;
    if (id == null || id.isEmpty) return;
    DriverTrip? target;
    final int idx = _trips.indexWhere((t) => t.tripId == id);
    if (idx != -1 && _trips[idx].points.length >= 2) target = _trips[idx];
    target ??= await DriverRouteHistoryService.fetchTripById(id);
    target ??= idx != -1 ? _trips[idx] : trip;
    if (!mounted) return;
    final DriverTrip? found = target;
    if (found == null) {
      setState(() => _routeNotice = "The requested trip ($id) has no recorded route.");
      return;
    }
    setState(() {
      _routeNotice = null;
      final int at = _trips.indexWhere((t) => t.tripId == found.tripId);
      if (at != -1) {
        _trips[at] = found;
      } else {
        _trips.insert(0, found);
      }
    });
    _selectTrip(found);
  }

  void _selectTrip(DriverTrip trip) {
    _replayTimer?.cancel();
    final analyzed = DriverRouteHistoryService.analyzeTrip(trip);
    setState(() {
      _selectedTrip = trip;
      _analyzedTrip = analyzed;
      _isReplaying = false;
      _replayProgress = 0.0;
    });
    _updateMapForTrip(analyzed);
  }

  void _setDatePreset(String preset) {
    final now = DateTime.now();
    setState(() {
      if (preset == 'today') {
        _startDate = DateTime(now.year, now.month, now.day);
        _endDate = now;
      } else if (preset == 'yesterday') {
        final y = now.subtract(const Duration(days: 1));
        _startDate = DateTime(y.year, y.month, y.day);
        _endDate = DateTime(y.year, y.month, y.day, 23, 59, 59);
      } else if (preset == 'week') {
        _startDate = now.subtract(const Duration(days: 7));
        _endDate = now;
      }
    });
    _fetchTrips();
  }

  void _toggleReplay() {
    if (_analyzedTrip == null || _analyzedTrip!.points.isEmpty) return;

    if (_isReplaying) {
      _replayTimer?.cancel();
      setState(() => _isReplaying = false);
    } else {
      setState(() => _isReplaying = true);
      const intervalMs = 100;
      _replayTimer?.cancel();
      _replayTimer = Timer.periodic(const Duration(milliseconds: intervalMs), (timer) {
        if (!mounted || _analyzedTrip == null || _analyzedTrip!.points.isEmpty) {
          timer.cancel();
          return;
        }
        setState(() {
          _replayProgress += (0.005 * _replaySpeedMultiplier);
          if (_replayProgress >= 1.0) {
            _replayProgress = 1.0;
            _isReplaying = false;
            timer.cancel();
          }
        });
        _updateReplayMapPosition();
      });
    }
  }

  void _jumpPlayback(int secondsOffset) {
    if (_analyzedTrip == null || _analyzedTrip!.points.isEmpty) return;
    final totalSec = _analyzedTrip!.endTime != null
        ? _analyzedTrip!.endTime!.difference(_analyzedTrip!.startTime).inSeconds
        : 3600;
    if (totalSec <= 0) return;

    final double step = secondsOffset / totalSec;
    setState(() {
      _replayProgress = (_replayProgress + step).clamp(0.0, 1.0);
    });
    _updateReplayMapPosition();
  }

  void _seekToTimestamp(DateTime targetTime) {
    if (_analyzedTrip == null || _analyzedTrip!.points.isEmpty) return;
    final start = _analyzedTrip!.startTime;
    final end = _analyzedTrip!.endTime ?? _analyzedTrip!.points.last.timestamp;
    final totalMs = end.difference(start).inMilliseconds;
    if (totalMs <= 0) return;

    final targetMs = targetTime.difference(start).inMilliseconds;
    final progress = (targetMs / totalMs).clamp(0.0, 1.0);
    setState(() {
      _replayProgress = progress;
    });
    _updateReplayMapPosition();
  }

  void _switchMapStyle(String newStyle) async {
    if (_selectedMapStyle == newStyle || _mapboxMap == null) return;
    setState(() => _selectedMapStyle = newStyle);

    // Same two styles as every other map (Map = the default Standard style).
    await MapStyles.apply(_mapboxMap, satellite: newStyle == 'satellite');
  }

  Future<void> _showAestheticDateRangePicker() async {
    final AppDatePick? pick = await showAppDateRangePicker(
      context,
      initialRange: DateTimeRange(
        start: _startDate ?? DateTime.now().subtract(const Duration(days: 7)),
        end: _endDate ?? DateTime.now(),
      ),
    );
    final DateTimeRange? range = pick?.range;

    if (range != null) {
      setState(() {
        _startDate = range.start;
        _endDate = range.end;
      });
      _fetchTrips();
    }
  }

  Future<void> _updateReplayMapPosition() async {
    if (_mapboxMap == null || _analyzedTrip == null || _analyzedTrip!.points.isEmpty) return;
    final points = DriverRouteHistoryService.filterStationaryGpsJitter(_analyzedTrip!.points);
    final int idx = ((points.length - 1) * _replayProgress).clamp(0, points.length - 1).toInt();
    final currentP = points[idx];

    try {
      final style = _mapboxMap!.style;
      const String replayRouteSourceId = "replay-route-source";
      const String replayRouteLayerId = "replay-route-layer";
      const String markersSourceId = "trip-markers-source";

      // Replay route line coordinates up to current index
      final List<List<double>> replayCoords = points.sublist(0, idx + 1).map((p) => [p.longitude, p.latitude]).toList();
      final replayFeature = {
        "type": "FeatureCollection",
        "features": replayCoords.length >= 2 ? [
          {
            "type": "Feature",
            "geometry": {"type": "LineString", "coordinates": replayCoords},
            "properties": {"color": "#00796B"}
          }
        ] : []
      };

      if (await style.styleSourceExists(replayRouteSourceId)) {
        await style.setStyleSourceProperty(replayRouteSourceId, "data", jsonEncode(replayFeature));
      } else {
        await style.addSource(GeoJsonSource(id: replayRouteSourceId, data: jsonEncode(replayFeature)));
        if (!(await style.styleLayerExists(replayRouteLayerId))) {
          await style.addLayer(LineLayer(
            id: replayRouteLayerId,
            sourceId: replayRouteSourceId,
            lineColor: const Color(0xFF00796B).toARGB32(),
            lineWidth: 6.0,
            lineOpacity: 0.95,
            lineCap: LineCap.ROUND,
            lineJoin: LineJoin.ROUND,
          ));
        }
      }

      // Map Markers Feature Collection (Start, End, Vehicle, Stops)
      final List<Map<String, dynamic>> markerFeatures = [];

      // Start marker
      if (points.isNotEmpty) {
        markerFeatures.add({
          "type": "Feature",
          "geometry": {"type": "Point", "coordinates": [points.first.longitude, points.first.latitude]},
          "properties": {"markerType": "START"}
        });
      }

      // End marker
      if (points.length > 1) {
        markerFeatures.add({
          "type": "Feature",
          "geometry": {"type": "Point", "coordinates": [points.last.longitude, points.last.latitude]},
          "properties": {"markerType": "END"}
        });
      }

      // Detected Stops markers
      for (var stop in _analyzedTrip!.detectedStops) {
        markerFeatures.add({
          "type": "Feature",
          "geometry": {"type": "Point", "coordinates": [stop.longitude, stop.latitude]},
          "properties": {"markerType": "STOP", "label": stop.label}
        });
      }

      // Current Vehicle marker
      markerFeatures.add({
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [currentP.longitude, currentP.latitude]},
        "properties": {"markerType": "VEHICLE"}
      });

      final markersCollection = {"type": "FeatureCollection", "features": markerFeatures};

      if (await style.styleSourceExists(markersSourceId)) {
        await style.setStyleSourceProperty(markersSourceId, "data", jsonEncode(markersCollection));
      } else {
        await style.addSource(GeoJsonSource(id: markersSourceId, data: jsonEncode(markersCollection)));

        if (!(await style.styleLayerExists("trip-markers-circle-layer"))) {
          final colorExpr = [
            "match", ["get", "markerType"],
            "START", mapColor(const Color(0xFF2E7D32)),
            "END", mapColor(const Color(0xFFD32F2F)),
            "STOP", mapColor(const Color(0xFFF57F17)),
            "VEHICLE", mapColor(const Color(0xFF00796B)),
            mapColor(Colors.blue)
          ];

          final radiusExpr = [
            "match", ["get", "markerType"],
            "VEHICLE", 12.0,
            "START", 9.0,
            "END", 9.0,
            "STOP", 8.0,
            7.0
          ];

          await style.addLayer(CircleLayer(
            id: "trip-markers-circle-layer",
            sourceId: markersSourceId,
            circleRadius: 8.0,
            circleColor: const Color(0xFF00796B).toARGB32(),
            circleStrokeWidth: 3.0,
            circleStrokeColor: Colors.white.toARGB32(),
          ));

          await style.setStyleLayerProperty("trip-markers-circle-layer", "circle-radius", radiusExpr);
          await style.setStyleLayerProperty("trip-markers-circle-layer", "circle-color", colorExpr);

          await style.addLayer(CircleLayer(
            id: "trip-markers-inner-dot",
            sourceId: markersSourceId,
            circleRadius: 4.0,
            circleColor: Colors.white.toARGB32(),
          ));
        }
      }

      if (_isReplaying) {
        _mapboxMap!.setCamera(CameraOptions(
          center: Point(coordinates: Position(currentP.longitude, currentP.latitude)),
        ));
      }
    } catch (_) {}
  }

  DateTime get _currentPlaybackTime {
    if (_analyzedTrip == null || _analyzedTrip!.points.isEmpty) {
      return DateTime.now();
    }
    final points = _analyzedTrip!.points;
    final int idx = ((points.length - 1) * _replayProgress).clamp(0, points.length - 1).toInt();
    return points[idx].timestamp;
  }

  // --- MAPBOX MAP CREATION & ROUTE DRAWING ---
  void _onMapCreated(MapboxMap map) {
    _mapboxMap = map;
    _isMapReady = true;
    _mapboxMap?.setCamera(CameraOptions(
      center: Point(coordinates: Position(121.1620, 13.9565)),
      zoom: 13.8,
    ));
    if (_analyzedTrip != null) {
      _updateMapForTrip(_analyzedTrip!);
    }
  }

  /// The style finishes loading after the map is created (always on the Web) and is replaced on
  /// every Map/Satellite switch: (re)draw the selected trip each time.
  void _onStyleLoaded(StyleLoadedEventData _) {
    if (_analyzedTrip != null) _updateMapForTrip(_analyzedTrip!);
  }

  Future<void> _updateMapForTrip(DriverTrip trip) async {
    if (_mapboxMap == null) return;
    if (_isUpdatingPolyline) {
      // Latest wins: selecting another trip during a redraw must not be dropped.
      _pendingMapTrip = trip;
      return;
    }
    _isUpdatingPolyline = true;

    try {
      final style = _mapboxMap!.style;
      const String fullRouteSourceId = "full-route-source";
      const String fullRouteLayerId = "full-route-layer";

      final points = trip.points;
      if (points.isEmpty) {
        final emptyFeature = {"type": "FeatureCollection", "features": []};
        if (await style.styleSourceExists(fullRouteSourceId)) {
          await style.setStyleSourceProperty(fullRouteSourceId, "data", jsonEncode(emptyFeature));
        }
        if (await style.styleSourceExists("replay-route-source")) {
          await style.setStyleSourceProperty("replay-route-source", "data", jsonEncode(emptyFeature));
        }
        if (await style.styleSourceExists("trip-markers-source")) {
          await style.setStyleSourceProperty("trip-markers-source", "data", jsonEncode(emptyFeature));
        }
        _mapboxMap?.setCamera(CameraOptions(
          center: Point(coordinates: Position(121.1620, 13.9565)),
          zoom: 13.8,
        ));
        return;
      }

      // Full Route Line Feature
      final cleanDisplayPoints = DriverRouteHistoryService.filterStationaryGpsJitter(points);
      final List<List<double>> fullCoords = cleanDisplayPoints.map((p) => [p.longitude, p.latitude]).toList();
      // A single recorded point is not a route: draw no line rather than an invalid one.
      final fullFeature = {
        "type": "FeatureCollection",
        "features": fullCoords.length >= 2
            ? [
                {
                  "type": "Feature",
                  "geometry": {"type": "LineString", "coordinates": fullCoords},
                  "properties": {"color": "#80CBC4"}
                }
              ]
            : []
      };

      if (await style.styleSourceExists(fullRouteSourceId)) {
        await style.setStyleSourceProperty(fullRouteSourceId, "data", jsonEncode(fullFeature));
        // Same colour as this truck on the live maps.
        await style.setStyleLayerProperty(fullRouteLayerId, "line-color", TruckIdentity.hex(trip.truckId));
      } else {
        await style.addSource(GeoJsonSource(id: fullRouteSourceId, data: jsonEncode(fullFeature)));
        if (!(await style.styleLayerExists(fullRouteLayerId))) {
          await style.addLayer(LineLayer(
            id: fullRouteLayerId,
            sourceId: fullRouteSourceId,
            lineColor: TruckIdentity.argb(trip.truckId),
            lineWidth: 5.0,
            lineOpacity: 0.85,
            lineCap: LineCap.ROUND,
            lineJoin: LineJoin.ROUND,
          ));
        }
      }

      _updateReplayMapPosition();

      if (points.isNotEmpty) {
        _mapboxMap?.setCamera(_cameraFittingRoute(points));
      } else {
        _mapboxMap?.setCamera(CameraOptions(
          center: Point(coordinates: Position(121.1620, 13.9565)),
          zoom: 13.8,
        ));
      }
    } catch (e) {
      debugPrint("[ROUTE HISTORY] Mapbox layer update error: $e");
    } finally {
      _isUpdatingPolyline = false;
      final DriverTrip? pending = _pendingMapTrip;
      _pendingMapTrip = null;
      if (pending != null && mounted) _updateMapForTrip(pending);
    }
  }

  /// Camera that shows the whole recorded route (bounds of the cleaned GPS points; impossible
  /// jumps excluded so one bad fix cannot zoom the map out).
  CameraOptions _cameraFittingRoute(List<GpsPoint> points) {
    final List<Map> clean = RouteGeometry.cleanPoints(points
        .map((p) => <String, dynamic>{'latitude': p.latitude, 'longitude': p.longitude, 'timestamp': p.timestamp.millisecondsSinceEpoch, 'accuracy': p.accuracyM})
        .toList());
    final List<List<double>> pts = clean.length >= 2
        ? clean.map((m) => <double>[(m['latitude'] as num).toDouble(), (m['longitude'] as num).toDouble()]).toList()
        : points.map((p) => <double>[p.latitude, p.longitude]).toList();
    double minLat = pts.first[0], maxLat = pts.first[0], minLng = pts.first[1], maxLng = pts.first[1];
    for (final List<double> q in pts) {
      minLat = math.min(minLat, q[0]);
      maxLat = math.max(maxLat, q[0]);
      minLng = math.min(minLng, q[1]);
      maxLng = math.max(maxLng, q[1]);
    }
    final double cLat = (minLat + maxLat) / 2, cLng = (minLng + maxLng) / 2;
    // Mapbox GL: 512 * 2^zoom px around the world. Fit into ~60% of a typical map panel.
    final Size view = MediaQuery.sizeOf(context);
    final double w = math.max(300, view.width * 0.45), h = math.max(240, view.height * 0.45);
    final double lngSpan = math.max(maxLng - minLng, 0.0005);
    final double latSpanM = math.max((maxLat - minLat) * 111320, 50);
    final double zLng = math.log(w * 360 / (512 * lngSpan)) / math.ln2;
    final double zLat = math.log(h * 78271.517 * math.cos(cLat * math.pi / 180) / latSpanM) / math.ln2;
    final double zoom = math.min(zLng, zLat).clamp(11.0, 17.0);
    return CameraOptions(center: Point(coordinates: Position(cLng, cLat)), zoom: zoom);
  }

  void _showLegendModal() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.info_outline_rounded, color: Color(0xFF00796B), size: 20),
            SizedBox(width: 8),
            Text("Map Legend", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildLegendRow(const Color(0xFF00796B), "Route (completed segment)"),
            _buildLegendRow(const Color(0xFF80CBC4), "Full route (entire trip)"),
            _buildLegendRow(const Color(0xFF2E7D32), "Start (trip start)"),
            _buildLegendRow(const Color(0xFFD32F2F), "End (trip end)"),
            _buildLegendRow(const Color(0xFF004D40), "Vehicle (selected time)"),
            _buildLegendRow(const Color(0xFFF57F17), "Stopped / Idle"),
            _buildLegendRow(Colors.blue, "Truck Full"),
            _buildLegendRow(Colors.grey, "Completed Trip"),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Close", style: TextStyle(color: Color(0xFF00796B), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showExportTripMenu(BuildContext context) {
    if (_isResident) return; // read-only: no export
    if (_analyzedTrip == null) return;
    final trip = _analyzedTrip!;

    bool includeAppendix = true;
    bool isExporting = false;
    String? statusMessage;

    Widget buildExportContent(StateSetter setModalState, bool isDialog) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: isDialog ? BorderRadius.circular(24) : const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: const Color(0xFFE0F2F1), borderRadius: BorderRadius.circular(10)),
                      child: const Icon(Icons.file_download_rounded, color: Color(0xFF00796B), size: 22),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Export GIS Route Data", style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
                        Text("Trip ${trip.truckId} · ${DateFormat('MMM d, yyyy').format(trip.startTime)}", style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.grey),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(height: 24),

            if (isExporting) ...[
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    children: [
                      const CircularProgressIndicator(color: Color(0xFF00796B)),
                      const SizedBox(height: 16),
                      Text(statusMessage ?? "Preparing export...", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF00796B))),
                    ],
                  ),
                ),
              ),
            ] else ...[
              // Option 1: PDF Route Report
              InkWell(
                onTap: () async {
                  setModalState(() {
                    isExporting = true;
                    statusMessage = "Generating PDF Route Report...";
                  });
                  await RouteExportManager.downloadPdfReport(trip: trip, includeGpsLogAppendix: includeAppendix);
                  if (context.mounted) {
                    Navigator.pop(context);
                    CustomSnackBar.show(context, message: "PDF Report downloaded to your Downloads folder!");
                  }
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2F9F9),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFB2DFDB)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: const Color(0xFF00796B), borderRadius: BorderRadius.circular(10)),
                        child: const Icon(Icons.picture_as_pdf_rounded, color: Colors.white, size: 22),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Download PDF Route Report", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13.5, color: Color(0xFF1A1A1A))),
                            SizedBox(height: 2),
                            Text("Formal PDF telemetry log & performance summary", style: TextStyle(fontSize: 10.5, color: Colors.grey, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Color(0xFF00796B)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Option 2: Animated GIF / HTML5 Replay
              InkWell(
                onTap: () async {
                  setModalState(() {
                    isExporting = true;
                    statusMessage = "Exporting Animated Route Replay...";
                  });
                  await RouteExportManager.exportTripAnimatedGif(trip);
                  if (context.mounted) {
                    Navigator.pop(context);
                    CustomSnackBar.show(context, message: "Animated Route Replay file downloaded!");
                  }
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: const Color(0xFF1E88E5), borderRadius: BorderRadius.circular(10)),
                        child: const Icon(Icons.gif_box_rounded, color: Colors.white, size: 22),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Animated GIF / Replay Player", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13.5, color: Color(0xFF1A1A1A))),
                            SizedBox(height: 2),
                            Text("Interactive animated vehicle movement player", style: TextStyle(fontSize: 10.5, color: Colors.grey, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Colors.grey),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Option 3: Print PDF
              InkWell(
                onTap: () async {
                  setModalState(() {
                    isExporting = true;
                    statusMessage = "Opening Print Preview...";
                  });
                  await RouteExportManager.printPdfReport(trip: trip, includeGpsLogAppendix: includeAppendix);
                  if (context.mounted) {
                    Navigator.pop(context);
                  }
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: const Color(0xFF546E7A), borderRadius: BorderRadius.circular(10)),
                        child: const Icon(Icons.print_rounded, color: Colors.white, size: 22),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Print PDF Report", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13.5, color: Color(0xFF1A1A1A))),
                            SizedBox(height: 2),
                            Text("Opens browser print preview window directly", style: TextStyle(fontSize: 10.5, color: Colors.grey, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                      const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: Colors.grey),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              CheckboxListTile(
                value: includeAppendix,
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text("Include GPS observation log appendix", style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
                subtitle: const Text("Chronological timestamps, latitude, longitude & speed", style: TextStyle(fontSize: 10, color: Colors.grey)),
                onChanged: (val) {
                  setModalState(() => includeAppendix = val ?? true);
                },
              ),
            ],
          ],
        ),
      );
    }

    if (Responsive.isDesktop(context)) {
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: StatefulBuilder(
              builder: (context, setModalState) => buildExportContent(setModalState, true),
            ),
          ),
        ),
      );
    } else {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (context) => StatefulBuilder(
          builder: (context, setModalState) => buildExportContent(setModalState, false),
        ),
      );
    }
  }

  void _showMobileTripListBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.82,
        padding: const EdgeInsets.only(top: 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 12),
            Expanded(child: _buildTripListView(onSelect: () => Navigator.pop(context))),
          ],
        ),
      ),
    );
  }

  Map<String, List<DriverTrip>> _groupTripsByDate(List<DriverTrip> trips) {
    final Map<String, List<DriverTrip>> groups = {};
    for (var trip in trips) {
      final key = DateFormat('MMM d, yyyy').format(trip.startTime);
      groups.putIfAbsent(key, () => []).add(trip);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingUser) {
      return const Scaffold(
        backgroundColor: Color(0xFFF8F9FA),
        body: Center(child: CircularProgressIndicator(color: Color(0xFF00897B))),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        bool isMobile = constraints.maxWidth < 900;

        return Scaffold(
          backgroundColor: const Color(0xFFF1F5F4),
          body: SafeArea(
            child: Column(
              children: [
                _buildHeaderBar(isMobile),
                Expanded(
                  child: _isLoadingTrips
                      ? const Center(child: CircularProgressIndicator(color: Color(0xFF00897B)))
                      : (_loadError != null
                          ? _buildLoadErrorView()
                          : (isMobile ? _buildMobileTabletLayout() : _buildDesktopLayout())),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildLoadErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 44, color: Color(0xFFB91C1C)),
            const SizedBox(height: 12),
            Text(
              _loadError ?? "Collection route history could not be loaded.",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF7F1D1D)),
            ),
            const SizedBox(height: 14),
            ElevatedButton.icon(
              onPressed: _fetchTrips,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text("Retry"),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00796B),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- SHARED LOOK ----------------------------------------------------------------------------

  static const Color _rhTeal = Color(0xFF00796B);
  static const Color _rhInk = Color(0xFF1A2B3C);
  static const Color _rhMuted = Color(0xFF64748B);
  static const Color _rhLine = Color(0xFFE6EBF0);

  /// Frosted "glass" panel floating over the map. On the Web the map is a separate HTML layer,
  /// so the blur only affects Flutter content; the translucent fill keeps the glass look.
  Widget _glass({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(14),
    BorderRadius? radius,
    double opacity = 0.84,
  }) {
    final BorderRadius r = radius ?? BorderRadius.circular(20);
    return PointerInterceptor(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: r,
          boxShadow: const [BoxShadow(color: Color(0x24000000), blurRadius: 24, offset: Offset(0, 8))],
        ),
        child: ClipRRect(
          borderRadius: r,
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              padding: padding,
              decoration: BoxDecoration(
                borderRadius: r,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Colors.white.withValues(alpha: opacity), Colors.white.withValues(alpha: opacity - 0.1)],
                ),
                border: Border.all(color: Colors.white.withValues(alpha: 0.8), width: 1.2),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  /// Solid soft card for content below the map on phones.
  Widget _softCard({required Widget child, EdgeInsetsGeometry padding = const EdgeInsets.all(14)}) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _rhLine),
        boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 16, offset: Offset(0, 6))],
      ),
      child: child,
    );
  }

  Widget _pillBody({required IconData icon, required String label, bool trailing = false, Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: color ?? _rhTeal),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: _rhInk)),
        if (trailing) ...[
          const SizedBox(width: 2),
          const Icon(Icons.expand_more_rounded, size: 18, color: _rhMuted),
        ],
      ]),
    );
  }

  // --- HEADER (title + filters in one compact bar) ----------------------------------------------

  Widget _buildHeaderBar(bool isMobile) {
    final String dateLabel = _startDate != null
        ? "${DateFormat('MMM d').format(_startDate!)} – ${DateFormat('MMM d, yyyy').format(_endDate ?? DateTime.now())}"
        : "Select dates";
    final List<Widget> filters = [
      Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _showAestheticDateRangePicker,
          child: _pillBody(icon: Icons.calendar_month_rounded, label: dateLabel, trailing: true),
        ),
      ),
      _buildDropdownFilter("Driver", _selectedDriverId, _driverOptions.map((d) => DropdownMenuItem(value: d['id']!, child: Text(d['name']!, overflow: TextOverflow.ellipsis))).toList(), (val) {
        if (val != null) {
          setState(() => _selectedDriverId = val);
          _fetchTrips();
        }
      }),
      if (_isResident) _buildResidentAreaSelector(),
      TextButton.icon(
        onPressed: _clearFilters,
        icon: const Icon(Icons.restart_alt_rounded, size: 16),
        label: const Text("Reset"),
        style: TextButton.styleFrom(foregroundColor: _rhTeal, textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
      ),
    ];
    final List<Widget> spacedFilters = [
      for (int i = 0; i < filters.length; i++) ...[if (i > 0) const SizedBox(width: 8), filters[i]],
    ];
    final Widget title = Row(mainAxisSize: MainAxisSize.min, children: [
      Material(
        color: const Color(0xFFF1F5F9),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            if (widget.onBack != null) {
              widget.onBack!();
            } else {
              Navigator.pop(context);
            }
          },
          child: const SizedBox(width: 36, height: 36, child: Icon(Icons.arrow_back_ios_new_rounded, color: _rhInk, size: 15)),
        ),
      ),
      const SizedBox(width: 12),
      Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF00897B), Color(0xFF00695C)]),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [BoxShadow(color: _rhTeal.withValues(alpha: 0.25), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: const Icon(Icons.route_rounded, color: Colors.white, size: 21),
      ),
      const SizedBox(width: 12),
      Flexible(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text("GIS Route History",
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: isMobile ? 16 : 18, fontWeight: FontWeight.w900, color: _rhInk, letterSpacing: -0.3)),
          Text(
            _isResident
                ? "Collection trips through your area"
                : (_isDriver ? "Your recorded collection trips" : "Recorded truck routes across all puroks"),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: _rhMuted, fontWeight: FontWeight.w600),
          ),
        ]),
      ),
    ]);
    final List<Widget> actions = [
      if (isMobile)
        IconButton(
          onPressed: _showMobileTripListBottomSheet,
          icon: const Icon(Icons.format_list_bulleted_rounded, color: _rhTeal),
          tooltip: "Trips",
        ),
      if (_currentUser?.role.toLowerCase() != 'resident')
        IconButton(
          onPressed: () => _showExportTripMenu(context),
          icon: const Icon(Icons.file_download_rounded, color: _rhTeal),
          tooltip: "Export Route Data",
        ),
      IconButton(
        onPressed: _fetchTrips,
        icon: const Icon(Icons.refresh_rounded, color: _rhTeal),
        tooltip: "Refresh History",
      ),
    ];
    return Container(
      padding: EdgeInsets.fromLTRB(isMobile ? 12 : 20, 10, isMobile ? 6 : 14, 10),
      decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: _rhLine))),
      child: isMobile
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Expanded(child: title), ...actions]),
              const SizedBox(height: 8),
              SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: spacedFilters)),
            ])
          : Row(children: [
              ConstrainedBox(constraints: const BoxConstraints(maxWidth: 380), child: title),
              const SizedBox(width: 20),
              Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: spacedFilters))),
              ...actions,
            ]),
    );
  }

  /// Residents start on their own purok; any other area or all areas can be chosen.
  Widget _buildResidentAreaSelector() {
    final List<String> names = _geofences.map((AreaGeofence g) => g.name).toSet().toList()..sort();
    if (names.isEmpty) return const SizedBox.shrink();
    String labelFor(String v) => v == 'all' ? 'All areas' : (v == _residentHomeArea ? 'My area · $v' : v);
    return PopupMenuButton<String>(
      tooltip: 'Show trips through an area',
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: _setResidentAreaView,
      itemBuilder: (BuildContext context) => [
        if (_residentHomeArea != null)
          CheckedPopupMenuItem<String>(value: _residentHomeArea!, checked: _residentAreaView == _residentHomeArea, child: Text('My area · ${_residentHomeArea!}')),
        CheckedPopupMenuItem<String>(value: 'all', checked: _residentAreaView == 'all', child: const Text('All areas')),
        const PopupMenuDivider(),
        for (final String n in names)
          if (n != _residentHomeArea) CheckedPopupMenuItem<String>(value: n, checked: _residentAreaView == n, child: Text(n)),
      ],
      child: _pillBody(icon: Icons.place_rounded, label: labelFor(_residentAreaView), trailing: true),
    );
  }

  Widget _buildDisclaimerBanner() => const SizedBox.shrink();

  void _confirmDeleteTrip(DriverTrip trip) {
    if (_isResident) return; // read-only: residents cannot delete
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.delete_forever_rounded, color: Colors.redAccent, size: 24),
            SizedBox(width: 8),
            Text("Delete Trip", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Are you sure you want to delete this trip record?",
              style: TextStyle(fontSize: 14, color: Colors.grey.shade800, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Driver: ${trip.driverName}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 4),
                  Text("Truck: ${trip.truckId}", style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 4),
                  Text("Date: ${DateFormat('MMM d, yyyy · h:mm a').format(trip.startTime)}", style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              "This action cannot be undone and will permanently remove this trip from history.",
              style: TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              Navigator.pop(context);
              await _performDeleteTrip(trip);
            },
            child: const Text("Delete Trip", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _performDeleteTrip(DriverTrip trip) async {
    if (_isResident) return; // read-only: enforced here, not only by hiding the button
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
            const SizedBox(width: 12),
            Text("Deleting trip ${trip.tripNumber}..."),
          ],
        ),
        duration: const Duration(seconds: 2),
      ),
    );

    final bool success = await DriverRouteHistoryService.deleteTrip(trip.tripId);

    if (mounted) {
      if (success) {
        setState(() {
          _trips.removeWhere((t) => t.tripId == trip.tripId);
          if (_selectedTrip?.tripId == trip.tripId) {
            if (_trips.isNotEmpty) {
              _selectTrip(_trips.first);
            } else {
              _selectedTrip = null;
              _analyzedTrip = null;
            }
          }
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Trip deleted successfully."),
            backgroundColor: Color(0xFF00796B),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Failed to delete trip. Please try again."),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildDropdownFilter<T>(String label, T currentValue, List<DropdownMenuItem<T>> items, ValueChanged<T?> onChanged) {
    if ((_isResident || _isDriver) && label == "Driver") return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: currentValue,
          items: items,
          onChanged: onChanged,
          isDense: true,
          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: Color(0xFF1A1A1A)),
        ),
      ),
    );
  }

  void _showMobileFilterBottomSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Filter Route History", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
                      Row(
                        children: [
                          TextButton(
                            onPressed: () {
                              _clearFilters();
                              Navigator.pop(context);
                            },
                            child: const Text("Reset", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF2196F3))),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, color: Colors.grey),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const Divider(height: 16),
                  const SizedBox(height: 8),

                  // Driver Selection
                  const Text("Driver", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
                  const SizedBox(height: 6),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(color: const Color(0xFFF1F4F8), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.grey.shade300)),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _selectedDriverId,
                        isExpanded: true,
                        items: _driverOptions.map((d) => DropdownMenuItem(value: d['id']!, child: Text(d['name']!, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)))).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setSheetState(() => _selectedDriverId = val);
                            setState(() => _selectedDriverId = val);
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Date Range Button
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _showAestheticDateRangePicker();
                      },
                      icon: const Icon(Icons.calendar_today_rounded, size: 16, color: Color(0xFF00796B)),
                      label: Text(_startDate != null ? "${DateFormat('MMM d').format(_startDate!)} – ${DateFormat('d, yyyy').format(_endDate ?? DateTime.now())}" : "Select Date Range", style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Apply Button
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _fetchTrips();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00796B),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text("Apply Filters", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // --- DESKTOP LAYOUT: full map with floating glass panels ---------------------------------------
  Widget _buildDesktopLayout() {
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints c) => _buildDesktopStack(c.maxWidth >= 1250));
  }

  bool _timelineOn(bool wide) => _showTimeline ?? wide;

  Widget _buildDesktopStack(bool wide) {
    final bool hasTrip = _analyzedTrip != null;
    final bool showList = !_isMapExpanded;
    final bool showTimeline = hasTrip && _timelineOn(wide) && !_isMapExpanded;
    const double gap = 16, listW = 330, timelineW = 300, controlsW = 52;
    final double leftInset = showList ? gap + listW + 12 : gap;
    final double rightInset = gap + controlsW + 12 + (showTimeline ? timelineW + 12 : 0);
    return Stack(
      children: [
        Positioned.fill(child: MapboxGate(child: MapWidget(onMapCreated: _onMapCreated, onStyleLoadedListener: _onStyleLoaded))),
        if (showList)
          Positioned(left: gap, top: gap, bottom: gap, width: listW, child: _glass(padding: EdgeInsets.zero, child: _buildTripListView())),
        Positioned(right: gap, top: 0, bottom: 0, child: Center(child: _buildMapControls(desktop: true, wide: wide))),
        if (showTimeline)
          Positioned(
            right: gap + controlsW + 12,
            top: gap,
            bottom: gap,
            width: timelineW,
            child: _glass(padding: EdgeInsets.zero, child: _buildRightTimelinePanel()),
          ),
        if (hasTrip) Positioned(left: leftInset, right: rightInset, top: gap, child: _glass(child: _buildSelectedTripHeaderAboveMap())),
        if (hasTrip)
          Positioned(
            left: leftInset,
            right: rightInset,
            bottom: gap,
            child: _glass(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(mainAxisSize: MainAxisSize.min, children: [_buildPlaybackControlsBar(), const SizedBox(height: 8), _buildMetricsRow()]),
            ),
          ),
        if (!hasTrip)
          Positioned(left: leftInset, right: rightInset, top: 0, bottom: 0, child: Center(child: _glass(child: _buildNoTripSelected()))),
      ],
    );
  }

  /// Selected trip: identity, recorded facts, route honesty and the related load.
  Widget _buildSelectedTripHeaderAboveMap() {
    final DriverTrip trip = _analyzedTrip!;
    final int validPoints = RouteGeometry.cleanPoints(trip.points
        .map((p) => <String, dynamic>{'latitude': p.latitude, 'longitude': p.longitude, 'timestamp': p.timestamp.millisecondsSinceEpoch, 'accuracy': p.accuracyM})
        .toList()).length;
    final String? incomplete = RouteGeometry.incompleteReason(
      validPointCount: validPoints,
      collectionFinalized: trip.isFinalizedCollection,
      recordedDistanceKm: trip.totalDistanceKm,
    );
    final TripLink loadLink = TripLinks.toLoad(trip);
    final String fullText = trip.isFinalizedCollection && trip.fullTime != null
        ? DateFormat('MMM d, h:mm a').format(trip.fullTime!.toLocal())
        : 'Not finalized';
    final String timeStr = trip.endTime != null
        ? "${DateFormat('h:mm a').format(trip.startTime)} – ${DateFormat('h:mm a').format(trip.endTime!)}"
        : "${DateFormat('h:mm a').format(trip.startTime)} – Now";
    final Color identity = TruckIdentity.color(trip.truckId);

    Widget fact(IconData icon, String label, String value) => Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _rhLine),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: _rhTeal),
            const SizedBox(width: 6),
            Text("$label ", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _rhMuted)),
            Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: _rhInk)),
          ]),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          // Truck identity colour: the same colour as its marker and live route.
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: identity.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12)),
            child: Icon(Icons.local_shipping_rounded, color: _readable(identity), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text("${trip.driverName}  •  ${trip.truckId}",
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: _rhInk, letterSpacing: -0.2)),
              const SizedBox(height: 2),
              Text("${DateFormat('EEE, MMM d, yyyy').format(trip.startTime)} · $timeStr · ${_areasLabel(trip)}",
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: _rhMuted, fontWeight: FontWeight.w700)),
            ]),
          ),
          const SizedBox(width: 8),
          _statusChip(trip.routeStatus),
          if (_currentUser?.role.toLowerCase() != 'resident') ...[
            const SizedBox(width: 6),
            IconButton(
              onPressed: () => _showExportTripMenu(context),
              icon: const Icon(Icons.file_download_rounded, size: 19, color: _rhTeal),
              tooltip: "Export trip",
              style: IconButton.styleFrom(backgroundColor: Colors.white.withValues(alpha: 0.75)),
            ),
            IconButton(
              onPressed: () => _confirmDeleteTrip(trip),
              icon: Icon(Icons.delete_outline_rounded, size: 19, color: Colors.red.shade600),
              tooltip: "Delete Trip",
              style: IconButton.styleFrom(backgroundColor: const Color(0xFFFFEBEE)),
            ),
          ],
        ]),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            fact(Icons.login_rounded, 'Start', DateFormat('MMM d, h:mm a').format(trip.startTime.toLocal())),
            fact(Icons.local_shipping_rounded, 'FULL', fullText),
            fact(Icons.timer_outlined, 'Duration', trip.formattedDuration),
            fact(Icons.scale_outlined, trip.isMeasured ? 'Load' : 'Est. load',
                trip.isFinalizedCollection ? "${trip.weightKg.toStringAsFixed(0)} kg" : 'Not finalized'),
            fact(Icons.tag_rounded, 'Trip', trip.tripId.length > 10 ? "…${trip.tripId.substring(trip.tripId.length - 8)}" : trip.tripId),
            if (!_isResident) ...[
              TextButton.icon(
                onPressed: () {
                  if (!loadLink.isAvailable) {
                    CustomSnackBar.show(context, message: loadLink.message ?? 'No load record for this trip.', isError: true);
                    return;
                  }
                  showLoadHistoryDialog(
                    context,
                    date: loadLink.date,
                    highlightTripId: loadLink.tripId,
                    onOpenRouteHistory: ({String? tripId, DriverTrip? trip}) => _openTripInPlace(tripId: tripId, trip: trip),
                  );
                },
                icon: const Icon(Icons.scale_rounded, size: 15),
                label: Text(loadLink.isAvailable ? "Associated load" : "Load unavailable"),
                style: TextButton.styleFrom(
                  foregroundColor: loadLink.isAvailable ? _rhTeal : Colors.grey,
                  textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                ),
              ),
            ],
          ]),
        ),
        if (incomplete != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF8E1).withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFFFE082)),
            ),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded, size: 15, color: Color(0xFFB45309)),
              const SizedBox(width: 8),
              Expanded(
                child: Text("Route incomplete — $incomplete",
                    style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFF92400E))),
              ),
            ]),
          ),
        ],
        if (_routeNotice != null) ...[
          const SizedBox(height: 6),
          Text(_routeNotice!, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFB91C1C))),
        ],
      ],
    );
  }

  /// Truck identity colour, darkened when too light to read as text or an icon.
  static Color _readable(Color c) => c.computeLuminance() > 0.45 ? Color.lerp(c, Colors.black, 0.45)! : c;

  Widget _statusChip(String status) {
    final String s = status.toUpperCase();
    final Color c = s == 'COMPLETED' || s == 'FINISHED'
        ? const Color(0xFF2E7D32)
        : (s == 'FULL' ? const Color(0xFF1565C0) : (s == 'ACTIVE' ? _rhTeal : const Color(0xFFEF6C00)));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Text(s, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, color: c, letterSpacing: 0.3)),
    );
  }

  // --- MAP CONTROLS (one glass column) ------------------------------------------------------------
  Widget _buildMapControls({required bool desktop, bool wide = true}) {
    Widget btn(IconData icon, String tip, VoidCallback onTap, {bool active = false}) => Tooltip(
          message: tip,
          child: Material(
            color: active ? _rhTeal : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: SizedBox(width: 38, height: 38, child: Icon(icon, size: 19, color: active ? Colors.white : _rhInk)),
            ),
          ),
        );
    return _glass(
      padding: const EdgeInsets.all(4),
      radius: BorderRadius.circular(16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        btn(_selectedMapStyle == 'map' ? Icons.satellite_alt_rounded : Icons.map_rounded,
            _selectedMapStyle == 'map' ? 'Satellite view' : 'Map view',
            () => _switchMapStyle(_selectedMapStyle == 'map' ? 'satellite' : 'map'),
            active: _selectedMapStyle == 'satellite'),
        btn(Icons.info_outline_rounded, 'Legend', _showLegendModal),
        if (desktop) ...[
          btn(_isMapExpanded ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded, _isMapExpanded ? 'Exit full map' : 'Full map', () {
            setState(() => _isMapExpanded = !_isMapExpanded);
            if (_mapboxMap != null && _analyzedTrip != null && _analyzedTrip!.points.isNotEmpty) {
              _updateMapForTrip(_analyzedTrip!);
            }
          }, active: _isMapExpanded),
          if (_analyzedTrip != null && !_isMapExpanded)
            btn(Icons.view_timeline_rounded, _timelineOn(wide) ? 'Hide timeline' : 'Show timeline',
                () => setState(() => _showTimeline = !_timelineOn(wide)), active: _timelineOn(wide)),
        ],
        if (desktop) const Padding(padding: EdgeInsets.symmetric(vertical: 2), child: SizedBox(width: 26, child: Divider(height: 8))),
        btn(Icons.my_location_rounded, 'Fit route', () {
          if (_mapboxMap != null && _analyzedTrip != null && _analyzedTrip!.points.isNotEmpty) {
            _updateMapForTrip(_analyzedTrip!);
          } else if (_mapboxMap != null) {
            _mapboxMap?.setCamera(CameraOptions(center: Point(coordinates: Position(121.1620, 13.9565)), zoom: 13.8));
          }
        }),
        // Phones zoom by pinching; the short map has room only for the essentials.
        if (desktop) btn(Icons.add_rounded, 'Zoom in', () async {
          if (_mapboxMap != null) {
            final state = await _mapboxMap!.getCameraState();
            _mapboxMap!.setCamera(CameraOptions(zoom: state.zoom + 1.0));
          }
        }),
        if (desktop) btn(Icons.remove_rounded, 'Zoom out', () async {
          if (_mapboxMap != null) {
            final state = await _mapboxMap!.getCameraState();
            _mapboxMap!.setCamera(CameraOptions(zoom: state.zoom - 1.0));
          }
        }),
      ]),
    );
  }

  // --- PHONE / TABLET LAYOUT: map first, details below, trips in a draggable sheet --------------
  Widget _buildMobileTabletLayout() {
    final double h = MediaQuery.sizeOf(context).height;
    final double mapH = (h * 0.42).clamp(260.0, 420.0);
    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 150),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_analyzedTrip != null) ...[
                SizedBox(
                  height: mapH,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Stack(children: [
                      Positioned.fill(child: MapboxGate(child: MapWidget(onMapCreated: _onMapCreated, onStyleLoadedListener: _onStyleLoaded))),
                      Positioned(right: 10, top: 10, child: _buildMapControls(desktop: false)),
                      Positioned(
                        left: 10,
                        right: 66,
                        bottom: 10,
                        child: _glass(padding: const EdgeInsets.fromLTRB(6, 4, 8, 6), radius: BorderRadius.circular(16), child: _buildPlaybackControlsBar(compact: true)),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                _softCard(child: _buildSelectedTripHeaderAboveMap()),
                const SizedBox(height: 12),
                _buildMetricsRow(grid: true),
                const SizedBox(height: 12),
                _softCard(padding: EdgeInsets.zero, child: _buildRightTimelinePanel(fill: false)),
              ] else
                SizedBox(height: 320, child: _buildNoTripSelected()),
            ],
          ),
        ),
        DraggableScrollableSheet(
          initialChildSize: 0.16,
          minChildSize: 0.1,
          maxChildSize: 0.86,
          snap: true,
          snapSizes: const [0.16, 0.5],
          builder: (context, scrollController) => _glass(
            padding: EdgeInsets.zero,
            opacity: 0.94,
            radius: const BorderRadius.vertical(top: Radius.circular(26)),
            child: _buildTripListViewScrollable(scrollController),
          ),
        ),
      ],
    );
  }

  /// Trip list for the phone sheet (scrolls with the sheet).
  Widget _buildTripListViewScrollable(ScrollController scrollController) {
    final List<DriverTrip> trips = _visibleTrips;
    final Map<String, List<DriverTrip>> groupedTrips = _groupTripsByDate(trips);
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        Center(
          child: Container(width: 42, height: 5, decoration: BoxDecoration(color: const Color(0xFFCBD5E1), borderRadius: BorderRadius.circular(3))),
        ),
        const SizedBox(height: 8),
        _tripListHeader(trips.length),
        if (trips.isEmpty) _emptyTrips() else ..._groupedTripCards(groupedTrips),
      ],
    );
  }

  /// Trip list for the desktop panel and the phone "Trips" sheet.
  Widget _buildTripListView({VoidCallback? onSelect}) {
    final List<DriverTrip> trips = _visibleTrips;
    final Map<String, List<DriverTrip>> groupedTrips = _groupTripsByDate(trips);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: const EdgeInsets.fromLTRB(14, 14, 14, 6), child: _tripListHeader(trips.length)),
        Expanded(
          child: trips.isEmpty
              ? _emptyTrips()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  children: _groupedTripCards(groupedTrips, onSelect: onSelect),
                ),
        ),
      ],
    );
  }

  Widget _tripListHeader(int count) {
    return Row(children: [
      const Text("Trips", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17, color: _rhInk)),
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: _rhTeal.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
        child: Text("$count", style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, color: _rhTeal)),
      ),
      const Spacer(),
      if (_loadPartial)
        const Tooltip(
          message: "Some history sources could not be reached; the list may be incomplete.",
          child: Icon(Icons.warning_amber_rounded, size: 17, color: Color(0xFFB45309)),
        ),
    ]);
  }

  Widget _emptyTrips() {
    final bool areaFiltered = _isResident && _residentAreaView != 'all';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.route_outlined, size: 44, color: Colors.grey.shade300),
        const SizedBox(height: 10),
        Text(
          areaFiltered ? "No recorded trips through $_residentAreaView in these dates." : "No collection route history available.",
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.grey, fontSize: 13),
        ),
        if (areaFiltered)
          TextButton(onPressed: () => _setResidentAreaView('all'), child: const Text("Show all areas")),
      ]),
    );
  }

  List<Widget> _groupedTripCards(Map<String, List<DriverTrip>> groups, {VoidCallback? onSelect}) {
    return [
      for (final MapEntry<String, List<DriverTrip>> g in groups.entries) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
          child: Row(children: [
            Text(g.key, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: _rhInk)),
            const SizedBox(width: 6),
            Text("· ${g.value.length} trip${g.value.length == 1 ? '' : 's'}",
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: _rhMuted)),
          ]),
        ),
        ...g.value.map((DriverTrip t) => _tripCard(t, onSelect: onSelect)),
      ],
    ];
  }

  Widget _tripCard(DriverTrip trip, {VoidCallback? onSelect}) {
    final bool isSelected = _selectedTrip?.tripId == trip.tripId;
    final Color identity = TruckIdentity.color(trip.truckId);
    final String timeStr = trip.endTime != null
        ? "${DateFormat('h:mm a').format(trip.startTime)} – ${DateFormat('h:mm a').format(trip.endTime!)}"
        : "${DateFormat('h:mm a').format(trip.startTime)} – Now";
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isSelected ? _rhTeal.withValues(alpha: 0.09) : Colors.white.withValues(alpha: 0.86),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: isSelected ? _rhTeal : _rhLine, width: isSelected ? 1.6 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            _selectTrip(trip);
            if (onSelect != null) onSelect();
          },
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(width: 4, color: identity),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(color: identity.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(8)),
                        child: Text(trip.truckId, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: _readable(identity))),
                      ),
                      const SizedBox(width: 6),
                      _statusChip(trip.routeStatus),
                      const Spacer(),
                      if (_currentUser?.role.toLowerCase() != 'resident')
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => _confirmDeleteTrip(trip),
                          child: Padding(padding: const EdgeInsets.all(2), child: Icon(Icons.delete_outline_rounded, size: 17, color: Colors.red.shade400)),
                        ),
                    ]),
                    const SizedBox(height: 6),
                    Text(trip.driverName,
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: _rhInk)),
                    const SizedBox(height: 2),
                    Text("$timeStr · ${trip.formattedDuration}",
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: _rhMuted, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Row(children: [
                      const Icon(Icons.place_outlined, size: 14, color: _rhTeal),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(_areasLabel(trip),
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11.5, color: Color(0xFF334155), fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(width: 6),
                      Text("${trip.totalDistanceKm.toStringAsFixed(1)} km",
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: _rhTeal)),
                    ]),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildNoTripSelected() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(color: _rhTeal.withValues(alpha: 0.1), shape: BoxShape.circle),
          child: const Icon(Icons.map_rounded, size: 30, color: _rhTeal),
        ),
        const SizedBox(height: 12),
        const Text("Select a trip to view its recorded GPS route",
            textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w800, color: _rhMuted, fontSize: 13)),
      ],
    );
  }

  Widget _buildLegendRow(Color color, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(radius: 5, backgroundColor: color),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF455A64))),
        ],
      ),
    );
  }

  /// Replay: play/pause, timeline slider with times, speed. [compact] (over the phone map)
  /// drops the 10 s jump buttons.
  Widget _buildPlaybackControlsBar({bool compact = false}) {
    final curTime = _currentPlaybackTime;
    final startStr = _analyzedTrip != null ? DateFormat('h:mm a').format(_analyzedTrip!.startTime) : "0:00";
    final endStr = _analyzedTrip?.endTime != null ? DateFormat('h:mm a').format(_analyzedTrip!.endTime!) : "0:00";
    return Row(
      children: [
        Material(
          color: _rhTeal,
          shape: const CircleBorder(),
          elevation: 2,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _toggleReplay,
            child: SizedBox(
              width: compact ? 36 : 42,
              height: compact ? 36 : 42,
              child: Tooltip(
                message: _isReplaying ? "Pause Replay" : "Play Replay",
                child: Icon(_isReplaying ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: compact ? 22 : 26),
              ),
            ),
          ),
        ),
        if (!compact)
          IconButton(
            onPressed: () => _jumpPlayback(-10),
            icon: const Icon(Icons.replay_10_rounded, color: _rhTeal, size: 20),
            tooltip: "Rewind 10s",
          )
        else
          const SizedBox(width: 6),
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: SizedBox(
                height: 26,
                child: Slider(
                  value: _replayProgress,
                  onChanged: (val) {
                    setState(() => _replayProgress = val);
                    _updateReplayMapPosition();
                  },
                  activeColor: _rhTeal,
                  inactiveColor: const Color(0xFFCBD5E1),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(children: [
                Text(startStr, style: const TextStyle(fontSize: 10, color: _rhMuted, fontWeight: FontWeight.w800)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: _rhInk, borderRadius: BorderRadius.circular(6)),
                  child: Text(DateFormat('h:mm:ss a').format(curTime),
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900, fontFamily: 'monospace')),
                ),
                const Spacer(),
                Text(endStr, style: const TextStyle(fontSize: 10, color: _rhMuted, fontWeight: FontWeight.w800)),
              ]),
            ),
          ]),
        ),
        if (!compact)
          IconButton(
            onPressed: () => _jumpPlayback(10),
            icon: const Icon(Icons.forward_10_rounded, color: _rhTeal, size: 20),
            tooltip: "Forward 10s",
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _rhLine),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<double>(
              value: _replaySpeedMultiplier,
              isDense: true,
              items: const [
                DropdownMenuItem(value: 0.25, child: Text("0.25×", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                DropdownMenuItem(value: 0.5, child: Text("0.5×", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                DropdownMenuItem(value: 1.0, child: Text("1×", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                DropdownMenuItem(value: 2.0, child: Text("2×", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                DropdownMenuItem(value: 5.0, child: Text("5×", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
              ],
              onChanged: (val) {
                if (val != null) setState(() => _replaySpeedMultiplier = val);
              },
            ),
          ),
        ),
      ],
    );
  }

  /// Distance, moving, stationary and stops as compact chips (one row, or 2 x 2 on phones).
  Widget _buildMetricsRow({bool grid = false}) {
    final DriverTrip t = _analyzedTrip!;
    final List<Widget> items = [
      _metricChip(Icons.straighten_rounded, "Distance", "${t.totalDistanceKm.toStringAsFixed(1)} km", "Total GPS route distance.", const Color(0xFF00796B)),
      _metricChip(Icons.play_circle_outline_rounded, "Moving", "${(t.movingTimeSeconds / 60).toStringAsFixed(0)} min", "Time spent in motion (speed > 5 km/h).", const Color(0xFF1565C0)),
      _metricChip(Icons.pause_circle_outline_rounded, "Stationary", "${(t.stoppedTimeSeconds / 60).toStringAsFixed(0)} min", "Time spent loading & collecting waste.", const Color(0xFFEF6C00)),
      _metricChip(Icons.pin_drop_outlined, "Stops", "${t.detectedStopsCount}", "Confirmed loading & pickup locations.", const Color(0xFF6A1B9A)),
    ];
    if (grid) {
      return GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 2.7,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        children: items,
      );
    }
    return Row(children: [
      for (int i = 0; i < items.length; i++) ...[if (i > 0) const SizedBox(width: 8), Expanded(child: items[i])],
    ]);
  }

  Widget _metricChip(IconData icon, String label, String value, String tooltip, Color color) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.18)),
        ),
        child: Row(children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: 16),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w900, color: _rhInk)),
              ),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: _rhMuted, fontWeight: FontWeight.w700)),
            ]),
          ),
        ]),
      ),
    );
  }

  /// Trip events (tap one to jump the replay there). [fill]: inside a fixed-height panel.
  Widget _buildRightTimelinePanel({bool fill = true}) {
    final trip = _analyzedTrip!;
    final Widget header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Row(children: [
        const Icon(Icons.view_timeline_rounded, size: 18, color: _rhTeal),
        const SizedBox(width: 8),
        const Text("Trip timeline", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: _rhInk)),
        const Spacer(),
        Text("${trip.events.length} events", style: const TextStyle(fontSize: 11, color: _rhMuted, fontWeight: FontWeight.w700)),
      ]),
    );
    Widget item(BuildContext context, int idx) {
      final evt = trip.events[idx];
      final isStart = evt.description.toLowerCase().contains("start");
      final isEnd = evt.description.toLowerCase().contains("end");
      final isStop = evt.description.toLowerCase().contains("stop");
      final Color dotColor = isStart
          ? _rhTeal
          : (isEnd ? Colors.redAccent : (isStop ? const Color(0xFFF57F17) : const Color(0xFF94A3B8)));
      final bool last = idx == trip.events.length - 1;
      return InkWell(
        onTap: () => _seekToTimestamp(evt.timestamp),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: 14,
                child: Column(children: [
                  const SizedBox(height: 9),
                  Container(
                    width: 11,
                    height: 11,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: [BoxShadow(color: dotColor.withValues(alpha: 0.4), blurRadius: 4)],
                    ),
                  ),
                  if (!last) Expanded(child: Container(width: 2, color: const Color(0xFFE2E8F0))),
                ]),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      evt.description.isNotEmpty ? evt.description : evt.eventType,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: (isStart || isEnd) ? FontWeight.w900 : FontWeight.w700,
                        color: (isStart || isEnd) ? _rhTeal : _rhInk,
                      ),
                    ),
                    Text(DateFormat('h:mm:ss a').format(evt.timestamp),
                        style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: _rhMuted, fontFamily: 'monospace')),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      );
    }

    const Widget empty = Padding(
      padding: EdgeInsets.all(16),
      child: Text("No recorded timeline events.", style: TextStyle(fontSize: 12, color: _rhMuted)),
    );
    if (fill) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        const Divider(height: 1, color: _rhLine),
        Expanded(
          child: trip.events.isEmpty
              ? empty
              : ListView.builder(padding: const EdgeInsets.symmetric(vertical: 8), itemCount: trip.events.length, itemBuilder: item),
        ),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      header,
      const Divider(height: 1, color: _rhLine),
      if (trip.events.isEmpty)
        empty
      else
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: trip.events.length,
          itemBuilder: item,
        ),
    ]);
  }
}
