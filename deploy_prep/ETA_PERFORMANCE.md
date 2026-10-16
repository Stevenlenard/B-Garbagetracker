# ETA Performance: one dataset, GPS-confirmed arrivals only

## Verified root cause (code review; no production data was read or changed)
| # | Defect | Where |
|---|---|---|
| 1 | Summary card = ALL Firebase `notifications` ever, matched by area NAME only (first later arrival of ANY truck/trip), no date/area/source filter | `analytics_screen.dart` card listener |
| 2 | Details = MySQL `get_eta_performance.php` (trip history + derived/synthetic rows) with date filter, which overwrote the Firebase list (race) | modal `_fetchModalData` |
| 3 | Fabrication: `abs(diff) > 720 -> abs % 15`; default ETA 5 min; defaults 3.5 min / 100 % / 2 visits; PHP GPS entry = start + 0.4 x duration, awaiting ETA = start + 900 s, `(index % 7) - 3`, hardcoded purok mock rows | card, modal, `get_eta_performance.php` |
| 4 | Records had no truck, trip, stage, sent time, ETA minutes or actual arrival | `_EtaRecord` |

Why 41 evaluated / 13.1 min vs 0 evaluated / 35 awaiting: different sources (all-time Firebase
vs date-filtered MySQL-derived), different matching, and different filters, so they could not agree.

## Local fix
- `lib/utils/eta_evaluation.dart`: the single evaluation. Prediction = persisted approach
  notification (sent time + stated minutes); arrival = persisted `auto_arrival`; visit = trip + area
  (first notified ETA judges the visit; later 15/10/5 alerts are listed, not re-counted);
  error = actual - predicted (+ late), 0.1 min; Asia/Manila date filter on sent time.
- Matching: trip id + area + truck (when both present), arrival >= sent. Legacy rows (no trip id):
  same truck + area, no trip id on the arrival, within 120 min; no truck => unmatched.
- Analytics card and ETA Performance details both call `EtaEvaluation.filter` + `summarize`.
  Nothing evaluated => "—" (never 0 % / 100 % / defaults).
- Details: expandable rows (area, truck, trip, notification type/stage, sent time, ETA when sent,
  predicted arrival, actual GPS-confirmed arrival or "Awaiting GPS-confirmed arrival", signed
  difference, absolute error, status).
- Tests: `test/eta_evaluation_test.dart` (25).

## Notes / limits
- "Actual arrival" = persisted time of the driver app's arrival record, written after 3 consecutive
  in-area fixes, so it is the confirmation time, slightly after the first in-area fix.
- Withdrawal from trip closure (FULL/COMPLETED) is supported (`closedTripIds`) but the Analytics
  screen has no closed-trip source wired; only explicit withdrawn notifications show as withdrawn.
- `get_eta_performance.php` / `ApiService.getEtaPerformance` are no longer used by the screens.
  The PHP still synthesises records; retire it (backend change, needs approval) rather than reuse it.
- Old records written before trip ids existed are matched conservatively, so fewer historical
  visits will count than the old 41. That is the honest number.
