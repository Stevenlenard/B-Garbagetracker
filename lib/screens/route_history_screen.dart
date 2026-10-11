import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size, Visibility;
import '../utils/session_manager.dart';
import '../models/user.dart';
import '../models/driver_trip.dart';
import '../services/driver_route_history_service.dart';
import '../services/service_area_service.dart';
import '../utils/app_theme.dart';
import '../utils/responsive.dart';
import '../utils/route_export_manager.dart';
import '../widgets/custom_snackbar.dart';
import '../api/api_service.dart';

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
  String _selectedMapStyle = 'map'; // 'map' or 'satellite'
  bool _isMapExpanded = false; // Expand Map Mode toggle

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

    final trips = await DriverRouteHistoryService.fetchRouteHistory(
      currentUser: _currentUser!,
      startDate: _startDate,
      endDate: _endDate,
      selectedDriverId: _selectedDriverId,
      selectedTruckId: _selectedTruckId,
      selectedArea: _selectedArea,
      selectedStatus: _selectedStatus,
    );

    if (mounted) {
      setState(() {
        _trips = trips;
        _isLoadingTrips = false;

        DriverTrip? targetTrip;
        if (_effectiveInitialTripId != null && _effectiveInitialTripId!.isNotEmpty) {
          final idx = _trips.indexWhere((t) => t.tripId == _effectiveInitialTripId);
          if (idx != -1) {
            targetTrip = _trips[idx];
          } else if (_effectiveInitialTrip != null) {
            _trips.insert(0, _effectiveInitialTrip!);
            targetTrip = _effectiveInitialTrip;
          }
        }

        if (targetTrip != null) {
          _selectTrip(targetTrip);
        } else if (_trips.isNotEmpty) {
          _selectTrip(_trips.first);
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
    });
    _fetchTrips();
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

    try {
      final styleUri = newStyle == 'satellite'
          ? MapboxStyles.SATELLITE_STREETS
          : MapboxStyles.MAPBOX_STREETS;
      await _mapboxMap!.style.setStyleURI(styleUri);
    } catch (e) {
      debugPrint("[ROUTE HISTORY] Map style switch error: $e");
    }
  }

  Future<void> _showAestheticDateRangePicker() async {
    final DateTimeRange? range = await showDialog<DateTimeRange>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: _AestheticDateRangePicker(
            initialRange: DateTimeRange(
              start: _startDate ?? DateTime.now().subtract(const Duration(days: 7)),
              end: _endDate ?? DateTime.now(),
            ),
          ),
        ),
      ),
    );

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
            "START", const Color(0xFF2E7D32).toARGB32(),
            "END", const Color(0xFFD32F2F).toARGB32(),
            "STOP", const Color(0xFFF57F17).toARGB32(),
            "VEHICLE", const Color(0xFF00796B).toARGB32(),
            Colors.blue.toARGB32()
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

  Future<void> _updateMapForTrip(DriverTrip trip) async {
    if (_mapboxMap == null || _isUpdatingPolyline) return;
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
      final fullFeature = {
        "type": "FeatureCollection",
        "features": [
          {
            "type": "Feature",
            "geometry": {"type": "LineString", "coordinates": fullCoords},
            "properties": {"color": "#80CBC4"}
          }
        ]
      };

      if (await style.styleSourceExists(fullRouteSourceId)) {
        await style.setStyleSourceProperty(fullRouteSourceId, "data", jsonEncode(fullFeature));
      } else {
        await style.addSource(GeoJsonSource(id: fullRouteSourceId, data: jsonEncode(fullFeature)));
        if (!(await style.styleLayerExists(fullRouteLayerId))) {
          await style.addLayer(LineLayer(
            id: fullRouteLayerId,
            sourceId: fullRouteSourceId,
            lineColor: const Color(0xFF80CBC4).toARGB32(),
            lineWidth: 5.0,
            lineOpacity: 0.6,
            lineCap: LineCap.ROUND,
            lineJoin: LineJoin.ROUND,
          ));
        }
      }

      _updateReplayMapPosition();

      if (points.isNotEmpty) {
        final centerLng = (points.first.longitude + points.last.longitude) / 2;
        final centerLat = (points.first.latitude + points.last.latitude) / 2;
        _mapboxMap?.setCamera(CameraOptions(
          center: Point(coordinates: Position(centerLng, centerLat)),
          zoom: 14.2,
        ));
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
    }
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
        bool isMobile = constraints.maxWidth < 600;

        return Scaffold(
          backgroundColor: const Color(0xFFF8F9FA),
          body: SafeArea(
            child: Column(
              children: [
                _buildTopHeader(isMobile),
                _buildDirectMapFilterBar(isMobile),
                Expanded(
                  child: _isLoadingTrips
                      ? const Center(child: CircularProgressIndicator(color: Color(0xFF00897B)))
                      : (isMobile ? _buildMobileTabletLayout() : _buildDesktopLayout()),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopHeader(bool isMobile) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 24, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 8, offset: const Offset(0, 2))
        ],
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              if (widget.onBack != null) {
                widget.onBack!();
              } else {
                Navigator.pop(context);
              }
            },
            child: Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(color: Color(0xFFF5F5F5), shape: BoxShape.circle),
              child: const Icon(Icons.arrow_back_ios_new_rounded, color: Color(0xFF1A1A1A), size: 16),
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: const Color(0xFFE0F2F1), borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.route_rounded, color: Color(0xFF00796B), size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        "GIS Route History",
                        style: TextStyle(fontSize: isMobile ? 15 : 19, fontWeight: FontWeight.w900, color: const Color(0xFF1A1A1A)),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    if (!isMobile) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: const Color(0xFFE0F2F1), borderRadius: BorderRadius.circular(12)),
                        child: const Row(
                          children: [
                            Icon(Icons.eco_rounded, size: 12, color: Color(0xFF00796B)),
                            SizedBox(width: 4),
                            Text("Gbage Tracker", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF00796B))),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  "Historical truck routes across puroks with status indicators.",
                  style: TextStyle(fontSize: isMobile ? 10 : 11.5, color: Colors.grey.shade600, fontWeight: FontWeight.w500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (isMobile) ...[
            ElevatedButton.icon(
              onPressed: _showMobileTripListBottomSheet,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE0F2F1),
                foregroundColor: const Color(0xFF00796B),
                elevation: 0,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.format_list_bulleted_rounded, size: 14),
              label: const Text("Trips ▼", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 6),
          ] else ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(20)),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: const Color(0xFF00796B),
                    child: Text(
                      _currentUser?.name.isNotEmpty == true ? _currentUser!.name[0].toUpperCase() : "S",
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    "${_currentUser?.role.toUpperCase() ?? 'DRIVER'} ▼",
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (_currentUser?.role.toLowerCase() != 'resident')
            IconButton(
              onPressed: () => _showExportTripMenu(context),
              icon: const Icon(Icons.file_download_rounded, color: Color(0xFF00796B)),
              tooltip: "Export Route Data",
            ),
          IconButton(
            onPressed: _fetchTrips,
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF00796B)),
            tooltip: "Refresh History",
          ),
        ],
      ),
    );
  }

  Widget _buildDisclaimerBanner() => const SizedBox.shrink();

  void _confirmDeleteTrip(DriverTrip trip) {
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

  // --- DIRECT MAP FILTER BAR (Date Range & Drivers Only) ---
  Widget _buildDirectMapFilterBar(bool isMobile) {
    if (isMobile) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: Colors.white,
        child: Row(
          children: [
            OutlinedButton.icon(
              onPressed: _showAestheticDateRangePicker,
              icon: const Icon(Icons.calendar_today_rounded, size: 14, color: Color(0xFF00796B)),
              label: Text(_startDate != null ? "${DateFormat('MMM d').format(_startDate!)} – ${DateFormat('d, yyyy').format(_endDate ?? DateTime.now())}" : "Select Dates", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildDropdownFilter("Driver", _selectedDriverId, _driverOptions.map((d) => DropdownMenuItem(value: d['id']!, child: Text(d['name']!, overflow: TextOverflow.ellipsis))).toList(), (val) {
                if (val != null) {
                  setState(() => _selectedDriverId = val);
                  _fetchTrips();
                }
              }),
            ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded, color: Color(0xFF00796B)),
              onPressed: _clearFilters,
              tooltip: "Reset Filters",
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      color: Colors.white,
      child: Row(
        children: [
          OutlinedButton.icon(
            onPressed: _showAestheticDateRangePicker,
            icon: const Icon(Icons.calendar_today_rounded, size: 14, color: Color(0xFF00796B)),
            label: Text(_startDate != null ? "${DateFormat('MMM d').format(_startDate!)} – ${DateFormat('d, yyyy').format(_endDate ?? DateTime.now())}" : "Select Dates", style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(width: 12),

          _buildDropdownFilter("Driver", _selectedDriverId, _driverOptions.map((d) => DropdownMenuItem(value: d['id']!, child: Text(d['name']!))).toList(), (val) {
            if (val != null) {
              setState(() => _selectedDriverId = val);
              _fetchTrips();
            }
          }),

          const SizedBox(width: 12),
          TextButton(
            onPressed: _clearFilters,
            child: const Text("Reset", style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: Color(0xFF2196F3))),
          ),
        ],
      ),
    );
  }

  Widget _buildDropdownFilter<T>(String label, T currentValue, List<DropdownMenuItem<T>> items, ValueChanged<T?> onChanged) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F4F8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
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

  // --- DESKTOP LAYOUT (2-column layout with collapsible sidebar) ---
  Widget _buildDesktopLayout() {
    return Row(
      children: [
        // Collapsible Left Column: Trips List (~280px)
        if (!_isMapExpanded) ...[
          SizedBox(
            width: 280,
            child: _buildTripListView(),
          ),
          const VerticalDivider(width: 1, thickness: 1, color: Color(0xFFEEEEEE)),
        ],

        // Center Workspace: Selected Trip Header, Map, Playback Controls, Metrics & Timeline
        Expanded(
          child: _analyzedTrip == null
              ? _buildNoTripSelected()
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Selected Trip Header Bar Above Map
                      _buildSelectedTripHeaderAboveMap(),
                      const SizedBox(height: 12),

                      // Map View with Floating Controls
                      Container(
                        height: _isMapExpanded ? 520 : 380,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: AppTheme.balancedPulidongShadow,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: Stack(
                            children: [
                              MapWidget(onMapCreated: _onMapCreated),
                              _buildMapStyleSegmentedControl(),
                              _buildInMapTopRightControls(),
                              _buildInMapBottomLeftControls(),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Playback Controls Bar
                      _buildPlaybackControlsBar(),

                      const SizedBox(height: 16),

                      // 4 Summary Metric Cards
                      Row(
                        children: [
                          Expanded(child: _buildMetricTile("Distance", "${_analyzedTrip!.totalDistanceKm.toStringAsFixed(1)} km", "Total GPS route distance.", Icons.straighten_rounded)),
                          const SizedBox(width: 10),
                          Expanded(child: _buildMetricTile("Moving time", "${(_analyzedTrip!.movingTimeSeconds / 60).toStringAsFixed(0)} min", "Time spent in motion (speed > 5 km/h).", Icons.play_circle_outline_rounded)),
                          const SizedBox(width: 10),
                          Expanded(child: _buildMetricTile("Stationary time", "${(_analyzedTrip!.stoppedTimeSeconds / 60).toStringAsFixed(0)} min", "Time spent loading & collecting waste.", Icons.pause_circle_outline_rounded)),
                          const SizedBox(width: 10),
                          Expanded(child: _buildMetricTile("Collection stops", "${_analyzedTrip!.detectedStopsCount}", "Confirmed loading & pickup locations.", Icons.pin_drop_outlined)),
                        ],
                      ),

                      if (!_isMapExpanded) ...[
                        const SizedBox(height: 16),
                        _buildRightTimelinePanel(),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildSelectedTripHeaderAboveMap() {
    final trip = _analyzedTrip!;
    final String timeStr = trip.endTime != null
        ? "${DateFormat('h:mm a').format(trip.startTime)} – ${DateFormat('h:mm a').format(trip.endTime!)}"
        : "${DateFormat('h:mm a').format(trip.startTime)} – Now";

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "${trip.driverName}  •  ${trip.truckId}",
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              const SizedBox(height: 4),
              Text(
                "${DateFormat('MMM d, yyyy').format(trip.startTime)} · $timeStr   |   ${trip.formattedVisitedAreas}",
                style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: trip.routeStatus == 'COMPLETED' ? const Color(0xFFE8F5E9) : const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                trip.routeStatus,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF2E7D32)),
              ),
            ),
            const SizedBox(width: 10),

            // Export Trip Button
            if (_currentUser?.role.toLowerCase() != 'resident') ...[
              ElevatedButton.icon(
                onPressed: () => _showExportTripMenu(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF00796B),
                  elevation: 1,
                  side: BorderSide(color: Colors.grey.shade300),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                icon: const Icon(Icons.file_download_rounded, size: 16, color: Color(0xFF00796B)),
                label: const Text("Export trip ▼", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF00796B))),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () => _confirmDeleteTrip(trip),
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFFFFEBEE),
                  foregroundColor: Colors.red.shade700,
                ),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                tooltip: "Delete Trip",
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildMapStyleSegmentedControl() {
    return Positioned(
      top: 12,
      left: 12,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.92),
          borderRadius: BorderRadius.circular(10),
          boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
        ),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => _switchMapStyle('map'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _selectedMapStyle == 'map' ? const Color(0xFF00796B) : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  "Map",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _selectedMapStyle == 'map' ? Colors.white : Colors.grey.shade800,
                  ),
                ),
              ),
            ),
            GestureDetector(
              onTap: () => _switchMapStyle('satellite'),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _selectedMapStyle == 'satellite' ? const Color(0xFF00796B) : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  "Satellite",
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _selectedMapStyle == 'satellite' ? Colors.white : Colors.grey.shade800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInMapTopRightControls() {
    return Positioned(
      top: 12,
      right: 12,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // On-demand Legend button
          GestureDetector(
            onTap: _showLegendModal,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.92),
                borderRadius: BorderRadius.circular(10),
                boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 14, color: Color(0xFF00796B)),
                  SizedBox(width: 4),
                  Text("Legend", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Expand Map button
          GestureDetector(
            onTap: () {
              setState(() {
                _isMapExpanded = !_isMapExpanded;
              });
              if (_mapboxMap != null && _analyzedTrip != null && _analyzedTrip!.points.isNotEmpty) {
                _updateMapForTrip(_analyzedTrip!);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _isMapExpanded ? const Color(0xFF00796B) : Colors.white.withOpacity(0.92),
                borderRadius: BorderRadius.circular(10),
                boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
              ),
              child: Row(
                children: [
                  Icon(
                    _isMapExpanded ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                    size: 15,
                    color: _isMapExpanded ? Colors.white : const Color(0xFF00796B),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _isMapExpanded ? "Exit Map" : "Expand map",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: _isMapExpanded ? Colors.white : const Color(0xFF1A1A1A),
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

  Widget _buildInMapBottomLeftControls() {
    return Positioned(
      bottom: 12,
      left: 12,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Recenter / Fit Route Button
          GestureDetector(
            onTap: () {
              if (_mapboxMap != null && _analyzedTrip != null && _analyzedTrip!.points.isNotEmpty) {
                _updateMapForTrip(_analyzedTrip!);
              } else if (_mapboxMap != null) {
                _mapboxMap?.setCamera(CameraOptions(
                  center: Point(coordinates: Position(121.1620, 13.9565)),
                  zoom: 13.8,
                ));
              }
            },
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.92),
                shape: BoxShape.circle,
                boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
              ),
              child: const Icon(Icons.my_location_rounded, size: 18, color: Color(0xFF1A1A1A)),
            ),
          ),
          const SizedBox(height: 6),

          // Zoom In / Zoom Out Joined Pill
          Container(
            width: 36,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.92),
              borderRadius: BorderRadius.circular(10),
              boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)],
            ),
            child: Column(
              children: [
                GestureDetector(
                  onTap: () async {
                    if (_mapboxMap != null) {
                      final state = await _mapboxMap!.getCameraState();
                      _mapboxMap!.setCamera(CameraOptions(zoom: state.zoom + 1.0));
                    }
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Icon(Icons.add_rounded, size: 18, color: Color(0xFF1A1A1A)),
                  ),
                ),
                Divider(height: 1, thickness: 1, color: Colors.grey.shade300),
                GestureDetector(
                  onTap: () async {
                    if (_mapboxMap != null) {
                      final state = await _mapboxMap!.getCameraState();
                      _mapboxMap!.setCamera(CameraOptions(zoom: state.zoom - 1.0));
                    }
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Icon(Icons.remove_rounded, size: 18, color: Color(0xFF1A1A1A)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- MOBILE LAYOUT ($440 x 956 & NARROW VIEWPORTS) ---
  Widget _buildMobileTabletLayout() {
    return Stack(
      children: [
        SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 280),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_analyzedTrip != null) ...[
                // Selected Trip Card Summary Header
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: AppTheme.balancedPulidongShadow,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "${_analyzedTrip!.driverName} • ${_analyzedTrip!.truckId}",
                              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Color(0xFF1A1A1A)),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _analyzedTrip!.formattedVisitedAreas,
                              style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F5E9),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _analyzedTrip!.routeStatus,
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Color(0xFF2E7D32)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Map Widget Container
                Container(
                  height: 320,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: AppTheme.balancedPulidongShadow,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Stack(
                      children: [
                        MapWidget(onMapCreated: _onMapCreated),
                        _buildMapStyleSegmentedControl(),
                        _buildInMapTopRightControls(),
                        _buildInMapBottomLeftControls(),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Playback Controls Bar
                _buildPlaybackControlsBar(),

                const SizedBox(height: 12),

                // 2 x 2 Compact Metrics Grid
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 1.85,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  children: [
                    _buildMetricTile("Distance", "${_analyzedTrip!.totalDistanceKm.toStringAsFixed(1)} km", "Total GPS route distance.", Icons.straighten_rounded),
                    _buildMetricTile("Moving time", "${(_analyzedTrip!.movingTimeSeconds / 60).toStringAsFixed(0)} min", "Time spent in motion.", Icons.play_circle_outline_rounded),
                    _buildMetricTile("Stationary time", "${(_analyzedTrip!.stoppedTimeSeconds / 60).toStringAsFixed(0)} min", "Time spent loading & collecting waste.", Icons.pause_circle_outline_rounded),
                    _buildMetricTile("Collection stops", "${_analyzedTrip!.detectedStopsCount}", "Confirmed loading & pickup locations.", Icons.pin_drop_outlined),
                  ],
                ),

                const SizedBox(height: 12),

                // Expandable Timeline
                _buildRightTimelinePanel(),
              ] else
                _buildNoTripSelected(),
            ],
          ),
        ),

        // Bottom Draggable Trips Sheet Overlay (Matching Reference Design)
        DraggableScrollableSheet(
          initialChildSize: 0.35,
          minChildSize: 0.12,
          maxChildSize: 0.85,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 16, offset: const Offset(0, -4))
                ],
              ),
              child: SingleChildScrollView(
                controller: scrollController,
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    // Drag Handle Bar
                    Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(3)),
                    ),
                    const SizedBox(height: 6),
                    _buildTripListViewScrollable(scrollController),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildTripListViewScrollable(ScrollController scrollController) {
    final Map<String, List<DriverTrip>> groupedTrips = _groupTripsByDate(_trips);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Colors.white,
          child: Row(
            children: [
              const Text("Trips", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF1A1A1A))),
              const Spacer(),
              if (_trips.isNotEmpty)
                Text("${_trips.length} total", style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
            ],
          ),
        ),
        const Divider(height: 1),
        if (_trips.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: Text("No GPS route recorded", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 13)),
            ),
          )
        else
          ListView.builder(
            controller: scrollController,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(12),
            itemCount: groupedTrips.keys.length,
            itemBuilder: (context, groupIdx) {
              final dateKey = groupedTrips.keys.elementAt(groupIdx);
              final tripsInGroup = groupedTrips[dateKey]!;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 4, top: 8, bottom: 8),
                    child: Text(
                      "$dateKey · ${tripsInGroup.length} trips",
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)),
                    ),
                  ),
                  ...tripsInGroup.map((trip) {
                    final bool isSelected = _selectedTrip?.tripId == trip.tripId;
                    final String timeStr = trip.endTime != null
                        ? "${DateFormat('h:mm a').format(trip.startTime)} – ${DateFormat('h:mm a').format(trip.endTime!)}"
                        : "${DateFormat('h:mm a').format(trip.startTime)} – Now";

                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      elevation: isSelected ? 3 : 0.5,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: isSelected ? const Color(0xFF00796B) : Colors.grey.shade200, width: isSelected ? 2 : 1),
                      ),
                      color: isSelected ? const Color(0xFFF2F9F9) : Colors.white,
                      child: InkWell(
                        onTap: () => _selectTrip(trip),
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFE8F5E9),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        trip.truckId,
                                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF00796B)),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFE8F5E9),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      trip.routeStatus,
                                      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: Color(0xFF2E7D32)),
                                    ),
                                  ),
                                  if (_currentUser?.role.toLowerCase() != 'resident') ...[
                                    const SizedBox(width: 6),
                                    InkWell(
                                      onTap: () => _confirmDeleteTrip(trip),
                                      child: Icon(Icons.delete_outline_rounded, size: 16, color: Colors.red.shade400),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                trip.driverName,
                                style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13.5, color: Color(0xFF1A1A1A)),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                "${DateFormat('MMM d').format(trip.startTime)} · $timeStr",
                                style: const TextStyle(fontSize: 10.5, color: Colors.grey, fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(Icons.location_on_outlined, size: 13, color: Color(0xFF00796B)),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      trip.formattedVisitedAreas,
                                      style: TextStyle(fontSize: 11, color: Colors.grey.shade800, fontWeight: FontWeight.w700),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  const Icon(Icons.access_time_rounded, size: 13, color: Color(0xFF00796B)),
                                  const SizedBox(width: 4),
                                  Text(
                                    trip.formattedDuration,
                                    style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
                                  ),
                                  const Spacer(),
                                  Text(
                                    "${trip.totalDistanceKm.toStringAsFixed(1)} km",
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF00796B)),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _buildTripListView({VoidCallback? onSelect}) {
    final Map<String, List<DriverTrip>> groupedTrips = _groupTripsByDate(_trips);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: Colors.white,
          child: const Text("Trips", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Color(0xFF1A1A1A))),
        ),
        const Divider(height: 1),
        Expanded(
          child: _trips.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.route_outlined, size: 48, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      const Text("No GPS route recorded", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 13)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: groupedTrips.keys.length,
                  itemBuilder: (context, groupIdx) {
                    final dateKey = groupedTrips.keys.elementAt(groupIdx);
                    final tripsInGroup = groupedTrips[dateKey]!;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 4, top: 8, bottom: 8),
                          child: Text(
                            "$dateKey  ·  ${tripsInGroup.length} trips",
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)),
                          ),
                        ),
                        ...tripsInGroup.map((trip) {
                          final bool isSelected = _selectedTrip?.tripId == trip.tripId;
                          final String timeStr = trip.endTime != null
                              ? "${DateFormat('h:mm a').format(trip.startTime)} – ${DateFormat('h:mm a').format(trip.endTime!)}"
                              : "${DateFormat('h:mm a').format(trip.startTime)} – Now";

                          return Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            elevation: isSelected ? 3 : 0.5,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(color: isSelected ? const Color(0xFF00796B) : Colors.grey.shade200, width: isSelected ? 2 : 1),
                            ),
                            color: isSelected ? const Color(0xFFF2F9F9) : Colors.white,
                            child: InkWell(
                              onTap: () {
                                _selectTrip(trip);
                                if (onSelect != null) onSelect();
                              },
                              borderRadius: BorderRadius.circular(14),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: const Color(0xFFE8F5E9),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              trip.truckId,
                                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF00796B)),
                                              overflow: TextOverflow.ellipsis,
                                              maxLines: 1,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: trip.routeStatus == 'COMPLETED' ? const Color(0xFFE8F5E9) : const Color(0xFFE8F5E9),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            trip.routeStatus,
                                            style: const TextStyle(
                                              fontSize: 9,
                                              fontWeight: FontWeight.w900,
                                              color: Color(0xFF2E7D32),
                                            ),
                                          ),
                                        ),
                                        if (_currentUser?.role.toLowerCase() != 'resident') ...[
                                          const SizedBox(width: 6),
                                          InkWell(
                                            onTap: () => _confirmDeleteTrip(trip),
                                            child: Icon(Icons.delete_outline_rounded, size: 16, color: Colors.red.shade400),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      trip.driverName,
                                      style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13.5, color: Color(0xFF1A1A1A)),
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      "${DateFormat('MMM d').format(trip.startTime)} · $timeStr",
                                      style: const TextStyle(fontSize: 10.5, color: Colors.grey, fontWeight: FontWeight.bold),
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        const Icon(Icons.location_on_outlined, size: 13, color: Color(0xFF00796B)),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            trip.formattedVisitedAreas,
                                            style: TextStyle(fontSize: 11, color: Colors.grey.shade800, fontWeight: FontWeight.w700),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        const Icon(Icons.access_time_rounded, size: 13, color: Color(0xFF00796B)),
                                        const SizedBox(width: 4),
                                        Text(
                                          trip.formattedDuration,
                                          style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
                                        ),
                                        const Spacer(),
                                        Text(
                                          "${trip.totalDistanceKm.toStringAsFixed(1)} km",
                                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF00796B)),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildNoTripSelected() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.map_rounded, size: 54, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          const Text("Select a trip to view recorded GPS route", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 13)),
        ],
      ),
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

  Widget _buildPlaybackControlsBar() {
    final curTime = _currentPlaybackTime;
    final startStr = _analyzedTrip != null ? DateFormat('h:mm a').format(_analyzedTrip!.startTime) : "0:00";
    final endStr = _analyzedTrip?.endTime != null ? DateFormat('h:mm a').format(_analyzedTrip!.endTime!) : "0:00";

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppTheme.balancedPulidongShadow,
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: _toggleReplay,
            icon: Icon(_isReplaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded, color: const Color(0xFF00796B), size: 36),
            tooltip: _isReplaying ? "Pause Replay" : "Play Replay",
          ),
          const SizedBox(width: 4),

          IconButton(
            onPressed: () => _jumpPlayback(-10),
            icon: const Icon(Icons.replay_10_rounded, color: Color(0xFF00796B), size: 20),
            tooltip: "Rewind 10s",
          ),

          Expanded(
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(6)),
                  child: Text(
                    DateFormat('h:mm a').format(curTime),
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900, fontFamily: 'monospace'),
                  ),
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                  ),
                  child: Slider(
                    value: _replayProgress,
                    onChanged: (val) {
                      setState(() => _replayProgress = val);
                      _updateReplayMapPosition();
                    },
                    activeColor: const Color(0xFF00796B),
                    inactiveColor: Colors.grey.shade200,
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(startStr, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)),
                    Text(endStr, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ),

          IconButton(
            onPressed: () => _jumpPlayback(10),
            icon: const Icon(Icons.forward_10_rounded, color: Color(0xFF00796B), size: 20),
            tooltip: "Forward 10s",
          ),
          const SizedBox(width: 6),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F4F8),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
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
      ),
    );
  }

  Widget _buildMetricTile(String label, String value, String tooltip, IconData icon) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: AppTheme.balancedPulidongShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: const Color(0xFF00796B), size: 18),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A))),
            ),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  Widget _buildRightTimelinePanel() {
    final trip = _analyzedTrip!;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: AppTheme.balancedPulidongShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Trip Timeline", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: Color(0xFF1A1A1A))),
          const SizedBox(height: 12),

          if (trip.events.isEmpty)
            const Padding(padding: EdgeInsets.all(12), child: Text("No recorded timeline events.", style: TextStyle(fontSize: 11, color: Colors.grey)))
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: trip.events.length,
              itemBuilder: (context, idx) {
                final evt = trip.events[idx];
                final isStart = evt.description.toLowerCase().contains("start");
                final isEnd = evt.description.toLowerCase().contains("end");
                final isStop = evt.description.toLowerCase().contains("stop");

                final Color dotColor = isStart
                    ? const Color(0xFF00796B)
                    : (isEnd ? Colors.redAccent : (isStop ? const Color(0xFFF57F17) : Colors.grey));

                return InkWell(
                  onTap: () => _seekToTimestamp(evt.timestamp),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        CircleAvatar(radius: 4.5, backgroundColor: dotColor),
                        const SizedBox(width: 12),
                        Text(DateFormat('h:mm:ss a').format(evt.timestamp), style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.grey)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            evt.description.isNotEmpty ? evt.description : evt.eventType,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: (isStart || isEnd) ? FontWeight.w900 : FontWeight.w600,
                              color: (isStart || isEnd) ? const Color(0xFF00796B) : const Color(0xFF1A1A1A),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _AestheticDateRangePicker extends StatefulWidget {
  final DateTimeRange initialRange;
  const _AestheticDateRangePicker({required this.initialRange});

  @override
  State<_AestheticDateRangePicker> createState() => _AestheticDateRangePickerState();
}

class _AestheticDateRangePickerState extends State<_AestheticDateRangePicker> {
  late DateTime _currentMonth;
  DateTime? _rangeStart;
  DateTime? _rangeEnd;
  bool _isFirstTap = true;

  @override
  void initState() {
    super.initState();
    _currentMonth = DateTime(widget.initialRange.start.year, widget.initialRange.start.month);
    _rangeStart = widget.initialRange.start;
    _rangeEnd = widget.initialRange.end;
    _isFirstTap = false;
  }

  void _onDayTapped(DateTime date) {
    final DateTime startOfDay = DateTime(date.year, date.month, date.day, 0, 0, 0);
    final DateTime endOfDay = DateTime(date.year, date.month, date.day, 23, 59, 59);

    setState(() {
      if (_isFirstTap || _rangeStart == null) {
        _rangeStart = startOfDay;
        _rangeEnd = endOfDay;
        _isFirstTap = false;
      } else {
        if (date.isBefore(_rangeStart!)) {
          _rangeStart = startOfDay;
          _isFirstTap = false;
        } else if (isSameDay(date, _rangeStart!)) {
          _rangeEnd = endOfDay;
          _isFirstTap = true;
        } else {
          _rangeEnd = endOfDay;
          _isFirstTap = true;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool hasRange = _rangeStart != null && _rangeEnd != null;
    final bool isSingleDay = hasRange && isSameDay(_rangeStart!, _rangeEnd!);

    final String dateDisplay = _rangeStart == null
        ? 'Select Date Range'
        : (isSingleDay
            ? DateFormat('MMM d, yyyy').format(_rangeStart!)
            : "${DateFormat('MMM d').format(_rangeStart!)} – ${DateFormat('MMM d, yyyy').format(_rangeEnd!)}");

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 20, spreadRadius: -2)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Select Date Range", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF00796B))),
                  const SizedBox(height: 2),
                  Text(dateDisplay, style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold)),
                ],
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: Colors.grey),
              ),
            ],
          ),
          const Divider(height: 28),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(DateFormat('MMMM yyyy').format(_currentMonth), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: Color(0xFF1A1A1A))),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left_rounded),
                    onPressed: () => setState(() => _currentMonth = DateTime(_currentMonth.year, _currentMonth.month - 1)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right_rounded),
                    onPressed: () => setState(() => _currentMonth = DateTime(_currentMonth.year, _currentMonth.month + 1)),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: const [
              Text("S", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
              Text("M", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
              Text("T", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
              Text("W", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
              Text("T", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
              Text("F", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
              Text("S", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),

          _buildDaysGrid(),

          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, null),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.grey,
                    side: const BorderSide(color: Colors.grey),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text("Cancel", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: (_rangeStart != null)
                      ? () {
                          final DateTime start = _rangeStart!;
                          final DateTime end = _rangeEnd ?? DateTime(start.year, start.month, start.day, 23, 59, 59);
                          Navigator.pop(context, DateTimeRange(start: start, end: end));
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00796B),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text("Apply Date Range", style: TextStyle(fontWeight: FontWeight.w900)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDaysGrid() {
    final firstDayOfMonth = DateTime(_currentMonth.year, _currentMonth.month, 1);
    final daysInMonth = DateTime(_currentMonth.year, _currentMonth.month + 1, 0).day;
    final leadingPadding = firstDayOfMonth.weekday % 7;

    final List<Widget> dayWidgets = [];

    for (int i = 0; i < leadingPadding; i++) {
      dayWidgets.add(const SizedBox.shrink());
    }

    for (int day = 1; day <= daysInMonth; day++) {
      final date = DateTime(_currentMonth.year, _currentMonth.month, day);
      final isStart = _rangeStart != null && isSameDay(date, _rangeStart!);
      final isEnd = _rangeEnd != null && isSameDay(date, _rangeEnd!);
      final isInRange = _rangeStart != null && _rangeEnd != null && date.isAfter(_rangeStart!) && date.isBefore(_rangeEnd!);

      dayWidgets.add(
        GestureDetector(
          onTap: () => _onDayTapped(date),
          child: Container(
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: isStart || isEnd
                  ? const Color(0xFF00796B)
                  : (isInRange ? const Color(0xFFE0F2F1) : Colors.transparent),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              "$day",
              style: TextStyle(
                fontSize: 12,
                fontWeight: isStart || isEnd || isInRange ? FontWeight.bold : FontWeight.normal,
                color: isStart || isEnd ? Colors.white : (isInRange ? const Color(0xFF00796B) : Colors.black87),
              ),
            ),
          ),
        ),
      );
    }

    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: dayWidgets,
    );
  }

  bool isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}
