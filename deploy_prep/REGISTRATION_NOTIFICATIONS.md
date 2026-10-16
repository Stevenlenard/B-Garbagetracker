# Registration notifications and driver approval e-mail

## Behaviour (local code)
| | Resident | Driver |
|---|---|---|
| Status | `approved` / `active` immediately, can log in | `pending` until an Admin approves |
| Admin in-app notification | exactly one (written by `register.php`, type `NEW_REGISTRATION`, with `relatedId` = username) | exactly one (same) |
| Admin e-mail | never | one message to every admin with `email_notifications = 1` and a valid address (max 5) |

The apps (`resident_register.dart`, `driver_register.dart`) no longer write their own `REGISTRATION`
notification: that was the duplicate. Old APKs/Web builds that are still in the field keep writing
one until they are updated, so an Admin can see two entries for a registration made from an old build.

## E-mail handling
- Outcome is logged on the server only (`error_log`): `smtp_accepted`, `failed`, `no_recipient`,
  `not_configured`. It is never put in the API response, and registration never fails because of it.
- `smtp_accepted` means the SMTP server accepted the message. Inbox delivery is NOT known.
- Log lines contain the exception class and a short hint with the SMTP user/password redacted.
- Recipient selection no longer uses `LIMIT 1` of an arbitrary admin.

## SMTP configuration
`backend/email_config.php` now reads, in order: `backend/email_credentials.php` (untracked, template
`email_credentials.example.php`), then `GT_SMTP_*` environment variables, then the legacy literals.
The legacy literals are still in the tracked file and in git history: create the untracked file on
Hostinger, rotate the Gmail app password, then delete the literals. Nothing was changed in production.

## Still requires production verification
1. Upload `register.php` and `email_config.php` (and create `email_credentials.php` if rotating).
2. Real SMTP test: register a throw-away driver and check the Admin inbox AND spam folder; check the
   Hostinger PHP error log for `ACCEPTED` or `failed`.
3. Confirm an admin row has `email_notifications = 1` and a valid e-mail.
4. Confirm the Firebase `notifications` node accepts the server REST write (log line
   "not accepted by Firebase" otherwise).
