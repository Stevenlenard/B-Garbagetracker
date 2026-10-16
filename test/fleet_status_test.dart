import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/fleet_status.dart';

void main() {
  const int now = 1700000000000;

  Map<String, dynamic> node({
    Object? isOnline = true,
    String status = 'ACTIVE',
    int? lastSeen,
    int? loginTime,
  }) {
    return {
      'isOnline': isOnline,
      'status': status,
      'lastSeen': lastSeen ?? now - 5000,
      if (loginTime != null) 'login_time': loginTime,
    };
  }

  group('FleetStatus.normalizeStatus', () {
    test('upper-cases and trims', () {
      expect(FleetStatus.normalizeStatus(' full '), 'FULL');
    });

    test('collapses legacy connection-loss labels to IDLE', () {
      expect(FleetStatus.normalizeStatus('IDLE (LOST)'), 'IDLE');
      expect(FleetStatus.normalizeStatus('idle (lost)'), 'IDLE');
    });

    test('missing status uses the fallback', () {
      expect(FleetStatus.normalizeStatus(null), 'OFFLINE');
      expect(FleetStatus.normalizeStatus('', fallback: 'ACTIVE'), 'ACTIVE');
    });
  });

  group('FleetStatus.isLive', () {
    test('online, collecting and fresh is live', () {
      expect(FleetStatus.isLive(node(), nowMs: now), isTrue);
    });

    test('online is not the same as collecting: IDLE and FULL trucks stay live', () {
      expect(FleetStatus.isLive(node(status: 'IDLE'), nowMs: now), isTrue);
      expect(FleetStatus.isLive(node(status: 'FULL'), nowMs: now), isTrue);
    });

    test('a COMPLETED trip is never live, even if a heartbeat set isOnline true', () {
      expect(FleetStatus.isLive(node(status: 'COMPLETED', isOnline: true), nowMs: now), isFalse);
      expect(FleetStatus.isLive(node(status: 'FINISHED', isOnline: true), nowMs: now), isFalse);
    });

    test('offline flag or OFFLINE status is not live', () {
      expect(FleetStatus.isLive(node(isOnline: false), nowMs: now), isFalse);
      expect(FleetStatus.isLive(node(status: 'OFFLINE'), nowMs: now), isFalse);
    });

    test('missing online flag is not online', () {
      final Map<String, dynamic> n = node()..remove('isOnline');
      expect(FleetStatus.isLive(n, nowMs: now), isFalse);
    });

    test('legacy numeric is_online flag is accepted', () {
      final Map<String, dynamic> n = node()..remove('isOnline');
      n['is_online'] = 1;
      expect(FleetStatus.isLive(n, nowMs: now), isTrue);
    });

    test('stale updates are not live; the window boundary is exclusive', () {
      expect(
        FleetStatus.isLive(node(lastSeen: now - FleetStatus.freshnessWindowMs + 1), nowMs: now),
        isTrue,
      );
      expect(
        FleetStatus.isLive(node(lastSeen: now - FleetStatus.freshnessWindowMs), nowMs: now),
        isFalse,
      );
    });

    test('legacy IDLE (LOST) with online flag reads as a live IDLE truck', () {
      expect(FleetStatus.isLive(node(status: 'IDLE (LOST)'), nowMs: now), isTrue);
    });

    test('session older than the limit is not live', () {
      expect(
        FleetStatus.isLive(node(loginTime: now - FleetStatus.sessionLimitMs - 1), nowMs: now),
        isFalse,
      );
      expect(
        FleetStatus.isLive(node(loginTime: now - 1000), nowMs: now),
        isTrue,
      );
    });
  });

  group('FleetStatus counting (multiple simultaneous drivers)', () {
    test('only live drivers are counted', () {
      final Map<String, Map<String, dynamic>> fleet = {
        'GT-001': node(),
        'GT-002': node(status: 'FULL'),
        'GT-003': node(status: 'IDLE'),
        'GT-004': node(status: 'COMPLETED'),
        'GT-005': node(isOnline: false),
        'GT-006': node(lastSeen: now - 10 * 60 * 1000),
      };
      final int live = fleet.values.where((n) => FleetStatus.isLive(n, nowMs: now)).length;
      expect(live, 3);
    });
  });

  group('FleetStatus helpers', () {
    test('parseTimestampMs handles numbers, ISO-like strings and null', () {
      expect(FleetStatus.parseTimestampMs(1234), 1234);
      expect(FleetStatus.parseTimestampMs(null), 0);
      expect(FleetStatus.parseTimestampMs('not a date'), 0);
      expect(
        FleetStatus.parseTimestampMs('2026-01-02 03:04:05'),
        DateTime(2026, 1, 2, 3, 4, 5).millisecondsSinceEpoch,
      );
    });

    test('hasValidCoords rejects zero and out-of-range values', () {
      expect(FleetStatus.hasValidCoords({'latitude': 13.9, 'longitude': 121.1}), isTrue);
      expect(FleetStatus.hasValidCoords({'lat': '13.9', 'lng': '121.1'}), isTrue);
      expect(FleetStatus.hasValidCoords({'latitude': 0.0, 'longitude': 0.0}), isFalse);
      expect(FleetStatus.hasValidCoords({'latitude': 95.0, 'longitude': 121.1}), isFalse);
      expect(FleetStatus.hasValidCoords({}), isFalse);
    });

    test('a missing timestamp is treated as fresh', () {
      expect(FleetStatus.isFresh(0, now), isTrue);
    });
  });
}
