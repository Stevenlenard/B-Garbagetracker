# Notifications and ETA: findings and local changes

## Verified defects (code + a read-only sample of 120 newest `notifications` records)
| # | Defect | Evidence |
|---|---|---|
| 1 | Resident app wrote a SHARED broadcast "Truck is Arriving!" (`TRUCK_PROXIMITY`) from every open resident session | 36 records for one purok, min gap 0.7 min, no truck_id/trip_id |
| 2 | Its ETA = straight line from the RESIDENT'S PHONE to the truck / (speed or 15 km/h), formatted with `toStringAsFixed(0)` | message "approximately 0 minutes away" |
| 3 | Driver "approach" alert used a fixed 15 km/h and a 5x-radius zone (<= 300 m), clamped to >= 1 min | every `auto_approach` says 1 or 2 min |
| 4 | De-dupe lived in memory (`_approachNotifiedPuroks`, `_sentProximityAlerts`): lost on restart, resume, reconnect, second device | repeats with gaps of 0.0 min across trucks/sessions |
| 5 | Approach fired before the "already completed this week" check, in any status (PAUSED, FULL) | code order in `_checkPurokProximity` |
| 6 | Overlapping zones notify several areas on the same fix | Central + Ayala Highway at the same second |
| 7 | "Clear All" / swipe DELETED the shared record; "read" wrote the shared `isRead` | affects all users and the analytics that read `notifications` |
| 8 | No timestamp shown in any notification list | UI code |

## Local changes
- `utils/relative_time.dart`: Just now / N minutes ago / N hours ago / Yesterday / N days ago / date.
- `services/notification_inbox.dart`: per-user `notification_inbox/{role}_{id}` (read, dismissed,
  cleared_before_ms). The shared `notifications` log is never edited by the apps.
- `services/arrival_notifications.dart`: write-once key `arr_{stage}_{trip}_{area}`; records carry
  trip_id, stage, area_key, truck_id, eta_minutes, persisted timestamp.
- `utils/eta_policy.dart`: ETA only for an ACTIVE truck with fresh GPS and a real speed; arrival is a
  measured fact (inside the radius); never 0; otherwise "ETA unavailable"; stages 15/10/5.
- Driver app: staged approach alerts (only while collecting, getting closer, area not yet collected).
- Resident app: no resident-generated broadcast; ETA card via `EtaPolicy`; approach/arrival records
  of the driver app are shown for the resident's purok.
- Resident, Driver, Admin: per-user read/dismiss/clear, unread count, relative time.

## Coordination required
- Firebase rules: new node `notification_inbox` (added to `rules_stage1_trip_immutability.json`;
  no change needed while rules are `.write: true`).
- Old resident APKs keep writing `TRUCK_PROXIMITY` until updated; the new apps ignore those records.
- No PHP or MySQL change.

## ETA model feasibility (see report)
Data currently available is NOT sufficient to train or evaluate a model (1 usable arrival
observation). Needed first: log prediction-vs-actual pairs (trip, area, stage, predicted
minutes, actual geofence-entry time) in production.
