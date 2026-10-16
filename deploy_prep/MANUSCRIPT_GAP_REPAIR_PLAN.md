# Manuscript gaps and repair plan (2026-10-15, local only)

Nothing here is deployed or applied. Matrix and Directions stay OFF. Read-only production reads
were used only for counts (Firebase nodes; local copies deleted afterwards). The system is NOT
manuscript-complete; the gaps are listed below.

Build status: blocked. `config/mapbox.web.local.json` and `config/mapbox.android.local.json`
still contain placeholders for `MAPBOX_ACCESS_TOKEN` (check: `scripts\build_release.ps1 -CheckOnly`).

---

## 1. ETA

### Every displayed ETA and its real calculation

| Where | Shown as | Calculation | Regression? |
|---|---|---|---|
| Resident dashboard stat card (`resident_dashboard.dart` 405-424) | "Estimated Time" | `EtaPolicy`: straight-line distance resident -> nearest COLLECTING truck / current or average GPS speed; unavailable without fresh GPS or speed | no |
| Approach notification (`driver_dashboard.dart` 2038-2066) | "Estimated arrival: N min" | `EtaPolicy`: straight-line distance to area edge / speed; stages 15/10/5 | no |
| Resident schedule card (`resident_dashboard.dart` 1164, `_getDynamicTime` 2462) | "Estimated Time" | FIXED windows hard-coded by purok name (e.g. "6:00 AM - 8:00 AM"); no data | no; also contradicts "no fixed time schedule" in 1.1 unless the barangay supplied these windows |
| Driver route card / sheet (`route_optimization_service.dart` 353) | "h:mm a (est)" per stop | Mapbox Directions legs; currently OFF | no |
| Analytics "ETA Performance" | error minutes | `EtaEvaluation`: approach prediction vs GPS-confirmed `auto_arrival` | evaluation only |

### Data available (Firebase, read-only)
`notifications`: 110 `auto_approach` (38 with `eta_minutes` and a trip id), 9 `auto_arrival`
(1 with a trip id) -> 1 prediction/arrival pair can be matched. Verified visits
(`CollectionVisits`): 6 in 90 days. No arrival/travel-time table exists in the repository.

### Minimum valid regression (proposed, not implemented)
* Observation: one verified visit (trip, area, entry time).
* Target: minutes from trip start to entry into the area.
* Features: cumulative recorded GPS distance from trip start to the entry (km), holiday flag
  (`HolidayTracker`), hour of trip start; per-area intercepts only when an area has >= 5 visits.
* Model: ordinary least squares, pure Dart (`lib/utils/arrival_regression.dart`), trained on
  demand from data already read (no schema change); coefficients shown with n and training date.
* Insufficient data: fewer than 30 observations overall (or < 10 for the test set) -> no
  regression output; the UI keeps `EtaPolicy` labelled "estimate (distance / speed)" and states
  "Regression ETA not available: n of 30 visits".
* Evaluation: time-ordered split (oldest 80 % train, newest 20 % test); MAE, RMSE, R² on the
  test set only, with n; never on training data, never on synthetic data.
* Today: 6 observations -> cannot be trained or evaluated.

## 2. Waste forecasting

Current (`PredictionEngine.predictWasteVolume`, used by Analytics):
`historicalAvgKg` = plain mean of ALL recorded weights found in Firebase `collection_progress`
for the area (no dates, no window) x holiday multiplier (`HolidayTracker`: 1.2 on 12 fixed
national dates, the Aug 26 fiesta AND every Saturday/Sunday; else 1.0) x 1.10 if stops > 10.
Fallback (no weights): documented-area sqm x 0.0217 kg/sqm x multiplier x 1.15. Analytics shows
0 / unavailable when no weights exist. Weekly = sum of 7 daily forecasts.

Differences from "holiday-weighted moving average": no moving window, observation dates are not
used, holidays only scale the forecast (observations are not weighted), weekends are treated
as holidays, the 1.10 / 1.15 factors, the density 0.0217 and the area sqm values have no source.

Dated observations available: Firebase `collection_progress` 176 sessions, 0 weights; Firebase
`load_history` empty. MySQL `driver_trip_history` weights could not be inspected
(`get_load_history.php` does not exist on the production server; no DB access). Recorded
weights are per TRIP (truck load), not per area.

Proposed calculation (explicit, documented):
1. Series: finalized trips with a recorded weight, by Asia/Manila date.
2. Normalize each observation: y'ᵢ = yᵢ / m(dᵢ), m = 1.2 for national holidays and the local
   fiesta, 1.0 otherwise; a weekend factor only after >= 8 weekend observations estimate it.
3. Base = mean of the last W = 7 normalized observations (configurable).
4. Forecast(d) = base x m(d). Fewer than W observations -> "Forecast unavailable (n of W)".
5. Evaluation: rolling-origin one-step-ahead forecasts; MAE and RMSE (R² is not meaningful
   for a moving average).

Ambiguity to resolve with the adviser (manuscript unchanged): objective 2.2 says arrival time
AND waste volume are predicted "using linear regression" considering sqm, travel time and
holiday multipliers; objective 3.1 says linear regression for arrival time and a holiday-weighted
moving average for waste volume. 2.2 also says "per area", while recorded weights are per trip:
per-area forecasting needs per-area weights or an agreed allocation rule.

## 3. Gemini summaries

Findings:
* Earlier removal: committed `analytics_screen.dart` (HEAD, lines 554-555) called
  `gemini-1.5-flash-latest` via `google_generative_ai` with a hard-coded key; removed from the
  working copy (comment at the current `_generateAiInsights`).
* The SAME key (hash prefix 29c5…) is still in `public_html/main.dart.js` (the repository copy
  of an old web build; the live `main.dart.js` was not checked for it) and in TWO tracked backend files:
  `backend/get_ai_load_summary.php` line 10 and `backend/get_operational_insights.php` line 12.
  A second Google key (hash prefix ecdb…) is in `public_html/main.dart.js`; its purpose is unknown.
* The app still calls `get_ai_load_summary.php` (`analytics_screen.dart` 1199).
* `gemini-1.5-flash` is not in Google's current model list (2026-10-15; even Gemini 2.0 Flash is
  listed as shut down), so these endpoints most likely fail and return their fallback text
  (not verified by calling them).

Manual (owner): delete/rotate the exposed key(s) in Google AI Studio / Cloud Console and check
their usage. Removing them from code does not invalidate them.

Server-side design (not implemented, not activated):
* Secret: `backend/ai_config.php` (git-ignored, like `auth_config.php`) or a Hostinger
  environment variable; never in Dart, never in Git; endpoints answer "AI disabled" without it.
* One endpoint `ai_summary.php`: admin token required even while `GT_AUTH_ENFORCE` is off;
  input = aggregates the server computes itself (no names, no coordinates); prompt forbids
  numbers not present in the input; output labelled "AI-generated wording of the figures above";
  deterministic fallback text.
* Bounds: feature flag `AI_SUMMARY_ENABLED=false` by default; cache one summary per report type
  and date range per day; daily call cap (e.g. 50) and 10 s timeout; failures not retried.
* Storage for cache/counter: a small MySQL table (migration, needs approval) or a file cache.
* Model: the manuscript-named Gemini 1.5 Flash is no longer listed; a current Flash/Flash-Lite
  model must be chosen and its pricing/free tier checked before activation (decision).

## 4. Historical route comparison: eligibility (real data, 236 trips, all years)

| Stage | Trips | Example trip ids | Genuine data gap or filter problem? |
|---|---|---|---|
| simulation trips | 0 | - | - |
| no GPS points recorded | 15 | -OzG0Ug_vsOH_5iX7e-d, -P-2YtNOQkNSTEvATaAS, -P3QB19ucs-0sTyUqz2x | genuine |
| all ACTIVE points less accurate than 40 m | 127 | -OzFxBUiLJb77jEN1cAu, -OzFy7XKYPF341mWvaqP, -OzFz763NtnYKFjHgJYa | genuine: median 2 points per trip, median accuracy 107 m, 31 points worse than 2 km (browser/network location). 40 m is the driver app's own proximity threshold |
| usable points, never inside an area | 76 | -P3dV2aM6C26uZ_18gL0 (123 m from an entrance), -P3mLbWnwVFZJG_UXNtn, -P3mM7Lu9HxZCxyGnsP6 | mostly genuine: 56 are 5+ km away (outside Balintawak); 15 within 300 m, 5 within 1 km -> partly geometry (below) |
| entered an area, no 60 s stay | 12 | -Ozq6e3XE53-QJYW7xFN, -Ozq8LGZdGH2iFPqNQ7s, -OzqA76s1JVfEm_4hmND | genuine pass-throughs |
| only 1 verified area visit | 6 | -OzqDaGZrtPGdLFz9zk9, -P0_wU3QvGZKAvSLw_8D, -P3K5-ctP6QkN1TwxGno | genuine for comparison (needs >= 2 areas) |
| reached path quality checks | 0 | - | - |

Filter / join checks:
* Status filter is not the cause: 4,298 of 5,224 points are ACTIVE; treating every point as
  ACTIVE (diagnostic) adds 0 visits.
* Incorrect geometry (a real join problem): Ayala Highway (1,135 m long) and T.M. Kalaw Street
  (550 m) have an end point but no polygon, so they are matched as an 80 m / 70 m circle at the
  entrance only. A corridor along entrance->end (half-width = radius; diagnostic) gives 2 more
  Ayala visits and 2 trips with >= 2 visits. Proposed fix: `AreaGeofence` corridor for road
  segments with `endLat/endLng` and no polygon (local code + tests).
* Data inconsistency: Central (Purok 1)'s entrance point lies outside its own polygon (1.19 km
  from the polygon centre). The admin must verify which is correct (no automatic change).
* San Nicolas is excluded because it is not a VERIFIED truck stop (configuration, by design).
* Relaxing the visit rule (diagnostic only: 2 fixes, 20 s, 60 m) would give 14 visits instead of 6;
  that would weaken evidence quality and is NOT proposed.

Field-testing procedure to collect qualifying history (real trips, no synthetic records):
1. Use the Android APK on the driver phone (not the web build), location permission "Allow
   all the time", precise location ON, battery optimisation OFF for the app.
2. Start the trip in the app before leaving; keep status ACTIVE while collecting; do not use
   simulation mode.
3. Before collecting, wait outside until the GPS accuracy shown is <= 40 m.
4. In each purok, collect normally; the truck should stay inside the area for at least 60 s
   (the verified-visit rule) - which normal collection already does.
5. Cover at least two areas per trip; finish the trip in the app (COMPLETED) at the end.
6. Repeat the same set of areas on at least 2 different days (comparison needs identical
   coverage); vary the order if the barangay allows it.
7. Afterwards, check Collection Route Optimization: verified visits appear per area; a
   comparison appears once 2 valid trips share the same coverage.
Demo data: only in widget tests (clearly synthetic), never written to production.

## 5. Collection evidence

"Verified visit" (`CollectionVisits`): one trip, one area, at least 3 GPS fixes recorded while the
trip status was ACTIVE, each with accuracy <= 40 m, spanning >= 60 s in one continuous stay inside
the area polygon (or radius when no polygon), gaps <= 3 min, one stray outside fix tolerated,
simulation and post-finalization fixes excluded, at most one visit per trip and area.

It establishes TRUCK PRESENCE while collecting. It does not establish partial service or
completed collection. The screen now says "Visited N days ago", "N days since verified visit",
"No verified visit record", "Last verified visit" (changed today; tests updated).

Mismatch with automatic completion logging: the driver app marks an area `completed` in
`weekly_collection_progress` after 3 in-radius fixes below 25 km/h with no dwell (GPS_PROXIMITY),
or when the driver sends an approach alert (MANUAL_ALERT). Both are weaker than a verified visit
and both are presence/notification events, not collection evidence. Proposal (decision): keep the
automatic log but call it "visit logged"; add an explicit driver action "Mark collected / Partial"
that writes `collection_scope`; stop MANUAL_ALERT from writing `completed`.

## 6. Matrix cause (pre-containment code = commit 8cd5947, same strings in the live builds)

Role Driver -> `DriverDashboard` -> `_buildMobileDashboard` (2504) / `_buildDesktopDashboard`
(2642) -> `_buildOptimizedRouteCard` (3606) -> `WidgetsBinding.instance.addPostFrameCallback` ->
`_tryAutoOptimizeRoute("CARD_BUILD")` (3612 -> 4880) -> `_optimizeRoute(isAuto: true)` (4664) ->
`RouteOptimizationService.getOptimizedRoute` (4844) -> `_getOptimizedRouteDirectMapbox` ->
`GET directions-matrix/v1/mapbox/driving` (service 214) -> `GET directions/v1/mapbox/driving`
(275) -> on Web after a failure `POST backend/route_optimization.php` (467).
Clock: `_startClock` (249) -> `Timer.periodic(500 ms)` -> `_updateTime` -> `setState` when the
displayed second changes -> rebuild -> the card schedules the next attempt while no route is stored.

Measured: none (no Mapbox statistics seen). Estimated only: 64-196 elements per run; ~235,000 -
705,600 elements per hour per looping dashboard at one run every 1-3 s.

---

## Recommended order

| # | Work | Type | Data / decision needed |
|---|---|---|---|
| 1 | Rotate the exposed Gemini key(s) | manual (owner) | none |
| 2 | Remove the Gemini key from the two PHP files (read from git-ignored config, disabled by default) | local code | decision to deploy |
| 3 | Paste Mapbox tokens, build APK + web, deploy containment | config + manual | tokens; deployment approval |
| 4 | Road-segment corridor geometry; admin verifies Central (Purok 1) coordinates | local code + admin | none for code |
| 5 | Relabel or remove the hard-coded resident "Estimated Time" windows | local code | barangay source for the windows, if any |
| 6 | Field testing to collect verified visits (section 4) | operations | 2+ weeks of real trips |
| 7 | Holiday-weighted moving average for waste | local code | recorded weights; adviser on 2.2 vs 3.1; per-area rule |
| 8 | Linear-regression ETA with held-out MAE/RMSE/R² | local code | >= 30 verified visits |
| 9 | Server-side Gemini endpoint | backend | model choice, billing, cap, cache table |
| 10 | Driver "Mark collected / Partial" | app + data | decision on completion semantics |

## Production changes needing a separate decision (none applied)
* Firebase rules: who may read `driver_routes` (residents currently can); a path for stored
  model coefficients if the regression should be shared rather than computed per device.
* MySQL: AI summary cache/counter table; client request ids if an offline queue is added;
  `collection_scope` storage if completion moves to MySQL.
* Service activation: any Gemini model (billable), any re-enable of Matrix/Directions.
* Hostinger: deploy the disabled `route_optimization.php`, remove/replace the AI endpoints'
  hard-coded key, remove `public_html/app.js`.
