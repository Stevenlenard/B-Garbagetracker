# Mapbox Matrix containment and account migration

**Status (2026-10-14): prepared and tested locally only.** Nothing has been uploaded, installed,
revoked or migrated. The LIVE website and the LIVE APK still contain the Matrix loop and the old
token (section 3). The migration is complete only after: new builds deployed, devices updated,
old token invalidated, live role checks passed.

---

## 0. Destination account `joven-2323` (update 2026-10-15)

| Item | State |
|---|---|
| `config/mapbox.web.local.json` | created with a PLACEHOLDER (git-ignored); paste the **Capstone Web** token |
| `config/mapbox.android.local.json` | created with a PLACEHOLDER (git-ignored); paste the **Capstone Android** token |
| Build script checks | token is `pk.`, issued by `joven-2323` (name inside the token), not the old account, platform label fits, web and android tokens differ, both switches `"false"` |
| Not checkable locally | the token's scopes, URL restrictions, validity, plan, trial end, remaining allowance: confirm in the Mapbox account |
| Hosted origin | `https://indigo-bear-885857.hostingersite.com` (http redirects to it; `www.` does not resolve). No `Referrer-Policy` header and no referrer meta tag, so browsers use the default policy and send this origin as `Referer` to `api.mapbox.com` (mapbox-gl JS). Allowed URL for Capstone Web: exactly this origin; nothing else needed |
| APK producer | Flutter project `android/` (`include(":app")`), ID `com.example.garbage_tracking_app`. The Kotlin folders `app/` and `Asia-repo1-main/` (ID `com.example.myapplication`) have no Gradle build files and cannot produce an APK; if any phone still has a `com.example.myapplication` app, it is a separate app with the old token and is NOT updated by the Flutter APK: uninstall it |
| Signing key | `~/.android/debug.keystore` (Gradle default for `signingConfigs.debug`; no `ANDROID_USER_HOME` override). Certificate SHA-256 `7B:8A:1C:F5:...:C0:AD` = hosted APK's signer. Backup: `%USERPROFILE%\keystore-backups\garbage_tracking_app\debug.keystore.signing-key.2026-10-15.file-C25F4F504C20` (same disk: also copy it to a USB drive / private storage) |

Files that still contain the OLD account's token (values not reproduced): `public_html/main.dart.js`,
`public_html/app.js` (repo copy of the live site), `build/web/main.dart.js` and
`build/app/outputs/flutter-apk/app-release.apk` / `app-debug.apk` (old local artifacts,
overwritten by the new builds; never distribute), `app/src/main/AndroidManifest.xml`,
`app/src/main/res/values/strings.xml` and the same two under `Asia-repo1-main/` (legacy, not
buildable). `scripts/build_release.ps1` contains only the base64 form of the old account
NAME as a detection pattern, not a token. No token in `lib/`, `web/`, `backend/`, `config/`.

### Feature status (with both switches OFF and a valid destination token)

| Feature | Android | Web | Dependency | Limitation or fallback |
|---|---|---|---|---|
| Base map | works* | works* | Mapbox Maps SDK / mapbox-gl JS, standard styles | without a token: "Map not configured" |
| Live marker updates, fleet status | works | works | Firebase RTDB + PHP location sync | - |
| Device location | works | works (browser permission) | GPS / Geolocator | - |
| Recorded GPS paths, collection history | works | works | stored trip paths | - |
| Purok boundaries, geofences, arrival alerts | works | works | local distance checks, stored boundaries | - |
| "Truck approaching, about N min" alert | works | works | existing local estimate from straight-line GPS distance and speed (`EtaPolicy`) | it is an estimate, not road-based; no value when speed or GPS is unknown |
| Road-route calculation | unavailable | unavailable | Mapbox Directions (off) | a route already stored for the current trip still displays |
| Road distance / travel time | unavailable | unavailable | Mapbox Directions (off) | no straight-line substitute |
| Per-stop ETA from route optimization | unavailable | unavailable | Matrix + Directions (off) | none |
| Collection-route optimization | unavailable | unavailable | Matrix (off) | card shows "turned off in this version"; code kept for a later controlled repair (fix `directions/v1` first) |

\* not yet verified live with the destination tokens.

## 0b. Old-account cutoff (manual, old account owner)

1. In the OLD account, Tokens page: find the token whose value starts with the old account's
   prefix used in the builds above (compare only the first/last characters; do not paste it
   anywhere). It is the only token found in any client or backend code. Do not touch tokens of
   the destination account `joven-2323`.
2. Before revoking, check Hostinger `public_html/backend/route_optimization.php` (section 6):
   if it holds a token, revoke that one too.
3. Delete (or, if it is the default public token, refresh) that token. Old installs and old
   web copies lose their maps at that moment; if usage is still growing, do it immediately
   instead of waiting for every phone to be updated.
4. Write down the cutoff date and time (with time zone).
5. After 24-48 h: old account statistics show no new Matrix/map usage after the cutoff;
   destination account statistics show map loads only, 0 Matrix, 0 Directions.
6. Migration does not cancel charges already incurred, the destination account is not
   guaranteed free, and usage alerts are notifications, not a spending cap.

## 1. Matrix request paths, per platform

| Platform | Path | State in this code |
|---|---|---|
| Android + Web (same Dart code) | `RouteOptimizationService._getOptimizedRouteDirectMapbox` -> `GET https://api.mapbox.com/directions-matrix/v1/mapbox/driving/{coords}` | blocked: `getOptimizedRoute` returns `ROUTE_OPTIMIZATION_DISABLED` before any request; the compiler removes the Matrix code from the release build |
| Web only | fallback `POST {backend}/route_optimization.php` after a failed direct attempt | blocked in the new build (same early return); old builds still call it -> server replacement (section 6) |
| Driver dashboard | `_optimizeRoute`, `_tryAutoOptimizeRoute` | return immediately while disabled; no build-time trigger |
| PHP backend (`backend/*.php`) | none: no file contains `api.mapbox.com` (checked by the PHP tests) | - |
| Hostinger `backend/route_optimization.php` | NOT in the repository; source cannot be read over HTTP. May forward to Matrix | replacement prepared: `deploy_prep/hostinger/backend/route_optimization.php` |
| Old hosted files | `main.dart.js` (Oct 7), `app-release.apk` (Oct 13), `app.js` | contain the old token; only replacement + token revocation stop them |

Verification (local): `test/mapbox_containment_test.dart` (mocked Dio records every request:
0 Matrix, 0 Directions, 0 proxy requests over 50 calls, also concurrent; missing token refused
before the network), PHP tests for the replacement proxy (no curl, no outbound call), and the
release web compile contains no `directions-matrix` and no `api.mapbox.com` string.

## 2. The two switches (both FALSE; compile-time, need a rebuild to change)

| Switch | Disables | Does not touch |
|---|---|---|
| `MAPBOX_MATRIX_ENABLED=false` | every Matrix request; with it the whole driver Route Optimization (stop order, road distance, per-stop arrival times) and the Web proxy fallback in the new build | map display, tiles, styles, markers, GPS, Firebase, PHP |
| `MAPBOX_DIRECTIONS_ENABLED=false` | the Directions request inside route optimization (only reached after a Matrix result, so currently unreachable anyway); prevents Directions from ever becoming an automatic substitute | same as above |

Even if later switched on: at most 10 Matrix requests of at most 12 coordinates (144 elements)
and 10 Directions requests per running app. This is a per-device limit, NOT an account-wide cap.

## 3. What still works

| Feature | State | Source |
|---|---|---|
| Live maps (all roles, guest) | works with a configured token; without one the map area says "Map not configured" | Mapbox Maps SDK (Android) / mapbox-gl JS (Web) |
| Truck markers | works | Firebase RTDB + PHP location sync |
| GPS tracking | works | device GPS -> Firebase |
| Geofences / area boundaries | works | local distance checks (`geofence_service.dart`), stored boundaries |
| Collection-history route display | works | recorded GPS paths |
| Optimized route line | temporarily unavailable; a route already stored for the current trip still shows | `driver_routes/<trip>/optimized_route` |
| Route-optimization ETA per stop | temporarily unavailable (no substitute) | was Mapbox Directions |
| "Truck approaching ... Estimated arrival: N min" notifications | works, unchanged | existing local estimate from GPS distance and speed (`EtaPolicy`), not Mapbox |

## 4. The `directions/v1` endpoint

Exact request (route_optimization_service.dart, only after a successful Matrix response):

    GET https://api.mapbox.com/directions/v1/mapbox/driving/{lng,lat;...}
        ?access_token=...&geometries=geojson&overview=full&steps=true

* It is a **Directions** request, not Matrix. Documented Directions endpoint:
  `/directions/v5/{profile}/{coordinates}` ("This documentation is for v5"). `v1` is not
  documented. Matrix is `/directions-matrix/v1/...` (there `v1` IS the current version).
* Billing units differ: Matrix "billed by elements" (sources x destinations; no
  `sources`/`destinations` given -> (stops+1)^2); Directions "billed by requests" (one request
  regardless of waypoints).
* What `directions/v1` returns was NOT tested (no live calls with the old token). Mapbox
  documentation does not say whether failed (4xx/5xx) requests are billed; nothing here
  assumes they are.

## 5. Cause analysis

Superseded in detail by `deploy_prep/MATRIX_USAGE_INVESTIGATION.md` (2026-10-15): Firebase shows
that none of the 23 stored optimized routes came from the app's direct Mapbox path; they match
`route_optimization.php`, which therefore exists on Hostinger and makes routing calls itself.

Confirmed in the code that is LIVE (hosted `main.dart.js`, Last-Modified 2026-10-07, and hosted
`app-release.apk`, 2026-10-13, both inspected read-only): while no optimized route was stored,
every build of the driver's route card scheduled an automatic optimization (`CARD_BUILD`), the
dashboard clock rebuilds every second, and failures were neither cached nor limited. So a failing
optimization repeated back to back while a driver dashboard with an active trip was open; each
attempt starts with one Matrix request.

Hypothesis (not verified): the attempts kept failing at the `directions/v1` step after a
successful (billed, element-based) Matrix response, so the route was never stored and the loop
never ended. Other ways the loop stays open: Firebase write of the route failing, the Web proxy.

Estimate: up to 25 coordinates per request = 625 elements; 9,565,159 elements = at least
~15,300 Matrix requests (more with fewer stops: ~118,000 at 81 elements).

Evidence still needed (account owner): Matrix usage per hour/day and per token in the old
account's statistics; correlation with driver trip times (Firebase `driver_routes`); whether
`route_optimization.php` exists and what it calls; whether the GitHub repository is public
(the token is in commit `e8e5c8c`).

## 6. Server side: `route_optimization.php`

Prepared: `deploy_prep/hostinger/backend/route_optimization.php`. It answers every request with
`{"success":false,"error":"ROUTE_OPTIMIZATION_DISABLED"}`, makes no outbound request, uses no
database, includes nothing, logs at most one line per 10 minutes. Old Web clients then show
"failed" and make no Matrix usage through the server. (It cannot stop old clients that call
`api.mapbox.com` directly; only token revocation does.)

Reversible procedure (Hostinger File Manager):
1. Open `public_html/backend/`. If `route_optimization.php` does not exist, upload nothing.
2. If it exists: download it, read it. If it ONLY does route optimization, move the original
   OUT of `public_html` (e.g. `~/backup_2026-10-14/route_optimization.php`; never leave a copy
   under `public_html` with another extension: its source and any token would become
   downloadable). Upload the prepared file in its place.
3. If it contains other functions used elsewhere, do not replace it; send it for review first.
4. Rollback of this step = put the original back. Do NOT do that while Matrix must stay off.

## 7. Tokens per platform (corrected)

Our Android integration: `mapbox_maps_flutter 3.0.0-alpha.1` -> Mapbox Maps SDK for Android
`11.25.0` (from the public releases Maven repository; no secret download token needed).
Mapbox does not support URL-restricted tokens for "requests from mobile applications built with
the Mapbox Maps or Navigation SDKs". Web uses mapbox-gl JS from the CDN, which sends the page
URL, so URL restrictions work there.

| Account type | Web token | Android token |
|---|---|---|
| Account that can create tokens | new public token, URL restriction = the hosted domain (e.g. `https://indigo-bear-885857.hostingersite.com`) | separate new public token, NO URL restriction, public scopes only |
| Card-free trial (Mapbox: one token; cannot create, rotate or delete tokens until a payment method is added; the default public token cannot have URL restrictions) | the one default token | the same token |

Card-free trial limitations: the token is unrestricted and is published on the website, so
anyone can copy it and use it against your account; it cannot be rotated or revoked without
adding a payment method; usage alerts notify but do not cut off. Mitigation: Matrix and
Directions stay off in our code; check the account statistics daily until the defense. Read the
destination account's own billing page for the trial end date and limits.

Configuration (both files git-ignored by `/config/*.local.json`):
* `config/mapbox.web.local.json` from `config/mapbox.web.example.json`
* `config/mapbox.android.local.json` from `config/mapbox.android.example.json`

Fields: `MAPBOX_TOKEN_PLATFORM` (`web` / `android`, or `shared` for the one-token trial),
`MAPBOX_ACCESS_TOKEN` (pk. token), `MAPBOX_MATRIX_ENABLED` = `"false"`,
`MAPBOX_DIRECTIONS_ENABLED` = `"false"`. The app refuses a token labelled for the other platform,
`sk.` tokens and tokens of the old account.

Public values embedded in the builds (readable by anyone): the platform's Mapbox `pk.` token, the
Firebase client configuration (API key, app ID, project, database URL; already in `main.dart`),
the Hostinger backend URL. Never in a build, Git or logs: `sk.` tokens, SMTP/database
credentials, `backend/auth_config.php`, `backend/email_credentials.php`. The token is never
printed by the app or by the build script.

## 8. Building

    powershell -ExecutionPolicy Bypass -File scripts\build_release.ps1 -Platform web -CheckOnly
    powershell -ExecutionPolicy Bypass -File scripts\build_release.ps1 -Platform web
    powershell -ExecutionPolicy Bypass -File scripts\build_release.ps1 -Platform android

The script refuses a missing/placeholder/old-account/`sk.` token, a wrong platform label, or
either switch not `"false"`; after building it fails if the output contains `directions-matrix`,
the old build trigger or an old-account token, or does not contain the configured token. Output
in `deploy_prep/out/` (git-ignored): `web_1.0.1+2.zip` (Flutter files only, without `.htaccess`
and `.well-known`), `htaccess.proposed.txt`, `app-release-1.0.1+2.apk`.

## 9. Web deployment

Directory, by evidence: the site root `https://indigo-bear-885857.hostingersite.com/` serves the
Flutter `index.html`, the API is `/backend/` below it, and the repository copy `public_html/`
has the same file set (`app.js`, `firebase-config.js`, `style.css`, `.well-known/` all answer
200 live; same `version.json`). The live `main.dart.js` is an older build (4,936,025 bytes,
2026-10-07) than the repository copy. So: Hostinger `public_html/`.

1. Back up the live `public_html` web files (File Manager -> compress, download).
2. Upload and overwrite from `web_1.0.1+2.zip`: `index.html`, `main.dart.js`,
   `flutter_bootstrap.js`, `flutter.js`, `flutter_service_worker.js`, `version.json`,
   `manifest.json`, `favicon.png`, `icons/`, `assets/`, `canvaskit/`.
3. Obsolete, by evidence (not referenced by `index.html`, not produced by the build): `app.js`
   (contains the OLD token -> move out of `public_html`), `firebase-config.js`, `style.css`
   (move out too), `canvaskit/experimental_webparagraph/` (older Flutter, harmless).
4. Do NOT touch: `backend/` (all PHP, except section 6), uploaded files, `.htaccess`,
   `.well-known/`, any other site content. Replace `app-release.apk` only in the Android step.
5. Caching: both old and new `flutter_service_worker.js` are Flutter's self-unregistering
   cleanup worker (no offline cache). The risk is HTTP caching: the host sends
   `Cache-Control: public, max-age=604800` for `.js`, so a browser may keep the old
   `main.dart.js` (with the loop) for up to 7 days. `htaccess.proposed.txt` adds
   `no-cache, must-revalidate` for the app shell and keeps `/backend/` out of the SPA fallback.
   Compare it with the live `.htaccess` and add only that block after review. Testers: Ctrl+F5
   or clear site data; check in DevTools Network that `main.dart.js` is the new one.

## 10. Android deployment

* Application ID `com.example.garbage_tracking_app`; version now `1.0.1` / versionCode `2`
  (live APK: 1.0.0 / 1).
* Signing: `android/app/build.gradle.kts` signs release builds with the debug key. The live
  APK's signer (SHA-256 `7B:8A:1C:F5:...:C0:AD`) is this machine's `~/.android/debug.keystore`
  (created 2026-10-12). Builds from THIS machine therefore update existing installs in place.
  Back up that keystore file now; losing it means no in-place updates.
* Devices that installed the hosted APK since 2026-10-13: open the new APK -> "Update". App
  data (saved sign-ins, settings) is kept.
* Devices with an APK from before 2026-10-12 were signed by another key (`assetlinks.json`
  lists `10:3B:82:...:E6:FB`). Android refuses the update ("package conflicts"). Options: build
  on the machine that holds that keystore, or uninstall + install. Uninstall deletes local app
  data only (saved sign-ins/remembered accounts, local preferences, notification state); MySQL
  and Firebase data are not affected. Users sign in again.
* Note: `assetlinks.json` does not list the current signer, so verified app links for the
  current APK are not verified (existing issue; affects deep links only).
* Distribution: replace `public_html/app-release.apk` with the new APK (same file name; the app
  links to it), then update each device. Old APKs keep working against the old token until it
  is revoked.

## 11. Old jobs and the old token

* No Mapbox job exists in the repository. `backend/auto_backup_checker.php` (backup cron) is
  unrelated. Check Hostinger -> Advanced -> Cron Jobs for any job calling
  `route_optimization.php` or an unknown script; disable it (note it down to restore).
* Old token (owner of the old account): Tokens page -> delete or rotate the token that starts
  with the old account name (if it is the default public token, "refresh" it: Mapbox creates a
  new one and the old value stops working). This is the only step that stops old APKs, old web
  copies and external use. Do it after the new builds are on the devices (old installs lose
  maps at that moment).
* Billing questions about the invoice: owner decision, not part of this change.

## 12. Minimal live checks (only after the destination token is configured)

1. Web: open the site, DevTools -> Network, filter `directions-matrix` and `route_optimization`:
   0 requests while using Admin, Driver (start trip, open route card, tap it), Resident, guest.
2. Android: same workflow on one device; logcat shows `[MAPBOX GUARD] matrix request blocked`
   and never a Matrix request.
3. After 24-48 h: destination account statistics show 0 Matrix elements; old account shows no
   new Matrix usage after revocation.
No load tests, no Matrix requests.

## 13. Rollback

Rollback = an earlier build of THIS code, with both switches still `false`, rebuilt with the
destination token. Never reinstall the old APK or re-upload the old `main.dart.js` / `app.js`
(they contain the loop and the old token), never restore the original `route_optimization.php`,
never re-enable a revoked token. If the destination token misbehaves: create/refresh a
destination token and rebuild. The app refuses old-account tokens anyway.
