import 'dart:async';

import '../screens/collection_route_optimization_screen.dart' show FirebaseCollectionDataSource;
import '../services/service_area_service.dart';
import '../services/truck_locations_feed.dart';
import '../utils/collection_visits.dart';
import '../utils/fleet_status.dart';

/// One truck that the live maps would show right now.
class LiveTruck {
  const LiveTruck({required this.id, required this.status, required this.ageSec, this.area, this.driver, this.lat = 0, this.lng = 0});

  final String id;
  final String status;

  /// Seconds since the last GPS update.
  final int ageSec;

  /// Purok the truck is in (from the purok boundaries), when known.
  final String? area;
  final String? driver;
  final double lat;
  final double lng;
}

/// What Truck Buddy knows about the fleet at one moment.
class FleetSnapshot {
  const FleetSnapshot(this.trucks, this.atMs);

  final List<LiveTruck> trucks;
  final int atMs;

  LiveTruck? byId(String id) {
    for (final LiveTruck t in trucks) {
      if (t.id == id) return t;
    }
    return null;
  }
}

/// Builds [FleetSnapshot]s with the SAME online rules as the live maps (status, online flag,
/// 3-minute freshness, 12-hour session, real coordinates, one truck per driver).
class LiveFleet {
  LiveFleet._();

  static FleetSnapshot parse(Map<String, dynamic> nodes, {List<AreaGeofence> areas = const <AreaGeofence>[], int? nowMs}) {
    final int now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final Map<String, LiveTruck> byDriver = <String, LiveTruck>{};
    final Map<String, int> seenAt = <String, int>{};
    nodes.forEach((String key, dynamic v) {
      if (v is! Map) return;
      final Map<dynamic, dynamic> n = v;
      final String id = (n['truck_id'] ?? n['truckId'] ?? key).toString().toUpperCase().trim();
      if (id.isEmpty || id == 'UNKNOWN' || id == 'N/A') return;
      final String status = FleetStatus.normalizeStatus(n['status'], fallback: 'ACTIVE');
      final bool activeStatus = status == 'ACTIVE' || status == 'IDLE' || status == 'COLLECTING' || status == 'FULL' || status == 'PAUSED';
      final double lat = double.tryParse('${n['latitude'] ?? n['lat'] ?? 0}') ?? 0;
      final double lng = double.tryParse('${n['longitude'] ?? n['lng'] ?? 0}') ?? 0;
      final bool coords = lat != 0 && lng != 0 && lat.abs() <= 90 && lng.abs() <= 180;
      final int lastSeen = FleetStatus.parseTimestampMs(n['lastSeen'] ?? n['last_seen'] ?? n['timestamp']);
      final bool fresh = lastSeen > 0 && FleetStatus.isFresh(lastSeen, now);
      final bool session = FleetStatus.isSessionValid(FleetStatus.parseTimestampMs(n['login_time'] ?? n['loginTime']), now);
      if (!(activeStatus && coords && fresh && session && FleetStatus.hasOnlineFlag(n))) return;

      String? area;
      for (final AreaGeofence g in areas) {
        if (g.contains(lat, lng)) {
          area = g.name;
          break;
        }
      }
      final String raw = (n['current_purok'] ?? '').toString().trim();
      area ??= raw.isEmpty ? null : raw;
      final String name = (n['driver_name'] ?? n['driverName'] ?? '').toString().trim();
      final LiveTruck t = LiveTruck(
        id: id,
        status: status,
        ageSec: ((now - lastSeen) / 1000).abs().round(),
        area: area,
        driver: name.isEmpty ? null : name,
        lat: lat,
        lng: lng,
      );
      final String driverKey = FleetStatus.driverKey(n);
      final String k = driverKey.isEmpty ? 'truck:$id' : driverKey;
      if (!seenAt.containsKey(k) || lastSeen > seenAt[k]!) {
        seenAt[k] = lastSeen;
        byDriver[k] = t;
      }
    });
    final List<LiveTruck> list = byDriver.values.toList()..sort((LiveTruck a, LiveTruck b) => a.id.compareTo(b.id));
    return FleetSnapshot(list, now);
  }

  /// Live snapshots from the shared truck feed (the one the maps use).
  static Stream<FleetSnapshot> watch() {
    List<AreaGeofence> areas = const <AreaGeofence>[];
    Map<String, dynamic> last = const <String, dynamic>{};
    late final StreamController<FleetSnapshot> out;
    StreamSubscription<TruckLocationsEvent>? sub;
    Timer? tick;
    void emit() {
      if (!out.isClosed) out.add(parse(last, areas: areas));
    }

    out = StreamController<FleetSnapshot>(
      onListen: () {
        ServiceAreaService().getAllServiceAreas().then((List<ServiceArea> list) {
          areas = list.map(FirebaseCollectionDataSource.toGeofence).toList();
          emit();
        }).catchError((Object _) {});
        sub = TruckLocationsFeed.shared().events.listen((TruckLocationsEvent e) {
          final Object? v = e.snapshot.value;
          last = v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
          emit();
        }, onError: (Object _) {});
        // Freshness changes with time even when nothing is written.
        tick = Timer.periodic(const Duration(seconds: 30), (_) => emit());
      },
      onCancel: () {
        tick?.cancel();
        return sub?.cancel();
      },
    );
    return out.stream;
  }
}
