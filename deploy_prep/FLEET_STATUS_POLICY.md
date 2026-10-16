# Fleet status policy (single source of truth)

Code: `lib/utils/fleet_status.dart` (rules) and `lib/utils/fleet_snapshot.dart`
(deduplicated live snapshot). Tests: `test/fleet_status_test.dart`,
`test/fleet_snapshot_test.dart`.

## Existing values (not new thresholds)

| Value | Setting | Origin |
|---|---|---|
| Freshness window | 180 000 ms (3 min) | `FleetStatus.freshnessWindowMs`; already used by Admin cards, Resident cards, dashboard map, admin map. The driver heartbeat is 30 s. |
| Session limit | 12 h from `login_time` | driver auto-logout uses the same limit |
| Re-evaluation tick | 15 s | cadence only, no new threshold; makes aging happen without a new event |
| Driver "GPS lost" | 2 min without a fix => driver publishes IDLE | `driver_dashboard` (unchanged) |

Previously inconsistent and now aligned: Analytics fleet chart and the Driver
track map used a private 120 s window plus a required `lastSeen > 0`.

## Concepts (kept separate)

| Concept | Rule |
|---|---|
| Connectivity | owner-aware `isOnline` flag AND fresh `lastSeen`. `offline_token == owner_token` means offline. A stale `isOnline:true` is NOT connected. |
| Collection status | ACTIVE, IDLE/PAUSED, FULL, COMPLETED. Independent of connectivity. |
| Open trip | `trip_active == true` and a non-empty `current_session`, status not COMPLETED/FINISHED/OFFLINE. |
| Collecting | open trip and status ACTIVE/COLLECTING. |

## Definitions (updated for the automatic lifecycle)

- **Online Drivers** = connected drivers, one per driver: online flag owned by the
  current session AND a fresh `lastSeen`, status not OFFLINE. A driver who
  confirmed COMPLETED but is still logged in IS online (connectivity is not a
  collection status).
- **Active Fleets** = the collection fleet: online drivers whose status is not
  COMPLETED/FINISHED. ACTIVE, PAUSED (IDLE) and FULL are included.
- **Collecting** = ACTIVE only (`FleetSnapshot.collecting`).
- **Map markers** = online drivers that are not COMPLETED, with valid coordinates.
  A FULL truck stays visible with its FULL status; a COMPLETED truck is counted as
  online but not drawn (its collection is over).
- **GPS freshness** (separate from connectivity): `gps_at` is stamped only by GPS
  publishes; the 30 s heartbeat refreshes `lastSeen` only. Same 180 000 ms window.
  A stale GPS marks the label "GPS delayed"; it does not change status or counts.
- A truck without a valid fix is online (counted) but has no marker yet.

Thresholds (all existing; none added): heartbeat 30 s, GPS fix age limit 30 s
(`GpsFixPolicy`), connectivity/GPS/marker freshness 180 s, session limit 12 h,
fleet re-evaluation tick 15 s, marker pulse 120 ms (visual only).

## Documented, intentional differences

| Place | Difference | Reason |
|---|---|---|
| Admin cards + admin map | also require `users/{id}` to be a non-archived driver that is itself online/fresh | Admin has account knowledge; the users node is refreshed by the same 30 s heartbeat |
| Resident cards | excludes reserved test names (ARIAN JOY, JOHN DRIVER, SYSTEM ADMIN) | existing behaviour, held per instruction |
| Dashboard map (Admin + Resident) | no `users` gate | it has no account data; shows every live node with coordinates |
| Standalone GIS web | accepts PHP `seconds_ago` as freshness for the PHP fallback | PHP rows carry no `lastSeen` |
| Maps | hide live nodes without coordinates | cannot be drawn; cards still count them |
| Analytics chart | counts per registered truck: live+FULL => Full, live+IDLE => Idle (was Active), live otherwise => Active, not live => Idle | chart has three buckets; paused is not collecting |

Admin and Resident can therefore differ only when `users/{id}` presence disagrees
with the truck node, or for the reserved test names.
