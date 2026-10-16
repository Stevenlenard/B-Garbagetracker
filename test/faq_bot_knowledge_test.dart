import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/chatbot/faq_bot.dart';
import 'package:garbage_tracking_app/chatbot/fleet_snapshot.dart';
import 'package:garbage_tracking_app/services/collection_schedule_service.dart';

void main() {
  final FaqBot guest = FaqBot(BotRole.guest);
  final FaqBot resident = FaqBot(BotRole.resident);
  final FaqBot driver = FaqBot(BotRole.driver);

  void expectId(FaqBot b, String q, String id) {
    final BotReply r = b.reply(q);
    expect(r.entry?.id, id, reason: '"$q" -> ${r.kind} ${r.entry?.id} ${r.text.split('\n').first}');
  }

  group('notifications', () {
    test('the questions from the screenshot', () {
      expectId(resident, 'how can i receive notifications', 'notif_what');
      expectId(resident, 'what are the notifications i will be receiving', 'notif_what');
      expectId(guest, 'what are the notifications i will be receiving', 'guest_alerts');
      expect(guest.reply('how can i receive notifications').text, contains('15, 10 and 5 minutes'));
    });

    test('other notification topics', () {
      expectId(resident, 'why am i not receiving notifications', 'notif_not_receiving');
      expectId(resident, 'walang notification na dumarating', 'notif_not_receiving');
      expectId(resident, 'what happens when i tap a notification', 'notif_tap');
      expectId(resident, 'how do i clear all notifications', 'notif_clear');
      expectId(driver, 'how to delete notification', 'notif_clear');
      expectId(resident, 'how to turn off notifications', 'notif_turn_off');
      expectId(driver, 'what notifications do i get', 'notif_driver');
    });
  });

  test('ETA', () {
    expectId(resident, 'what is the estimated time on my dashboard', 'eta_resident');
    expectId(guest, 'how is the eta calculated', 'map_eta');
  });

  group('complaints', () {
    test('everyone can ask about complaints', () {
      expectId(guest, 'what can i report', 'complaint_categories');
      expectId(guest, 'can i file a complaint without an account', 'complaint_guest');
      expectId(guest, 'who can file a complaint', 'complaint_who');
      expectId(resident, 'what does in progress mean', 'complaint_status_meaning');
      expectId(resident, 'how do i file a complaint', 'file_complaint');
      expectId(resident, 'can i delete my complaint', 'complaint_who');
    });
  });

  group('terms, privacy, FAQs', () {
    test('policies', () {
      expectId(guest, 'what are the terms and conditions', 'terms_summary');
      expectId(resident, 'ano ang patakaran', 'terms_summary');
      expectId(guest, 'what is your privacy policy', 'privacy_summary');
      expectId(resident, 'who can see my location', 'privacy_location');
      expectId(guest, 'data privacy act delete my data', 'privacy_rights');
    });

    test('general', () {
      expectId(guest, 'is the app free', 'faq_cost');
      expectId(guest, 'magkano ang app', 'faq_cost');
      expectId(resident, 'what languages are supported', 'faq_languages');
      expectId(guest, 'can i use it on iphone', 'faq_devices');
      expectId(guest, 'who manages this system', 'faq_who_runs');
    });
  });

  group('fleet size', () {
    const PublicStats stats = PublicStats(drivers: 4, trucks: 3, serviceAreas: 10);
    const FleetSnapshot none = FleetSnapshot(<LiveTruck>[], 0);

    test('registered drivers and trucks plus online now', () {
      final BotReply r = guest.reply('how many trucks are there', stats: stats, fleet: none);
      expect(r.kind, BotReplyKind.live);
      expect(r.text, contains('4 registered drivers and 3 garbage trucks'));
      expect(r.text, contains('no truck is online'));
      expect(guest.reply('ilan ang driver', stats: stats).text, contains('4 registered drivers'));
    });

    test('"how many trucks are online now" stays a live question', () {
      expect(guest.reply('how many trucks are online now', stats: stats, fleet: none).text, contains('no garbage truck is online'));
    });

    test('counts not loaded', () {
      expect(guest.reply('how many drivers are there').text, contains('could not load'));
    });
  });

  group('usual collection days', () {
    final Map<String, CollectionSchedule> sched = <String, CollectionSchedule>{
      'Central (Purok 1)': const CollectionSchedule(area: 'Central (Purok 1)', days: <int>[1, 4], time: '07:00'),
      'Riverside': const CollectionSchedule(area: 'Riverside', days: <int>[6], time: '13:30'),
    };

    test('a resident gets their own purok', () {
      final BotReply r = resident.reply('what day is the garbage collection', schedules: sched, purok: 'Central (Purok 1)');
      expect(r.text, contains('Collection in Central (Purok 1): every Monday and Thursday, around 7:00 AM'));
    });

    test('a purok named in the question, including short names', () {
      expect(guest.reply('anong araw ang koleksyon sa riverside', schedules: sched).text, contains('every Saturday, around 1:30 PM'));
      expect(guest.reply('schedule of purok 1', schedules: sched).text, contains('Central (Purok 1)'));
    });

    test('a guest without a purok gets every area', () {
      final String t = guest.reply('what is the collection schedule', schedules: sched).text;
      expect(t, contains('• Central (Purok 1)'));
      expect(t, contains('• Riverside'));
    });

    test('no schedule published: honest answer, nothing invented', () {
      final String t = resident.reply('what day do you collect', schedules: const <String, CollectionSchedule>{}, purok: 'Purok 2').text;
      expect(t, contains('has not published a fixed weekly collection schedule'));
      expect(resident.reply('what day is collection', schedules: sched, purok: 'Purok 2').text, contains('no fixed schedule for Purok 2'));
    });
  });

  test('schedule model', () {
    const CollectionSchedule s = CollectionSchedule(area: 'Central (Purok 1)', days: <int>[1, 4], time: '07:00');
    expect(s.nextAfter(DateTime(2026, 10, 16, 9)), DateTime(2026, 10, 19, 7)); // Fri -> Mon
    expect(s.nextAfter(DateTime(2026, 10, 19, 6)), DateTime(2026, 10, 19, 7));
    expect(CollectionScheduleService.forPurok(<String, CollectionSchedule>{'Central (Purok 1)': s}, 'Purok 1'), s);
  });
}
