# Collection Route Optimization (local, NOT deployed) — 2026-10-15

Matrix and Directions stay OFF. The feature below uses no Mapbox routing service (the map only
displays). The repaired Matrix workflow and its 30-day pair cache stay disabled and are not used.

## 1. What the feature does

| Part | What it shows | Evidence used |
|---|---|---|
| Collection-status markers | per area: days since the last verified truck visit (0-6 green ✓, 7-13 red ◷, 14+ dark red ◷, partial orange !, no record gray ?) | `CollectionVisits.detect` on `driver_routes/{trip}/route` (ACTIVE fixes, accuracy <= 40 m, >= 3 fixes and >= 60 s in one continuous stay, no simulation) |
| Area details | status + explanation, last confirmed visit (Asia/Manila), days since, latest partial (if a record exists), latest other activity, visit history | same; weekly-progress marks shown as "activity", never as collection |
| Historical path comparison (Driver: own trips; Admin: all) | trips that served the SAME set of areas, shortest recorded distance, median baseline, stop order of the shortest trip, travel vs in-area time | recorded GPS paths, quality-checked |
| Select reference path (Driver only) | highlights the recorded path on the map, remembers it on that device | no shared record is written |
| Insufficient history | "Insufficient history for route comparison." with the exclusion reasons and what is needed | - |

Definitions (central, `CollectionStatusConfig`): recentDays 7, staleDays 14, window 90 days.
Days are Asia/Manila calendar days (`CollectionStatus.manilaDaysBetween`). Bands update at Manila
midnight and on app resume without new data; records update live (one listener, debounced 2 s,
cancelled when the screen closes). "Unknown" = no confirmed visit in the 90-day window; it is
never called missed or overdue (there is no verified schedule data).

Precedence: the band always comes from the last confirmed visit. A newer partial record is shown
next to it ("newer partial activity") and does not change the band; partial without any
confirmed visit is its own state. The current app writes NO partial record (see section 6).

## 2. Route optimization: objective, baseline, algorithm

* Objective: for a given set of areas, the shortest recorded travel distance.
* Data: recorded GPS fixes of real trips (no invented paths, times or dates).
* Coverage constraint: only trips with an identical set of verified area visits are compared.
* Segment: first area entry to last area exit (depot travel excluded).
* Quality: >= 30 fixes, no gap > 3 min, no jump > 80 km/h, >= 2 served areas; otherwise excluded
  with the reason shown.
* Baseline: median recorded distance of the comparable valid trips (>= 2 needed).
* Algorithm: minimum over observed trips; suggested stop order = that trip's visit order.
* Distances are lengths of recorded GPS traces (great-circle between consecutive fixes), not
  road-network distances; no straight lines are drawn as roads; no optimality is claimed beyond
  "shortest among the recorded trips compared"; recorded paths do not prove current road access.
* Collection PRIORITY (which areas have gone longest without a confirmed visit) and route
  EFFICIENCY (which recorded path served a set of areas with the least distance) are separate:
  more red markers on a path is not evidence of a shorter route.

The old Matrix-based nearest-neighbour ordering is kept in the code, disabled.

### What the real data currently gives (read-only offline run, 2026-10-15)

* 236 trips in 90 days; 142 have no usable ACTIVE GPS fix; 6 confirmed visits in total.
* Status: Brixton Homes 3 days, Purok Paraiso 8 days, Riverside 64 days; the other 6 verified
  truck-stop areas: no confirmed record (Ayala Highway has a weekly GPS-proximity mark, shown as
  activity only).
* Path comparison: 0 valid paths (no trip has >= 2 verified area visits) -> every view shows
  "Insufficient history for route comparison."
* To get comparisons: trips must record GPS points throughout the collection (status ACTIVE,
  accuracy <= 40 m), stay >= 60 s in each served area, and the same set of areas must be served
  on at least 2 such trips.

## 3. Roles (permissions come from the signed-in account; no role switch in the UI)

| Role | Entry | Sees | Can do |
|---|---|---|---|
| Driver | route card on the driver dashboard ("Collection Route Optimization"; RE-OPTIMIZE opens it too while routing is off) | status, details, history incl. truck, comparison of OWN trips | select a reference path (device-local) |
| Resident | dashboard card "Collection Status" (mobile and desktop layouts) | status, details, visit dates; no truck/driver details | view only |
| Admin | sidebar / drawer "Collection Route Optimization" (index 9) | status, details, history, comparison of all trips | view only (no new editing authority) |

Interaction: web hover on an area row = quick details (tooltip), click/keyboard activation =
persistent details; Android tap on a list row or map label = bottom sheet. Map labels carry text
and symbols ("✓ Purok 2", "◷ Riverside · 64 days"). Map hover is not available (Mapbox Flutter
annotations have no hover event); the list provides it.

Data permissions: the screen reads `puroks`, `driver_routes` (90-day push-key window) and
`weekly_collection_progress`, exactly what Analytics / Route History already read. The live
Firebase rules were not inspected; residents' apps can read GPS traces today (existing
behaviour, also used by Route History). Restricting that needs rules or a server endpoint
(not changed here).

## 4. Manuscript mapping

| Manuscript requirement | Existing implementation | Change in this work | Verification | Remaining limitation |
|---|---|---|---|---|
| 1.1 real-time GPS location | driver GPS -> Firebase -> markers | none | existing tests | - |
| 1.2 route visualization + historical pathing with status indicators | Route History (recorded paths) | status markers + legend + selected recorded path | widget/unit tests | map rendering needs the destination token build |
| 1.3 geofencing, approach notifications, automatic completion logging | weekly marks (3 fixes < 25 km/h), staged approach alerts (`EtaPolicy`), verified visits in analytics | status uses verified visits only; weekly marks shown as activity | tests: pass-through is not a visit | logging rule unchanged; see section 6 gaps |
| 2.1 descriptive analytics (routes, frequency, arrival times, notification logs, coverage) | Analytics screen, PDF/Excel | collection recency per area | tests | coverage = verified visits, not households |
| 2.2 predictive arrival time by linear regression | NOT implemented: approach ETA = distance / speed rule (`EtaPolicy`) | none (not invented) | - | discrepancy, see section 5 |
| 2.2 waste volume with holiday multipliers | `PredictionEngine` (historical average x holiday multiplier, area-density fallback) | none | existing tests | only as good as recorded weights |
| 2.3 Gemini summaries | client call removed earlier (API key was public); deterministic recommendations | none | - | needs a server-side proxy (approval) |
| 3.1 linear regression + holiday-weighted moving average | regression absent; waste forecast is an average x multiplier, not a moving average | none | - | discrepancy |
| 3.2 MAE / RMSE / R² | Analytics showed an "MAE" computed as 8% of average collection time (not measured) | replaced by the MEASURED ETA error from `EtaEvaluation` (first notified ETA vs GPS-confirmed arrival) and the share within ±5 min; "Not available" when nothing is evaluated | analyzer, existing ETA evaluation tests | RMSE and R² are not computed; no regression model to evaluate |
| Route optimization (operational: analyze movement data and route patterns to identify more efficient paths) | Matrix nearest-neighbour (disabled) | recorded-path comparison over comparable coverage | unit + widget tests | today's data gives no comparison (section 2) |

## 5. ETA (separate from route optimization)

* Approach notifications: `EtaPolicy.evaluate` = straight-line distance to the area edge / current
  or average GPS speed, only while ACTIVE with a fresh fix; staged 15/10/5 min; labelled an
  estimate; no Matrix/Directions dependency; "unavailable" without speed or fresh GPS.
* Evaluation: `EtaEvaluation` matches persisted approach predictions with GPS-confirmed arrivals
  and reports average absolute error and within-±5-min share.
* No linear regression model and no training process exist in the repository. Proposed
  alternative (not implemented, needs approval): fit arrival time per area from recorded visits
  (features: time of day, area order position, recorded segment travel time, holiday flag) with
  ordinary least squares, train/test split by date, report MAE/RMSE/R² only on held-out
  observed arrivals, and keep `EtaPolicy` as the fallback while history is insufficient.
  With 6 confirmed visits today, such a model cannot yet be trained or evaluated honestly.

## 6. Completion evidence gaps (prepared findings, nothing applied)

1. GPS_PROXIMITY weekly mark: 3 consecutive fixes inside the radius at < 25 km/h; no dwell time,
   so slow pass-through traffic can satisfy it. Status markers therefore use verified visits.
2. MANUAL_ALERT: sending an "approaching" alert also writes `completed: true` for the area
   (`driver_dashboard.dart` `_sendManualAlert`); an approach alert is not a collection.
   Proposed: stop writing `completed` there, or add an explicit "Mark collected" action.
3. Weekly records are keyed by area NAME (GPS) or area ID (manual alert); the screen maps both.
4. No partial-collection record exists. Minimal proposal: optional field
   `collection_scope: "PARTIAL" | "FULL"` on the weekly area record written by an explicit driver
   action; default absent = unknown scope (no backfill).
5. `lib/services/geofence_service.dart` (unused) writes `collection_logs` with fixed "mock"
   duration 15 min and distance 2.5 km. It is not called anywhere; Analytics still reads
   `collection_logs`. Proposed: delete the unused service or remove the mock values.
None of these changes production data or rules in this work.

## 7. Files

New: `lib/utils/collection_status.dart`, `lib/utils/path_comparison.dart`,
`lib/screens/collection_route_optimization_screen.dart`, `test/collection_route_optimization_test.dart`.
Changed: `lib/utils/collection_visits.dart` (public `activeFixesOf`), `driver_dashboard.dart`
(card title/tap), `resident_dashboard.dart` (card), `admin_dashboard.dart` +
`admin_quick_actions.dart` (destination 9), `route_optimization_card.dart` (message),
`analytics_screen.dart` (measured ETA error instead of the formula "MAE"),
`test/mapbox_containment_test.dart` (whitespace-tolerant gate check).
