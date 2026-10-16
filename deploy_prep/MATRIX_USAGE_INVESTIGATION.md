# Matrix usage investigation and sustainable repair (2026-10-15)

Matrix and Directions stay OFF (`MAPBOX_MATRIX_ENABLED=false`, `MAPBOX_DIRECTIONS_ENABLED=false`).
No Mapbox request was made for this investigation. Evidence comes from:
* the pre-containment code: commit `8cd5947` (`HEAD`), identical in the relevant parts to the
  LIVE web build (`main.dart.js`, Last-Modified 2026-10-07) and the LIVE APK (2026-10-13), both
  downloaded read-only and checked for the same strings;
* a read-only, shallow read of Firebase `driver_routes` (trip metadata only, no coordinates).

The Mapbox account statistics have not been seen. Nothing below is a historical request count.

## 1. The only Matrix caller

Role **Driver** -> screen **Driver dashboard** (`lib/screens/driver_dashboard.dart`, route card in
`_buildMobileDashboard` line 2571 and `_buildDesktopDashboard` line 2738) -> trigger (below) ->
`_tryAutoOptimizeRoute` (4880) -> `_optimizeRoute` (4664) -> `RouteOptimizationService.getOptimizedRoute`
(call at 4844) -> `_getOptimizedRouteDirectMapbox` -> `GET directions-matrix/v1/mapbox/driving`
(`route_optimization_service.dart` 214) -> `GET directions/v1/mapbox/driving` (275) ->
Firebase `driver_routes/<trip>/optimized_route` (334). Web only, after a failed direct attempt:
`POST backend/route_optimization.php` (467) -> unknown server code -> Firebase write (495).
(Line numbers: `HEAD` versions.)

No other caller: Admin, Resident and guest screens never call it; no PHP file in the repository
calls Mapbox; there is no background service, scheduled job or WorkManager task; the Kotlin
project (`app/`, `Asia-repo1-main/`) has no Matrix code (only map resources with the old token)
and cannot be built.

### Triggers (pre-containment)

| Trigger | Line | Kind | Note |
|---|---|---|---|
| `CARD_BUILD` | 3612 | **rebuild-driven** | `addPostFrameCallback` inside `_buildOptimizedRouteCard`, on EVERY build while `_optimizedData == null` |
| clock | 249-252 | timer | `Timer.periodic(500 ms)` -> `setState` once per second -> rebuild -> `CARD_BUILD` |
| `NEW_TRIP` | 1299 | lifecycle | after a trip is created; the dashboard **creates a trip automatically** when none is unfinished (839) |
| `RESTORE` | 837 | lifecycle | resumed trip |
| `AREAS_LOADED` | 342 | Firebase-driven | areas loaded |
| `PROGRESS_CHANGED` | 1141 | Firebase-driven | every weekly-progress change; not in the "route already valid" skip list, so it re-optimizes after every completed area |
| `GPS_FIRST_FIX` | 1423 | GPS-driven (once) | first fix only; ordinary GPS updates do not call it |
| manual | 3623, RE-OPTIMIZE | manual | card tap, details sheet |

Guards in `HEAD`: only `_isOptimizing` (one run at a time per dashboard). Nothing limited the
number of runs, failures were not remembered, and the in-memory result cache (17, 43) stored
successes only.

### Request size

`sources`/`destinations` omitted -> elements = (N + 1)^2, N = verified pending stops plus one
extra point per road-segment end. Stored routes show N = 7 to 13 -> **64 to 196 elements per
request** (Mapbox limit 25 coordinates = 625). `annotations=duration,distance`; only
`durations` was used.

### Response use

| Request | Fields used | Feature |
|---|---|---|
| Matrix | `durations` | nearest-neighbour stop order (`_solveNearestNeighborTour`); the 2-opt solver exists but is unused |
| Directions | `routes[0].geometry`, `legs[].duration/distance`, `distance`, `duration` | road route line on the driver's map, per-stop "estimated arrival (est)", total km, estimated duration and completion |

## 2. What "the route card no longer loops" means

`HEAD`: while no optimized route was stored, every build of the route card scheduled an
automatic optimization; the clock rebuilds the dashboard every second; when a run ended without
a stored route, the next rebuild started another. Each run starts with one Matrix request, so a
driver dashboard with an active trip and a failing optimization sent Matrix requests back to
back (one per run, i.e. roughly every 1-15 s depending on response time and timeouts) for as long
as it stayed open and in the foreground.

Now (local code): the card never starts an optimization; automatic runs happen at most once per
trip + area configuration + pending set (`RouteOptimizationGate`), failures are not retried
automatically, a completed area no longer re-runs it while a route exists, manual runs are
limited to one per 60 s, and with Matrix OFF nothing runs at all.

## 3. Evidence

Proven (code): the rebuild-driven loop above exists in `HEAD`, in the live web build and in the
live APK (strings `CARD_BUILD`, `directions-matrix/v1`, old token present in both).

Firebase `driver_routes` (read-only, 2026-10-15):
* 236 trips from 2026-07-20 to 2026-10-13, 9 drivers, mostly truck GT-001 (141) and GT-007 (53).
* 98 trips still `ACTIVE`, 49 `IDLE`: trips that were never finished.
* 67 trips have start and `last_seen`: 1,300 open hours in total; 952 of them in trips that never
  got a stored route. Longest: 323 h, 243 h, 142 h, 95 h, 95 h.
* Only **23** trips have a stored optimized route, all from 2026-09-06 onward, all `success: true`.
* None of the 23 has `generated_at`, and their arrival times have no " (est)" suffix. The direct
  Mapbox path in `HEAD` always writes both. So **no stored route was produced by the app's direct
  Mapbox path**; they match the Web fallback `route_optimization.php` (or an older client).

Inferences:
* `route_optimization.php` exists on Hostinger and has produced working road routes (it must call
  a routing service itself, with a credential that is not in the repository).
* The direct path apparently never completed successfully; on Android there is no fallback, so
  every Android driver dashboard with an active trip and pending stops kept the loop running.

Hypothesis (unverified, consistent with the above): the Matrix request succeeded (billed per
element) and the following `directions/v1` request failed (undocumented version), so nothing was
stored and the loop continued. Whether failed Matrix or Directions requests are billed is not
stated in Mapbox documentation.

Scale check, not a count: at 64-196 elements per run, 9,565,159 elements correspond to about
49,000-150,000 runs; at one run every 1-2 s that is about 14-83 hours of a looping, foreground
driver dashboard. The open-trip time recorded above is much larger, but how much of it a
dashboard was actually in the foreground is not recorded. **The code can account for the volume;
the data available here cannot prove it did.**

Evidence needed: old-account statistics per hour and per token (Matrix elements, Directions
requests); whether the Matrix usage is under the client token or another one (the PHP proxy's);
the source of `route_optimization.php`; Hostinger access logs for it.

## 4. Feature status, all roles (code as of 2026-10-15, switches OFF)

| Feature | Current behaviour | API dependency | Testable now? | Repair needed |
|---|---|---|---|---|
| Base map (Admin, Driver, Resident; guest web map) | shows "Map not configured" until the new token is built in | Mapbox Maps SDK / mapbox-gl JS (map loads, not Matrix) | after the token build | none |
| Firebase coordinate writes (Driver) | unchanged | Firebase RTDB | yes | none |
| Live marker movement (Admin, Resident, guest, Driver) | unchanged | Firebase + PHP location sync | yes (map needs token) | none |
| GPS trail / collection history | unchanged | stored trip paths | yes | none |
| Geofences, completion detection | unchanged | local distance checks | yes | none |
| Arrival / approach notifications | unchanged; "about N min" is an existing local estimate from straight-line distance and speed | Firebase | yes | none (it is labelled an estimate, not road time) |
| Complaints, other notifications | unchanged | PHP/MySQL, Firebase | yes | none |
| Collection-stop order (Driver) | "turned off in this version" | Matrix | no | approval to re-enable with the repaired design |
| Road route line (Driver) | not drawn unless already stored for the trip | Directions | no | same |
| Road distance / travel time (Driver) | unavailable | Directions | no | same |
| Per-stop ETA (Driver) | unavailable, no substitute | Directions | no | same |

## 5. Sustainable repair (implemented locally, behind the switches, NOT enabled)

| Measure | Where | Effect |
|---|---|---|
| No rebuild/timer triggers; one automatic run per trip+areas+pending set; no automatic retry | `RouteOptimizationGate`, dashboard | ends the feedback loop |
| Completed area does not re-run optimization while a route exists | `_tryAutoOptimizeRoute` | no request per completed stop |
| Manual re-optimize at most once per 60 s | `RouteOptimizationGate(manualCooldown)` | taps cannot burst |
| Smallest Matrix request: full (N+1)^2 only while a stop pair is unknown; otherwise `sources=0`, `destinations=1..N` (N elements); stop pairs cached on the device for 30 days | `route_matrix_plan.dart`, service | 13 stops: 196 elements once, then 13 |
| `annotations=duration` only | service | smaller response (elements unchanged) |
| Directions: documented `v5`, `steps=false`, one request per optimization | service | removes the undocumented endpoint |
| Per app run: at most 10 Matrix requests, 1,000 Matrix elements, 200 elements per request, 25 coordinates, 10 Directions requests | `MapboxRequestGuard` | bounded per device (not an account cap) |
| Result stored once per trip in Firebase and shown from there | existing | the route is not recalculated per viewer |
| Old-account token refused, no fallback token | `MapboxConfig` | - |

Not implemented (needs your decision): an account-wide shared limit. Options: (a) move the
Mapbox calls to one PHP endpoint with a daily element budget in MySQL (needs a migration and a
server-side token, so old clients and many devices share one budget), or (b) a Firebase daily
counter written by transaction (needs rules; client-enforced only). Reuse of stop pairs ACROSS
devices also needs (a) or a Firebase path with rules.

### Usage estimate (measured by the mocked model test, not guessed)

Assumptions: 3 test phones, 3 trips per phone per day, per trip 1 automatic run + 2 manual
re-optimizations, 13 stops, 1,000 GPS fixes + 1,000 rebuilds and 40 rapid taps per trip.
Result recorded by the interceptor: **27 runs/day, 900 Matrix elements and 27 Directions requests
on the first day** (one full 196-element matrix per phone), then 27 x 13 = **351 elements/day**.
Month (30 days): about 900 + 29 x 351 = **~11,100 Matrix elements and ~810 Directions requests**.
Compare with the free allowance shown on the destination account's pricing page (not verified
here). For contrast: the old loop at one 196-element run per second is ~705,600 elements per hour.
Assumptions behind that figure: 13 stops (14 coordinates, 14 x 14 = 196 elements, the largest
stop count seen in stored routes), one new run per second (the dashboard clock's rebuild rate),
i.e. every run finishing within a second. Real runs need two HTTP requests and a Firebase read,
so 1-3 s per run is more realistic: about 235,000-705,000 elements per hour per looping
dashboard, fewer with fewer stops. It is an upper-bound illustration, not a measured rate.

Status 2026-10-15: this repaired workflow (including the device pair cache) stays DISABLED and is
not used by Collection Route Optimization, which now works from recorded data only
(`deploy_prep/COLLECTION_ROUTE_OPTIMIZATION.md`). No shared budget or migration was implemented.

## 6. Restoring the route features for continuous testing

1. Keep both switches OFF until you approve this design and the numbers above.
2. Prerequisites: new builds deployed and old APKs/web copies replaced (they still contain the
   loop); old token revoked; `route_optimization.php` replaced by the disabled version or
   reviewed; usage alerts set on the destination account.
3. Controlled re-enable (on approval): build with `MAPBOX_MATRIX_ENABLED=true` and
   `MAPBOX_DIRECTIONS_ENABLED=true` for ONE test phone first, watch the destination account's
   statistics after the reporting delay, then the other devices.
4. Abort criteria: Matrix elements per day above the estimate x 2, or any growth while no trip
   is running -> rebuild with the switches OFF and revoke the destination token if needed.

The build script currently refuses switches set to `true`; that check is changed only with your
explicit approval.
