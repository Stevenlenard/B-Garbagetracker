# Deployment record: 2026-10-15 (via hPanel File Browser API in the owner's signed-in session)

Document root verified: File Browser `/public_html` (contained gt_canary_1015.txt; index.html/main.dart.js
matched what the site served). No production file changed before the backups completed.

## Backups (complete, verified: 43 files, 44,751,368 bytes each)
* Local (PRIVATE, contains the old Gemini key and an old Mapbox pk token): 
  `%USERPROFILE%\project-backups\B-Garbagetracker\2026-10-15_live_server_backup\`
* Server, outside public_html: `/gt_backup_2026-10-15/` (not web-served).
* Never restore the old get_operational_insights.php / route_optimization.php / main.dart.js to the web root.

## Deployed (each file hash-verified on the server after upload)
* backend/: ai_config_loader, load_history_lib, complaint_lib, complaint_center, update_complaint,
  get_load_history, get_eta_performance (schema-aware notifications fix, added during deployment),
  get_ai_load_summary, get_operational_insights (AI disabled), route_optimization (disabled stub).
* NOT replaced: backend/auth_token.php: live file is a strict subset of the package file (only
  difference: package adds gt_require_verified_role, used by no deployed file). Left unchanged.
* Web: all 39 files of web_1.0.1+2.zip (version 1.0.1+2, main.dart.js f0bb2ea0...).
* Untouched: db_config.php, email_config.php, .htaccess, .well-known/, uploads/, app-release.apk,
  app.js, style.css, firebase-config.js, database (no migrations).

## Leftovers to remove by hand (deletion was blocked for the agent)
* `/C:/Program Files/Git/public_html/backend/*` and empty `/Program Files/` at the File Browser root
  (outside public_html, not served; copies of the new package files, no credentials). Cause: Git Bash
  path conversion of the first upload attempt.
* `/public_html/gt_canary_1015.txt` (optional).

## Verification (live)
* Endpoint/regression script: 20/21 PASS; the only difference is icons/*.png served recompressed by
  Hostinger's CDN image optimisation (origin files byte-identical).
* Hosted guest map in headless Chrome: streets and labels rendered, Mapbox styles/fonts/sessions 200,
  0 directions-matrix / directions requests, 0 console errors.
* Not yet verified: authenticated Admin/Resident screens, Driver GPS -> Firebase -> markers.

## Later on 2026-10-15
* .htaccess: no-cache block added for the app shell (rewrite rules unchanged; draft's backend/ 404 rule
  NOT applied). Backup: local `htaccess.before-nocache`, server `/gt_backup_2026-10-15/htaccess.before-nocache`.
  Result: main.dart.js / index.html / flutter_bootstrap.js etc. `no-cache, must-revalidate`, CDN BYPASS.
* Web build with the shared date picker + one-tap saved sign-in client: all 39 files hash-verified,
  served identically without cache-busting. Previous live build kept as web_1.0.1+2.deployed-2026-10-15.zip.
* Saved sign-in (option A): uploaded auth_session_lib.php, session_refresh.php, session_logout.php,
  verify_otp.php (repo = live + session block) and login.php (LIVE file + session step only; 2 lines
  replaced). Backups of the previous login.php / verify_otp.php: local backend/ backup folder and
  server /gt_backup_2026-10-15/backend/. Inert until BOTH exist:
    1. table auth_sessions (deploy_prep/sql/09_...): run by the owner in phpMyAdmin (agent was blocked);
    2. backend/auth_config.php (GT_AUTH_SECRET, GT_AUTH_ENFORCE=false): prepared privately in
       %USERPROFILE%\project-backups\B-Garbagetracker\PRIVATE_auth_config_2026-10-15\ (never in git/chat).
  Rollback: delete backend/auth_config.php (everything returns to the previous behaviour at once);
  optionally restore login.php / verify_otp.php from the backups; the table can stay (unused) or be
  dropped with 10_rollback_auth_sessions.sql.
* SECURITY (found 2026-10-15): backend/backups/*.sql (27 full database dumps incl. users/residents
  emails, phones, password hashes) and backend/exports/*.zip were publicly downloadable (HTTP 200).
  Fixed with backend/backups/.htaccess and backend/exports/.htaccess = deny all (copy:
  deploy_prep/hostinger/backend_backups.htaccess). Verified: .sql/.zip/.txt there now 403; site, app
  and PHP endpoints unchanged. Side effect: Database Center "Download" links now get 403 until an
  admin-only download endpoint replaces direct links. Rollback: delete the two .htaccess files.
