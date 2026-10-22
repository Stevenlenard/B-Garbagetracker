import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/config/mapbox_config.dart';
import 'package:garbage_tracking_app/models/driver_trip.dart';
import 'package:garbage_tracking_app/services/driver_route_history_service.dart';
import 'package:garbage_tracking_app/services/map_matching_service.dart';
import 'package:garbage_tracking_app/utils/gps_smoothing.dart';
import 'package:garbage_tracking_app/utils/route_geometry.dart';

/// Answers every Mapbox request with [body] and counts the requests.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.body);
  final Map<String, Object?> Function(RequestOptions o) body;
  final List<String> paths = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    paths.add(o.uri.path);
    return ResponseBody.fromString(jsonEncode(body(o)), 200, headers: <String, List<String>>{
      Headers.contentTypeHeader: <String>[Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  Map<String, Object?> pt(double lat, double lng, int ts, {double acc = 8, String color = 'GREEN'}) =>
      <String, Object?>{'lat': lat, 'lng': lng, 'timestamp': ts, 'accuracy': acc, 'status': 'ACTIVE', 'color': color};

  group('Kalman + stationary display smoothing', () {
    test('a phone lying still with GPS jitter draws no star of lines', () {
      // 40 fixes scattered up to ~25 m around one spot (indoors), 5 s apart.
      final List<Map> raw = <Map>[
        for (int i = 0; i < 40; i++) pt(13.95400 + ((i * 7) % 5 - 2) * 0.00005, 121.16000 + ((i * 3) % 5 - 2) * 0.00005, i * 5000, acc: 25),
      ];
      final List<Map> drawn = RouteGeometry.smoothForDisplay(RouteGeometry.cleanPoints(raw));
      expect(drawn.length, lessThan(8));
      double spread = 0;
      for (final Map p in drawn) {
        spread = spread > RouteGeometry.distanceM(13.954, 121.16, p['lat'] as double, p['lng'] as double)
            ? spread
            : RouteGeometry.distanceM(13.954, 121.16, p['lat'] as double, p['lng'] as double);
      }
      expect(spread, lessThan(20)); // the raw fixes reach ~16 m out in each axis; smoothed ones stay near the spot
    });

    test('real travel is kept: a 1 km straight drive stays about 1 km long', () {
      final List<Map> raw = <Map>[for (int i = 0; i <= 50; i++) pt(13.9500 + i * 0.00018, 121.1600, i * 4000)];
      final List<Map> drawn = RouteGeometry.smoothForDisplay(RouteGeometry.cleanPoints(raw));
      double len = 0;
      for (int i = 1; i < drawn.length; i++) {
        len += RouteGeometry.distanceM(drawn[i - 1]['lat'] as double, drawn[i - 1]['lng'] as double, drawn[i]['lat'] as double, drawn[i]['lng'] as double);
      }
      expect(len, closeTo(1000, 60));
      expect(drawn.last['lat'], closeTo(13.9590, 0.0001));
    });

    test('a single wild fix is pulled in, not drawn onto the roof 60 m away', () {
      final List<Map> raw = <Map>[
        for (int i = 0; i < 10; i++) pt(13.9500 + i * 0.0001, 121.1600, i * 5000, acc: 5),
        pt(13.9510, 121.1606, 50000, acc: 45), // 60 m sideways, poor accuracy
        for (int i = 11; i < 15; i++) pt(13.9500 + i * 0.0001, 121.1600, i * 5000, acc: 5),
      ];
      final List<List<double>> s = GpsSmoothing.kalman(raw
          .map((m) => GpsSample(lat: m['lat'] as double, lng: m['lng'] as double, accuracyM: (m['accuracy'] as num).toDouble(), timestampMs: m['timestamp'] as int))
          .toList());
      final double sideways = RouteGeometry.distanceM(13.9510, 121.1600, s[10][0], s[10][1]);
      expect(sideways, lessThan(25));
    });

    test('colour changes (FULL stretch) and the live tail survive the stationary filter', () {
      final List<Map> raw = <Map>[
        for (int i = 0; i < 10; i++) pt(13.9500 + i * 0.0002, 121.1600, i * 5000),
        pt(13.95181, 121.1600, 50000, color: 'PINK'),
        pt(13.95182, 121.1600, 55000, color: 'PINK'),
      ];
      final List<Map> drawn = RouteGeometry.smoothForDisplay(RouteGeometry.cleanPoints(raw));
      expect(drawn.any((p) => p['color'] == 'PINK'), isTrue);
      final List<Map> withTail = RouteGeometry.withLiveTail(RouteGeometry.cleanPoints(raw), 13.9530, 121.1600);
      final List<Map> drawnTail = RouteGeometry.smoothForDisplay(RouteGeometry.cleanPoints(withTail));
      expect(drawnTail.last['lat'], 13.9530);
    });

    test('route history display points are smoothed copies; the recorded points are untouched', () {
      final List<GpsPoint> pts = <GpsPoint>[
        for (int i = 0; i < 20; i++)
          GpsPoint(latitude: 13.95 + i * 0.0002 + (i.isEven ? 0.00004 : -0.00004), longitude: 121.16, accuracyM: 10, timestamp: DateTime.fromMillisecondsSinceEpoch(i * 5000)),
      ];
      final List<double> before = pts.map((p) => p.latitude).toList();
      final List<GpsPoint> shown = DriverRouteHistoryService.smoothForDisplay(pts);
      expect(shown, isNotEmpty);
      expect(pts.map((p) => p.latitude).toList(), before);
    });
  });

  group('Map Matching', () {
    final List<GpsPoint> pts = <GpsPoint>[
      for (int i = 0; i < 5; i++) GpsPoint(latitude: 13.95 + i * 0.0006, longitude: 121.16 + 0.00002, accuracyM: 8, timestamp: DateTime.fromMillisecondsSinceEpoch(i * 10000)),
    ];
    Map<String, Object?> okResponse(RequestOptions o) => <String, Object?>{
          'code': 'Ok',
          'matchings': <Object?>[
            <String, Object?>{
              'confidence': 0.9,
              'geometry': <String, Object?>{
                'coordinates': <Object?>[
                  for (int i = 0; i <= 8; i++) <double>[121.16, 13.95 + i * 0.0003],
                ],
              },
              'legs': <Object?>[for (int i = 0; i < 4; i++) <String, Object?>{'distance': 66.7}],
            },
          ],
          'tracepoints': <Object?>[
            for (int i = 0; i < 5; i++) <String, Object?>{'matchings_index': 0, 'waypoint_index': i, 'location': <double>[121.16, 13.95 + i * 0.0006]},
          ],
        };

    setUp(() {
      MapboxRequestGuard.debugReset();
      MapMatchingService.debugClear();
    });
    tearDown(MapboxRequestGuard.debugReset);

    test('off by default: no request, no road line', () async {
      final _FakeAdapter fake = _FakeAdapter(okResponse);
      MapMatchingService.debugDio = Dio()..httpClientAdapter = fake;
      MapboxRequestGuard.debugAccessToken = 'pk.test';
      expect(await MapMatchingService.forTrip('t1', pts, finished: false), isNull);
      expect(fake.paths, isEmpty);
    });

    test('snaps the line to the road and keeps every point on it in order', () async {
      final _FakeAdapter fake = _FakeAdapter(okResponse);
      MapMatchingService.debugDio = Dio()..httpClientAdapter = fake;
      MapboxRequestGuard.debugAccessToken = 'pk.test';
      MapboxRequestGuard.debugMapMatchingEnabled = true;
      final MatchedRoute? r = await MapMatchingService.forTrip('t1', pts, finished: false);
      expect(r, isNotNull);
      expect(fake.paths.single, contains('/matching/v5/mapbox/driving/'));
      expect(r!.line.every((c) => c[0] == 121.16), isTrue); // on the road, not 2 m beside it
      expect(r.vertexOfPoint.length, pts.length);
      for (int i = 1; i < r.vertexOfPoint.length; i++) {
        expect(r.vertexOfPoint[i], greaterThanOrEqualTo(r.vertexOfPoint[i - 1]));
      }
      expect(r.vertexOfPoint.first, 0);
      expect(r.vertexOfPoint.last, r.line.length - 1);
      // second call for the same points is served from memory
      await MapMatchingService.forTrip('t1', pts, finished: false);
      expect(fake.paths.length, 1);
    });

    test('a stretch no road fits is retried as a walk; still nothing is invented when both fail', () async {
      final _FakeAdapter fake = _FakeAdapter((o) => <String, Object?>{'code': 'Ok', 'matchings': <Object?>[], 'tracepoints': <Object?>[null, null, null, null, null]});
      MapMatchingService.debugDio = Dio()..httpClientAdapter = fake;
      MapboxRequestGuard.debugAccessToken = 'pk.test';
      MapboxRequestGuard.debugMapMatchingEnabled = true;
      expect(await MapMatchingService.forTrip('t2', pts, finished: false), isNull);
      expect(fake.paths.length, 2);
      expect(fake.paths.last, contains('/walking/'));
    });

    test('a trip that stood still (line under 150 m) is never matched onto a street', () async {
      final _FakeAdapter fake = _FakeAdapter(okResponse);
      MapMatchingService.debugDio = Dio()..httpClientAdapter = fake;
      MapboxRequestGuard.debugAccessToken = 'pk.test';
      MapboxRequestGuard.debugMapMatchingEnabled = true;
      final List<GpsPoint> home = <GpsPoint>[
        for (int i = 0; i < 6; i++) GpsPoint(latitude: 13.95 + (i.isEven ? 0.0001 : 0), longitude: 121.16, accuracyM: 20, timestamp: DateTime.fromMillisecondsSinceEpoch(i * 10000)),
      ];
      expect(await MapMatchingService.forTrip('home', home, finished: true), isNull);
      expect(fake.paths, isEmpty);
    });

    test('polyline storage round-trips at 6 decimals', () {
      final List<List<double>> line = <List<double>>[<double>[121.160123, 13.954321], <double>[121.161, 13.9551], <double>[121.159876, 13.953999]];
      final List<List<double>> back = MapMatchingService.decodePolyline(MapMatchingService.encodePolyline(line));
      expect(back.length, 3);
      for (int i = 0; i < 3; i++) {
        expect(back[i][0], closeTo(line[i][0], 1e-6));
        expect(back[i][1], closeTo(line[i][1], 1e-6));
      }
    });
  });
}
