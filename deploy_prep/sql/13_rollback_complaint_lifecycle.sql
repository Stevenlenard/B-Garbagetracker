-- Rollback for 12_complaint_lifecycle.NOT_APPLIED.sql. Run only if 12_ was applied and must be undone.
-- Complaints themselves (ids, status, admin_response/resolution notes) are NOT touched.
-- Lost by rolling back: the recorded status history and the in_progress_at / resolved_at /
-- resolved_by / resolved_by_name values. Export them first if they are needed:
--   SELECT * FROM complaint_status_history;
--   SELECT complaint_id, in_progress_at, resolved_at, resolved_by, resolved_by_name FROM complaints;
-- The PHP endpoints keep working after the rollback (they detect the missing columns/table).
--
-- `updated_at` is NOT dropped here: older databases may already have had it before 12_.
-- Drop it manually only if 11_inspect showed it did not exist before.

DROP TABLE IF EXISTS complaint_status_history;

ALTER TABLE complaints DROP INDEX idx_complaints_status_created;
ALTER TABLE complaints DROP INDEX idx_complaints_resolved_at;
ALTER TABLE complaints DROP INDEX idx_complaints_category;

ALTER TABLE complaints
    DROP COLUMN in_progress_at,
    DROP COLUMN resolved_at,
    DROP COLUMN resolved_by,
    DROP COLUMN resolved_by_name;
