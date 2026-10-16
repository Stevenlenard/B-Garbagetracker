# Pre-deployment runbook (Priority 1 + lifecycle + account/complaint fixes)

Nothing in this document has been executed. Every step that touches production
(Hostinger files, MySQL, Firebase rules, installed apps) needs explicit approval.
Companion documents: `ROLLOUT_PLAN.md` (GPS/Firebase stages), `DRIVER_LIFECYCLE.md`,
`FLEET_STATUS_POLICY.md`, `sql/` (approval repair), `firebase_rules/`.

## 1. What must change on the server

### PHP files to upload to Hostinger (`public_html/backend/`)

| File | Change | Required for |
|---|---|---|
| `register.php` | admin self-registration refused, validation, duplicate pre-check, `user_id` returned | registration |
| `login.php` | pending/rejected blocked (with legacy exception), optional `auth_token` | login, approval |
| `approve_user.php` | sets `approval_status`/`account_status`, admin check | driver approval |
| `reject_user.php` | admin check | driver approval |
| `file_complaint.php` | validates resident, optional ownership check, `complaint_id` | complaints |
| `update_complaint.php` | existence check, `previous_status`, admin check | complaint resolution |
| `verify_otp.php` | returns `auth_token` for a 2FA *login* verification only | 2FA + tokens |
| `save_trip_history.php` | FULL freezes the record; writes `full_time`, load, areas | Load History, Waste Collection Summary |
| `auth_token.php` (new) | token issue/verify helper | token authorization |
| `get_load_history.php` | finalized FULL/COMPLETED trips only (ACTIVE excluded), one load per trip, chart from the same rows | Load History, Waste Collection Summary |
| `load_history_lib.php` (new) | shared finalized-trip / summary / monthly helpers | Load History |

Optional, server-only files (never in git):
- `auth_config.php` - `GT_AUTH_SECRET`, `GT_AUTH_ENFORCE` (see "Authorization modes").
- `approval_config.php` - `define('APPROVAL_LEGACY_GRACE', false);` once approvals are repaired.

Do NOT upload: `db_config.php`, `email_config.php` (the server's own copies stay),
`backups/`, anything under `test/`.

### Database
- **No schema change is required.** Optional columns are detected at runtime.
- `save_trip_history.php` writes `full_time`, `weight_kg`, `weight_type`,
  `areas_visited` only if they exist. Run `update_load_history_schema.php` (already in
  the project) once if `DESCRIBE driver_trip_history` lacks them, otherwise the FULL
  time cannot be stored and Load History falls back to the start time.
- `users.approval_status` / `account_status` and `residents.*` must exist (register.php
  already depended on them). `01_inspect_approval_status.READONLY.sql` checks this.

### Firebase
- Realtime Database rules: `firebase_rules/rules_stage1_trip_immutability.json`
  (allow-list now includes `unloading_confirmed_at_ms`, `post_full_distance_km`,
  `unload_lat`, `unload_lng`). Simulate in the console Rules Playground first.
- Stage 2/3 rules and `firebase_auth` stay DRAFT (not needed for this release).

## 2. Authorization modes (decide separately from the code deploy)

| Mode | Server config | Effect |
|---|---|---|
| legacy (default after upload) | no `auth_config.php` | identical to today; no tokens |
| token-optional | `GT_AUTH_SECRET` set, `GT_AUTH_ENFORCE` false/absent | tokens issued; a valid token of the WRONG role is refused; token-less (old APK/web) still accepted |
| enforced | `GT_AUTH_ENFORCE` true | valid token with the right role required (401/403) |

Order: upload PHP in legacy mode -> deploy Web + new APK (they send the token when they
have one) -> turn on token-optional -> confirm every driver/resident/admin has logged in
again on the new build -> only then enforced.
Saved-profile quick login and an app that was logged in before the update have NO token:
under enforced mode they must log in again.
Unprotected endpoints that still trust the caller (out of scope here):
`archive_user`, `delete_user`, `bulk_delete_complaints`, `delete_complaint`,
`archive_complaint`, `update_user_profile`, `change_password`.

## 3. Deployment order

1. **Backups** (no change): `backup_firebase_readonly.ps1`; download current
   `public_html/` and `public_html/backend/`; export the Firebase rules; mysqldump of
   `users`, `residents`, `complaints`, `driver_trip_history`, `access_logs`; note the
   installed Driver APK version and signing certificate.
2. **Compatibility checks** (read-only): run `sql/01_inspect_approval_status.READONLY.sql`;
   confirm `DESCRIBE driver_trip_history`; confirm `backend/backups/` is not web-readable.
3. **PHP** (legacy mode): upload the files above; last upload `login.php`.
   Smoke-test with the existing Web app: resident login, driver login, file complaint.
4. **Approval repair** (only after review): `sql/02_repair_approval_status.NOT_APPLIED.sql`
   with the administrator-confirmed ids; rollback `sql/03_rollback_approval_status.sql`.
5. **Firebase rules Stage 1**: simulate, publish, watch 30 minutes (ROLLOUT_PLAN.md).
6. **Flutter Web**: upload build output only (ROLLOUT_PLAN.md Stage 3); hard refresh.
7. **Android APK**: the test-signed APK is signed with a different key than the installed
   one, so Android refuses an in-place update. Either sign with the ORIGINAL keystore
   (data kept) or uninstall first (local app data only). Increase `versionCode` above the
   installed one (pubspec `version:`), otherwise Android treats it as a downgrade.
   Update ALL driver phones in one window.
8. **Controlled verification** (below), then enable token-optional mode.
9. **Rollback**: re-upload the backed-up PHP files and Web build; republish the saved
   rules; reinstall the previous APK (same key); `03_rollback_approval_status.sql` if the
   repair was applied.

## 4. Old Driver APKs
An old APK keeps publishing GPS and can still write to Firebase (no authentication).
- It cannot take over a new runtime's session, but it is not blocked either, until the
  Stage 1 rules (finished trips become immutable) and the newer APK are in place.
- `save_trip_history.php` now ignores an old APK's late COMPLETED distance/coordinates
  (the FULL record is frozen), so its history writes cannot corrupt a finalized record.
- Retire old APKs: log every old phone out (or uninstall) before the new APK goes live.
  Identify survivors with `truck_locations/*/owner_token` missing and `runtime` field
  absent on trips.

## 5. Controlled verification (production, after approval)
| Check | Pass condition |
|---|---|
| Resident registration | row in `residents`, `approval_status=approved`, login works |
| Driver registration | row in `users`, `pending`, login refused with the pending message |
| Admin approval | `approval_status=approved`, driver can log in |
| Admin cannot be self-registered | `register.php` role=admin refused |
| Driver login | trip opens by itself, truck ACTIVE on Admin and Resident maps |
| Stationary 3 min | still ACTIVE and online |
| FULL | `driver_routes/{trip}/collection` set; Load History shows FULL time/distance |
| COMPLETED | `isFinished`, distance unchanged, driver still online, not counted in Active Fleets |
| Complaint | stored with the resident id; admin sees it; resolve once; one notification |
| Disconnect | driver leaves counts within the freshness window |
Latency is MEASURED only with the telemetry build in test mode; this runbook does not
claim a figure.
