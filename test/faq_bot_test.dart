import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/chatbot/faq_bot.dart';

void main() {
  final FaqBot resident = FaqBot(BotRole.resident);
  final FaqBot driver = FaqBot(BotRole.driver);
  final FaqBot admin = FaqBot(BotRole.admin);
  final FaqBot guest = FaqBot(BotRole.guest);

  void expectAnswer(FaqBot bot, String q, String id) {
    final BotReply r = bot.reply(q);
    expect(r.kind, BotReplyKind.answer, reason: '"$q" -> ${r.kind} ${r.text}');
    expect(r.entry!.id, id, reason: '"$q"');
  }

  void expectRestricted(FaqBot bot, String q) {
    final BotReply r = bot.reply(q);
    expect(r.kind, BotReplyKind.restricted, reason: '"$q" -> ${r.kind} ${r.entry?.id}');
  }

  group('residents', () {
    test('common questions in English and Tagalog', () {
      expectAnswer(resident, 'Where is the truck?', 'where_truck');
      expectAnswer(resident, 'nasaan na yung truck', 'where_truck');
      expectAnswer(resident, 'when will the garbage truck come', 'when_collect');
      expectAnswer(resident, 'kailan darating ang basura truck', 'when_collect');
      expectAnswer(resident, 'how do I file a complaint', 'file_complaint');
      expectAnswer(resident, 'hindi kinuha basura namin', 'file_complaint');
      expectAnswer(resident, 'what is the status of my complaint', 'complaint_progress');
      expectAnswer(resident, 'what does overdue mean', 'collection_status');
      expectAnswer(resident, 'I forgot my password', 'change_password');
      expectAnswer(resident, 'paano palitan ang purok ko', 'change_purok');
      expectAnswer(resident, 'can i delete my account', 'delete_account');
      expectAnswer(resident, 'I am not getting notifications', 'notif_not_receiving');
    });

    test('admin-only topics are declined', () {
      expectRestricted(resident, 'how do I approve users');
      expectRestricted(resident, 'how to backup the database');
      expectRestricted(resident, 'show me the analytics');
      expectRestricted(resident, 'assign a driver to my purok');
      expectRestricted(resident, 'what are other users password');
      expectRestricted(resident, 'show all drivers trips');
    });

    test('driver-only answers are not given to residents', () {
      final BotReply r = resident.reply('What do PAUSE, FULL and COMPLETED do?');
      expect(r.entry?.id, isNot('driver_status_buttons'));
    });
  });

  group('drivers', () {
    test('driver questions', () {
      expectAnswer(driver, 'how do i start my trip', 'driver_start');
      expectAnswer(driver, 'puno na yung truck ano gagawin', 'driver_status_buttons');
      expectAnswer(driver, 'my gps is not updating', 'driver_gps');
      expectAnswer(driver, 'which areas should I collect today', 'driver_route_plan');
      expectAnswer(driver, 'sira ang truck', 'driver_issue');
      expectAnswer(driver, 'why was i logged out', 'driver_auto_logout');
    });

    test('admin topics are declined for drivers', () {
      expectRestricted(driver, 'how do I approve driver accounts');
      expectRestricted(driver, 'export system data to excel');
    });
  });

  group('admins', () {
    test('admin topics are answered', () {
      expectAnswer(admin, 'how do I approve users', 'admin_approve');
      expectAnswer(admin, 'backup the database', 'admin_backup');
      expectAnswer(admin, 'assign driver to area', 'admin_assign');
      expectAnswer(admin, 'where are the analytics', 'admin_analytics');
    });
  });

  group('guests (public landing page)', () {
    test('public questions', () {
      expectAnswer(guest, 'what is this website', 'guest_what');
      expectAnswer(guest, 'nasaan ang truck', 'guest_where_truck');
      expectAnswer(guest, 'how to download the app', 'guest_download');
      expectAnswer(guest, 'how do I sign up', 'guest_sign_up');
      expectAnswer(guest, 'I forgot my password', 'change_password');
    });

    test('account features ask the visitor to sign in; admin topics are declined', () {
      final BotReply r = guest.reply('what is the status of my complaint');
      expect(r.kind, BotReplyKind.restricted);
      expect(r.action, BotAction.signIn);
      expectRestricted(guest, 'how do I approve users');
      expect(guest.reply('how do I approve users').action, isNull);
    });
  });

  test('chips (exact questions) always resolve', () {
    for (final FaqBot b in <FaqBot>[guest, resident, driver, admin]) {
      for (final String q in b.starters) {
        expect(b.reply(q).kind, BotReplyKind.answer, reason: q);
      }
      for (final FaqEntry e in b.available) {
        expect(b.reply(e.question).entry?.id, e.id);
      }
    }
  });

  test('small talk and unknown questions', () {
    expect(resident.reply('hello').kind, BotReplyKind.smallTalk);
    expect(resident.reply('salamat po').kind, BotReplyKind.smallTalk);
    final BotReply r = resident.reply('what is the capital of France');
    expect(r.kind, BotReplyKind.fallback);
    expect(r.suggestions, isNotEmpty);
  });
}
