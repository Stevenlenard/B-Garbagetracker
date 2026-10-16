ROUTE ASSIGNMENTS - HOSTINGER DEPLOYMENT PACKAGE (prepared locally, NOT deployed)
===============================================================================

!! WARNING: Review and apply the migration (sql/07) BEFORE enabling Route Assignments.
!! Without the tables the new endpoints only answer "not set up"; nothing breaks, but the
!! feature does not work.

Target folder on Hostinger: public_html/backend/  (the folder that contains login.php)

CONTENTS
  backend/                 upload for the feature
    auth_token.php           (newer than the copy in hostinger_complaint_fix - additive only)
    assignment_lib.php       new
    get_assignments.php      new
    save_assignment.php      new
    cancel_assignment.php    new
    link_assignment_trip.php new
    save_trip_history.php    links trips to assignments; automatic 200-trips/month deletion removed
  backend_login_tokens/    upload ONLY when you create auth_config.php (step 4)
    login.php                issues the sign-in token (also contains the registration approval gate)
    verify_otp.php           issues the token after 2FA login
  sql/
    06_inspect_route_assignments.READONLY.sql   read-only pre-check
    07_create_route_assignments.NOT_APPLIED.sql migration (adds 3 tables, changes nothing else)
    08_rollback_route_assignments.sql           rollback
    01_inspect_approval_status.READONLY.sql     read-only check before uploading login.php

NOT INCLUDED (keep the server's own copies; never overwrite): auth_config.php, db_config.php,
email_config.php, email_credentials.php, approval_config.php, any database dump.

DEPLOYMENT ORDER
 0. Backup: File Manager > public_html/backend > download auth_token.php, save_trip_history.php,
    login.php, verify_otp.php (and auth_config.php if it already exists - do NOT replace it).
    phpMyAdmin > Export the database (keep it off the server and out of git).
 1. phpMyAdmin > SQL: run sql/06 (read-only). Expect: no route_assignment* tables yet.
 2. Review sql/07, then run it in phpMyAdmin. Re-run sql/06 step 3: three tables now listed.
 3. Upload everything in backend/ to public_html/backend/ (Overwrite).
    Current APK/Web keep working: no secret yet = old behaviour; save_trip_history still saves.
 4. Server authorization (needed for the feature; see "GT_AUTH_SECRET" below):
    a. Run sql/01 (read-only). If drivers/residents who must log in show approval_status
       'pending' or 'rejected', fix that first - the new login.php blocks those accounts.
    b. Create public_html/backend/auth_config.php (only if it does not exist).
    c. Upload backend_login_tokens/login.php and verify_otp.php (Overwrite).
    d. Users log out and log in again to receive a token.
 5. Ship the new Web/APK (Route Assignments screens). Old clients ignore the new fields.

GT_AUTH_SECRET (create it ON the server; never in git, chat, screenshots or logs)
  Option A - hPanel > Advanced > SSH Access (if your plan has it), in public_html/backend:
    php -r '$s=bin2hex(random_bytes(32)); file_put_contents("auth_config.php", "<?php\ndefine(\"GT_AUTH_SECRET\", \"$s\");\ndefine(\"GT_AUTH_ENFORCE\", false);\n", LOCK_EX);' && chmod 640 auth_config.php
    (the value is written straight to the file and never printed)
  Option B - File Manager only: generate 64 random hex characters in a password manager on your
    own computer, then File Manager > New File "auth_config.php" with:
      <?php
      define('GT_AUTH_SECRET', 'PASTE_THE_64_CHARACTERS_HERE');
      define('GT_AUTH_ENFORCE', false);
    Save, close, and do not store the value anywhere else.
  Keep GT_AUTH_ENFORCE false. backend/auth_config.php is already in .gitignore.
  Changing the secret later signs everyone out (they log in again).

VERIFY (2 minutes)
  - Open https://<site>/backend/get_assignments.php in a browser:
      before step 4: {"success":false,"message":"This feature is not available until server authorization is configured."}
      after step 4 (no token in the browser): {"success":false,"message":"Please log in again."}
    Either answer proves the endpoint is reachable and refuses token-less access.
  - Existing app: log in as a driver, run a short trip to FULL/COMPLETED -> trip still appears in
    Route History / Load History.
  - After step 5: Admin creates an assignment; the driver sees "Today's Assignment"; the trip links;
    FULL shows In Progress, COMPLETED shows Completed.

ROLLBACK
  - Files: re-upload the backed-up auth_token.php, save_trip_history.php, login.php, verify_otp.php;
    delete the 4 new endpoint files and assignment_lib.php.
  - Authorization: delete auth_config.php (or set GT_AUTH_ENFORCE false - it already is). Tokens
    stop being issued; existing endpoints return to legacy behaviour.
  - Database: Export the three route_assignment* tables, then run sql/08 (drops ONLY them).
    Note: re-uploading the old save_trip_history.php also restores its automatic
    200-completed-trips-per-month deletion.

OTHER PACKAGES
  deploy_prep/hostinger_complaint_fix/ contains file_complaint.php and get_complaints.php (unchanged)
  and auth_token.php (now updated to the same newer version as this package). If both packages are
  uploaded, any order is fine; never upload an auth_token.php older than this one.

Checksums: SHA256SUMS.txt
