import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/services/arrival_notifications.dart';
import 'package:garbage_tracking_app/services/notification_inbox.dart';
import 'package:garbage_tracking_app/utils/eta_policy.dart';
import 'package:garbage_tracking_app/utils/relative_time.dart';

import 'support/fake_rtdb.dart';

String src(String p) => File(p).readAsStringSync().replaceAll(String.fromCharCodes(<int>[13, 10]), String.fromCharCode(10));

void main() {
  // A fixed "now": Monday 2026-10-12 12:00 local time.
  final DateTime nowDt = DateTime(2026, 10, 12, 12, 0, 0);
  final int now = nowDt.millisecondsSinceEpoch;
  int ago({int seconds = 0, int minutes = 0, int hours = 0, int days = 0}) =>
      now - ((((days * 24 + hours) * 60 + minutes) * 60 + seconds) * 1000);

  group('relative timestamps (from the persisted time)', () {
    test('just now / minutes / hours', () {
      expect(RelativeTime.format(ago(seconds: 5), nowMs: now), 'Just now');
      expect(RelativeTime.format(ago(seconds: 59), nowMs: now), 'Just now');
      expect(RelativeTime.format(ago(minutes: 1), nowMs: now), '1 minute ago');
      expect(RelativeTime.format(ago(minutes: 3), nowMs: now), '3 minutes ago');
      expect(RelativeTime.format(ago(minutes: 59), nowMs: now), '59 minutes ago');
      expect(RelativeTime.format(ago(hours: 1, minutes: 5), nowMs: now), '1 hour ago');
      expect(RelativeTime.format(ago(hours: 5), nowMs: now), '5 hours ago');
    });

    test('yesterday / days / older dates', () {
      expect(RelativeTime.format(DateTime(2026, 10, 11, 23, 30).millisecondsSinceEpoch, nowMs: now), 'Yesterday');
      expect(RelativeTime.format(ago(days: 2), nowMs: now), '2 days ago');
      expect(RelativeTime.format(ago(days: 6), nowMs: now), '6 days ago');
      expect(RelativeTime.format(ago(days: 20), nowMs: now), matches(RegExp(r'^[A-Z][a-z]{2} \d{1,2}, \d{4}$')));
    });

    test('the label is a function of the stored timestamp, not of when the list opens', () {
      final int stamp = ago(minutes: 10);
      // "reopening" later shows a larger age; reopening at the same moment is identical
      expect(RelativeTime.format(stamp, nowMs: now), RelativeTime.format(stamp, nowMs: now));
      expect(RelativeTime.format(stamp, nowMs: now + 3600000), '1 hour ago');
    });

    test('missing or invalid timestamps show nothing instead of a made-up time', () {
      expect(RelativeTime.format(null, nowMs: now), '');
      expect(RelativeTime.format(0, nowMs: now), '');
      expect(RelativeTime.format('abc', nowMs: now), '');
    });

    test('a timestamp slightly in the future (clock skew) is "Just now"', () {
      expect(RelativeTime.format(now + 30000, nowMs: now), 'Just now');
    });
  });

  group('notification inbox is per user and never edits the shared log', () {
    FakeRtdb seeded() {
      final db = FakeRtdb();
      db.seed('notifications', <String, Object?>{
        'n1': {'type': 'auto_approach', 'title': 'A', 'purok': 'Central (Purok 1)', 'timestamp': 1000, 'isRead': false},
        'n2': {'type': 'auto_arrival', 'title': 'B', 'purok': 'Central (Purok 1)', 'timestamp': 2000, 'isRead': false},
        'n3': {'type': 'auto_approach', 'title': 'C', 'purok': 'Central (Purok 1)', 'timestamp': 3000, 'isRead': false},
      });
      return db;
    }

    List<Map> relevant(FakeRtdb db) {
      final Map m = db.read('notifications') as Map;
      return m.entries.map((e) => <dynamic, dynamic>{...(e.value as Map), 'key': e.key}).toList();
    }

    test('Clear All hides everything for THAT user only', () async {
      final db = seeded();
      final alice = NotificationInbox(db: db, role: 'resident', userId: 15);
      final bob = NotificationInbox(db: db, role: 'resident', userId: 16);

      final aliceState0 = await alice.load();
      await alice.clearAll(NotificationInbox.visible(relevant(db), aliceState0));

      final aliceView = NotificationInbox.visible(relevant(db), await alice.load());
      final bobView = NotificationInbox.visible(relevant(db), await bob.load());
      expect(aliceView, isEmpty);
      expect(bobView.length, 3, reason: 'another resident still has all three');
    });

    test('the shared operational log is preserved (analytics / audit)', () async {
      final db = seeded();
      final inbox = NotificationInbox(db: db, role: 'resident', userId: 15);
      await inbox.markRead(<String>['n1', 'n2']);
      await inbox.dismiss('n3');
      await inbox.clearAll(relevant(db));
      final Map log = db.read('notifications') as Map;
      expect(log.length, 3);
      expect((log['n1'] as Map)['isRead'], false, reason: 'shared flag untouched');
    });

    test('unread counts follow this user\'s read state', () async {
      final db = seeded();
      final inbox = NotificationInbox(db: db, role: 'resident', userId: 15);
      InboxState st = await inbox.load();
      var visible = NotificationInbox.visible(relevant(db), st);
      expect(NotificationInbox.unreadCount(visible, st), 3);

      await inbox.markRead(<String>['n1']);
      st = await inbox.load();
      visible = NotificationInbox.visible(relevant(db), st);
      expect(NotificationInbox.unreadCount(visible, st), 2);

      await inbox.dismiss('n2');
      st = await inbox.load();
      visible = NotificationInbox.visible(relevant(db), st);
      expect(visible.length, 2);
      expect(NotificationInbox.unreadCount(visible, st), 1);
    });

    test('another user reading does not change my unread count', () async {
      final db = seeded();
      final me = NotificationInbox(db: db, role: 'resident', userId: 15);
      final other = NotificationInbox(db: db, role: 'resident', userId: 16);
      await other.markRead(<String>['n1', 'n2', 'n3']);
      final st = await me.load();
      expect(NotificationInbox.unreadCount(NotificationInbox.visible(relevant(db), st), st), 3);
    });

    test('a notification that arrives AFTER Clear All stays visible', () async {
      final db = seeded();
      final inbox = NotificationInbox(db: db, role: 'driver', userId: 7);
      await inbox.clearAll(relevant(db));
      db.seed('notifications/n4', <String, Object?>{'type': 'auto_approach', 'timestamp': 5000, 'isRead': false});
      final st = await inbox.load();
      final visible = NotificationInbox.visible(relevant(db), st);
      expect(visible.map((n) => n['key']), ['n4']);
    });

    test('roles are separate inboxes even with the same numeric id', () async {
      final db = seeded();
      final resident = NotificationInbox(db: db, role: 'resident', userId: 15);
      final driver = NotificationInbox(db: db, role: 'driver', userId: 15);
      expect(resident.path, isNot(driver.path));
      await resident.clearAll(relevant(db));
      final st = await driver.load();
      expect(NotificationInbox.visible(relevant(db), st).length, 3);
    });

    test('Clear All with nothing visible writes nothing', () async {
      final db = FakeRtdb();
      final inbox = NotificationInbox(db: db, role: 'admin', userId: 1);
      await inbox.clearAll(<Map>[]);
      expect(db.read(inbox.path), isNull);
    });
  });

  group('arrival notifications: once per truck trip, area and stage', () {
    Future<bool> send(FakeRtdb db, {String trip = 'trip-1', String area = 'Central (Purok 1)', String stage = 'approach_10', String truck = 'GT-007'}) =>
        ArrivalNotifications.publishOnce(
          db: db,
          stage: stage,
          tripId: trip,
          areaKey: area,
          nowMs: 1760000000000,
          payload: <String, Object?>{'type': 'auto_approach', 'title': 'T', 'message': 'M', 'purok': area, 'truck_id': truck},
        );

    test('repeated GPS updates / restarts / second runtime create ONE record', () async {
      final db = FakeRtdb();
      expect(await send(db), isTrue);
      for (int i = 0; i < 5; i++) {
        expect(await send(db), isFalse);
      }
      expect((db.read('notifications') as Map).length, 1);
    });

    test('a NEW trip alerts again (legitimate new notification)', () async {
      final db = FakeRtdb();
      expect(await send(db, trip: 'trip-1'), isTrue);
      expect(await send(db, trip: 'trip-2'), isTrue);
      expect((db.read('notifications') as Map).length, 2);
    });

    test('different stage or area is a different notification', () async {
      final db = FakeRtdb();
      expect(await send(db, stage: 'approach_15'), isTrue);
      expect(await send(db, stage: 'approach_10'), isTrue);
      expect(await send(db, stage: 'approach_5'), isTrue);
      expect(await send(db, area: 'Brixton Homes'), isTrue);
      expect((db.read('notifications') as Map).length, 4);
    });

    test('the record names its truck, trip, area and stage and carries a persisted time', () async {
      final db = FakeRtdb();
      await send(db, trip: 'trip-9', area: 'Central (Purok 1)', stage: 'arrival', truck: 'GT-008');
      final Map rec = (db.read('notifications') as Map).values.single as Map;
      expect(rec['trip_id'], 'trip-9');
      expect(rec['stage'], 'arrival');
      expect(rec['area_key'], 'Central (Purok 1)');
      expect(rec['truck_id'], 'GT-008');
      expect(rec['timestamp'], 1760000000000);
      expect(rec['isRead'], false);
    });

    test('keys are valid Firebase keys', () {
      final k = ArrivalNotifications.key(stage: 'approach_10', tripId: '-Nx.y', areaKey: 'Ayala Highway (A/B)');
      expect(k, isNot(contains('.')));
      expect(k, isNot(contains('/')));
      expect(k, isNot(contains(' ')));
    });
  });

  group('ETA policy', () {
    test('a justified estimate: collecting, fresh GPS, real speed, real distance', () {
      final r = EtaPolicy.evaluate(status: 'ACTIVE', gpsAgeMs: 4000, distanceKm: 2.5, speedKmh: 20);
      expect(r.kind, EtaKind.minutes);
      expect(r.minutes, 8); // 2.5 km / 20 km/h = 7.5 min -> 8
      expect(r.stage, 10);
      expect(r.approximate, isTrue, reason: 'straight-line distance is labelled approximate');
      expect(r.label, '~8 min');
    });

    test('route distance is not marked approximate', () {
      final r = EtaPolicy.evaluate(status: 'ACTIVE', gpsAgeMs: 0, distanceKm: 1.0, speedKmh: 15, distanceIsRoute: true);
      expect(r.label, '4 min');
    });

    test('0 minutes never appears: close but not arrived is at least 1 minute', () {
      final r = EtaPolicy.evaluate(status: 'ACTIVE', gpsAgeMs: 0, distanceKm: 0.12, speedKmh: 40);
      expect(r.kind, EtaKind.minutes);
      expect(r.minutes, 1);
    });

    test('arrival is a confirmed fact, not "0 minutes"', () {
      final r = EtaPolicy.evaluate(status: 'ACTIVE', gpsAgeMs: 0, distanceKm: 0.03, speedKmh: 10, arrivalRadiusM: 60);
      expect(r.kind, EtaKind.arrived);
      expect(r.minutes, isNull);
      expect(r.label, 'Arrived');
    });

    test('PAUSED, FULL, COMPLETED and OFFLINE trucks give no estimate', () {
      for (final s in ['IDLE', 'PAUSED', 'FULL', 'COMPLETED', 'OFFLINE']) {
        final r = EtaPolicy.evaluate(status: s, gpsAgeMs: 0, distanceKm: 1, speedKmh: 20);
        expect(r.isAvailable, isFalse, reason: s);
        expect(r.label, 'ETA unavailable');
      }
    });

    test('stale GPS gives no estimate', () {
      final r = EtaPolicy.evaluate(status: 'ACTIVE', gpsAgeMs: 400000, distanceKm: 1, speedKmh: 20);
      expect(r.isAvailable, isFalse);
      expect(r.reason, contains('out of date'));
    });

    test('missing data gives "ETA unavailable", never a guess', () {
      expect(EtaPolicy.evaluate(status: 'ACTIVE', gpsAgeMs: null, distanceKm: 1, speedKmh: 20).isAvailable, isFalse);
      expect(EtaPolicy.evaluate(status: 'ACTIVE', gpsAgeMs: 0, distanceKm: null, speedKmh: 20).isAvailable, isFalse);
      expect(EtaPolicy.evaluate(status: 'ACTIVE', gpsAgeMs: 0, distanceKm: 1, speedKmh: null).isAvailable, isFalse);
      expect(EtaPolicy.evaluate(status: null, gpsAgeMs: 0, distanceKm: 1, speedKmh: 20).isAvailable, isFalse);
    });

    test('a stationary collecting truck falls back to its measured average speed, else unavailable', () {
      final withAvg = EtaPolicy.evaluate(status: 'ACTIVE', gpsAgeMs: 0, distanceKm: 1.2, speedKmh: 0, averageSpeedKmh: 12);
      expect(withAvg.isAvailable, isTrue);
      expect(withAvg.minutes, 6);
      final noAvg = EtaPolicy.evaluate(status: 'ACTIVE', gpsAgeMs: 0, distanceKm: 1.2, speedKmh: 0, averageSpeedKmh: 0);
      expect(noAvg.isAvailable, isFalse);
    });

    test('estimates beyond 90 minutes are not meaningful', () {
      final r = EtaPolicy.evaluate(status: 'ACTIVE', gpsAgeMs: 0, distanceKm: 60, speedKmh: 20);
      expect(r.isAvailable, isFalse);
    });

    test('stages are 15 / 10 / 5 minutes', () {
      expect(EtaPolicy.stageFor(30), isNull);
      expect(EtaPolicy.stageFor(15), 15);
      expect(EtaPolicy.stageFor(11), 15);
      expect(EtaPolicy.stageFor(10), 10);
      expect(EtaPolicy.stageFor(6), 10);
      expect(EtaPolicy.stageFor(5), 5);
      expect(EtaPolicy.stageFor(1), 5);
    });
  });

  group('the defects are gone from the code paths', () {
    test('the resident app no longer broadcasts its own arrival alerts', () {
      final resident = src('lib/screens/resident_dashboard.dart');
      expect(resident.contains("'type': 'TRUCK_PROXIMITY'"), isFalse);
      expect(resident.contains('Truck is Arriving!'), isFalse);
      expect(resident.contains('PredictionEngine.estimateArrivalTime'), isFalse);
      expect(resident.contains('EtaPolicy.evaluate'), isTrue);
    });

    test('the driver approach alert uses the policy and the once-only write, not a fixed 15 km/h', () {
      final driver = src('lib/screens/driver_dashboard.dart');
      expect(driver.contains('double speedMps = 15 / 3.6'), isFalse);
      expect(driver.contains('etaMinutes < 1'), isFalse);
      expect(driver.contains('ArrivalNotifications.publishOnce'), isTrue);
      expect(driver.contains('EtaPolicy.evaluate'), isTrue);
    });

    test('no role deletes records from the shared notification log any more', () {
      for (final f in [
        'lib/screens/resident_dashboard.dart',
        'lib/screens/admin_dashboard.dart',
        'lib/screens/driver_dashboard.dart',
      ]) {
        final s = src(f);
        expect(RegExp(r"ref\('notifications/[^']*'\)\.remove\(\)").hasMatch(s), isFalse, reason: f);
        expect(s.contains('NotificationInbox'), isTrue, reason: f);
        expect(s.contains('showNotificationCenter('), isTrue, reason: '$f uses the shared notification center');
      }
      expect(src('lib/widgets/notification_center.dart').contains('RelativeTime.format'), isTrue);
    });
  });
}
