import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/config/mapbox_config.dart';
import 'package:garbage_tracking_app/services/route_matrix_plan.dart';
import 'package:garbage_tracking_app/services/route_optimization_service.dart';
import 'package:garbage_tracking_app/utils/route_optimization_gate.dart';
import 'package:garbage_tracking_app/utils/route_optimization_card.dart';
import 'package:garbage_tracking_app/widgets/mapbox_gate.dart';

/// Every request the service tries to send is recorded and answered locally; nothing leaves
/// the test process. Matrix answers have the real shape (sources x destinations); Directions
/// answers with one leg per waypoint pair when [directionsOk].
class _Recorder extends Interceptor {
  final List<Uri> requests = <Uri>[];
  bool directionsOk = false;
  int get matrix => requests.where((u) => u.path.contains('directions-matrix')).length;
  int get directions => requests.where((u) => u.path.contains('/directions/')).length;
  int get proxy => requests.where((u) => u.path.contains('route_optimization.php')).length;

  /// Elements of every Matrix request sent (sources x destinations).
  int get matrixElements => requests.where((u) => u.path.contains('directions-matrix')).fold(0, (int sum, Uri u) {
        final int n = u.pathSegments.last.split(';').length;
        final int src = u.queryParameters['sources']?.split(';').length ?? n;
        final int dst = u.queryParameters['destinations']?.split(';').length ?? n;
        return sum + src * dst;
      });

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final Uri u = options.uri;
    requests.add(u);
    final int n = u.pathSegments.last.split(';').length;
    dynamic data;
    if (u.path.contains('directions-matrix')) {
      final List<int> src = u.queryParameters['sources']?.split(';').map(int.parse).toList() ?? List<int>.generate(n, (int i) => i);
      final List<int> dst = u.queryParameters['destinations']?.split(';').map(int.parse).toList() ?? List<int>.generate(n, (int i) => i);
      data = <String, dynamic>{
        'code': 'Ok',
        'durations': <List<num>>[for (final int i in src) <num>[for (final int j in dst) (i - j).abs() * 60]],
      };
    } else if (directionsOk) {
      data = <String, dynamic>{
        'code': 'Ok',
        'routes': <Map<String, dynamic>>[
          <String, dynamic>{
            'distance': 1000.0 * (n - 1),
            'duration': 60.0 * (n - 1),
            'geometry': <String, dynamic>{'type': 'LineString', 'coordinates': <dynamic>[]},
            'legs': <Map<String, dynamic>>[for (int i = 1; i < n; i++) <String, dynamic>{'distance': 1000.0, 'duration': 60.0}],
          }
        ],
      };
    } else {
      data = <String, dynamic>{'code': 'NoRoute', 'message': 'test'};
    }
    handler.resolve(Response<dynamic>(requestOptions: options, statusCode: 200, data: data));
  }
}

/// dart:io level trap: records every URL an HttpClient created in the zone tries to open.
class _NetTrap {
  final List<Uri> opened = <Uri>[];
  HttpClient create(SecurityContext? _) => _TrapClient(this);
}

class _TrapClient implements HttpClient {
  _TrapClient(this.trap);
  final _NetTrap trap;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    trap.opened.add(url);
    throw const SocketException('network disabled in test');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null; // settings setters, close(), ...
}

String _fakeToken(String account) =>
    'pk.${base64Url.encode(utf8.encode('{"u":"$account","a":"x"}')).replaceAll('=', '')}.signature0123';

List<Map<String, dynamic>> _stops(int n) => List<Map<String, dynamic>>.generate(
    n,
    (int i) => <String, dynamic>{
          'name': 'Area $i',
          'lat': 13.95 + i * 0.001,
          'lng': 121.16 + i * 0.001,
          'verificationStatus': 'VERIFIED',
        });

void main() {
  late _Recorder rec;
  late RouteOptimizationService service;
  late MemoryStopMatrixStore store;

  setUp(() {
    MapboxRequestGuard.debugReset();
    MapboxGate.debugConfigured = null;
    rec = _Recorder();
    store = MemoryStopMatrixStore();
    service = RouteOptimizationService(dio: Dio()..interceptors.add(rec), stopMatrixStore: store);
  });

  Future<Map<String, dynamic>?> optimize({int stops = 2, double lat = 13.95}) => service.getOptimizedRoute(
        sessionId: 's1',
        currentLat: lat,
        currentLng: 121.16,
        remainingPuroks: _stops(stops),
        configHash: 'h',
      );

  group('defaults of this build', () {
    test('Matrix and Directions are OFF and no token is built in', () {
      expect(MapboxConfig.matrixEnabled, isFalse);
      expect(MapboxConfig.directionsEnabled, isFalse);
      expect(MapboxRequestGuard.isEnabled(MapboxService.matrix), isFalse);
      expect(RouteOptimizationService.isAvailable, isFalse);
      expect(MapboxConfig.isConfigured, isFalse, reason: 'no --dart-define in tests and no fallback token');
      expect(MapboxConfig.accessToken, isEmpty);
      expect(MapboxConfig.diagnostics, contains('missing'));
      expect(MapboxConfig.diagnostics, contains('matrix: OFF'));
    });

    test('token validation: only pk. tokens of a non-blocked account', () {
      expect(MapboxConfig.isUsableToken(''), isFalse);
      expect(MapboxConfig.isUsableToken('REPLACE_WITH_DESTINATION_ACCOUNT_PUBLIC_PK_TOKEN'), isFalse);
      expect(MapboxConfig.isUsableToken('sk.${'x' * 40}'), isFalse, reason: 'secret tokens never accepted');
      expect(MapboxConfig.isUsableToken(_fakeToken('prince6703')), isFalse, reason: 'old account blocked');
      expect(MapboxConfig.accountOf(_fakeToken('prince6703')), 'prince6703');
      expect(MapboxConfig.isUsableToken(_fakeToken('new-account')), isTrue);
    });

    test('the example configs cannot be used as tokens and keep both switches off', () {
      for (final String platform in <String>['web', 'android']) {
        final Map<String, dynamic> example = jsonDecode(
            File('config/mapbox.$platform.example.json').readAsStringSync()) as Map<String, dynamic>;
        expect(MapboxConfig.isUsableToken(example['MAPBOX_ACCESS_TOKEN'] as String), isFalse);
        expect(example['MAPBOX_TOKEN_PLATFORM'], platform);
        expect(example['MAPBOX_MATRIX_ENABLED'], 'false');
        expect(example['MAPBOX_DIRECTIONS_ENABLED'], 'false');
      }
    });

    test('a token labelled for the other platform is refused', () {
      expect(MapboxConfig.platformMatches('web', isWeb: true), isTrue);
      expect(MapboxConfig.platformMatches('web', isWeb: false), isFalse, reason: 'URL-restricted token fails in the SDK');
      expect(MapboxConfig.platformMatches('android', isWeb: false), isTrue);
      expect(MapboxConfig.platformMatches('android', isWeb: true), isFalse, reason: 'unrestricted token not on the website');
      expect(MapboxConfig.platformMatches('shared', isWeb: true), isTrue);
      expect(MapboxConfig.platformMatches('shared', isWeb: false), isTrue);
      expect(MapboxConfig.platformMatches('', isWeb: false), isFalse, reason: 'label required');
    });

    test('local config files are git-ignored', () {
      final String ignore = File('.gitignore').readAsStringSync();
      expect(ignore.contains('/config/*.local.json'), isTrue);
    });
  });

  group('Matrix OFF: zero requests', () {
    test('route optimization returns the disabled result without any request', () async {
      final Map<String, dynamic>? r = await optimize();
      expect(r?['success'], isFalse);
      expect(r?['error'], 'ROUTE_OPTIMIZATION_DISABLED');
      expect(rec.requests, isEmpty);
      expect(MapboxRequestGuard.sent(MapboxService.matrix), 0);
      expect(MapboxRequestGuard.blocked(MapboxService.matrix), 1);
    });

    test('repeated / concurrent calls (rebuilds, GPS updates, retries) still send nothing', () async {
      await Future.wait(List<Future<Map<String, dynamic>?>>.generate(25, (int i) => optimize(lat: 13.95 + i * 0.01)));
      for (int i = 0; i < 25; i++) {
        await optimize(stops: 1 + i % 5);
      }
      expect(rec.requests, isEmpty, reason: 'no Matrix, Directions or PHP proxy request');
      expect(MapboxRequestGuard.sent(MapboxService.matrix), 0);
      expect(MapboxRequestGuard.blocked(MapboxService.matrix), 50);
    });

    test('no socket is opened: real Dio clients under an HttpOverrides trap, 5 simultaneous clients', () async {
      final _NetTrap trap = _NetTrap();
      await HttpOverrides.runZoned(() async {
        // Default Dio (real IO adapter) - no interceptor: any request would reach the trap.
        final List<RouteOptimizationService> clients =
            List<RouteOptimizationService>.generate(5, (_) => RouteOptimizationService(stopMatrixStore: MemoryStopMatrixStore()));
        await Future.wait(clients.map((RouteOptimizationService c) => c.getOptimizedRoute(
              sessionId: 's',
              currentLat: 13.95,
              currentLng: 121.16,
              remainingPuroks: _stops(3),
            )));
      }, createHttpClient: trap.create);
      expect(trap.opened, isEmpty, reason: 'no HTTP connection of any kind was attempted');
    });

    test('positive control: the same trap does see a request when Matrix is switched on', () async {
      MapboxRequestGuard.debugMatrixEnabled = true;
      MapboxRequestGuard.debugAccessToken = _fakeToken('new-account');
      final _NetTrap trap = _NetTrap();
      await HttpOverrides.runZoned(() async {
        await RouteOptimizationService(stopMatrixStore: MemoryStopMatrixStore()).getOptimizedRoute(
            sessionId: 's', currentLat: 13.95, currentLng: 121.16, remainingPuroks: _stops(2));
      }, createHttpClient: trap.create);
      expect(trap.opened.length, 1);
      expect(trap.opened.single.path, contains('directions-matrix'));
    });

    test('Matrix ON but no token: refused before the network (no fallback token)', () async {
      MapboxRequestGuard.debugMatrixEnabled = true;
      final Map<String, dynamic>? r = await optimize();
      expect(r?['error'], 'MATRIX_BLOCKED');
      expect(r?['message'], contains('no token'));
      expect(rec.requests, isEmpty);
    });
  });

  group('controlled re-enable limits (only if later authorized)', () {
    setUp(() {
      MapboxRequestGuard.debugMatrixEnabled = true;
      MapboxRequestGuard.debugAccessToken = _fakeToken('new-account');
    });

    test('too many coordinates are refused before the network', () async {
      final Map<String, dynamic>? r = await optimize(stops: MapboxConfig.maxMatrixCoordinates);
      expect(r?['error'], 'MATRIX_BLOCKED');
      expect(rec.requests, isEmpty);
    });

    test('Directions stays off: one Matrix request, no Directions, no automatic substitute', () async {
      final Map<String, dynamic>? r = await optimize();
      expect(rec.matrix, 1);
      expect(rec.directions, 0);
      expect(rec.proxy, 0, reason: 'the PHP proxy fallback exists on Web only (kIsWeb is false here)');
      expect(r?['error'], 'DIRECTIONS_BLOCKED');
      final Uri m = rec.requests.single;
      expect(m.pathSegments.last.split(';').length, 3, reason: '1 start + 2 stops = 3 x 3 = 9 elements');
    });

    test('per-session request limit (not an account-wide cap)', () async {
      for (int i = 0; i < MapboxConfig.maxMatrixRequestsPerSession + 5; i++) {
        await optimize();
      }
      expect(rec.matrix, MapboxConfig.maxMatrixRequestsPerSession);
      expect(MapboxRequestGuard.blocked(MapboxService.matrix), 5);
    });
  });

  group('repaired request design (switches forced ON only inside these tests)', () {
    setUp(() {
      MapboxRequestGuard.debugMatrixEnabled = true;
      MapboxRequestGuard.debugDirectionsEnabled = true;
      MapboxRequestGuard.debugAccessToken = _fakeToken('joven-2323');
      rec.directionsOk = true;
    });

    Future<Map<String, dynamic>?> run(List<Map<String, dynamic>> stops, {RouteOptimizationService? s}) =>
        (s ?? service).getOptimizedRoute(
            sessionId: 's', currentLat: 13.95, currentLng: 121.16, remainingPuroks: stops, configHash: null);

    test('full matrix once, then only the truck row; a completed stop needs no new full matrix', () async {
      final List<Map<String, dynamic>> stops = _stops(4);
      expect((await run(stops))?['success'], isTrue);
      expect(rec.matrixElements, 25, reason: 'first time: (4 + 1)^2');
      expect((await run(stops))?['success'], isTrue);
      expect(rec.matrixElements, 25 + 4, reason: 'second time: 1 x 4 row');
      expect(rec.requests.where((u) => u.path.contains('directions-matrix')).last.queryParameters['sources'], '0');
      expect((await run(stops.sublist(1)))?['success'], isTrue);
      expect(rec.matrixElements, 25 + 4 + 3, reason: 'one area completed: 1 x 3 row');
    });

    test('the cached order equals the order from a full matrix', () async {
      final List<Map<String, dynamic>> stops = _stops(5).reversed.toList();
      final List<dynamic> full = (await run(stops))!['stops'] as List<dynamic>;
      final List<dynamic> cached = (await run(stops))!['stops'] as List<dynamic>;
      expect(cached.map((dynamic s) => s['area_name']).toList(), full.map((dynamic s) => s['area_name']).toList());
    });

    test('pairs are reused by another service instance on the same device (shared store)', () async {
      await run(_stops(3));
      final RouteOptimizationService second =
          RouteOptimizationService(dio: Dio()..interceptors.add(rec), stopMatrixStore: store);
      await run(_stops(3), s: second);
      expect(rec.matrixElements, 16 + 3);
    });

    test('Directions uses the documented v5 endpoint, one request per optimization, no steps', () async {
      final Map<String, dynamic>? r = await run(_stops(2));
      final Uri d = rec.requests.firstWhere((Uri u) => u.path.contains('/directions/v'));
      expect(d.path, contains('/directions/v5/mapbox/driving/'));
      expect(d.queryParameters['steps'], 'false');
      expect(rec.directions, 1);
      expect((r!['stops'] as List<dynamic>).first['estimated_arrival'], endsWith('(est)'));
    });

    test('per-request element cap: an oversized first matrix is refused before the network', () async {
      final Map<String, dynamic>? r = await run(_stops(15)); // 16 x 16 = 256 > 200
      expect(r?['error'], 'MATRIX_BLOCKED');
      expect(rec.requests, isEmpty);
    });

    test('per-app-run caps hold even with cached rows', () async {
      for (int i = 0; i < 30; i++) {
        await run(_stops(13));
      }
      expect(rec.matrix, MapboxConfig.maxMatrixRequestsPerSession);
      expect(rec.matrixElements, 196 + 13 * (MapboxConfig.maxMatrixRequestsPerSession - 1));
      expect(rec.matrixElements, lessThanOrEqualTo(MapboxConfig.maxMatrixElementsPerSession));
    });

    test('manual cooldown: taps within 60 s start nothing', () {
      DateTime now = DateTime(2026, 10, 15, 8);
      final RouteOptimizationGate gate = RouteOptimizationGate(manualCooldown: const Duration(seconds: 60), clock: () => now);
      final int? t1 = gate.begin();
      expect(t1, isNotNull);
      gate.finish(t1!);
      for (int i = 0; i < 20; i++) {
        now = now.add(const Duration(seconds: 2));
        expect(gate.begin(), isNull);
      }
      now = now.add(const Duration(seconds: 30));
      expect(gate.begin(), isNotNull);
    });

    test('usage model for one testing day (assumptions in the test) is measured, not guessed', () async {
      // Assumptions: 3 test phones; each phone 3 trips per day; per trip 1 automatic run and 2
      // manual re-optimizations; 13 stops; 1000 GPS fixes and 1000 rebuilds per trip (they
      // reach the gate with an unchanged key and are refused); 20 rapid taps per trip.
      int runs = 0;
      DateTime now = DateTime(2026, 10, 15, 6);
      for (int phone = 0; phone < 3; phone++) {
        MapboxRequestGuard.debugReset();
        MapboxRequestGuard.debugMatrixEnabled = true;
        MapboxRequestGuard.debugDirectionsEnabled = true;
        MapboxRequestGuard.debugAccessToken = _fakeToken('joven-2323');
        final MemoryStopMatrixStore phoneStore = MemoryStopMatrixStore();
        final RouteOptimizationService phoneService =
            RouteOptimizationService(dio: Dio()..interceptors.add(rec), stopMatrixStore: phoneStore);
        final RouteOptimizationGate gate = RouteOptimizationGate(manualCooldown: const Duration(seconds: 60), clock: () => now);
        for (int trip = 0; trip < 3; trip++) {
          gate.reset();
          Future<void> attempt({String? autoKey}) async {
            final int? t = gate.begin(autoKey: autoKey);
            if (t == null) return;
            runs++;
            await run(_stops(13), s: phoneService);
            gate.finish(t);
          }
          final String key = 'trip$trip|hash|all';
          await attempt(autoKey: key);
          for (int i = 0; i < 2000; i++) {
            if (gate.shouldAutoRun(key)) await attempt(autoKey: key); // GPS fixes + rebuilds
          }
          for (int manual = 0; manual < 2; manual++) {
            now = now.add(const Duration(minutes: 30));
            await attempt(); // accepted re-optimize
            for (int tap = 0; tap < 20; tap++) {
              now = now.add(const Duration(seconds: 2));
              await attempt(); // rapid repeat taps within 60 s: refused
            }
          }
          now = now.add(const Duration(hours: 2));
        }
      }
      // Recorded by the interceptor:
      final int perPhoneRuns = runs ~/ 3;
      expect(runs, 27, reason: '3 phones x 3 trips x (1 automatic + 2 manual)');
      expect(rec.matrix, runs);
      expect(rec.directions, runs);
      expect(rec.matrixElements, 3 * (196 + 13 * (perPhoneRuns - 1)));
      // Printed for the report.
      // ignore: avoid_print
      print('USAGE MODEL: runs/day=$runs, matrix elements/day=${rec.matrixElements} '
          '(first day incl. one full matrix per phone), directions requests/day=${rec.directions}');
    });
  });

  group('driver route card', () {
    test('disabled: fixed notice, no retry offer, saved route still shown', () {
      final RouteCardState off = RouteCardState.resolve(hasRoute: false, isOptimizing: false, issue: 'x', disabled: true);
      expect(off.kind, RouteCardKind.disabled);
      expect(off.canRetry, isFalse);
      expect(off.isLoading, isFalse);
      expect(off.message, RouteCardState.disabledMessage);
      expect(RouteCardState.resolve(hasRoute: true, isOptimizing: false, disabled: true).kind, RouteCardKind.ready);
    });
  });

  group('map without a token', () {
    testWidgets('shows an honest notice instead of the map', (WidgetTester tester) async {
      MapboxGate.debugConfigured = false;
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MapboxGate(child: Text('MAP')))));
      expect(find.text('Map not configured'), findsOneWidget);
      expect(find.text('MAP'), findsNothing);
    });

    testWidgets('shows the map when configured', (WidgetTester tester) async {
      MapboxGate.debugConfigured = true;
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MapboxGate(child: Text('MAP')))));
      expect(find.text('MAP'), findsOneWidget);
    });
  });

  group('source checks', () {
    Iterable<File> dartFiles(String dir) => Directory(dir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'));
    String norm(File f) => f.path.replaceAll('\\', '/');

    test('no Mapbox token is hard-coded in lib/', () {
      for (final File f in dartFiles('lib')) {
        expect(RegExp(r'[ps]k\.ey[A-Za-z0-9_-]{10,}').hasMatch(f.readAsStringSync()), isFalse, reason: norm(f));
      }
    });

    test('the only Matrix call site is behind the guard', () {
      final List<String> sites = dartFiles('lib')
          .where((File f) => f.readAsStringSync().contains('api.mapbox.com/directions-matrix'))
          .map(norm)
          .toList();
      expect(sites, <String>['lib/services/route_optimization_service.dart']);
      final String src = File(sites.single).readAsStringSync();
      expect(src.indexOf('MapboxRequestGuard.acquire(MapboxService.matrix, coordinates'),
          lessThan(src.indexOf('directions-matrix/v1')));
      expect(src.indexOf('if (!isAvailable)'), lessThan(src.indexOf('_getOptimizedRouteDirectMapbox(')),
          reason: 'disabled check precedes both the direct and the proxy path');
      expect(src.indexOf('MapboxRequestGuard.acquire(MapboxService.directions)'),
          lessThan(src.indexOf('directions/v5/mapbox')));
      expect(src.contains('directions/v1/'), isFalse, reason: 'undocumented Directions version removed');
    });

    test('no Mapbox REST call in the PHP backend', () {
      for (final File f in Directory('backend').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.php')) continue;
        expect(f.readAsStringSync().contains('api.mapbox.com'), isFalse, reason: norm(f));
      }
    });

    test('driver dashboard: no build-time trigger, both entry points check the switch', () {
      final String src = File('lib/screens/driver_dashboard.dart').readAsStringSync();
      expect(src.contains('CARD_BUILD'), isFalse);
      for (final String entry in <String>[
        'Future<void> _optimizeRoute({bool isAuto = false, String? autoKey}) async {',
        'void _tryAutoOptimizeRoute(String trigger) async {',
      ]) {
        final int at = src.indexOf(entry);
        expect(at, greaterThan(0), reason: entry);
        final String head = src.substring(at, at + 500);
        expect(head.contains('if (!RouteOptimizationService.isAvailable)'), isTrue, reason: entry);
      }
    });

    test('every MapWidget is wrapped in MapboxGate', () {
      for (final File f in dartFiles('lib')) {
        final String src = f.readAsStringSync();
        final int all = RegExp(r'(?<![A-Za-z_])MapWidget\(').allMatches(src).length;
        final int gated = RegExp(r'MapboxGate\(\s*child:\s*MapWidget\(').allMatches(src).length;
        expect(gated, all, reason: norm(f));
      }
    });
  });
}
