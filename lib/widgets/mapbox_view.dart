import '../utils/truck_identity.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size, Visibility;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mbox show Visibility;
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart' as geo;
import '../utils/fleet_snapshot.dart';
import '../utils/fleet_status.dart';
import '../utils/marker_labels.dart';
import '../utils/tracking_telemetry.dart';
import '../services/truck_locations_feed.dart';
import 'map_style_toggle.dart';
import 'mapbox_gate.dart';
import '../utils/map_colors.dart';

class MapboxView extends StatefulWidget {
  final String mode; 
  final String? selectedTruckId;
  final VoidCallback? onTap;

  const MapboxView({super.key, required this.mode, this.selectedTruckId, this.onTap});

  @override
  State<MapboxView> createState() => _MapboxViewState();
}

class _MapboxViewState extends State<MapboxView> {
  MapboxMap? _map;
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  geo.Position? _residentPosition;
  bool _truckLayersCreated = false;
  bool _managersReady = false;
  bool _satellite = false;
  bool _firstStyleLoaded = false; // camera and live feed are set up once, not per style switch
  bool _isUpdatingMarkers = false;
  // Latest truck snapshot that arrived while a marker update was running
  // ("latest wins"): applied as soon as the in-flight update finishes.
  Map<String, Map<dynamic, dynamic>>? _pendingTrucksData;
  bool _isPulseUpdating = false;
  bool _isFollowLocked = false;
  bool _isMapActive = false;
  bool _isTargetActive = false;

  // Pulse Animation State
  Timer? _pulseTimer;
  StreamSubscription<dynamic>? _feedSubscription;
  Timer? _agingTimer;
  String? _lastMarkerSignature; // skips re-sending an unchanged marker set
  Object? _lastRawTrucks; // latest raw truck_locations, re-evaluated as it ages
  double _pulseRadius = 8.0;
  double _pulseOpacity = 0.5;
  double _pulseRadius2 = 14.0;
  double _pulseOpacity2 = 0.3;

  // Resident Pin Animation
  double _resPulseRadius = 8.0;
  double _resPulseOpacity = 0.5;

  @override
  void initState() {
    super.initState();
    _getResidentLocation();
    _startPulseAnimation();
  }

  void _startPulseAnimation() {
    _pulseTimer?.cancel();
    // 120 ms ticks (was 35 ms). Step sizes are scaled so the pulse period is
    // unchanged. The pulse values are only read by the map style layers, so no
    // widget rebuild (setState) is needed per tick.
    _pulseTimer = Timer.periodic(const Duration(milliseconds: 120), (timer) {
      if (!mounted || _map == null) return;

      _pulseRadius += 2.0;
      _pulseOpacity -= 0.05;
      if (_pulseRadius >= 28.0) {
        _pulseRadius = 8.0;
        _pulseOpacity = 0.6;
      }

      _pulseRadius2 += 2.0;
      _pulseOpacity2 -= 0.05;
      if (_pulseRadius2 >= 28.0) {
        _pulseRadius2 = 8.0;
        _pulseOpacity2 = 0.4;
      } else if (_pulseRadius2 < 8.0) {
        _pulseRadius2 = 18.0;
        _pulseOpacity2 = 0.4;
      }

      // Resident Pulse
      _resPulseRadius += 1.7;
      _resPulseOpacity -= 0.04;
      if (_resPulseRadius >= 24.0) {
        _resPulseRadius = 8.0;
        _resPulseOpacity = 0.5;
      }
      _updateMapLayers();
    });
  }

  void _updateMapLayers() async {
    if (_map == null) return;
    // Skip this tick if the previous style update is still running so platform
    // calls never queue up behind the live marker updates.
    if (_isPulseUpdating) return;
    _isPulseUpdating = true;
    try {
      final style = _map!.style;
      
      // Truck Pulses
      if (await style.styleLayerExists("trucks-pulse-layer")) {
        await style.setStyleLayerProperty("trucks-pulse-layer", "circle-radius", _pulseRadius);
        await style.setStyleLayerProperty("trucks-pulse-layer", "circle-opacity", _pulseOpacity.clamp(0.0, 1.0));
      }
      if (await style.styleLayerExists("trucks-pulse-layer-2")) {
        await style.setStyleLayerProperty("trucks-pulse-layer-2", "circle-radius", _pulseRadius2);
        await style.setStyleLayerProperty("trucks-pulse-layer-2", "circle-opacity", _pulseOpacity2.clamp(0.0, 1.0));
      }

      // Resident Pulse
      if (await style.styleLayerExists("resident-pulse-layer")) {
        await style.setStyleLayerProperty("resident-pulse-layer", "circle-radius", _resPulseRadius);
        await style.setStyleLayerProperty("resident-pulse-layer", "circle-opacity", _resPulseOpacity.clamp(0.0, 1.0));
      }
    } catch (_) {
    } finally {
      _isPulseUpdating = false;
    }
  }

  @override
  void dispose() {
    _pulseTimer?.cancel();
    _agingTimer?.cancel();
    _feedSubscription?.cancel();
    super.dispose();
  }

  Future<void> _getResidentLocation() async {
    geo.LocationPermission permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) permission = await geo.Geolocator.requestPermission();
    if (permission == geo.LocationPermission.always || permission == geo.LocationPermission.whileInUse) {
      final pos = await geo.Geolocator.getCurrentPosition();
      if (mounted) {
        setState(() => _residentPosition = pos);
        _updateResidentMarker();
      }
    }
  }

  void _updateResidentMarker() async {
    if (_map == null || _residentPosition == null) return;
    final style = _map!.style;
    final sourceId = "resident-source";
    final feature = {
      "type": "FeatureCollection",
      "features": [{
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [_residentPosition!.longitude, _residentPosition!.latitude]},
        "properties": {"name": "YOU"}
      }]
    };

    try {
      if (!(await style.styleSourceExists(sourceId))) {
        await style.addSource(GeoJsonSource(id: sourceId, data: jsonEncode(feature)));
        
        // Pulse layer for resident
        await style.addLayer(CircleLayer(
          id: "resident-pulse-layer",
          sourceId: sourceId,
          circleRadius: _resPulseRadius,
          circleColor: const Color(0xFF00796B).toARGB32(),
          circleOpacity: _resPulseOpacity,
        ));

        // Main pin layer for resident
        await style.addLayer(CircleLayer(
          id: "resident-layer",
          sourceId: sourceId,
          circleRadius: 10.0,
          circleColor: const Color(0xFF00796B).toARGB32(),
          circleStrokeWidth: 4.0,
          circleStrokeColor: Colors.white.toARGB32(),
        ));

        // Inner dot
        await style.addLayer(CircleLayer(
          id: "resident-inner-dot",
          sourceId: sourceId,
          circleRadius: 3.5,
          circleColor: Colors.white.toARGB32(),
        ));
      } else {
        await style.setStyleSourceProperty(sourceId, "data", jsonEncode(feature));
      }
    } catch (_) {}
  }

  double _getResponsiveZoom(BuildContext context) {
    final double width = MediaQuery.of(context).size.width;
    if (width < 600) {
      return 12.8; // Mobile / iOS / Android: comfortable wider view of Balintawak & surrounding areas
    } else if (width < 1024) {
      return 13.4; // Tablet: balanced view
    } else {
      return 13.8; // Desktop / Web: crisp wider view
    }
  }

  Future<void> _enableMapGestures() async {
    if (_map == null) return;
    try {
      await _map!.gestures.updateSettings(GesturesSettings(
        scrollEnabled: true,
        rotateEnabled: true,
        pitchEnabled: true,
        doubleTapToZoomInEnabled: true,
        quickZoomEnabled: true,
        pinchToZoomEnabled: true,
      ));
    } catch (e) {
      debugPrint("Map gesture error: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final Position balintawakCenter = Position(121.1620, 13.9565);
    final double responsiveZoom = _getResponsiveZoom(context);

    return Stack(
      children: [
        MapboxGate(child: MapWidget(
          key: const ValueKey("mapbox_map"),
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
          },
          onMapCreated: (map) async {
            _map = map;
            await _enableMapGestures();
          },
          onStyleLoadedListener: (data) async {
             if (_map == null) return;
             try {
               await _map!.location.updateSettings(LocationComponentSettings(enabled: false, pulsingEnabled: false));
             } catch (_) {}
             
             await _enableMapGestures();

             if (_residentPosition != null) {
               _updateResidentMarker();
             }
             if (mounted) setState(() => _managersReady = true);

             if (!_firstStyleLoaded) {
               _firstStyleLoaded = true;
               // Initial camera start position centered on Barangay Balintawak, Lipa City, Batangas
               _map?.setCamera(CameraOptions(center: Point(coordinates: balintawakCenter), zoom: responsiveZoom));
               _setupFirebaseSync();
             } else {
               // After a Map | Satellite switch the truck layers are gone: draw them again.
               _truckLayersCreated = false;
               _publishLiveMarkers();
             }
          },
          viewport: CameraViewportState(center: Point(coordinates: balintawakCenter), zoom: responsiveZoom),
        )),
        Positioned(
          top: 10,
          right: 10,
          child: MapStyleToggle(
            satellite: _satellite,
            compact: true,
            onChanged: (bool v) {
              setState(() => _satellite = v);
              MapStyles.apply(_map, satellite: v);
            },
          ),
        ),
        if (widget.mode == 'dashboard')
          Positioned(
            bottom: 10,
            right: 10,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildMiniMapAction(
                  icon: _isFollowLocked ? Icons.gps_fixed_rounded : Icons.gps_not_fixed_rounded,
                  isActive: _isFollowLocked || _isTargetActive,
                  onTap: () async {
                    setState(() {
                      _isFollowLocked = !_isFollowLocked;
                      _isTargetActive = true;
                    });
                    if (_isFollowLocked && _residentPosition != null) {
                      _map?.setCamera(CameraOptions(center: Point(coordinates: Position(_residentPosition!.longitude, _residentPosition!.latitude)), zoom: 15.5));
                    } else {
                      await _enableMapGestures();
                    }
                    Future.delayed(const Duration(seconds: 2), () {
                      if (mounted) setState(() => _isTargetActive = false);
                    });
                  },
                ),
                const SizedBox(height: 8),
                _buildMiniMapAction(
                  icon: Icons.map_outlined,
                  isActive: _isMapActive,
                  onTap: () async {
                    setState(() => _isMapActive = true);
                    _map?.setCamera(CameraOptions(center: Point(coordinates: balintawakCenter), zoom: responsiveZoom));
                    await _enableMapGestures();
                    Future.delayed(const Duration(seconds: 2), () {
                      if (mounted) setState(() => _isMapActive = false);
                    });
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildMiniMapAction({required IconData icon, required VoidCallback onTap, bool isActive = false}) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final double btnSize = (screenWidth * 0.12).clamp(40.0, 48.0);
    final double iconSize = (screenWidth * 0.06).clamp(20.0, 24.0);

    return StatefulBuilder(
      builder: (context, setInnerState) {
        bool isHovered = false;
        return MouseRegion(
          onEnter: (_) => setInnerState(() => isHovered = true),
          onExit: (_) => setInnerState(() => isHovered = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: btnSize,
              height: btnSize,
              decoration: BoxDecoration(
                color: isActive 
                    ? const Color(0xFF00796B) 
                    : (isHovered ? const Color(0xFFE0F2F1) : Colors.white),
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Colors.black.withAlpha(20), blurRadius: 8, offset: const Offset(0, 2))],
                border: Border.all(
                  color: isActive ? const Color(0xFF00796B) : (isHovered ? const Color(0xFF00796B).withOpacity(0.3) : Colors.transparent),
                  width: 1.5,
                ),
              ),
              child: Icon(
                icon, 
                color: isActive ? Colors.white : (isHovered ? const Color(0xFF00796B) : const Color(0xFF1A1A1A)), 
                size: iconSize
              ),
            ),
          ),
        );
      },
    );
  }

  void _setupFirebaseSync() {
    _feedSubscription?.cancel();
    _feedSubscription = TruckLocationsFeed.shared().events.listen((event) {
      final Object? raw = event.snapshot.value;
      TrackingTelemetry.onTruckLocations(raw, source: 'map_dashboard'); // dev-only, no-op in production
      _lastRawTrucks = event.snapshot.exists ? raw : null;
      _publishLiveMarkers();
    });
    // A driver that stops reporting sends no further events, so freshness is
    // re-evaluated on a timer too; otherwise the marker would never age out.
    _agingTimer?.cancel();
    _agingTimer = Timer.periodic(const Duration(seconds: 15), (_) => _publishLiveMarkers());
  }

  void _publishLiveMarkers() {
    // Same snapshot as the Admin/Resident Active Fleet cards: online flag, not
    // OFFLINE/COMPLETED/FINISHED, fresh, within the session limit, one per driver.
    final FleetSnapshot fleet = FleetSnapshot.derive(_lastRawTrucks, requireCoords: true);
    final Map<String, Map<dynamic, dynamic>> trucks = {
      for (final LiveTruck t in fleet.trucks) t.nodeKey: t.node,
    };
    final List<String> parts = trucks.entries
        .map((MapEntry<String, Map<dynamic, dynamic>> e) =>
            '${e.key}|${e.value['latitude']}|${e.value['longitude']}|${e.value['status']}|${e.value['truck_id']}|${e.value['driver_name']}|${FleetStatus.isGpsFresh(e.value)}')
        .toList()
      ..sort();
    final String signature = parts.join(';');
    if (_truckLayersCreated && signature == _lastMarkerSignature) return;
    _lastMarkerSignature = signature;
    // An empty or removed node yields an empty map so stale markers are cleared.
    _updateTruckMarkers(trucks);
  }

  /// Current zoom, for fanning out overlapping truck markers (default when unavailable).
  Future<double> _markerZoom() async {
    try {
      return (await _map?.getCameraState())?.zoom ?? 14.5;
    } catch (_) {
      return 14.5;
    }
  }

  void _updateTruckMarkers(Map<String, Map<dynamic, dynamic>> trucksData) async {
    if (_map == null || !_managersReady) return;
    if (_isUpdatingMarkers) {
      // Latest wins: remember only the newest snapshot instead of dropping it.
      if (_pendingTrucksData != null) TrackingTelemetry.onCoalesced(source: 'map_dashboard');
      _pendingTrucksData = trucksData;
      return;
    }
    _isUpdatingMarkers = true;
    final Stopwatch? telemetryClock = TrackingTelemetry.enabled ? (Stopwatch()..start()) : null;
    final String sourceId = "trucks-source";
    final String layerId = "trucks-layer";

    final List<Map<String, dynamic>> markerFeatures = trucksData.entries.map((e) {
      final Object? tid = e.value['truck_id'];
      final String truckLabelId = (tid != null && tid != "Unknown") ? tid.toString() : e.key;
      return <String, dynamic>{
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [e.value['longitude'], e.value['latitude']]},
        "properties": {
          "type": "TRUCK",
          ...TruckIdentity.markerProps(truckLabelId, (e.value['status'] ?? "ACTIVE").toString()),
          "truckId": truckLabelId,
          "nodeKey": e.key,
          "driverName": (e.value['driver_name'] ?? '').toString(),
          "tripId": (e.value['current_session'] ?? '').toString(),
          "status": (e.value['status'] ?? "ACTIVE").toString().toUpperCase(),
          "label": MarkerLabels.forNode(e.value, truckId: truckLabelId),
        }
      };
    }).toList();
    // True coordinates are kept; overlapping trucks share one combined label.
    MarkerLabels.fanOutOverlapping(markerFeatures, zoom: await _markerZoom());
    final featureCollection = {
      "type": "FeatureCollection",
      "features": markerFeatures,
    };

    final statusColorExpr = [
      "match", ["get", "status"],
      "IDLE", mapColor(Colors.orange),
      "FULL", mapColor(Colors.redAccent),
      "FINISHED", mapColor(Colors.blueAccent),
      "COMPLETED", mapColor(Colors.blueAccent),
      mapColor(Colors.green)
    ];

    try {
      final style = _map!.style;
      if (!_truckLayersCreated || !(await style.styleLayerExists(layerId))) {
        try { await style.removeStyleLayer(layerId); } catch (_) {}
        try { await style.removeStyleLayer("trucks-pulse-layer"); } catch (_) {}
        try { await style.removeStyleLayer("trucks-pulse-layer-2"); } catch (_) {}
        try { await style.removeStyleLayer("trucks-label-layer"); } catch (_) {}
        try { await style.removeStyleSource(sourceId); } catch (_) {}
        await style.addSource(GeoJsonSource(id: sourceId, data: jsonEncode(featureCollection)));

        // PULSE LAYERS
        await style.addLayer(CircleLayer(
          id: "trucks-pulse-layer", 
          sourceId: sourceId, 
          circleRadius: _pulseRadius, 
          circleColor: Colors.green.toARGB32(), 
          circleOpacity: _pulseOpacity
        ));
        await style.addLayer(CircleLayer(
          id: "trucks-pulse-layer-2", 
          sourceId: sourceId, 
          circleRadius: _pulseRadius2, 
          circleColor: Colors.green.toARGB32(), 
          circleOpacity: _pulseOpacity2
        ));

        await style.setStyleLayerProperty("trucks-pulse-layer", "circle-color", statusColorExpr);
        await style.setStyleLayerProperty("trucks-pulse-layer-2", "circle-color", statusColorExpr);

        await style.addLayer(CircleLayer(
          id: layerId, 
          sourceId: sourceId, 
          circleRadius: 10.0, // Slightly larger for better visibility
          circleColor: Colors.green.toARGB32(), 
          circleStrokeWidth: 4.0, 
          circleStrokeColor: Colors.white.toARGB32(), 
          visibility: mbox.Visibility.VISIBLE
        ));
                // Identity colour = truck id (stable everywhere); ring = operational status.
        await style.setStyleLayerProperty(layerId, "circle-color", ["get", "truckColor"]);
        await style.setStyleLayerProperty(layerId, "circle-stroke-color", ["get", "statusColor"]);
        await style.setStyleLayerProperty(layerId, "circle-stroke-width", 4.5);
        await style.setStyleLayerProperty(layerId, "circle-radius", ["to-number", ["coalesce", ["get", "radius"], "10"]]);
        await style.setStyleLayerProperty(layerId, "circle-sort-key", ["to-number", ["coalesce", ["get", "sortKey"], "90"]]);
        
        // Inner dot for premium look
        await style.addLayer(CircleLayer(
          id: "trucks-inner-dot", 
          sourceId: sourceId, 
          circleRadius: 3.5, 
          circleColor: Colors.white.toARGB32(),
          circleSortKey: 10.0
        ));
        // Driver - truck - status label (overlapping trucks share one combined label).
        try { await style.removeStyleLayer("trucks-label-layer"); } catch (_) {}
        await style.addLayer(SymbolLayer(
          id: "trucks-label-layer",
          sourceId: sourceId,
          textSize: 11.0,
          textColor: Colors.black87.toARGB32(),
          textHaloColor: Colors.white.toARGB32(),
          textHaloWidth: 2.5,
          textAnchor: TextAnchor.BOTTOM,
          textOffset: [0.0, -1.6],
          textAllowOverlap: true,
          textJustify: TextJustify.CENTER,
          symbolSortKey: 100.0,
        ));
        await style.setStyleLayerProperty("trucks-label-layer", "text-field", ["get", "label"]);
        if (mounted) setState(() => _truckLayersCreated = true);
      } else {
        await style.setStyleSourceProperty(sourceId, "data", jsonEncode(featureCollection));
        await style.setStyleLayerProperty("trucks-pulse-layer", "circle-color", statusColorExpr);
        await style.setStyleLayerProperty("trucks-pulse-layer-2", "circle-color", statusColorExpr);
      }
    } catch (e) {
      debugPrint("Map Error: $e");
      if (mounted) setState(() => _truckLayersCreated = false);
    } finally {
      _isUpdatingMarkers = false;
      if (telemetryClock != null) {
        TrackingTelemetry.onMarkersRendered(source: 'map_dashboard', ms: telemetryClock.elapsedMilliseconds);
      }
      final Map<String, Map<dynamic, dynamic>>? pending = _pendingTrucksData;
      _pendingTrucksData = null;
      if (pending != null && mounted) _updateTruckMarkers(pending);
    }
  }
}
