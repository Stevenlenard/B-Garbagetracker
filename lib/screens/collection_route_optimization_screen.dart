import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chatbot/fleet_snapshot.dart';
import '../services/service_area_service.dart';
import '../utils/collection_status.dart';
import '../utils/collection_visits.dart';
import '../utils/history_playback.dart';
import '../utils/map_colors.dart';
import '../utils/path_comparison.dart';
import '../utils/truck_identity.dart';
import '../widgets/map_style_toggle.dart';
import '../widgets/mapbox_gate.dart';
import '../utils/map_home.dart';

/// Records the screen works on. Everything is read-only.
class CollectionData {
  const CollectionData({
    required this.areas,
    required this.trips,
    required this.weeklyProgress,
    this.areasFromDefaults = false,
    this.areaIdToName = const <String, String>{},
  });

  /// `puroks` record id -> area name (weekly-progress records may be keyed by id).
  final Map<String, String> areaIdToName;

  final List<AreaGeofence> areas;

  /// `driver_routes` trips of the analysed window (push-key scoped).
  final Map trips;

  /// `weekly_collection_progress` (activity only, never counted as collection).
  final Object? weeklyProgress;
  final bool areasFromDefaults;
}

abstract class CollectionDataSource {
  /// Emits whenever the underlying records change. One subscription per screen.
  Stream<CollectionData> watch({required DateTime start, required DateTime end});
}

/// Firebase implementation: `puroks` once, `driver_routes` (push keys of the window) and
/// `weekly_collection_progress` live. Listeners end when the stream subscription is cancelled.
class FirebaseCollectionDataSource implements CollectionDataSource {
  FirebaseCollectionDataSource([FirebaseDatabase? db]) : _db = db;
  final FirebaseDatabase? _db;
  FirebaseDatabase get _database => _db ?? FirebaseDatabase.instance;

  static AreaGeofence toGeofence(ServiceArea a) => AreaGeofence(
        name: ServiceAreaService.canonicalizeAreaName(a.name) ?? a.name,
        lat: a.entranceLat,
        lng: a.entranceLng,
        radiusM: a.radius,
        polygon: a.boundaryGeometry,
        isTruckStop: a.isTruckStop && a.verificationStatus.toUpperCase() == 'VERIFIED',
      );

  @override
  Stream<CollectionData> watch({required DateTime start, required DateTime end}) {
    late StreamController<CollectionData> c;
    StreamSubscription<DatabaseEvent>? trips;
    StreamSubscription<DatabaseEvent>? weekly;
    List<AreaGeofence>? areas;
    final Map<String, String> ids = <String, String>{};
    bool defaults = false;
    Map tripMap = const <Object?, Object?>{};
    Object? weeklyValue;
    bool tripsLoaded = false;

    void emit() {
      if (areas != null && tripsLoaded && !c.isClosed) {
        c.add(CollectionData(areas: areas!, trips: tripMap, weeklyProgress: weeklyValue, areasFromDefaults: defaults, areaIdToName: ids));
      }
    }

    c = StreamController<CollectionData>(
      onListen: () async {
        final List<AreaGeofence> list = <AreaGeofence>[];
        try {
          final DataSnapshot snap = await _database.ref('puroks').get().timeout(const Duration(seconds: 10));
          if (snap.value is Map) {
            (snap.value as Map).forEach((Object? k, Object? v) {
              if (v is! Map) return;
              try {
                final Map<String, dynamic> m = Map<String, dynamic>.from(v);
                m['id'] ??= k.toString();
                final AreaGeofence g = toGeofence(ServiceArea.fromJson(m));
                list.add(g);
                ids[k.toString()] = g.name;
                ids[m['id'].toString()] = g.name;
              } catch (_) {}
            });
          }
        } catch (e) {
          debugPrint('[COLLECTION] areas could not be read: $e');
        }
        defaults = list.isEmpty;
        areas = defaults ? ServiceAreaService.defaultServiceAreas.map(toGeofence).toList() : list;
        final (String from, String to) = HistoryDates.firebaseKeyBounds(start, end);
        trips = _database.ref('driver_routes').orderByKey().startAt(from).endAt(to).onValue.listen(
          (DatabaseEvent e) {
            tripMap = e.snapshot.value is Map ? e.snapshot.value as Map : const <Object?, Object?>{};
            tripsLoaded = true;
            emit();
          },
          onError: (Object e) => c.addError(e),
        );
        weekly = _database.ref('weekly_collection_progress').onValue.listen((DatabaseEvent e) {
          weeklyValue = e.snapshot.value;
          emit();
        }, onError: (_) {});
      },
      onCancel: () async {
        await trips?.cancel();
        await weekly?.cancel();
      },
    );
    return c.stream;
  }
}

/// Status colours (always shown together with a symbol and a text label).
class CollectionColors {
  static const Color recent = Color(0xFF2E7D32);
  static const Color aging = Color(0xFFD32F2F);
  static const Color stale = Color(0xFFB71C1C);
  static const Color partial = Color(0xFFEF6C00);
  static const Color unknown = Color(0xFF607D8B);

  static Color of(CollectionBand b) => switch (b) {
        CollectionBand.recent => recent,
        CollectionBand.aging => aging,
        CollectionBand.stale => stale,
        CollectionBand.partialOnly => partial,
        CollectionBand.unknown => unknown,
      };
}

/// Collection Route Optimization: collection-status markers (recency of verified truck visits)
/// plus, for Drivers and Admins, a comparison of recorded paths that served the same areas.
/// No Mapbox routing service is used; the map only displays.
class CollectionRouteOptimizationScreen extends StatefulWidget {
  const CollectionRouteOptimizationScreen({
    super.key,
    required this.role,
    this.userId,
    this.isEmbedded = false,
    this.onBack,
    this.source,
    this.clock,
    this.config = const CollectionStatusConfig(),
    this.showMap = true,
    this.headerAccessory,
    this.liveFleet,
    this.showHeader = true,
  });

  /// 'driver', 'resident', 'admin' (from the signed-in account; never switchable here) or 'public'
  /// (landing page, not signed in: view-only like a resident).
  final String role;
  final String? userId;
  final bool isEmbedded;
  final VoidCallback? onBack;
  final CollectionDataSource? source;
  final DateTime Function()? clock;
  final CollectionStatusConfig config;
  final bool showMap;

  /// Shown at the right of the header when embedded in a dashboard panel (e.g. the
  /// "Map | Route plan" switch of the role's map panel).
  final Widget? headerAccessory;

  /// Trucks online right now, drawn over the status map. Defaults to the shared live feed
  /// (same online rules as the live map); tests with their own [source] get none.
  final Stream<FleetSnapshot>? liveFleet;

  /// False when the host page already has a header (public landing page).
  final bool showHeader;

  @override
  State<CollectionRouteOptimizationScreen> createState() => _CollectionRouteOptimizationScreenState();
}

class _CollectionRouteOptimizationScreenState extends State<CollectionRouteOptimizationScreen> with WidgetsBindingObserver {
  static const String _refPathKey = 'collection_reference_path_v1';

  StreamSubscription<CollectionData>? _sub;
  DateTime? _subscribedDay;
  bool _analysedOnce = false;
  Timer? _debounce;
  Timer? _midnight;
  CollectionData? _data;
  Object? _error;
  DateTime? _lastDataAt;
  List<CollectionVisit> _visits = const <CollectionVisit>[];
  Map<String, List<AreaActivity>> _activity = const <String, List<AreaActivity>>{};
  List<AreaCollectionStatus> _statuses = const <AreaCollectionStatus>[];
  PathAnalysis? _paths;
  String _areaFilter = 'All areas';
  StatusFilter _statusFilter = StatusFilter.all;
  String? _selectedArea;
  String? _highlightTripId;
  String? _referenceTripId;
  String? _hoverArea;

  MapboxMap? _map;

  String get _role => widget.role.toLowerCase();
  bool get _viewOnly => _role == 'resident' || _role == 'public';
  bool get _canComparePaths => _role == 'driver' || _role == 'admin';
  bool get _canSelectReference => _role == 'driver';
  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscribe();
    _loadReference();
    final Stream<FleetSnapshot>? fleet = widget.liveFleet ?? (widget.source == null ? LiveFleet.watch() : null);
    _fleetSub = fleet?.listen((FleetSnapshot f) {
      _fleet = f;
      if (mounted) setState(() {});
      _updateLiveTrucks();
    }, onError: (Object _) {});
  }

  StreamSubscription<FleetSnapshot>? _fleetSub;
  FleetSnapshot? _fleet;
  bool _satellite = false;

  Widget _styleToggle({required bool compact}) => MapStyleToggle(
        satellite: _satellite,
        compact: compact,
        onChanged: (bool v) {
          setState(() => _satellite = v);
          MapStyles.apply(_map, satellite: v); // the style-loaded handler redraws every layer
        },
      );

  static const String _liveSource = 'collection-live-trucks';

  /// Live trucks over the purok markers: fill = the truck's own colour, ring = status, label
  /// "GT-007 · ACTIVE" (same look as the live map). Driver names are not shown here.
  Future<void> _updateLiveTrucks() async {
    final MapboxMap? map = _map;
    if (map == null) return;
    try {
      final StyleManager style = map.style;
      if (!await style.styleSourceExists(_areaSource)) return; // drawn after the purok layers
      final List<LiveTruck> trucks = _fleet?.trucks ?? const <LiveTruck>[];
      final String geo = jsonEncode(<String, Object>{
        'type': 'FeatureCollection',
        'features': <Object>[
          for (final LiveTruck t in trucks)
            <String, Object>{
              'type': 'Feature',
              'geometry': <String, Object>{'type': 'Point', 'coordinates': <double>[t.lng, t.lat]},
              'properties': <String, Object>{
                'label': '${t.id} · ${t.status}',
                'color': TruckIdentity.hex(t.id),
                'statusColor': TruckIdentity.statusHex(t.status),
              },
            },
        ],
      });
      if (await style.styleSourceExists(_liveSource)) {
        await style.setStyleSourceProperty(_liveSource, 'data', geo);
        return;
      }
      await style.addSource(GeoJsonSource(id: _liveSource, data: geo));
      await style.addLayer(CircleLayer(id: 'collection-live-halo', sourceId: _liveSource, circleRadius: 18, circleOpacity: 0.22));
      await style.setStyleLayerProperty('collection-live-halo', 'circle-color', <Object>['get', 'statusColor']);
      await style.addLayer(CircleLayer(id: 'collection-live-dot', sourceId: _liveSource, circleRadius: 9, circleStrokeWidth: 3.5));
      await style.setStyleLayerProperty('collection-live-dot', 'circle-color', <Object>['get', 'color']);
      await style.setStyleLayerProperty('collection-live-dot', 'circle-stroke-color', <Object>['get', 'statusColor']);
      await style.addLayer(CircleLayer(id: 'collection-live-core', sourceId: _liveSource, circleRadius: 3, circleColor: Colors.white.toARGB32()));
      await style.addLayer(SymbolLayer(
        id: 'collection-live-label',
        sourceId: _liveSource,
        textSize: 12.5,
        textHaloColor: Colors.white.toARGB32(),
        textHaloWidth: 3,
        textAnchor: TextAnchor.BOTTOM,
        textOffset: <double>[0.0, -1.4],
        textAllowOverlap: true,
      ));
      await style.setStyleLayerProperty('collection-live-label', 'text-field', <Object>['get', 'label']);
      await style.setStyleLayerProperty('collection-live-label', 'text-color', <Object>['get', 'statusColor']);
    } catch (e) {
      debugPrint('[COLLECTION] live trucks skipped: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    _fleetSub?.cancel();
    _debounce?.cancel();
    _midnight?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onClockBoundary(); // days may have passed
  }

  void _subscribe() {
    _sub?.cancel();
    final DateTime now = _now();
    final DateTime today = HistoryDates.manilaToday(now);
    _subscribedDay = today;
    final CollectionDataSource src = widget.source ?? FirebaseCollectionDataSource();
    _sub = src.watch(start: today.subtract(Duration(days: widget.config.windowDays)), end: today).listen((CollectionData d) {
      _data = d;
      _lastDataAt = _now();
      _error = null;
      // driver_routes changes with every GPS point while trucks are out: analyse at most every 2 s.
      _debounce?.cancel();
      if (!_analysedOnce) {
        _analysedOnce = true;
        _analyse(); // first load at once
      } else {
        _debounce = Timer(const Duration(seconds: 2), _analyse);
      }
    }, onError: (Object e) {
      if (mounted) setState(() => _error = e);
    });
    _scheduleMidnight();
  }

  void _scheduleMidnight() {
    _midnight?.cancel();
    final DateTime now = _now();
    final Duration wait = CollectionStatus.nextBoundary(now).difference(now) + const Duration(seconds: 1);
    _midnight = Timer(wait, _onClockBoundary);
  }

  /// Time passes without new data: recompute the bands (cheap). A new Manila day also moves
  /// the analysed window (one re-subscription per day, not per resume).
  void _onClockBoundary() {
    if (!mounted) return;
    if (HistoryDates.manilaToday(_now()) != _subscribedDay) {
      _analysedOnce = false;
      _subscribe();
    } else {
      _scheduleMidnight();
    }
    setState(_computeStatuses);
    _updateMap();
  }

  void _analyse() {
    final CollectionData? d = _data;
    if (d == null || !mounted) return;
    final DateTime today = HistoryDates.manilaToday(_now());
    final DateTime start = today.subtract(Duration(days: widget.config.windowDays));
    final VisitSummary v = CollectionVisits.detect(trips: d.trips, areas: d.areas, start: start, end: today);
    final Set<String> names = d.areas.where((AreaGeofence a) => a.isTruckStop).map((AreaGeofence a) => a.name).toSet();
    final Map<String, String> byKey = <String, String>{
      for (final MapEntry<String, String> e in d.areaIdToName.entries)
        if (names.contains(e.value)) e.key: e.value,
      for (final String n in names) n: n,
      for (final String n in names) n.replaceAll('/', '_'): n,
    };
    _visits = v.visits;
    _activity = CollectionStatus.activityFromWeeklyProgress(
        d.weeklyProgress, (String k) => byKey[k] ?? byKey[ServiceAreaService.canonicalizeAreaName(k) ?? '']);
    if (_canComparePaths) {
      Map trips = d.trips;
      if (_role == 'driver' && widget.userId != null) {
        // Drivers compare their own recorded trips (same scope as their Route History).
        trips = <Object?, Object?>{
          for (final MapEntry<dynamic, dynamic> e in d.trips.entries)
            if (e.value is Map && (e.value['driver_id'] ?? e.value['driverId'])?.toString() == widget.userId) e.key: e.value,
        };
      }
      _paths = PathComparisonEngine.analyze(trips: trips, areas: d.areas, start: start, end: today);
    }
    setState(_computeStatuses);
    _updateMap();
  }

  void _computeStatuses() {
    final CollectionData? d = _data;
    if (d == null) return;
    final int nowMs = _now().millisecondsSinceEpoch;
    _statuses = d.areas.where((AreaGeofence a) => a.isTruckStop).map((AreaGeofence a) {
      return CollectionStatus.evaluate(
        area: a.name,
        confirmedVisits: _visits,
        activity: _activity[a.name] ?? const <AreaActivity>[],
        nowMs: nowMs,
        config: widget.config,
      );
    }).toList()
      ..sort((AreaCollectionStatus a, AreaCollectionStatus b) => a.area.compareTo(b.area));
  }

  List<AreaCollectionStatus> get _visible => _statuses
      .where((AreaCollectionStatus s) => (_areaFilter == 'All areas' || s.area == _areaFilter) && s.matches(_statusFilter, widget.config))
      .toList();

  Future<void> _loadReference() async {
    if (!_canSelectReference) return;
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      if (mounted) setState(() => _referenceTripId = p.getString(_refPathKey));
    } catch (_) {}
  }

  Future<void> _selectReference(RecordedPath path) async {
    setState(() {
      _referenceTripId = path.tripId;
      _highlightTripId = path.tripId;
    });
    _updateMap();
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(_refPathKey, path.tripId); // this device only; no shared record is changed
    } catch (_) {}
  }

  RecordedPath? _pathById(String? id) {
    if (id == null || _paths == null) return null;
    for (final RecordedPath p in _paths!.validPaths) {
      if (p.tripId == id) return p;
    }
    return null;
  }

  // ---------------------------------------------------------------- map (display only)

  static const String _areaSource = 'collection-areas';
  static const String _pathSource = 'collection-recorded-path';

  Future<void> _onMapCreated(MapboxMap map) async {
    _map = map;
    _updateMap();
  }

  String _markerLabel(AreaCollectionStatus s) =>
      s.daysSince != null && s.band != CollectionBand.recent ? '${s.area} · ${s.daysSince}d' : s.area;

  /// Area markers as map layers (colours as CSS strings: they render on Android AND Web).
  Future<void> _updateMap() async {
    final MapboxMap? map = _map;
    final CollectionData? d = _data;
    if (map == null || d == null) return;
    try {
      final StyleManager style = map.style;
      final List<Map<String, Object>> features = <Map<String, Object>>[];
      for (final AreaCollectionStatus s in _visible) {
        final AreaGeofence? a = d.areas.where((AreaGeofence g) => g.name == s.area).firstOrNull;
        if (a == null) continue;
        features.add(<String, Object>{
          'type': 'Feature',
          'geometry': <String, Object>{
            'type': 'Point',
            'coordinates': <double>[a.lng, a.lat]
          },
          'properties': <String, Object>{
            'name': s.area,
            'label': _markerLabel(s),
            'color': mapColor(CollectionColors.of(s.band)),
            'radius': s.area == _selectedArea ? 13 : 9,
          },
        });
      }
      final String areas = jsonEncode(<String, Object>{'type': 'FeatureCollection', 'features': features});
      if (await style.styleSourceExists(_areaSource)) {
        await style.setStyleSourceProperty(_areaSource, 'data', areas);
      } else {
        await style.addSource(GeoJsonSource(id: _areaSource, data: areas));
      }
      if (!await style.styleLayerExists('collection-area-halo')) {
        await style.addLayer(CircleLayer(id: 'collection-area-halo', sourceId: _areaSource, circleRadius: 20, circleOpacity: 0.18));
        await style.setStyleLayerProperty('collection-area-halo', 'circle-color', <Object>['get', 'color']);
        await style.addLayer(CircleLayer(
          id: 'collection-area-dot',
          sourceId: _areaSource,
          circleRadius: 9,
          circleStrokeWidth: 3,
          circleStrokeColor: Colors.white.toARGB32(),
        ));
        await style.setStyleLayerProperty('collection-area-dot', 'circle-color', <Object>['get', 'color']);
        await style.setStyleLayerProperty('collection-area-dot', 'circle-radius', <Object>[
          'to-number',
          <Object>['get', 'radius']
        ]);
        await style.addLayer(SymbolLayer(
          id: 'collection-area-label',
          sourceId: _areaSource,
          textSize: 12.5,
          textHaloColor: Colors.white.toARGB32(),
          textHaloWidth: 2.5,
          textAnchor: TextAnchor.TOP,
          textOffset: <double>[0.0, 1.3],
          textAllowOverlap: false,
        ));
        await style.setStyleLayerProperty('collection-area-label', 'text-field', <Object>['get', 'label']);
        await style.setStyleLayerProperty('collection-area-label', 'text-color', <Object>['get', 'color']);
      }

      final RecordedPath? path = _pathById(_highlightTripId);
      final String geo = jsonEncode(<String, Object>{
        'type': 'FeatureCollection',
        'features': path == null
            ? <Object>[]
            : <Object>[
                <String, Object>{
                  'type': 'Feature',
                  'geometry': <String, Object>{'type': 'LineString', 'coordinates': path.coordinates},
                  'properties': <String, Object>{},
                }
              ],
      });
      if (await style.styleSourceExists(_pathSource)) {
        await style.setStyleSourceProperty(_pathSource, 'data', geo);
      } else {
        await style.addSource(GeoJsonSource(id: _pathSource, data: geo));
        await style.addLayer(LineLayer(
          id: 'collection-recorded-path-line',
          sourceId: _pathSource,
          lineColor: const Color(0xFF6A4CE0).toARGB32(),
          lineWidth: 5,
          lineOpacity: 0.9,
        ));
      }
      await _updateLiveTrucks(); // keep the live trucks on top of the purok markers
    } catch (e) {
      debugPrint('[COLLECTION] map update skipped: $e');
    }
  }

  Future<void> _focusArea(String area) async {
    final AreaGeofence? a = _data?.areas.where((AreaGeofence g) => g.name == area).firstOrNull;
    if (_map == null || a == null) return;
    try {
      await _map!.flyTo(
        CameraOptions(center: Point(coordinates: Position(a.lng, a.lat)), zoom: 15.4),
        MapAnimationOptions(duration: 700),
      );
    } catch (_) {}
  }

  // ---------------------------------------------------------------- UI

  static const Color _teal = Color(0xFF00796B);
  static const Color _ink = Color(0xFF1A2B3C);
  static const Color _muted = Color(0xFF64748B);
  static const Color _line = Color(0xFFE6EBF0);

  /// Summary panel (desktop): expanded or compact, and where it was dragged to.
  bool _panelExpanded = false;
  double _panelLeft = 16;
  double _panelBottom = 16;

  void _selectArea(String area) {
    setState(() => _selectedArea = _selectedArea == area ? null : area);
    _updateMap();
    if (_selectedArea != null) _focusArea(area);
  }

  @override
  Widget build(BuildContext context) {
    final bool narrowHeader = MediaQuery.sizeOf(context).width < 600;
    final Widget body;
    if (_data == null) {
      body = Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Collection records could not be loaded: $_error', textAlign: TextAlign.center),
              )
            : const CircularProgressIndicator(color: _teal),
      );
    } else if (!widget.showMap) {
      body = Column(children: <Widget>[
        Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4), child: _toolbar(compact: narrowHeader)),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: _panelContent()),
        ),
      ]);
    } else {
      body = LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) => c.maxWidth >= 900 ? _desktopLayout(c) : _mobileLayout(),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FA),
      appBar: widget.showHeader ? _appBar(narrowHeader) : null,
      body: body,
    );
  }

  PreferredSizeWidget _appBar(bool narrowHeader) {
    final bool hasBack = !widget.isEmbedded || widget.onBack != null;
    return AppBar(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      foregroundColor: _ink,
      elevation: 0,
      toolbarHeight: 66,
      automaticallyImplyLeading: !widget.isEmbedded,
      leading: widget.isEmbedded && widget.onBack != null
          ? IconButton(icon: const Icon(Icons.arrow_back), tooltip: 'Back', onPressed: widget.onBack)
          : null,
      titleSpacing: hasBack ? 0 : 20,
      shape: const Border(bottom: BorderSide(color: _line)),
      title: Row(children: <Widget>[
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: <Color>[Color(0xFF00897B), Color(0xFF00695C)]),
            borderRadius: BorderRadius.circular(12),
            boxShadow: <BoxShadow>[BoxShadow(color: _teal.withValues(alpha: 0.25), blurRadius: 10, offset: const Offset(0, 4))],
          ),
          child: const Icon(Icons.alt_route_rounded, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 12),
        const Flexible(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: <Widget>[
            Text('Collection Route Optimization',
                overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17, letterSpacing: -0.3)),
            SizedBox(height: 2),
            Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
              Icon(Icons.place_rounded, size: 12, color: _muted),
              SizedBox(width: 3),
              Flexible(
                child: Text('Barangay Balintawak, Lipa City',
                    overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: _muted, fontWeight: FontWeight.w600)),
              ),
            ]),
          ]),
        ),
      ]),
      actions: <Widget>[
        if (widget.headerAccessory != null && !narrowHeader)
          Padding(padding: const EdgeInsets.only(right: 16), child: Center(child: widget.headerAccessory)),
      ],
      // Phones: the switch gets its own row under the title.
      bottom: widget.headerAccessory != null && narrowHeader
          ? PreferredSize(
              preferredSize: const Size.fromHeight(44),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Align(alignment: Alignment.centerLeft, child: widget.headerAccessory),
              ),
            )
          : null,
    );
  }

  Widget _mapWidget() => MapboxGate(
        child: MapWidget(
          key: const ValueKey<String>('collection-route-optimization-map'),
          viewport: CameraViewportState(center: Point(coordinates: Position(121.1620, 13.9565)), zoom: 14.2),
          onMapCreated: _onMapCreated,
          onStyleLoadedListener: (_) {
            MapHome.ensure(_map);
            _updateMap();
          },
        ),
      );

  // ---- layouts

  Widget _desktopLayout(BoxConstraints c) {
    const double panelWidth = 384;
    final double height = _panelExpanded ? math.min(c.maxHeight - 110, 640.0) : 214.0;
    final double left = _panelLeft.clamp(8.0, math.max(8.0, c.maxWidth - panelWidth - 8));
    final double bottom = _panelBottom.clamp(8.0, math.max(8.0, c.maxHeight - height - 96));
    return Stack(children: <Widget>[
      Positioned.fill(child: _mapWidget()),
      Positioned(
        top: 16,
        left: 16,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: c.maxWidth - 32),
          child: PointerInterceptor(child: _toolbar(compact: false)),
        ),
      ),
      Positioned(top: 16, right: 16, child: _styleToggle(compact: false)),
      AnimatedPositioned(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        left: left,
        bottom: bottom,
        width: panelWidth,
        height: height,
        child: PointerInterceptor(child: _floatingPanel()),
      ),
    ]);
  }

  Widget _floatingPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _line),
        boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x26000000), blurRadius: 24, offset: Offset(0, 10))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: <Widget>[
        // Drag the header to move the panel anywhere on the map.
        GestureDetector(
          onPanUpdate: (DragUpdateDetails d) => setState(() {
            _panelLeft += d.delta.dx;
            _panelBottom -= d.delta.dy;
          }),
          child: MouseRegion(cursor: SystemMouseCursors.move, child: _panelHeader(showToggle: true)),
        ),
        Expanded(
          child: _panelExpanded
              ? ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 20), children: _panelContent())
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                    _statStrip(),
                    const SizedBox(height: 10),
                    _priorityLine(compact: true),
                  ]),
                ),
        ),
      ]),
    );
  }

  Widget _mobileLayout() {
    return Stack(children: <Widget>[
      Positioned.fill(child: _mapWidget()),
      Positioned(top: 10, left: 10, right: 10, child: PointerInterceptor(child: _toolbar(compact: true))),
      Positioned(top: 66, right: 10, child: _styleToggle(compact: true)),
      Positioned.fill(
        child: DraggableScrollableSheet(
          initialChildSize: 0.34,
          minChildSize: 0.2,
          maxChildSize: 0.92,
          snap: true,
          snapSizes: const <double>[0.34, 0.6],
          builder: (BuildContext context, ScrollController sc) => PointerInterceptor(
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
                boxShadow: <BoxShadow>[BoxShadow(color: Color(0x33000000), blurRadius: 24, offset: Offset(0, -6))],
              ),
              child: ListView(
                controller: sc,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
                children: <Widget>[_panelHeader(showToggle: false), ..._panelContent(includeStats: true)],
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  // ---- toolbar (top)

  Widget _toolbar({required bool compact}) {
    final List<Widget> items = <Widget>[
      _areaPicker(),
      const SizedBox(width: 10),
      _statusChip('All', StatusFilter.all, Icons.layers_rounded, _teal),
      _statusChip('7+ days', StatusFilter.sevenPlus, Icons.schedule_rounded, CollectionColors.aging),
      _statusChip('14+ days', StatusFilter.fourteenPlus, Icons.history_toggle_off_rounded, CollectionColors.stale),
      const SizedBox(width: 6),
      _livePill(),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _line),
        boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x1F000000), blurRadius: 18, offset: Offset(0, 6))],
      ),
      child: compact
          ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: items))
          : Row(mainAxisSize: MainAxisSize.min, children: items),
    );
  }

  Widget _areaPicker() {
    final List<String> names = <String>['All areas', ..._statuses.map((AreaCollectionStatus s) => s.area)];
    final String current = names.contains(_areaFilter) ? _areaFilter : 'All areas';
    return PopupMenuButton<String>(
      tooltip: 'Choose an area',
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: (String v) {
        setState(() => _areaFilter = v);
        _updateMap();
        if (v != 'All areas') _focusArea(v);
      },
      itemBuilder: (BuildContext context) =>
          names.map((String n) => CheckedPopupMenuItem<String>(value: n, checked: n == current, child: Text(n))).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
          const Icon(Icons.place_rounded, size: 16, color: _teal),
          const SizedBox(width: 6),
          Text(current, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: _ink)),
          const SizedBox(width: 2),
          const Icon(Icons.expand_more_rounded, size: 18, color: _muted),
        ]),
      ),
    );
  }

  Widget _statusChip(String label, StatusFilter f, IconData icon, Color color) {
    final bool on = _statusFilter == f;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        showCheckmark: false,
        avatar: Icon(icon, size: 15, color: on ? color : _muted),
        label: Text(label),
        labelStyle: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: on ? color : const Color(0xFF334155)),
        selected: on,
        selectedColor: color.withValues(alpha: 0.12),
        backgroundColor: Colors.white,
        side: BorderSide(color: on ? color.withValues(alpha: 0.6) : _line),
        shape: const StadiumBorder(),
        visualDensity: VisualDensity.compact,
        onSelected: (bool sel) {
          setState(() => _statusFilter = sel ? f : StatusFilter.all);
          _updateMap();
        },
      ),
    );
  }

  Widget _livePill() {
    final bool live = _error == null;
    final Color c = live ? CollectionColors.recent : CollectionColors.unknown;
    return Tooltip(
      message: _lastDataAt == null ? '' : 'Records last received ${CollectionStatus.formatManila(_lastDataAt!.millisecondsSinceEpoch)}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
          Icon(Icons.circle, size: 8, color: c),
          const SizedBox(width: 6),
          Text(live ? 'Live' : 'Updates paused', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: c)),
        ]),
      ),
    );
  }

  // ---- summary panel

  Widget _panelHeader({required bool showToggle}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 6),
      child: Column(children: <Widget>[
        Container(width: 38, height: 4, decoration: BoxDecoration(color: const Color(0xFFCBD5E1), borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 8),
        Row(children: <Widget>[
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: _teal.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.insights_rounded, size: 18, color: _teal),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Collection status', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _ink)),
          ),
          IconButton(
            tooltip: 'How status works',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.info_outline_rounded, size: 20, color: _muted),
            onPressed: _showHowItWorks,
          ),
          if (showToggle)
            IconButton(
              key: const ValueKey<String>('collection-panel-toggle'),
              tooltip: _panelExpanded ? 'Show less' : 'Show all areas',
              visualDensity: VisualDensity.compact,
              icon: Icon(_panelExpanded ? Icons.close_fullscreen_rounded : Icons.open_in_full_rounded, size: 19, color: _teal),
              onPressed: () => setState(() => _panelExpanded = !_panelExpanded),
            ),
        ]),
      ]),
    );
  }

  void _showHowItWorks() {
    final CollectionStatusConfig c = widget.config;
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('How collection status works', style: TextStyle(fontWeight: FontWeight.w900)),
        content: Text(
          'Each area shows the days since its last verified visit: a recorded trip in which the truck '
          'stayed at least 60 seconds inside the area while collecting.\n\n'
          '• 0-${c.recentDays - 1} days: recently visited\n'
          '• ${c.recentDays}-${c.staleDays - 1} days: due\n'
          '• ${c.staleDays}+ days: overdue\n'
          '• No record: no verified visit in the last ${c.windowDays} days\n\n'
          'A verified visit shows the truck was there; it does not confirm that every household was collected, '
          'and it is not a schedule check. Simulated trips are never counted.'
          '${_viewOnly ? '\n\nThis view shows collection details only. Route planning is for authorized drivers.' : ''}',
          style: const TextStyle(height: 1.45),
        ),
        actions: <Widget>[TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got it'))],
      ),
    );
  }

  static const List<CollectionBand> _bandOrder = <CollectionBand>[
    CollectionBand.stale,
    CollectionBand.aging,
    CollectionBand.partialOnly,
    CollectionBand.unknown,
    CollectionBand.recent,
  ];

  String _bandTitle(CollectionBand b) {
    final CollectionStatusConfig c = widget.config;
    return switch (b) {
      CollectionBand.stale => 'Overdue · ${c.staleDays}+ days',
      CollectionBand.aging => 'Due · ${c.recentDays}-${c.staleDays - 1} days',
      CollectionBand.partialOnly => 'Partial activity only',
      CollectionBand.unknown => 'No verified visit yet',
      CollectionBand.recent => 'Recently visited',
    };
  }

  String _bandShort(CollectionBand b) => switch (b) {
        CollectionBand.recent => 'Recent',
        CollectionBand.aging => 'Due',
        CollectionBand.stale => 'Overdue',
        CollectionBand.partialOnly => 'Partial',
        CollectionBand.unknown => 'No record',
      };

  /// Counts per status; also the map legend.
  Widget _statStrip() {
    final List<AreaCollectionStatus> v =
        _statuses.where((AreaCollectionStatus s) => _areaFilter == 'All areas' || s.area == _areaFilter).toList();
    const List<CollectionBand> order = <CollectionBand>[
      CollectionBand.recent,
      CollectionBand.aging,
      CollectionBand.stale,
      CollectionBand.partialOnly,
      CollectionBand.unknown,
    ];
    return Row(children: <Widget>[
      for (final CollectionBand b in order)
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: CollectionColors.of(b).withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border(top: BorderSide(color: CollectionColors.of(b), width: 3)),
            ),
            child: Column(children: <Widget>[
              Text('${v.where((AreaCollectionStatus s) => s.band == b).length}',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: CollectionColors.of(b))),
              const SizedBox(height: 2),
              Text(_bandShort(b),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: _muted)),
            ]),
          ),
        ),
    ]);
  }

  AreaCollectionStatus? get _longestSince {
    AreaCollectionStatus? best;
    for (final AreaCollectionStatus s in _visible) {
      if (s.band != CollectionBand.aging && s.band != CollectionBand.stale) continue;
      if (best == null || (s.daysSince ?? 0) > (best.daysSince ?? 0)) best = s;
    }
    return best;
  }

  Widget _priorityLine({bool compact = false}) {
    final AreaCollectionStatus? s = _longestSince;
    if (s == null) {
      final bool allRecent = _visible.isNotEmpty && _visible.every((AreaCollectionStatus x) => x.band == CollectionBand.recent);
      if (!allRecent) return const SizedBox.shrink();
      return const Row(children: <Widget>[
        Icon(Icons.verified_rounded, size: 18, color: CollectionColors.recent),
        SizedBox(width: 8),
        Expanded(child: Text('Every area had a verified visit this week', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13))),
      ]);
    }
    final Color c = CollectionColors.of(s.band);
    return Material(
      color: c.withValues(alpha: 0.07),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          if (!_panelExpanded) setState(() => _panelExpanded = true);
          _selectArea(s.area);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: <Widget>[
            Icon(Icons.priority_high_rounded, size: 18, color: c),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                const Text('Longest since a verified visit', style: TextStyle(fontSize: 11, color: _muted, fontWeight: FontWeight.w700)),
                Text(s.area, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: _ink)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(20)),
              child: Text('${s.daysSince ?? '?'} days',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12)),
            ),
          ]),
        ),
      ),
    );
  }

  List<Widget> _panelContent({bool includeStats = true}) {
    final List<AreaCollectionStatus> v = _visible;
    final List<Widget> out = <Widget>[
      if (includeStats) ...<Widget>[_statStrip(), const SizedBox(height: 12)],
      _priorityLine(),
      if (_data?.areasFromDefaults == true)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text('Service areas could not be read; documented default areas are shown.',
              style: TextStyle(fontSize: 11.5, color: CollectionColors.partial, fontWeight: FontWeight.w600)),
        ),
      const SizedBox(height: 6),
      if (v.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Text('No area matches the selected filters.', textAlign: TextAlign.center, style: TextStyle(color: _muted)),
        ),
    ];
    for (final CollectionBand b in _bandOrder) {
      final List<AreaCollectionStatus> group = v.where((AreaCollectionStatus s) => s.band == b).toList();
      if (group.isEmpty) continue;
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
        child: Row(children: <Widget>[
          Container(width: 8, height: 8, decoration: BoxDecoration(color: CollectionColors.of(b), shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(_bandTitle(b), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12.5, color: _ink, letterSpacing: 0.2)),
          const SizedBox(width: 6),
          Text('${group.length}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: _muted)),
        ]),
      ));
      out.addAll(group.map(_areaCard));
    }
    if (_canComparePaths) out.add(_comparison());
    out.add(Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Text(
        'As of ${CollectionStatus.formatManila(_now().millisecondsSinceEpoch)} (Asia/Manila)',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
      ),
    ));
    return out;
  }

  Widget _areaCard(AreaCollectionStatus s) {
    final Color c = CollectionColors.of(s.band);
    final bool selected = s.area == _selectedArea;
    final bool hover = _hoverArea == s.area;
    return MouseRegion(
      onEnter: (_) => setState(() => _hoverArea = s.area),
      onExit: (_) => setState(() => _hoverArea = null),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: selected ? c.withValues(alpha: 0.06) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? c.withValues(alpha: 0.55) : (hover ? c.withValues(alpha: 0.35) : _line)),
          boxShadow: hover || selected
              ? <BoxShadow>[BoxShadow(color: c.withValues(alpha: 0.12), blurRadius: 12, offset: const Offset(0, 4))]
              : const <BoxShadow>[],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey<String>('area-${s.area}'),
            borderRadius: BorderRadius.circular(16),
            onTap: () => _selectArea(s.area), // also keyboard activation
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Row(children: <Widget>[
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: c.withValues(alpha: 0.12), shape: BoxShape.circle),
                    child: Text(s.symbol, style: TextStyle(color: c, fontWeight: FontWeight.w900, fontSize: 15)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                      Text(s.area, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: _ink)),
                      const SizedBox(height: 1),
                      Text(s.hasNewerPartial ? '${s.label} · newer partial activity' : s.label,
                          style: const TextStyle(fontSize: 12, color: _muted, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                  if (s.daysSince != null && s.band != CollectionBand.recent)
                    Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                      child: Text('${s.daysSince}d', style: TextStyle(color: c, fontWeight: FontWeight.w900, fontSize: 11.5)),
                    ),
                  Icon(selected ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: _muted, size: 20),
                ]),
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: selected
                      ? Padding(padding: const EdgeInsets.fromLTRB(4, 10, 4, 2), child: _details(s.area))
                      : const SizedBox(width: double.infinity),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _details(String area) {
    final AreaCollectionStatus? s = _statuses.where((AreaCollectionStatus x) => x.area == area).firstOrNull;
    if (s == null) return const SizedBox.shrink();
    final List<CollectionVisit> history = _visits.where((CollectionVisit v) => v.area == area).toList()
      ..sort((CollectionVisit a, CollectionVisit b) => b.firstFixMs.compareTo(a.firstFixMs));
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            SizedBox(width: 140, child: Text(k, style: const TextStyle(fontSize: 12, color: _muted))),
            Expanded(child: Text(v, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _ink))),
          ]),
        );
    return Column(
      key: const ValueKey<String>('area-details'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(s.explanation(widget.config), style: const TextStyle(fontSize: 12, color: Color(0xFF475569), height: 1.35)),
        const Divider(height: 18, color: _line),
        row('Last verified visit', s.lastConfirmedMs == null ? 'No record' : CollectionStatus.formatManila(s.lastConfirmedMs!)),
        row('Days since', s.daysSince == null ? 'Unknown' : '${s.daysSince}'),
        if (s.latestPartialMs != null) row('Latest partial activity', CollectionStatus.formatManila(s.latestPartialMs!)),
        if (s.latestActivity != null)
          row('Latest other activity',
              '${CollectionStatus.formatManila(s.latestActivity!.ms)} (${s.latestActivity!.source}; not a verified visit)'),
        row('Verified visits (${widget.config.windowDays} days)', '${s.confirmedVisits}'),
        if (history.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          const Text('Verified visit history', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: _ink)),
          const SizedBox(height: 4),
          ...history.take(10).map((CollectionVisit v) => Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  const Padding(padding: EdgeInsets.only(top: 5), child: Icon(Icons.circle, size: 6, color: _teal)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${CollectionStatus.formatManila(v.firstFixMs)} · ${(v.dwellMs / 60000).toStringAsFixed(0)} min in area'
                      '${!_viewOnly && v.truckId != null && v.truckId != 'Unknown' ? ' · ${v.truckId}' : ''}',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF475569)),
                    ),
                  ),
                ]),
              )),
        ],
      ],
    );
  }

  /// Route suggestion from recorded trips: shown only when real history allows a comparison.
  Widget _comparison() {
    final PathAnalysis? a = _paths;
    final List<PathComparison> groups =
        a == null ? const <PathComparison>[] : (_selectedArea == null ? a.comparisons : a.including(_selectedArea!));
    if (groups.isEmpty) return const SizedBox.shrink();
    final RecordedPath? reference = _pathById(_referenceTripId);
    final List<Widget> out = <Widget>[
      Row(children: <Widget>[
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(color: const Color(0xFF6A4CE0).withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.route_rounded, size: 18, color: Color(0xFF6A4CE0)),
        ),
        const SizedBox(width: 10),
        const Expanded(child: Text('Route from past trips', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, color: _ink))),
      ]),
      if (_selectedArea != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Trips that served $_selectedArea', style: const TextStyle(fontSize: 12, color: _muted)),
        ),
      const SizedBox(height: 8),
    ];
    for (final PathComparison g in groups.take(3)) {
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Material(
          color: const Color(0xFFF8F7FF),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFE4DFFB)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('Same coverage: ${g.coverage.join(', ')}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _ink)),
              for (final RecordedPath p in g.paths.take(5))
                RadioListTile<String>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  activeColor: const Color(0xFF6A4CE0),
                  value: p.tripId,
                  groupValue: _highlightTripId,
                  onChanged: (String? id) {
                    setState(() => _highlightTripId = id);
                    _updateMap();
                  },
                  title: Text('${p.distanceKm.toStringAsFixed(1)} km recorded · ${(p.travelMs / 60000).round()} min travel'
                      ' + ${(p.inAreaMs / 60000).round()} min in areas'),
                  subtitle: Text('${CollectionStatus.formatManila(p.startMs)}${p.truckId != null ? ' · ${p.truckId}' : ''}'
                      '${p.tripId == _referenceTripId ? ' · your reference' : ''}'),
                ),
              Text(
                g.savingVsMedianKm > 0.05
                    ? 'Shortest is ${g.savingVsMedianKm.toStringAsFixed(1)} km below the median of these recorded trips.'
                    : 'No meaningful difference between these recorded trips.',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _ink),
              ),
              const SizedBox(height: 2),
              Text('Suggested from available history: ${g.basis}', style: const TextStyle(fontSize: 12, color: _muted)),
              Text('Stop order of the shortest trip: ${g.shortest.areaOrder.join(' → ')}',
                  style: const TextStyle(fontSize: 12, color: _muted)),
              if (_canSelectReference)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: FilledButton.icon(
                    key: const ValueKey<String>('select-reference-path'),
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF6A4CE0)),
                    icon: const Icon(Icons.alt_route_rounded, size: 18),
                    label: const Text('Select reference path'),
                    onPressed: () => _selectReference(_pathById(_highlightTripId) ?? g.shortest),
                  ),
                ),
            ]),
          ),
        ),
      ));
    }
    if (_canSelectReference && reference != null) {
      out.add(Text('Your reference path: ${reference.areaOrder.join(' → ')} (${reference.distanceKm.toStringAsFixed(1)} km recorded)',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _ink)));
    }
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(key: const ValueKey<String>('route-from-past-trips'), crossAxisAlignment: CrossAxisAlignment.start, children: out),
    );
  }
}
