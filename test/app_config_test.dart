import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/config/app_config.dart';
import 'package:garbage_tracking_app/utils/tracking_telemetry.dart';

void main() {
  // A complete, valid test-mode configuration (dummy, non-production values).
  Map<String, String> validTest() => {
        'apiKey': 'test-key',
        'appId': '1:111:web:abc',
        'senderId': '111',
        'projectId': 'gt-isolated-test',
        'databaseUrl': 'https://gt-isolated-test-default-rtdb.firebaseio.com',
        'apiBaseUrl': 'http://127.0.0.1:8080/',
      };

  List<String> check({required bool testMode, Map<String, String>? values}) {
    final v = values ?? {};
    return AppConfig.validateValues(
      testMode: testMode,
      apiKey: v['apiKey'] ?? '',
      appId: v['appId'] ?? '',
      senderId: v['senderId'] ?? '',
      projectId: v['projectId'] ?? '',
      databaseUrl: v['databaseUrl'] ?? '',
      apiBaseUrl: v['apiBaseUrl'] ?? '',
    );
  }

  group('AppConfig.validateValues: production default', () {
    test('no overrides and no test flag is valid (production unchanged)', () {
      expect(check(testMode: false), isEmpty);
    });

    test('any override without GT_TEST_MODE is refused, never silently used', () {
      final problems = check(testMode: false, values: {'apiBaseUrl': 'http://127.0.0.1:8080/'});
      expect(problems, hasLength(1));
      expect(problems.first, contains('GT_API_BASE_URL'));
      expect(problems.first, contains('GT_TEST_MODE'));
    });
  });

  group('AppConfig.validateValues: test mode', () {
    test('a complete isolated configuration is valid', () {
      expect(check(testMode: true, values: validTest()), isEmpty);
    });

    test('every missing key is reported by name and nothing falls back', () {
      final problems = check(testMode: true);
      expect(problems, hasLength(6));
      for (final key in [
        'GT_FIREBASE_API_KEY',
        'GT_FIREBASE_APP_ID',
        'GT_FIREBASE_MESSAGING_SENDER_ID',
        'GT_FIREBASE_PROJECT_ID',
        'GT_FIREBASE_DATABASE_URL',
        'GT_API_BASE_URL',
      ]) {
        expect(problems.any((p) => p.contains(key)), isTrue, reason: '$key should be reported');
      }
    });

    test('a single missing key is enough to fail', () {
      final v = validTest()..['projectId'] = '';
      final problems = check(testMode: true, values: v);
      expect(problems, hasLength(1));
      expect(problems.first, contains('GT_FIREBASE_PROJECT_ID'));
    });

    test('the production Firebase project is rejected', () {
      final v = validTest()
        ..['projectId'] = AppConfig.productionProjectId
        ..['databaseUrl'] = 'https://${AppConfig.productionProjectId}-default-rtdb.firebasedatabase.app';
      expect(check(testMode: true, values: v), isNotEmpty);
    });

    test('a production database URL is rejected even with a different project id', () {
      final v = validTest()
        ..['databaseUrl'] = 'https://${AppConfig.productionProjectId}-default-rtdb.firebasedatabase.app';
      expect(check(testMode: true, values: v), isNotEmpty);
    });

    test('the Hostinger backend is rejected', () {
      final v = validTest()..['apiBaseUrl'] = 'https://example.hostingersite.com/backend/';
      expect(check(testMode: true, values: v), isNotEmpty);
    });

    test('only loopback / private LAN addresses are accepted for the stub', () {
      for (final ok in [
        'http://127.0.0.1:8080/',
        'http://localhost:8080/',
        'http://10.0.2.2:8080/',
        'http://192.168.1.20:8080/',
        'http://172.16.5.4:8080/',
      ]) {
        final v = validTest()..['apiBaseUrl'] = ok;
        expect(check(testMode: true, values: v), isEmpty, reason: ok);
      }
      for (final bad in [
        'http://8.8.8.8/',
        'http://172.32.0.1/',
        'https://api.example.com/backend/',
        'not a url',
      ]) {
        final v = validTest()..['apiBaseUrl'] = bad;
        expect(check(testMode: true, values: v), isNotEmpty, reason: bad);
      }
    });

    test('problem messages never contain the configured values', () {
      final v = validTest()
        ..['apiKey'] = 'SECRET-KEY-VALUE'
        ..['projectId'] = AppConfig.productionProjectId;
      final text = check(testMode: true, values: v).join(' ');
      expect(text, isNot(contains('SECRET-KEY-VALUE')));
    });
  });

  group('AppConfig.scrubForLogs', () {
    test('removes coordinate-like decimals', () {
      final out = AppConfig.scrubForLogs('latitude: 13.956512 longitude: 121.162034 speed: 3');
      expect(out, isNot(contains('13.956512')));
      expect(out, isNot(contains('121.162034')));
      expect(out, contains('speed: 3'));
    });

    test('handles negative values and null', () {
      expect(AppConfig.scrubForLogs('lng=-121.16203'), isNot(contains('121.16203')));
      expect(AppConfig.scrubForLogs(null), '');
    });
  });

  group('TrackingTelemetry statistics', () {
    test('is disabled unless explicitly enabled in test mode', () {
      expect(TrackingTelemetry.enabled, isFalse);
    });

    test('stats of an empty list are zeros', () {
      expect(TrackingTelemetry.stats(const [])['n'], 0);
    });

    test('min / median / p95 / max', () {
      final samples = List<int>.generate(100, (i) => i + 1); // 1..100
      final st = TrackingTelemetry.stats(samples);
      expect(st['n'], 100);
      expect(st['min'], 1);
      expect(st['median'], 50);
      expect(st['p95'], 95);
      expect(st['max'], 100);
    });

    test('unsorted input and a single sample', () {
      expect(TrackingTelemetry.stats([30, 10, 20])['median'], 20);
      final one = TrackingTelemetry.stats([42]);
      expect([one['min'], one['median'], one['p95'], one['max']], [42, 42, 42, 42]);
    });
  });
}
