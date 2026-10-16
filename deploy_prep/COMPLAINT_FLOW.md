# Resident complaint -> Admin (single path)

Resident (Web/Android) -> `ApiService.fileComplaint` -> `file_complaint.php` -> MySQL `complaints`
-> `get_complaints.php` -> Admin Complaint Management and the Admin Overview counts. No other store.

## Defects fixed locally
| Area | Before | Now |
|---|---|---|
| `file_complaint.php` | INSERT named `purok, location` unconditionally (fails on an older table); a mail error that is not a PHPMailer exception became an HTTP 500 AFTER the row was saved (resident sees "failed", resubmits -> duplicates) | INSERT uses only existing columns; any mail error is caught and logged; one Admin in-app notification written server-side after the INSERT |
| `get_complaints.php` | open to everyone; ignored the complaint's own purok/location; `created_at` hard-coded; DB error text returned | admin: all; resident token: own only; legacy token-less unchanged; schema-aware; generic error |
| Admin Overview counts | a Firebase `complaints` listener overwrote the MySQL counts with stale data | MySQL only; refreshed when a RESIDENT_COMPLAINT notification arrives |
| Admin Complaint Management | loaded once; failure silent | live refresh on new complaint; visible error + Retry |
| Apps | each wrote its own RESIDENT_COMPLAINT notification (and showed "failed" if that write threw after the save) | no client write |

## Deployment order (important)
1. Upload `file_complaint.php` and `get_complaints.php` FIRST (they now own the notification).
2. Then deploy the Web build / new APK. A new client against the OLD PHP would send no Admin notification.
3. Old clients in the field will still write a notification of their own until updated (possible duplicate).
4. Notification writes from PHP need the Firebase `notifications` node to accept REST writes (same assumption as registration).

## Complaint Center lifecycle (local, NOT deployed)
Pending -> In Progress -> Resolved (Pending may be resolved directly; Resolved is final, no reopening).

| Piece | What it does |
|---|---|
| `backend/complaint_lib.php` (new) | status mapping (old spellings included), list SQL (bound params), conditional single transition, status history, complainant notification |
| `backend/complaint_center.php` (new) | Admin list: Active/Resolved, server-side search/filters/pagination, real counts; details + history (Admin or the complaining resident) |
| `backend/update_complaint.php` (rewritten, same request format) | Admin only; resolution note required; `UPDATE ... WHERE status NOT IN (...)` so double clicks / two admins transition once; writes the resident notification server side at `notifications/complaint_in_progress_<id>` / `complaint_resolved_<id>` (the second key is the one older Admin apps already use -> no duplicates with them); notification failure is reported (`notification: failed`) and retried by re-sending the same status |
| `backend/get_complaints.php` | + optional `updated_at`, `in_progress_at`, `resolved_at` (NULL before the migration) |
| `file_complaint.php`, `auth_token.php` | unchanged (identical to the copies uploaded with the Web submission fix) |
| Driver reports | still Firebase `truck_issues` (no MySQL table); Admin change guarded by a Firebase transaction; private `ISSUE_UPDATE` to `targetUserId` only (no `targetRole`/`truck_id` broadcast) |

SQL (all optional, none applied): `11_inspect_complaint_lifecycle.READONLY.sql`, `12_complaint_lifecycle.NOT_APPLIED.sql`,
rollback `13_rollback_complaint_lifecycle.sql`. The endpoints work with and without 12_.

Deployment order: (1) run 11_ (read only); (2) upload `complaint_lib.php`, then `complaint_center.php`,
`update_complaint.php`, `get_complaints.php` together; (3) optionally apply 12_; (4) deploy the Web build / APK.
A new client against an old server shows "web page instead of data" (or "not available on the server yet")
in the Complaint Center instead of failing silently; resident submission is unaffected either way.
Older Admin APKs keep working but must now enter a resolution note to resolve.

## Not proven from code
The reported missing complaint cannot be attributed to one failure point without the production
database / PHP log. Run `deploy_prep/sql/05_inspect_complaints.READONLY.sql` and read the Hostinger PHP
error log: row present -> admin-side (stale list / filter / old build); row absent -> A/B/C.
