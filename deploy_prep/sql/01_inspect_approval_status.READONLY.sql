-- READ-ONLY inspection. Safe to run in phpMyAdmin: contains only SELECT statements.
-- Purpose: find driver/admin accounts whose approval_status would block them at login
-- after the new login.php, and separate legitimately approved drivers from real
-- pending applications.
--
-- Background: the old approve_user.php only cleared is_archived and never wrote
-- approval_status, so drivers approved in the past may still read 'pending'.

-- 0) Do the columns exist?  (both should be returned)
SELECT COLUMN_NAME
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME = 'users'
  AND COLUMN_NAME IN ('approval_status', 'account_status');

-- 1) Overview: how many accounts per role / approval_status / archive flag
SELECT role,
       COALESCE(approval_status, 'NULL')  AS approval_status,
       COALESCE(account_status, 'NULL')   AS account_status,
       is_archived,
       COUNT(*)                           AS accounts
FROM users
GROUP BY role, approval_status, account_status, is_archived
ORDER BY role, approval_status;

-- 2) Accounts the new login.php will treat as "pending", split by evidence.
--    last_ok_login is the most recent successful login in access_logs.
SELECT u.user_id,
       u.username,
       u.role,
       u.approval_status,
       u.is_archived,
       u.created_at,
       MAX(CASE WHEN a.action LIKE 'Successful Login%' THEN a.`timestamp` END) AS last_ok_login,
       SUM(CASE WHEN a.action LIKE 'Successful Login%' THEN 1 ELSE 0 END)     AS ok_logins,
       CASE
         WHEN SUM(CASE WHEN a.action LIKE 'Successful Login%' THEN 1 ELSE 0 END) > 0
           THEN 'HAS LOGIN HISTORY (allowed by compatibility rule; review)'
         ELSE 'NEVER LOGGED IN (blocked until approved)'
       END AS login_decision
FROM users u
LEFT JOIN access_logs a
       ON a.user_id = u.user_id AND a.username = u.username
WHERE u.role = 'driver'
  AND LOWER(COALESCE(u.approval_status, '')) = 'pending'
  AND u.is_archived = 0
GROUP BY u.user_id, u.username, u.role, u.approval_status, u.is_archived, u.created_at
ORDER BY ok_logins DESC, u.created_at DESC;

-- 3) Rejected accounts (always blocked at login)
SELECT user_id, username, role, approval_status, is_archived, created_at
FROM users
WHERE LOWER(COALESCE(approval_status, '')) = 'rejected';

-- 4) Same check for residents (residents are auto-approved at registration)
SELECT COALESCE(approval_status, 'NULL') AS approval_status, is_archived, COUNT(*) AS residents
FROM residents
GROUP BY approval_status, is_archived;

-- 5) Pending drivers who logged in DURING the bypass window (before this fix, a
--    pending driver could log in). These cannot be told apart from legacy approved
--    drivers by the log alone - review them manually against the admin's list of
--    drivers who were actually approved.
SELECT u.user_id, u.username, u.name, u.created_at, MIN(a.`timestamp`) AS first_ok_login
FROM users u
JOIN access_logs a ON a.user_id = u.user_id AND a.username = u.username
WHERE u.role = 'driver'
  AND LOWER(COALESCE(u.approval_status, '')) = 'pending'
  AND a.action LIKE 'Successful Login%'
GROUP BY u.user_id, u.username, u.name, u.created_at
ORDER BY first_ok_login;
