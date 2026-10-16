-- NOT APPLIED. Restores approval_status/account_status of the rows captured by
-- 02_repair_approval_status.NOT_APPLIED.sql (table users_approval_backup_20261012).
UPDATE users u
JOIN users_approval_backup_20261012 b ON b.user_id = u.user_id
SET u.approval_status = b.approval_status,
    u.account_status  = b.account_status,
    u.is_archived     = b.is_archived;

-- After the rollout is accepted and the rollback window has passed:
-- DROP TABLE users_approval_backup_20261012;
