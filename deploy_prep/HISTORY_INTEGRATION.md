# Route History, Load History and Waste Collection Summary: one trip id

Tests: `test/history_integration_test.dart` (Dart), `test/php/run_tests.php` (PHP).

## Data flow

```
LOGIN  TripOpener creates/resumes ONE trip            driver_routes/{tripId}
         start coordinate = real GPS fix               (driver_id, truck_id, start_*)
GPS    guarded route points  ->  driver_routes/{tripId}/route      (LOGIN -> FULL only)
FULL   CollectionFinalizer (atomic, write-once)      driver_routes/{tripId}/collection
         duration_s, distance_km, end point, load, FULL time        <- frozen
       saveTripHistory (upsert by trip_id)           driver_trip_history (1 row / trip)
COMPLETED  completion fields on the SAME trip         unloading_confirmed_at_ms,
         (never distance / duration / route)           post_full_distance_km, isFinished
         saveTripHistory (frozen values resent; backend also freezes them)
```

| Feature | Reads | Key | Notes |
|---|---|---|---|
| Route History | `driver_routes/{tripId}` (+`/route` points), MySQL `driver_trip_history` | `trip_id` | Points stop at FULL. Distance/duration come from the frozen `collection` record. |
| Load History | MySQL `driver_trip_history` (+ Firebase trips, `load_history` weights) | `trip_id` | `LoadHistory.uniqueLoads`: finalized trips only, richest record per trip, measured weight applied. |
| Waste Collection Summary | the SAME `uniqueLoads` list | `trip_id` | totals, tons label and the yearly chart are all derived from it. |

## Rules (single source of truth)
- A **load** = a finalized collection (FULL, or a legacy COMPLETED/FINISHED trip with
  real movement). ACTIVE, PAUSED and INTERRUPTED trips are never loads.
- One trip id = one load, however many sources mention it.
- Reported time = FULL time; collection duration = LOGIN -> FULL (never -> unloading).
- Estimated load = the existing 5 t default (`weight_type ESTIMATED`); a MEASURED weight
  replaces the estimate for that trip only. Any estimate keeps the total labelled
  "Estimated waste".
- Historical rows are only read: nothing in this change updates old trips.

## What changed
Backend: `save_trip_history.php` (merge + freeze + FULL time/load/areas),
`get_load_history.php` + new `load_history_lib.php` (finalized only, one per trip,
chart from the same rows).
Flutter: `models/driver_trip.dart` (frozen record, FULL time parsing, collection
duration), new `utils/load_history.dart`, `screens/analytics_screen.dart` (single list for
totals + chart, duration/labels), `screens/driver_dashboard.dart` (exact start instant in
the history write).

## Known limits
- MySQL `driver_trip_history` has no duration column; duration is `start_time -> full_time`
  (exact now that the app sends ISO start/FULL instants) or the Firebase `duration_s`.
- Rows saved before this change keep their old values (no repair applied).
- `get_ai_load_summary.php` contains a hardcoded Gemini API key (pre-existing): rotate it.

## Priority 2.1: why the Summary said 0 while Load History listed 5

Root cause (traced in code): the two views used different pipelines.

| | Waste Collection Summary | Load History dialog (before) |
|---|---|---|
| Loader | `_fetchLoadHistoryData` | `_LoadHistoryDialogModal._fetchData` (own loader) |
| Sources | PHP `get_load_history` + route history + `load_history` node | `DriverRouteHistoryService` only |
| Rule | finalized collections only (FULL/COMPLETED) | ANY trip with movement, no status filter |
| Period | selected period | one day |

Trips that were still ACTIVE (never FULL) showed in the dialog (movement, no status
test, duration measured to "now") but are correctly not counted by the Summary. The old
PHP on Hostinger also returns ACTIVE rows, so nothing hid them until the client rule.

Fix: both views now call `LoadHistoryRepository.load()` and `LoadHistory.uniqueLoads`
(same finalized rule, one record per trip id, FULL qualifies even at 0 km, COMPLETED never
double counts). Only the date filter differs. The Summary shows loading / error+retry
states (an unreachable backend is never "0 trips"), and both views report how many
unfinished trips were left out. A change in the number of finalized `driver_routes`
(a new FULL) triggers one debounced reload; closing the dialog reloads the Summary.

Note: the five screenshot trips cannot be classified from the screenshots alone. Rows
with long, still-growing durations (16 h 56 min) and 0.0 km are the signature of
unfinished trips; a trip qualifies only if it has a FULL event (frozen `collection`
record, a stored FULL time, or status FULL/COMPLETED with movement).

## Priority 2.2: Admin quick action, route lines, two-way links

- **Quick Action**: `utils/admin_quick_actions.dart` holds the five permanent actions
  (same list for mobile and desktop). "Driver Route History" opens the existing
  `RouteHistoryScreen` (IndexedStack index 7, also in the sidebar/drawer), independent of
  the live map. Back returns to the dashboard (index 0, including Android system back).
  Each open re-creates the screen (key epoch) so it shows current data.
- **Route points** are always `driver_routes/{trip}/route` (the driver's persisted,
  guarded writes). Admin live map, Resident live map and Route History read that node.
  Live maps: `RouteGeometry.lineFeatures` (accuracy <= 100 m, jump/duplicate rejection,
  gap split at 3 min / 800 m). History: `DriverRouteHistoryService` (accuracy <= 50 m,
  stationary-jitter filter). The policies differ only in which low-quality fixes are
  dropped; collection boundaries (first/last recorded collection point) are the same.
- **Admin live map** previously never drew a live route (the "compare path" button only
  flipped a label). It now draws persisted points per truck, latest-wins, rebound per trip.
- **Resident live map** polyline updates are serialized latest-wins (no dropped update).
- **Route History** map updates are latest-wins; one point draws no line; incomplete or
  unfinalized routes are labelled; removed fabricated 960 s/480 s defaults, the invented
  24-minute end time and an unused hard-coded sample route.
- **Links**: `utils/trip_links.dart` - Route History -> "View Associated Load" opens the
  Load History dialog on the FULL date with that trip highlighted; Load History ->
  "View Collection Route" opens Route History on that trip id (loaded by id from its
  persisted record, even if filters would hide it). A trip without a finalized load is
  reported as unavailable instead of opening something else.

## Map identity (truck colours)
`utils/truck_identity.dart`: colour = f(truck id) only (16-colour palette, consecutive
numbers never collide), used by the Admin live map, Resident live map, dashboard map and
Route History (marker fill, route line, header dot, legend chip). Operational status is the
marker RING and label text. Overlapping trucks keep their true coordinates and show as
nested rings plus a combined label; the legend (`widgets/truck_legend.dart`) selects a
truck and highlights its route (Admin: line-sort-key + width; Resident: width + layer move).
