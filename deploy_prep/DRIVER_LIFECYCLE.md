# Automatic driver collection lifecycle

LOGIN -> ACTIVE (automatic) -> [PAUSE/RESUME optional] -> FULL (collection frozen) -> COMPLETED (unloading confirmed)

Code: `lib/services/driver_lifecycle.dart` (`AutoStartPolicy`, `TripOpener`,
`CollectionRecord`, `CollectionFinalizer`, `TripResumePolicy`, `TripFinalizer`),
`lib/screens/driver_dashboard.dart` (wiring). Tests: `test/auto_lifecycle_test.dart`.

## Behaviour

| Step | What happens | Where it is recorded |
|---|---|---|
| LOGIN | Session claimed (epoch takeover), presence published, GPS started, then ONE trip is resumed or created from a REAL GPS fix and set ACTIVE. No START tap. | `driver_routes/{trip}` (`start_lat/lng`, `server_start_time`, `started_by: AUTO_LOGIN`), `truck_locations/{truck}`, `users/{id}` |
| No GPS yet | Driver stays ONLINE, no trip, no coordinate. The trip opens on the first valid fix; a failed attempt is retried (same trip id, no orphan). | - |
| PAUSE (optional) | Status IDLE, same trip, still online. | truck node `status` |
| RESUME | Status ACTIVE on the same trip. The old START button is repurposed: indicator `ACTIVE`, `RESUME` after PAUSE, `NEW TRIP` when no trip is open. | - |
| FULL | Atomic, write-once freeze of duration, distance, end point and estimated load; status FULL published; backend record upserted. | `driver_routes/{trip}/collection` + mirrored legacy fields (`total_distance`, `route_status: FULL`, ...), MySQL `driver_trip_history` (one row per `trip_id`) |
| After FULL | Live position still published (truck stays visible as FULL). No route point, no distance, no purok progress is added to the finalized collection. Travel is kept apart as `post_full_distance_km`. | truck node only |
| COMPLETED | Unloading timestamp + post-FULL distance added to the same record, trip sealed (`isFinished`), status COMPLETED, driver stays ONLINE. Collection metrics are NOT recalculated. | `unloading_confirmed_at_ms`, `post_full_distance_km`, `isFinished` |

Start/end/duration/distance/route/load of a collection = LOGIN trip start -> FULL.
Estimated load keeps the existing estimate (5000 kg, `ESTIMATED`); no new load model
was introduced.

## Safe policies (decisions the code makes for the driver)

| Situation | Behaviour |
|---|---|
| Reconnect / app restart during ACTIVE | Same unfinished trip is resumed (id, start time, distance). |
| Reconnect while FULL | Restored as FULL awaiting unloading. Never reopened for collecting, never a new trip. |
| Login after COMPLETED, same login session (app restart) | No new trip opens automatically. Explicit `NEW TRIP` starts a genuinely new collection. |
| Fresh login (new login session) | A new trip opens automatically. |
| Unfinished trip older than 12 h (earlier working day) | Left untouched (never silently adopted); a new trip is created. |
| FULL pressed twice / retries | Same stored record is re-applied; nothing is duplicated. |
| COMPLETED pressed twice | Second call reports `alreadyFinished`; nothing changes. |
| COMPLETED without FULL | Collection is finalized first (flagged `COMPLETED_WITHOUT_FULL`) and then sealed, so landfill travel is never counted as collection. |
| Driver never presses COMPLETED | Trip stays FULL (unfinished). It is not auto-completed; it ages out of fleet counts with the connectivity window and is not adopted after 12 h. |
| FULL before the first GPS fix | Rejected with a message; no coordinate or distance is invented. |
| Logout before FULL | Trip stays unfinished; resumed on next login within 12 h. |
| Two runtimes / older APK | Epoch ownership + trip bind: only the owner can open, finalize or complete; an older APK without the protocol can still write until Stage 4/5 rules are applied (see ROLLOUT_PLAN.md). |

## Removed assumptions

- START is not required (hidden/repurposed, see above).
- Login no longer means IDLE-with-no-trip.
- Stationary GPS no longer flips ACTIVE to IDLE, and movement no longer flips an
  explicit PAUSE to ACTIVE. A missing GPS signal is shown as "GPS signal lost"
  (freshness) without changing the collection status.
- DONE is renamed COMPLETED and no longer finalizes the collection route.
- `isOnline` is no longer forced false at COMPLETED; the heartbeat keeps a logged-in
  COMPLETED driver online.
- Route coverage counts a FULL-finalized collection as collected.
- Route History shows a "Truck full - collection ended" event for FULL trips.

## Server-side (needs approval, nothing applied)

1. **Rules**: `rules_stage1_trip_immutability.json` allow-list extended with
   `unloading_confirmed_at_ms`, `post_full_distance_km`, `unload_lat`, `unload_lng`
   (they are written right after `isFinished` flips). Re-simulate before publishing.
2. **PHP `save_trip_history.php`** (optional hardening): it upserts by `trip_id` and
   overwrites `total_distance_km` / `finish_lat/lng` with each call. The app now
   resends the FROZEN values at COMPLETED, so it is correct today; a server-side
   guard "do not overwrite distance once status is FULL" would also protect against
   older APKs. Not applied.
3. No schema migration is required by this change.
