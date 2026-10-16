# Admin endpoint authorization and removal of automatic account deletion

## What changed (backend only; no Flutter change was needed)
| Endpoint | Before | Now |
|---|---|---|
| `archive_user.php` | open | admin only (`gt_require_role(['admin'])`) |
| `bulk_delete_complaints.php` | open | admin only |
| `archive_complaint.php` | open; ran `ALTER TABLE` on every call | admin only; no schema change (errors if `is_archived` is missing) |
| `delete_complaint.php` | open | admin: any; resident: only their own complaint (`complaints.resident_id` = token subject); driver: refused |
| `delete_user.php` | open | admin: any; resident/driver: only their own account (role and id must match the token) - this is the existing in-app "delete my account" |
| `get_users.php` | open; **deleted archived users older than 6 months on every read** | automatic deletion removed. Admin: full lists. Resident/driver: drivers only, fields `user_id,name,role,preferred_truck,is_archived` (no email, phone, licence, username, no resident rows) |

Note: the reported "six-month automatic deletion" was found in `get_users.php` and deleted archived
USERS (residents/drivers), not complaints. No automatic complaint deletion exists. Complaint deletion is
only the explicit delete / bulk-delete actions above.

## Clients
`lib/api/api_client.dart` already adds `X-GT-Token` to every request while a token exists, so the
current Admin, Resident and Driver builds send it. `get_users` callers (admin dashboard, resident
dashboards, track trucks, route history) read only fields that remain in the redacted view.

## Rollout (uses the existing auth_token.php modes; nothing locks anyone out until enforcement)
1. Upload the six PHP files (and keep `auth_token.php`, `login.php`, `verify_otp.php` current).
2. `backend/auth_config.php` (not in git): define `GT_AUTH_SECRET` (64+ chars), `GT_AUTH_ENFORCE=false`.
   Now tokens are issued; a valid token of the WRONG role is refused; token-less requests still pass
   (old APKs/Web). In this mode the endpoints are NOT yet protected against token-less callers.
3. Ship the Android and Web builds that carry `api_client.dart`; have admins log out and in once
   (existing sessions have no token).
4. Set `GT_AUTH_ENFORCE=true` only after all active clients are updated. Then token-less or invalid
   requests get 401, wrong role 403.
5. Rollback: set `GT_AUTH_ENFORCE=false` (or remove the secret) - no code change needed.

## Not done here
- `delete_user.php` is still a permanent delete (self-deletion); a soft-delete/retention policy is a
  separate item. Hard deletion of a user can orphan trips/complaints that reference them.
- Automatic complaint archiving, archived-complaint view and Analytics inclusion are separate features.
- `email_config.php` SMTP credentials are tracked in git and should be rotated.

## Login / logout / remembered account (client)
- Logout shows one dialog for Admin, Driver and Resident (Android + Web): Cancel, Logout and Forget
  Login, Logout and Remember Login. The session, its token and timestamp are ALWAYS removed.
- Remembering keeps only an identifier (user id, name, username/email, role) to pre-fill the login
  form; the password is always required. Older saved profiles that contained the session (and the
  auth token) are scrubbed the first time they are read.
- Known limitation: while a user is signed in, the session token is held in shared_preferences
  (browser localStorage on Web). `flutter_secure_storage` is not a dependency and adding it needs a
  native rebuild; the token is removed on logout and never written to the remembered profile.
