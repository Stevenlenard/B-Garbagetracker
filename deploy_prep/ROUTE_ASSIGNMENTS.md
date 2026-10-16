# Route Assignments — backend (local only, NOT deployed)

## Files
| File | Change |
|---|---|
| `backend/assignment_lib.php` | new — status rules, validation, Manila dates, trip linking |
| `backend/get_assignments.php` | new — admin: all (driver/truck/status filters); driver: own only; includes `summary` |
| `backend/save_assignment.php` | new — admin: create, or edit while PENDING |
| `backend/cancel_assignment.php` | new — admin: cancel while PENDING (row kept) |
| `backend/link_assignment_trip.php` | new — driver: link own recent trip |
| `backend/save_trip_history.php` | linking step added after the history save (optional, never blocks) |
| `backend/auth_token.php` | new `gt_require_verified_role()` (existing functions unchanged) |
| `deploy_prep/sql/06_…READONLY.sql`, `07_…NOT_APPLIED.sql`, `08_rollback…sql` | inspect / migrate / rollback |

## Authorization
* All four assignment endpoints use `gt_require_verified_role()`: a **valid token is always
  required**, independent of `GT_AUTH_ENFORCE`. With no `auth_config.php`/secret on the server they
  answer **503** (fail closed). Missing/invalid token → 401, wrong role → 403.
* Admin endpoints (`save_`, `cancel_`) accept only `admin`. `get_assignments` accepts admin and
  driver; a driver is always restricted to `driver_id = token subject` (filters ignored).
* `link_assignment_trip` accepts only `driver`; the driver id comes from the token, never the body.
* `save_trip_history.php` is unchanged for token-less (legacy) callers: the history is saved, but
  assignment data is written **only** when the request carries a verified driver token whose subject
  equals the trip's `driver_id`. No new unauthenticated write path exists.

## Linking rules
A trip links to the assignment where driver = token subject, `assignment_date` = Asia/Manila date of
the trip start, not cancelled, and truck matches (case-insensitive). Otherwise: `no_assignment`,
`truck_mismatch`. `trip_id` is the primary key of `route_assignment_trips` (one assignment per trip,
counted once). Repeated calls are idempotent. A trip already in `driver_trip_history` under another
driver is refused (`not_owner`). The app link call only accepts a trip start within the last 36 h.
If a trip was attached to ANOTHER driver's assignment, the authenticated owner's save moves it.

## Status (derived on read)
CANCELLED → PENDING (no trip, date ≥ today) → IN_PROGRESS (any linked trip not COMPLETED/FINISHED/
INTERRUPTED; **FULL stays IN_PROGRESS**) → COMPLETED (all linked trips finalized) / MISSED (date
passed, no linked trip — never while a linked trip is open). Trip status comes from
`driver_trip_history`, falling back to the link snapshot. `trips_interrupted` is reported separately.
COMPLETED is **operational closure only**; area coverage is a separate metric.

## Metrics
* **Assignment completion rate** (`summary.completion_rate`) = COMPLETED ÷ due, where due = not
  cancelled and date ≤ today (Manila) within the range. `null` when nothing is due ("Not available").
  Note: today's not-yet-started assignments are due and lower the rate until they close.
* **Assigned-area coverage** (Flutter, not yet implemented) = assigned areas with a verified GPS visit
  (`utils/collection_visits.dart`) by a linked trip ÷ assigned areas of COMPLETED + IN_PROGRESS
  assignments. Kept separate from the completion rate.
* Trips without a link (all trips before this feature) are "unassigned"; no schedule is invented.

## Deployment order (each step needs approval)
1. Run `06_inspect_route_assignments.READONLY.sql`; confirm the new tables do not exist.
2. Apply `07_create_route_assignments.NOT_APPLIED.sql`.
3. Upload `auth_token.php`, `assignment_lib.php`, the 4 endpoints and `save_trip_history.php`.
4. **Blocker for real use:** create server-only `auth_config.php` with `GT_AUTH_SECRET`
   (keep `GT_AUTH_ENFORCE` false). Until then the assignment endpoints return 503 by design, and
   existing endpoints keep working as today. Clients must log in again to receive a token.
5. Ship the Flutter Admin/Driver changes (not written yet).
Rollback: `08_rollback_route_assignments.sql` (export first), re-upload the previous
`save_trip_history.php` if desired (the new one works with or without the tables).

## Known limitations
* One assignment per driver/day and truck/day (see the migration header for the multi-shift path).
* The former 200-completed-trips-per-month purge in `save_trip_history.php` has been REMOVED (no
  automatic deletion; existing rows untouched, no migration). Trips already purged earlier cannot be
  recovered.
* A trip whose driver never reports FULL/COMPLETED keeps its assignment IN_PROGRESS.

## Flutter (local, not built)
* Admin: `lib/screens/route_assignments_screen.dart` (sidebar, drawer and Quick Action "Route
  Assignments", destination index 8). Create/edit/cancel only while Pending; status counts; date range.
* Driver: "Today's Assignment" card on the dashboard (hidden while the server feature is unavailable).
  After the automatic trip open/resume the app calls `link_assignment_trip.php` in the background; no
  START button, no change to GPS/trip status/route recording.
* Analytics: "Completed trips" renamed **Full loads** (trips that reached FULL). New "Scheduled Routes"
  card, shown only when assignments exist: Scheduled route completion (server rules) and Assigned-area
  coverage (verified visits of the assignment's own trips), kept separate.
* Shared: `lib/models/route_assignment.dart`, `lib/services/route_assignment_service.dart`
  (existing `ApiClient` + token; 401/403/503/409 mapped to messages, no token-less fallback).
