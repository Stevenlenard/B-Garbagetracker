# Priority 1 rollout and rollback plan

Nothing in this document has been executed. Every production-changing step needs
explicit approval. Order matters: each step is safe on its own and assumes the
previous ones are done.

## What exists locally (this branch: `fix/priority1-gps-sync`, uncommitted)

| Artifact | Location |
|---|---|
| Driver/Admin/Resident code | `lib/` (see final report for file list) |
| Release APK (new logic) | `build/app/outputs/flutter-apk/app-release.apk` (built 1.1.0+2) |
| Web build | `build/web/` |
| Rules, Stage 1 (ready) | `deploy_prep/firebase_rules/rules_stage1_trip_immutability.json` |
| Rules, Stage 2 / 3 (drafts) | `deploy_prep/firebase_rules/*.DRAFT.json` |
| PHP custom-token prototype | `deploy_prep/backend/firebase_custom_token.php` |
| Read-only backup script | `deploy_prep/backup_firebase_readonly.ps1` |
| Backup + inconsistency report | `C:\Projects\gt-backups\2026-10-12\` (outside the repo; contains GPS/user data) |

## Stage 0 - Backups (safe, no production change)

1. Run `deploy_prep/backup_firebase_readonly.ps1` (GET only).
2. In Firebase console > Realtime Database > Rules: copy the CURRENT rules to
   `rules.backup.json`. Rules cannot be read over the public API, so this is manual.
3. Hostinger File Manager / SFTP: download `public_html/` (web app) and
   `public_html/backend/` (PHP) to a dated folder. Do not rely on the repo copy.
4. Note the installed Driver APK's `versionName/versionCode` (Settings > Apps) and
   its signing certificate (see Stage 2).

**Rollback:** nothing to roll back.

## Stage 1 - Data hygiene (needs approval; non-destructive)

Source: `C:\Projects\gt-backups\2026-10-12\inconsistent_trips_report.md` and
`proposed_repairs.NOT_APPLIED.json`.

1. Approve the list. Nothing is deleted; every proposal is an annotation, a flag
   fix, or a MOVE with verification.
2. Apply in this order, re-reading after each group:
   a. `truck_locations/*/isOnline = false` for stale nodes (presence flag only).
   b. `driver_routes/<trip>/isFinished = true` where `route_status` is already
      COMPLETED/FINISHED (45 legacy trips).
   c. Annotate abandoned trips (`abandoned: true`); statuses are not changed.
   d. MOVE `truck_locations/GT-001/route_history` (16,038 entries, 2.3 MB) to
      `legacy_route_history/GT-001`: copy, compare counts, only then remove from
      the live node.
3. Trips with post-finish points are annotated, never trimmed.

**Rollback:** restore the touched paths from the Stage 0 backup JSON (PUT per path).

## Stage 2 - Driver runtimes (APK)

1. **Signing check first.** The debug keystore on the build machine was created on
   2026-10-12, so an APK installed earlier was signed with a different key. Android
   refuses to update an app across different signing keys.
   - If the original keystore is available: sign with it and update in place
     (data kept).
   - Otherwise: the old app must be uninstalled first. That removes the app's local
     data only (saved login/profile, preferences). Server data is untouched.
2. Take the Driver phone offline from the old app: log out of the old app, then
   uninstall or force-stop it. Never run old and new runtimes for one driver.
3. Install `app-release.apk`, log in, confirm:
   `driver_sessions/<driverId>` appears; the truck node gains `owner_token`,
   `owner_epoch`, `wseq`; the status is IDLE with `trip_active:false`.
4. Do the same for every other Driver phone, and close any Driver browser tabs.

**Rollback:** reinstall the previous APK (same signing key required) or the
Stage 0 copy; Stage 1 rules (below) never block an old APK from reading, and block
it only from writing to FINISHED trips.

## Stage 3 - Hosted Admin/Resident web app

Destination: Hostinger site root (`https://indigo-bear-885857.hostingersite.com/`),
document root `public_html/`. `.htaccess` serves existing files directly, so
`public_html/backend/` keeps working next to the Flutter build.

1. Upload ONLY the Flutter build output: `main.dart.js`, `flutter_bootstrap.js`,
   `flutter_service_worker.js`, `flutter.js`, `version.json`, `manifest.json`,
   `index.html`, `favicon.png`, `assets/`, `canvaskit/`, `icons/`.
2. Do NOT touch `backend/`, `uploads/`, `app.js`, `firebase-config.js`, `style.css`
   or `.htaccess`.
3. Upload `main.dart.js` and `flutter_service_worker.js` LAST so a half-uploaded
   build is never served.
4. Hard-refresh (Ctrl+F5) once; the service worker then serves the new build.

**Rollback:** re-upload the Stage 0 `public_html` copy of the same file set.

## Stage 4 - Firebase rules Stage 1 (needs approval)

Enforceable WITHOUT Authentication: a finished trip rejects new route points and
cannot be re-opened (works against ANY client, including older APKs). It also
constrains `driver_sessions` epochs. It does not identify callers.

1. Simulate in the console Rules Playground (no emulator is available locally):
   - write a point to a finished trip: denied;
   - write a point to an active trip: allowed;
   - admin weight edit on a finished trip: allowed;
   - delete a trip: allowed.
2. Publish `rules_stage1_trip_immutability.json`.
3. Watch for 30 minutes: Admin dashboard, a Driver START/PAUSE/FULL/DONE cycle,
   weight edit, trip delete.

**Rollback:** re-publish `rules.backup.json` (seconds).

Known effect: an older APK's final "FINISHED" route point after DONE is rejected
(it is written after the trip is sealed). Everything else is unchanged.

## Stage 5 - Server-enforced ownership (needs APK change + approval) - DRAFT

Stage 2 rules (`rules_stage2_session_epoch.DRAFT.json`) require each live write to
carry the current session epoch/token and an incremented `wseq`. This locks out
every client that does not follow the protocol. Before it can be applied:

1. A client change so each live write is a single transaction (server timestamps
   inside it) - verified on a device; today a second `update` stamps `lastSeen`.
2. Every Driver runtime on the new APK (Stage 2).
3. The admin "archive driver" write path reviewed (the draft only allows the
   OFFLINE/isOnline=false shape).

Stage 3 (Authentication) is required to prove WHO is writing:

1. Approve adding `firebase_auth` (new dependency).
2. PHP login returns `firebase_token` using
   `deploy_prep/backend/firebase_custom_token.php` (service account kept outside
   the web root).
3. Clients sign in with the custom token; rules key on `auth.token.role` and
   `auth.token.driver_id`.
4. Roll out in two phases: first sign in only (rules unchanged), then enforce.

## Monitoring after each stage

- `driver_sessions` has one record per active driver; `epoch` only increases.
- No `driver_routes/<finished trip>` shows `last_seen` newer than `finishTime`.
- Truck nodes carry `owner_token`; nodes without it are still on an older runtime.
- Admin "Online Drivers" equals "Active Fleets" equals markers on the map.
- Re-run the read-only analysis in `C:\Projects\gt-backups\...\analyze_backup.py`.

## Approval gates

| Stage | Production change | Approval needed |
|---|---|---|
| 0 | none (reads) | no |
| 1 | RTDB data annotations/moves | yes |
| 2 | install on Driver phones | yes |
| 3 | overwrite hosted web files | yes |
| 4 | publish RTDB rules | yes |
| 5 | rules + PHP + new dependency | yes (separately) |
