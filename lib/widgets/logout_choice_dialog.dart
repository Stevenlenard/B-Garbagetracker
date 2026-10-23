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

/// Shared logout confirmation for Admin, Driver and Resident (Android and Web): Log out or Cancel.
///
/// Whether the account is remembered is decided once, on the login screen ("Remember account" /
/// "Stay signed in"), so the
/// dialog does not ask again. Log out keeps what that choice saved ([LogoutChoice.remember]): with
/// a saved sign-in the account can be resumed from Saved Logins, otherwise only the account name is
/// kept. [canSwitchAccount] overrides the check (tests).
Future<LogoutChoice> showLogoutChoiceDialog(BuildContext context, {bool? canSwitchAccount}) async {
  final bool canSwitch = canSwitchAccount ?? await SessionManager.canSwitchAccount();
  if (!context.mounted) return LogoutChoice.cancel;
  const Color teal = Color(0xFF00796B);
  const Color ink = Color(0xFF1F2A27);
  final LogoutChoice? result = await showDialog<LogoutChoice>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (BuildContext ctx) => Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(color: teal.withValues(alpha: 0.10), shape: BoxShape.circle),
                child: const Icon(Icons.logout_rounded, size: 28, color: teal),
              ),
              const SizedBox(height: 16),
              const Text('Log out?', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: ink)),
              const SizedBox(height: 8),
              Text(
                canSwitch
                    ? 'You chose Stay signed in, so this account stays in Saved Logins on this device and can be opened again with one tap.'
                    : 'You will need your username and password to sign in again.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, height: 1.45, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 22),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(LogoutChoice.cancel),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF3C4A45),
                        side: const BorderSide(color: Color(0xFFD5DDD9)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(ctx).pop(LogoutChoice.remember),
                      style: FilledButton.styleFrom(
                        backgroundColor: teal,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(Icons.logout_rounded, size: 18),
                      label: const Text('Log out', style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return result ?? LogoutChoice.cancel;
}
