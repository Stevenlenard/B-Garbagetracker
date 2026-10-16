import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/chatbot/faq_bot.dart';

/// Real questions users type, per role: the answer must be the one written for that role's
/// screens, and its button must open the screen the answer talks about.
void main() {
  final FaqBot resident = FaqBot(BotRole.resident);
  final FaqBot driver = FaqBot(BotRole.driver);
  final FaqBot admin = FaqBot(BotRole.admin);

  void expectRoute(FaqBot bot, String q, String id, BotAction? action) {
    final BotReply r = bot.reply(q);
    expect(r.entry?.id, id, reason: '[${bot.role.name}] "$q" -> ${r.kind} ${r.entry?.id}: ${r.text}');
    expect(r.action, action, reason: '[${bot.role.name}] "$q" button');
  }

  group('admin: complaints always go to Complaint Management', () {
    for (final String q in <String>[
      'how can i manage complaints',
      'how do I manage complaints',
      'managing complaints',
      'complaints',
      'where can i see the complaints',
      'how to resolve a complaint',
      'how do I mark a complaint resolved',
      'how do I view resident complaints',
      'update complaint status',
      'paano ayusin ang reklamo',
      'saan makikita ang mga reklamo',
      'may bagong reklamo ba',
      'unresolved complaints',
    ]) {
      test(q, () => expectRoute(admin, q, 'admin_complaints', BotAction.complaints));
    }
    test('driver reports', () {
      expectRoute(admin, 'where are the truck problems reported by drivers', 'admin_driver_reports', BotAction.complaints);
      expectRoute(admin, 'driver issue reports', 'admin_driver_reports', BotAction.complaints);
    });
  });

  test('admin: other screens', () {
    expectRoute(admin, 'how do I approve new drivers', 'admin_approve', BotAction.users);
    expectRoute(admin, 'where is the truck', 'admin_track', BotAction.track);
    expectRoute(admin, 'show me the live map', 'admin_track', BotAction.track);
    expectRoute(admin, 'how do I assign a truck to a driver', 'admin_assign', BotAction.routeAssignments);
    expectRoute(admin, 'which puroks are overdue', 'admin_collection_status', BotAction.collectionStatus);
    expectRoute(admin, 'how do I set the collection schedule', 'admin_schedule', BotAction.settings);
    expectRoute(admin, 'how to add a new purok', 'admin_service_areas', BotAction.settings);
    expectRoute(admin, 'how do I download a pdf report', 'admin_reports_export', BotAction.analytics);
    expectRoute(admin, 'backup the database', 'admin_backup', BotAction.settings);
    expectRoute(admin, 'what does route coverage mean', 'admin_dashboard', BotAction.home);
    expectRoute(admin, 'how accurate is the eta', 'admin_eta', BotAction.analytics);
    expectRoute(admin, 'show all drivers trips', 'admin_driver_tracking', BotAction.routeHistory);
    expectRoute(admin, 'what notifications do I get', 'admin_notifications', null);
    expectRoute(admin, 'I forgot my password', 'change_password', BotAction.settings);
  });

  test('admin never gets a resident or driver button', () {
    for (final String q in <String>['how do i file a complaint', 'how do I start a trip', 'paano palitan ang purok ko', 'what do pause full completed do']) {
      final BotReply r = admin.reply(q);
      expect(r.kind, isNot(BotReplyKind.restricted), reason: q);
      if (r.entry != null && !r.entry!.roles.contains(BotRole.admin)) {
        expect(r.text, startsWith('For '), reason: q);
        expect(r.action, isNull, reason: q);
      }
    }
  });

  test('resident', () {
    expectRoute(resident, 'how do I file a complaint', 'file_complaint', BotAction.fileComplaint);
    expectRoute(resident, 'how do I check my complaint', 'complaint_progress', BotAction.complaints);
    expectRoute(resident, 'nasaan ang truck', 'where_truck', BotAction.track);
    expectRoute(resident, 'can i see past trips in my area', 'resident_route_history', BotAction.routeHistory);
    expectRoute(resident, 'what do the collection status colours mean', 'collection_status', BotAction.collectionStatus);
    expectRoute(resident, 'how do I change my purok', 'change_purok', BotAction.settings);
  });

  test('driver', () {
    expectRoute(driver, 'how do I start a collection trip', 'driver_start', BotAction.home);
    expectRoute(driver, 'how to send manual alert to residents', 'driver_manual_alert', BotAction.home);
    expectRoute(driver, 'what is simulation', 'driver_simulation', BotAction.home);
    expectRoute(driver, 'where is my weekly progress', 'driver_progress', BotAction.home);
    expectRoute(driver, 'which areas do I collect today', 'driver_route_plan', BotAction.routePlan);
    expectRoute(driver, 'my past trips', 'driver_history', BotAction.routeHistory);
    expectRoute(driver, 'how do I report a truck problem', 'driver_issue', BotAction.settings);
    final BotReply r = driver.reply('how do i file a complaint');
    expect(r.kind, BotReplyKind.restricted);
    expect(r.text, contains('resident feature'));
  });

  test('every button is one the role\'s page can open', () {
    for (final FaqBot b in <FaqBot>[FaqBot(BotRole.guest), resident, driver, admin]) {
      for (final FaqEntry e in b.entries) {
        final BotAction? a = b.reply(e.question).action;
        if (a != null) expect(botSupportedActions[b.role], contains(a), reason: '${b.role.name}: ${e.id} -> $a');
      }
    }
  });

  test('short follow-ups use the previous question', () {
    expect(admin.reply('paano?', previous: 'complaints of residents').entry?.id, 'admin_complaints');
    expect(resident.reply('how about my complaint?', previous: 'what notifications will I receive').kind, isNot(BotReplyKind.fallback));
    expect(driver.reply('where?', previous: 'how do I start a collection trip').entry?.id, 'driver_start');
    // A full new question is answered on its own.
    expect(admin.reply('how do I approve new drivers', previous: 'complaints').entry?.id, 'admin_approve');
  });
}
