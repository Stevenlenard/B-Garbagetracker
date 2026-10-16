# Map integration audit — 2026-10-15

## Blank web map: evidence
* Live site (read-only fetch, cache-busted): `index.html`, `main.dart.js`, `flutter_bootstrap.js`,
  `version.json` all DIFFER from the new build. Live `version.json` = 1.0.0+1 (new = 1.0.1+2).
  Live `main.dart.js` Last-Modified 2026-10-07, contains the OLD account's token (1) and the old
  `CARD_BUILD` loop; the new web token is absent.
* CDN header `x-hcdn-cache-status: DYNAMIC` -> not a CDN copy; the origin still serves the old files.
* `/web_1.0.1+2/...`, `/web/...` return the fallback `index.html` -> the package was not extracted
  into a reachable subfolder either. Hosted `app-release.apk` is still the 2026-10-12 file.
* New web token (minimal live check): style `mapbox/standard` -> HTTP 200 with the site Referer,
  without Referer and with a foreign Referer -> the token is valid; NO URL restriction is in effect.
* Conclusion: the site still runs the old build that uses the old account's token. The old token
  was not called (by instruction), so its refusal is inferred, not tested.
* Fix: no code change; extract the package into the folder the site serves (the one containing
  `backend/` and `.htaccess`). Then `/version.json` must show 1.0.1 / 2.
* Not the cause, noted: page loads mapbox-gl-js 3.25.0 (the plugin's documented minimum); the
  Standard style metadata mentions 3.30.0 as its compatibility version. Change only if the browser
  console shows a style error after the correct build is live.

## Platforms and roles that exist
| Surface | Roles | Map screens |
|---|---|---|
| Android app (Flutter `android/`, ID com.example.garbage_tracking_app) | Driver, Resident, Admin | driver dashboard + `DriverTrackTruckScreen`; resident `MapboxView` card + `ResidentTrackTruckScreen`; admin `MapboxView` + `TrackTrucksScreen`; `RouteHistoryScreen`; `CollectionRouteOptimizationScreen` |
| Web (same code) desktop / mobile browser | Guest (route `/`, `/tracking`, `/gis`), Driver, Resident, Admin | guest `StandaloneGisWebScreen`; same role screens |
| Kotlin `app/`, `Asia-repo1-main/` | none | not buildable (no Gradle files) |
| PHP | - | no Mapbox calls; `route_optimization.php` (not in repo) replaced by a disabled version (prepared) |
| Firebase | - | `truck_locations`, `driver_routes`, `weekly_collection_progress`, `notifications`, `puroks` |

## What changed in the migration (vs commit 8cd5947)
* Token: hard-coded old token -> per-platform dart-define (`MapboxConfig`), old account refused,
  no fallback; every `MapWidget` wrapped in `MapboxGate` ("Map not configured" without a token).
* Route optimization: Matrix/Directions OFF; card no longer starts runs on rebuild; gate/cooldown.
* New: Collection Route Optimization screen (status + recorded-path comparison), entry points.
* Analytics: formula "MAE" replaced by measured ETA error.
* NOT changed: GPS acquisition, `truck_locations` / `driver_routes` writes, listeners, markers,
  paths, boundaries, styles, geofencing, notifications, Firebase config.

## Live state (read-only, 2026-10-15)
No truck updated in the last ~45 h; newest trip created 2026-10-13 07:21 (before the new APK).
The installed new APK has not started a trip yet.
