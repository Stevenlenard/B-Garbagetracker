# Older-runtime compatibility and live verification

Nothing here has been executed against production.

## Compatibility with older Driver runtimes (old APK / old browser tab)

| Old runtime behaviour | New Admin/Resident build | New Driver build |
|---|---|---|
| Writes `truck_locations/<truck>` without `owner_token`/`owner_epoch`/`wseq` | Shown normally (presence rules treat missing token as "no token", not offline) | Takes over via `driver_sessions` transaction; its writes carry epoch and win by `owner_epoch` ordering |
| Sets `isOnline:false` on disconnect (unscoped) | Honoured (a plain `isOnline:false` is offline) | A newer owner's node is re-asserted by its own next publish |
| Status lowercase / "IDLE (LOST)" | Normalised by `FleetStatus.normalizeStatus` | n/a |
| Embeds `route_history` in the live node | Dropped by `TruckLocationsFeed` (never delivered to the map) | n/a |
| Does not read `driver_sessions` | n/a | Cannot be displaced by it; **both runtimes can still write** until Stage 2 rules or the old runtime is retired |

Conclusion: the new Admin/Resident build is safe against old Drivers. Duplicate-session
protection only holds between NEW runtimes. Until every Driver phone/tab runs the new
build, an old runtime can still write; Stage 4 rules block only its writes to
finished trips.

Rollout order that keeps old runtimes working: Stage 1 data hygiene -> Stage 3 web ->
Stage 2 Driver APKs (all phones in one window) -> Stage 4 rules.

## Live verification checklist (UNVERIFIED until run on devices)

Run only in the isolated test setup (`--dart-define=GT_TEST_MODE=true ...`,
`GT_TELEMETRY=true`); never on production data without approval.

1. Two Driver runtimes, one driver id: second login displaces the first; first shows
   "session taken over" and stops writing; `driver_sessions/<id>.epoch` +1.
2. START -> FULL -> force-close -> relaunch: FULL and trip id restored, no new trip.
3. DONE: no further route point on that trip (`last_seen` frozen); relaunch does not
   resume it.
4. Admin + Resident open: moving the driver updates both markers; Active Fleets ==
   Online Drivers == marker count.
5. Airplane mode 60 s on the Driver: node goes stale then offline-by-token only for the
   current owner; reconnect revalidates ownership, no new session.
6. Latency: with telemetry on, read `p50/p95` of `driver_ack_ms`, `delivery_ms` from
   the dev log. Publish the numbers; do not state a fix before they exist.

## Known unmeasured risks

- Real RTDB transaction behaviour on Android/Web (fake in-memory port only).
- Extra round trip per GPS fix (guarded transaction + server-timestamp touch).
- Foreground/background location behaviour on the TECNO device.
- Rules are untested outside the console Rules Playground.
