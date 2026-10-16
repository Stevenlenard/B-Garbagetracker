import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/utils/fleet_status.dart';
import 'package:garbage_tracking_app/utils/gps_fix_policy.dart';

void main() {
  final DateTime now = DateTime.utc(2026, 10, 12, 8, 0, 0);

  group('GpsFixPolicy (driver-side fix acceptance)', () {
    test('fresh fix is accepted', () {
      expect(
        GpsFixPolicy.evaluate(fixTime: now.subtract(const Duration(seconds: 2)), nowTime: now),
        GpsFixVerdict.accept,
      );
    });

    test('stale cached fix is rejected', () {
      expect(
        GpsFixPolicy.evaluate(fixTime: now.subtract(const Duration(minutes: 5)), nowTime: now),
        GpsFixVerdict.stale,
      );
    });

    test('older fix arriving after a newer one is rejected as out-of-order', () {
      final DateTime newer = now.subtract(const Duration(seconds: 1));
      final DateTime older = now.subtract(const Duration(seconds: 6));
      expect(
        GpsFixPolicy.evaluate(fixTime: older, nowTime: now, lastAcceptedFixTime: newer),
        GpsFixVerdict.outOfOrder,
      );
    });

    test('newer fix always wins over the last accepted one', () {
      final DateTime last = now.subtract(const Duration(seconds: 4));
      final DateTime next = now.subtract(const Duration(seconds: 1));
      expect(
        GpsFixPolicy.evaluate(fixTime: next, nowTime: now, lastAcceptedFixTime: last),
        GpsFixVerdict.accept,
      );
    });

    test('missing or zero timestamp is accepted rather than blocking tracking', () {
      expect(
        GpsFixPolicy.evaluate(fixTime: DateTime.fromMillisecondsSinceEpoch(0), nowTime: now),
        GpsFixVerdict.accept,
      );
    });

    test('device clock far in the future does not freeze tracking', () {
      expect(
        GpsFixPolicy.evaluate(fixTime: now.add(const Duration(hours: 3)), nowTime: now),
        GpsFixVerdict.accept,
      );
    });
  });

  group('Admin and Resident consume the same rule', () {
    final int nowMs = now.millisecondsSinceEpoch;
    Map<String, Object?> node(String driver, int ageMs, {String status = 'ACTIVE', bool online = true}) => {
          'driver_id': driver,
          'status': status,
          'isOnline': online,
          'lastSeen': nowMs - ageMs,
          'latitude': 13.75,
          'longitude': 121.05,
        };

    test('latestPerKey keeps the newest node per driver regardless of arrival order', () {
      final Map<String, Map> a = FleetStatus.latestPerKey([
        MapEntry('7', node('7', 1000)),
        MapEntry('7', node('7', 90000)), // older event delivered later
      ]);
      expect(a['7']!['lastSeen'], nowMs - 1000);
    });

    test('stale node is not live, fresh node is', () {
      expect(FleetStatus.isLive(node('7', 300000), nowMs: nowMs), isFalse);
      expect(FleetStatus.isLive(node('7', 5000), nowMs: nowMs), isTrue);
    });

    test('FULL stays live and COMPLETED does not (status survives reconnect)', () {
      expect(FleetStatus.isLive(node('7', 5000, status: 'FULL'), nowMs: nowMs), isTrue);
      expect(FleetStatus.isLive(node('7', 5000, status: 'COMPLETED'), nowMs: nowMs), isFalse);
    });

    test('Active Fleets count equals Online Drivers count for the same snapshot', () {
      final Map<String, Map> snapshot = {
        'GT-001': node('7', 2000),
        'GT-002': node('9', 4000, status: 'IDLE'),
        'GT-007': node('7', 90000), // duplicate runtime of driver 7, older
        'GT-003': node('12', 600000), // stale ghost
        'GT-004': node('13', 1000, online: false),
      };
      final live = snapshot.entries
          .where((e) => FleetStatus.isLive(e.value, nowMs: nowMs))
          .map((e) => MapEntry(FleetStatus.driverKey(e.value), e.value));
      final Map<String, Map> perDriver = FleetStatus.latestPerKey(live);
      expect(perDriver.keys.toSet(), {'7', '9'});
      // Both dashboards derive their count from this map, so they cannot disagree.
      expect(perDriver.length, 2);
    });
  });

  group('GpsFixPolicy accuracy handling', () {
    DateTime t(int sAgo) => now.subtract(Duration(seconds: sAgo));

    test('degraded fix right after a good fix is rejected (rooftop jump)', () {
      expect(
        GpsFixPolicy.evaluate(
          fixTime: t(1), nowTime: now, lastAcceptedFixTime: t(3),
          accuracyM: 90, lastAcceptedAccuracyM: 8, lastAcceptedAgeMs: 2000),
        GpsFixVerdict.degraded,
      );
    });

    test('degraded fix is accepted when there is no recent good fix (no freeze)', () {
      expect(
        GpsFixPolicy.evaluate(
          fixTime: t(1), nowTime: now, lastAcceptedFixTime: t(30),
          accuracyM: 90, lastAcceptedAccuracyM: 8, lastAcceptedAgeMs: 29000),
        GpsFixVerdict.accept,
      );
      expect(
        GpsFixPolicy.evaluate(
          fixTime: t(1), nowTime: now, lastAcceptedFixTime: t(3),
          accuracyM: 90, lastAcceptedAccuracyM: 70, lastAcceptedAgeMs: 2000),
        GpsFixVerdict.accept,
      );
      expect(GpsFixPolicy.evaluate(fixTime: t(1), nowTime: now, accuracyM: 120), GpsFixVerdict.accept);
    });

    test('good fixes always pass, so walking stays responsive', () {
      expect(
        GpsFixPolicy.evaluate(
          fixTime: t(1), nowTime: now, lastAcceptedFixTime: t(2),
          accuracyM: 6, lastAcceptedAccuracyM: 8, lastAcceptedAgeMs: 1000),
        GpsFixVerdict.accept,
      );
    });

    test('two drivers are judged independently (no shared state)', () {
      final a = GpsFixPolicy.evaluate(fixTime: t(1), nowTime: now, accuracyM: 5);
      final b = GpsFixPolicy.evaluate(
          fixTime: t(1), nowTime: now, accuracyM: 90, lastAcceptedAccuracyM: 8, lastAcceptedAgeMs: 1000);
      expect(a, GpsFixVerdict.accept);
      expect(b, GpsFixVerdict.degraded);
    });

    test('out-of-order still wins over accuracy rules', () {
      expect(
        GpsFixPolicy.evaluate(
          fixTime: t(6), nowTime: now, lastAcceptedFixTime: t(1),
          accuracyM: 5, lastAcceptedAccuracyM: 5, lastAcceptedAgeMs: 500),
        GpsFixVerdict.outOfOrder,
      );
    });
  });
}
