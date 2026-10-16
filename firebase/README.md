# Firebase Realtime Database rules

**Published 2026-10-16.** The previous rules were fully open (`.read`/`.write` true); a copy is in the
2026-10-16 full-backup folder (`rules_before_publish_2026-10-16.json`).

`database.rules.json` replaces the open rules (anyone could read, change or wipe the whole
database). It must be published by an account that has access to the Firebase project
`garbagesis-78d39`.

## What the rules do

The app does not sign in to Firebase (no Firebase Authentication), so the rules cannot tell
users apart. Within that limit they:

- deny reading or writing the database root (no one-request dump, no one-request wipe);
- allow only the nodes the app and the PHP backend use; everything else is closed, including
  the old unused nodes `alerts`, `demo_simulations`, `manual_alerts`, `resident_locations`,
  `trip_history`, `user_evaluations`, `user_ratings` (kept in the 2026-10-16 full backup);
- block deleting whole collections, and block deleting records the app never deletes
  (users, trucks, truck locations, load history, collection logs, settings, weekly progress);
- hide lists of per-account nodes: `residents`, `login_security`, `driver_sessions`,
  `driver_settings`, `notification_inbox` can only be read one account at a time;
- add indexes for the app's queries (`driver_routes.driver_id`, `collection_logs.date`,
  `system_logs.timestamp`), so those queries download less.

Still possible without Firebase Authentication: reading the collections the app shows
(trucks, live locations, notifications, route history...), and changing or deleting single
records one by one. Closing that needs Firebase sign-in for the app (a later step).

## Tested

`test_rules.py` loads these rules and the real data backup into the
official Firebase Database Emulator and checks 78 operations the app and backend perform
(all allowed) and 47 abusive ones (all denied).

## Publish (about 1 minute)

1. Open https://console.firebase.google.com/project/garbagesis-78d39/database/garbagesis-78d39-default-rtdb/rules
2. Copy the CURRENT rules into a text file first (to undo if ever needed).
3. Replace everything in the editor with the contents of `database.rules.json`.
4. Click **Publish**.
5. Check: https://garbagesis-78d39-default-rtdb.asia-southeast1.firebasedatabase.app/.json
   should now answer `Permission denied`, and the app keeps working.

Undo: paste the copied old rules back and Publish.

## Backup

`backend/firebase_backup.php` runs daily by Hostinger cron (00:00) and keeps 14 compressed
backups in `gt_private/firebase_backups` (outside `public_html`). It works with these rules
without any Firebase secret.

Run the test again after changing the rules:

    java -jar firebase-database-emulator-v4.11.2.jar --host 127.0.0.1 --port 9010
    python firebase/test_rules.py firebase/database.rules.json <full-backup.json>
