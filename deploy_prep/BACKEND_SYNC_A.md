# Backend sync A (prepared 2026-10-15; upload attempted, NOT live as of the 2026-10-15 check)

ZIP: `deploy_prep/out/backend_sync_A_2026-10-15.zip` (26,424 bytes, 11 files, `/` paths)
Layout: one top folder `backend/` -> extract into `/domains/indigo-bear-885857.hostingersite.com/public_html`
so files land in `public_html/backend/`. Not included: `db_config.php`, `email_config.php`,
`auth_config.php`, any credential. Secret scan of every file: clean.

## Files
| File | On server now | Feature | Needs |
|---|---|---|---|
| auth_token.php | NEW (missing) | shared role check used by the files below | nothing; without `auth_config.php` it runs in legacy mode (no tokens issued or checked) |
| complaint_lib.php | NEW | Complaint Center lifecycle, counts, resident notifications | `complaints` (+ `residents`/`users` for names); optional `complaint_status_history` (migration 12, not required) |
| complaint_center.php | NEW (missing -> today's "Could not reach the server") | Complaint Center list/detail/counts | auth_token, complaint_lib |
| update_complaint.php | REPLACE | status changes (requires a resolution note; server-side notification) | auth_token, complaint_lib |
| load_history_lib.php | NEW | Load History calculations | - |
| get_load_history.php | NEW on server (missing) | Load History | `driver_trip_history` (schema-aware: works without `full_time` / `weight_kg`); optional MySQL `driver_routes` |
| get_eta_performance.php | NEW on server (missing; unchanged since commit) | Analytics ETA Performance | `driver_trip_history`; optional MySQL `notifications` (both checked with SHOW TABLES) |
| ai_config_loader.php | NEW | AI config (AI DISABLED unless configured outside the web root) | - |
| get_ai_load_summary.php | REPLACE (live copy likely missing: CORS failure observed) | removes the exposed Gemini key; AI off -> deterministic summary | `driver_trip_history`; schema-aware (no `full_time`/weight columns needed); a missing weight = ESTIMATED 5,000 kg, never 0 |
| get_operational_insights.php | REPLACE | removes the exposed Gemini key; answers "AI disabled" | - |
| route_optimization.php | REPLACE if present | Matrix containment (no outbound call) | - |

## Production-schema evidence (read-only, 2026-10-15)
* `complaints`: fields returned by the live `get_complaints.php` = complaint_id, id, resident_id,
  user_id, category, description, status, admin_response, purok, location, created_at, is_archived,
  deleted_by_resident, full_name (44 rows; status values pending 16 / in_progress 8 / resolved 20,
  all handled). No `updated_at` / `resolved_at` -> lifecycle columns absent; the code's legacy mode.
* `users`: user_id, username, name, email, phone, role, account_status, approval_status,
  preferred_truck, license_number, is_archived, created_at.
* `driver_trip_history`: live output shows trip_id, driver_id, driver_name, truck_id, route_name,
  route_status, route_date, start/end_time, start/finish lat/lng, total_distance_km, moving/stopped
  seconds, detected_stops_count, created_at - and NOT full_time / weight_kg / weight_type. The live
  file's version is unknown, so this is strong but not conclusive evidence that those columns are
  missing. `get_load_history.php` was made schema-aware for this (PHP tests: both schemas pass).
* `access_logs` exists (live `get_access_logs.php`).
* NOT verified (no evidence): MySQL `driver_routes` and `notifications` tables and their columns
  (both are only queried after SHOW TABLES); `complaint_status_history` (not expected).
* Evidence needed for certainty (hPanel -> Databases -> phpMyAdmin -> SQL tab, read-only):
      SHOW TABLES;
      SHOW COLUMNS FROM driver_trip_history;
      SHOW COLUMNS FROM complaints;
      SHOW COLUMNS FROM driver_routes;      -- only if listed by SHOW TABLES
      SHOW COLUMNS FROM notifications;      -- only if listed by SHOW TABLES

## Not in this package (separate decisions)
* Needs schema/config: route assignments (`get_/save_/cancel_assignment.php`,
  `link_assignment_trip.php`, `assignment_lib.php`: migration 07); sessions (`auth_session_lib.php`,
  `session_refresh.php`, `session_logout.php`, and `login.php` / `verify_otp.php` that use them:
  migration 09 + `GT_AUTH_SECRET`). The current login keeps working.
* Not needed for the reported failures (review later): approve_user, archive_complaint,
  archive_user, bulk_delete_complaints, delete_complaint, delete_user, file_complaint,
  get_complaints, get_users, register, reject_user, save_trip_history.
* `email_config.php`: EXCLUDED. Its tracked copy (and the committed one) contains the SMTP
  (Gmail app) password; the server's email setup is left untouched, so OTP/approval emails keep
  working. Transition (later, separate): create the password in a private file, deploy an
  `email_config.php` without the password, then rotate the Gmail app password.

## Limitations
* Load History without weight columns: every finalized trip counts as an ESTIMATED 5,000 kg load
  (existing rule, labelled "estimated"); no measured weights exist.
* Old Admin APKs must enter a resolution note to resolve (server rule).
* PHP lint and the local test harness do not prove compatibility with the live database.

## Steps
1. Backup (File Manager, `public_html/backend/`): select `update_complaint.php`,
   `get_ai_load_summary.php`, `get_operational_insights.php`, `route_optimization.php` (if
   present), `auth_token.php` (exists on the server) -> Compress -> `backend_backup_2026-10-15.zip` -> Download. Also move
   `route_optimization.php` itself outside `public_html` (keep it private; it may contain a key).
2. Upload `backend_sync_A_2026-10-15.zip` to `public_html/` -> Extract into `public_html`
   (the zip's `backend/` folder merges into the existing one) -> Overwrite.
3. Verify (I can check remotely): `backend/complaint_center.php?action=list&scope=active&source=resident`
   returns JSON (not the web page); `backend/get_load_history.php` returns `"success":true`;
   `backend/get_eta_performance.php` returns JSON; `backend/get_operational_insights.php` returns
   `"ai_disabled":true`.
4. Rollback (CORRECTED 2026-10-15; preserves containment and the credential removal):
   * NEVER put back on the server: the original `get_ai_load_summary.php` /
     `get_operational_insights.php` (embedded Gemini key), the original `route_optimization.php`
     (uncontained Matrix proxy), or `web_backup_2026-10-15.zip` (old `main.dart.js` embeds the
     Gemini key and the old Mapbox token). Keep those backups offline only.
   * Correction: `auth_token.php` already existed on the server before this package (live check
     returned an empty 200). Add it to the step-1 backup; on rollback restore that copy, do not delete it.
   * Backend: extract `deploy_prep/out/backend_rollback_safe_2026-10-15.zip` into `public_html`
     (overwrite). It contains the disabled `route_optimization.php`, AI-off
     `get_operational_insights.php` + `ai_config_loader.php`, an AI-off/no-DB
     `get_ai_load_summary.php` stub, and the commit's `update_complaint.php` (no credential).
     Then restore `auth_token.php` from the backup and delete `complaint_center.php`,
     `complaint_lib.php`, `load_history_lib.php`, `get_load_history.php`, `get_eta_performance.php`.
   * Web: extract `deploy_prep/out/web_1.0.1+2.before-mapfix.zip` (sha ae45c830; new restricted
     token, no Gemini key, 0 Matrix/Directions strings) instead of the old build.
