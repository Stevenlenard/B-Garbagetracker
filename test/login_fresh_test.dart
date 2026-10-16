import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:garbage_tracking_app/chatbot/faq_bot.dart';

/// The sign-in screen needs Firebase, so the rule is checked in the source; the live page was
/// checked in a browser (#/login_new shows the form only).
void main() {
  test('#/login_new opens the sign-in screen in fresh mode, which never loads saved accounts', () {
    final String main = File('lib/main.dart').readAsStringSync();
    expect(main, contains("'/login_new': (context) => const LoginScreen(startFresh: true)"));
    expect(main.indexOf("fragment.contains('login_new')"), lessThan(main.indexOf("fragment.contains('login')")),
        reason: 'login_new must be matched before the plain login route');
    final String login = File('lib/screens/login_screen.dart').readAsStringSync();
    expect(login, contains('if (widget.startFresh) return; // fresh sign-in page: no saved accounts'));
  });

  test('Truck Buddy sends visitors to a fresh login or the registration page, never the saved logins', () {
    final FaqBot guest = FaqBot(BotRole.guest);
    expect(guest.reply('how do I log in').action, BotAction.signIn);
    expect(guest.reply('how do I create an account').action, BotAction.createAccount);
    expect(guest.reply('paano mag login').entry?.id, 'guest_login');
    final String page = File('lib/screens/standalone_gis_web_screen.dart').readAsStringSync();
    expect(page, contains("if (a == BotAction.signIn) _openWebPage('login_new');"));
    expect(page, contains("if (a == BotAction.createAccount) _openWebPage('register');"));
  });
}
