import 'package:flutter/material.dart';

import '../utils/session_manager.dart';

/// What the user chose in the logout dialog.
enum LogoutChoice {
  /// Stay signed in.
  cancel,

  /// Sign out, end the saved sign-in and remove the remembered account from this device.
  forget,

  /// Sign out but keep the account: with a saved sign-in, resumable with one tap (no password);
  /// otherwise only the account name is kept.
  remember,

  /// Leave this account but keep its saved sign-in ("Stay signed in"), so it can be resumed
  /// with one tap from Saved Logins. Offered only when such a sign-in exists.
  switchAccount,
}

/// Shared logout confirmation for Admin, Driver and Resident (Android and Web).
///
/// "Remember": when the account has a saved sign-in (remembered, revocable server session),
/// it is KEPT so the account can be resumed with one tap from Saved Logins, without the
/// password; otherwise only the account name is kept. "Forget" ends the saved sign-in on the
/// server and removes the account from the device. [canSwitchAccount] overrides the check (tests).
Future<LogoutChoice> showLogoutChoiceDialog(BuildContext context, {bool? canSwitchAccount}) async {
  final bool canSwitch = canSwitchAccount ?? await SessionManager.canSwitchAccount();
  if (!context.mounted) return LogoutChoice.cancel;
  final LogoutChoice? result = await showDialog<LogoutChoice>(
    context: context,
    barrierDismissible: true,
    builder: (BuildContext ctx) => Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Icon(Icons.logout_rounded, size: 44, color: Color(0xFF00796B)),
              const SizedBox(height: 16),
              const Text(
                'Log out?',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1A1A1A)),
              ),
              const SizedBox(height: 10),
              Text(
                canSwitch
                    ? 'Do you want to remember your login on this device? With Remember Login, '
                        'you can sign in again with one tap, without your password. Your password '
                        'is not saved. On a shared device, choose Forget Login.'
                    : 'Do you want to remember your login information on this device? '
                        'Only your account name is kept, to make signing in easier. You will still '
                        'need your password, and you will not stay signed in.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, height: 1.4, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(LogoutChoice.remember),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00796B),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Logout and Remember Login', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: () => Navigator.of(ctx).pop(LogoutChoice.forget),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFC62828),
                  side: const BorderSide(color: Color(0xFFC62828)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Logout and Forget Login', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(LogoutChoice.cancel),
                child: const Text('Cancel', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return result ?? LogoutChoice.cancel;
}
