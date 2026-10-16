import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/chatbot/faq_bot.dart';
import 'package:garbage_tracking_app/chatbot/fleet_snapshot.dart';
import 'package:garbage_tracking_app/utils/collection_visits.dart';

void main() {
  final FaqBot resident = FaqBot(BotRole.resident);
  final FaqBot guest = FaqBot(BotRole.guest);
  final FaqBot admin = FaqBot(BotRole.admin);
  const int now = 1792110000000;

  Map<String, Object?> node({String status = 'ACTIVE', bool online = true, int ageS = 10, double lat = 13.9545, double lng = 121.1601, Object driver = 7, int? loginAgeS}) =>
      <String, Object?>{
        'status': status,
        'isOnline': online,
        'lastSeen': now - ageS * 1000,
        'latitude': lat,
        'longitude': lng,
        'driver_id': driver,
        'driver_name': 'Steve Espaldon',
        if (loginAgeS != null) 'login_time': now - loginAgeS * 1000,
      };

  final List<AreaGeofence> areas = <AreaGeofence>[const AreaGeofence(name: 'Central (Purok 1)', lat: 13.9545, lng: 121.1601, radiusM: 200)];

  group('LiveFleet uses the map rules', () {
    test('online, fresh, real coordinates -> shown with its purok', () {
      final FleetSnapshot f = LiveFleet.parse(<String, dynamic>{'GT-007': node()}, areas: areas, nowMs: now);
      expect(f.trucks.single.id, 'GT-007');
      expect(f.trucks.single.area, 'Central (Purok 1)');
    });

    test('stale, offline, completed, zero coordinates or expired session -> hidden', () {
      final FleetSnapshot f = LiveFleet.parse(<String, dynamic>{
        'GT-001': node(ageS: 400, driver: 1),
        'GT-002': node(online: false, driver: 2),
        'GT-003': node(status: 'COMPLETED', driver: 3),
        'GT-004': node(lat: 0, lng: 0, driver: 4),
        'GT-005': node(loginAgeS: 13 * 3600, driver: 5),
      }, nowMs: now);
      expect(f.trucks, isEmpty);
    });

    test('one truck per driver: the newest wins', () {
      final FleetSnapshot f = LiveFleet.parse(<String, dynamic>{'GT-001': node(ageS: 100), 'GT-007': node(ageS: 5)}, nowMs: now);
      expect(f.trucks.map((LiveTruck t) => t.id), <String>['GT-007']);
    });
  });

  group('live answers', () {
    final FleetSnapshot one = LiveFleet.parse(<String, dynamic>{'GT-007': node()}, areas: areas, nowMs: now);
    const FleetSnapshot none = FleetSnapshot(<LiveTruck>[], now);

    test('how many trucks / ilan', () {
      final BotReply r = resident.reply('how many trucks are online', fleet: one);
      expect(r.kind, BotReplyKind.live);
      expect(r.text, contains('1 truck is online'));
      expect(r.text, contains('GT-007'));
      expect(r.text, contains('Central (Purok 1)'));
      expect(resident.reply('ilan ang truck ngayon', fleet: none).text, contains('no garbage truck is online'));
    });

    test('a specific truck, written different ways', () {
      expect(resident.reply('nasaan ang gt 7', fleet: one).text, startsWith('GT-007 is on an active collection trip in Central (Purok 1)'));
      expect(resident.reply('is GT-005 online?', fleet: one).text, contains('GT-005 is not online right now'));
      expect(FaqBot.truckIdIn(FaqBot.normalize('gt007')), 'GT-007');
    });

    test('driver names only for admins and drivers', () {
      expect(resident.reply('where is gt-007', fleet: one).text, isNot(contains('Steve')));
      expect(guest.reply('where is gt-007', fleet: one).text, isNot(contains('Steve')));
      expect(admin.reply('where is gt-007', fleet: one).text, contains('Steve Espaldon'));
    });

    test('"where is the truck" adds the live situation to the answer', () {
      final BotReply r = guest.reply('where is the truck', fleet: one);
      expect(r.entry?.id, 'guest_where_truck');
      expect(r.text, startsWith('Right now 1 truck is online'));
    });

    test('rule questions are not mistaken for live questions', () {
      expect(resident.reply('why is a truck not showing on the map', fleet: one).entry?.id, 'map_truck_missing');
    });

    test('before the data loads', () {
      expect(resident.reply('how many trucks are online').text, contains('still loading'));
    });
  });

  group('map knowledge', () {
    void expectId(FaqBot b, String q, String id) => expect(b.reply(q).entry?.id, id, reason: q);

    test('colours, rings, words and rules', () {
      expectId(resident, 'what do the colors mean', 'map_colors');
      expectId(guest, 'ano ibig sabihin ng kulay', 'map_colors');
      expectId(resident, 'why does each truck have a different color', 'map_truck_color');
      expectId(resident, 'what does the orange ring mean', 'map_ring');
      expectId(guest, 'what does idle mean', 'map_status_words');
      expectId(resident, 'what does GPS delayed mean', 'map_gps_delayed');
      expectId(guest, 'bakit wala sa mapa yung truck', 'map_truck_missing');
      expectId(resident, 'what is a verified visit', 'map_verified_visit');
      expectId(resident, 'does no record mean we were skipped', 'map_no_record');
      expectId(resident, 'what does overdue mean', 'collection_status');
      expectId(guest, 'what do the collection status colours mean', 'collection_status');
      expectId(resident, 'how is the eta computed', 'map_eta');
      expectId(resident, 'what is the blue dot', 'map_you_marker');
      expectId(resident, 'what does 14+ days filter do', 'map_filters');
    });

    test('collection status answer states the real thresholds', () {
      final String a = resident.reply('what does overdue mean').text;
      expect(a, contains('less than 7 days'));
      expect(a, contains('7 to 13 days'));
      expect(a, contains('14 days or more'));
      expect(a, contains('90 days'));
    });
  });

  test('one typo is tolerated', () {
    expect(resident.reply('I am not getting notifcations').entry?.id, 'notif_not_receiving');
    expect(resident.reply('how do I file a complant').entry?.id, 'file_complaint');
  });

  test('rude messages get a polite reply', () {
    final BotReply r = guest.reply('tanginamo');
    expect(r.kind, BotReplyKind.smallTalk);
    expect(r.text, contains('friendly'));
  });
}
