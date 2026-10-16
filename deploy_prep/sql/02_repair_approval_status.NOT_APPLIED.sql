-- NOT APPLIED. Reversible repair for legacy "approved but still pending" drivers.
-- Run ONLY after:
--   1. a full database backup (see 00 below),
--   2. reviewing the output of 01_inspect_approval_status.READONLY.sql, section 2 and 5,
--   3. the administrator confirming which listed drivers were really approved.
--
-- Nothing is deleted. The previous values are copied to a backup table first, and
-- every change can be undone by 03_rollback_approval_status.sql.

-- 00) Backup of the affected rows (run first; keep the table until the rollout is accepted)
CREATE TABLE IF NOT EXISTS users_approval_backup_20261012 AS
SELECT user_id, username, role, approval_status, account_status, is_archived, NOW() AS backed_up_at
FROM users
WHERE role = 'driver'
  AND LOWER(COALESCE(approval_status, '')) IN ('pending', 'rejected');

-- 01) EDIT THIS LIST: only driver ids the administrator confirmed as approved.
--     (Do not use "all pending drivers": real pending applications must stay pending.)
--     Example:  SET @approved_ids = '5,7,12';
SET @approved_ids = '';

-- 02) Apply. Does nothing while @approved_ids is empty.
UPDATE users
SET approval_status = 'approved',
    account_status  = 'active'
WHERE role = 'driver'
  AND is_archived = 0
  AND LOWER(COALESCE(approval_status, '')) = 'pending'
  AND FIND_IN_SET(user_id, @approved_ids) > 0;

-- 03) Verify
SELECT user_id, username, approval_status, account_status
FROM users
WHERE FIND_IN_SET(user_id, @approved_ids) > 0;
