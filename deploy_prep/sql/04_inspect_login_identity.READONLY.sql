-- READ-ONLY. SELECT statements only; run in phpMyAdmin. Prints no password hashes.
-- Purpose: find out WHICH account actually authenticated when "Labubu" was typed.

-- 1) The decisive evidence: the access log stores the DB username of the account that
--    authenticated (not the text that was typed). Look at the rows around the test time.
SELECT id, user_id, username, action, ip_address, `timestamp`
FROM access_logs
ORDER BY id DESC
LIMIT 40;

-- 2) Does any account (driver/admin or resident) carry "labubu" in username, e-mail or name?
SELECT 'users' AS source, user_id AS id, username, name, email, role, is_archived, approval_status
FROM users
WHERE username LIKE '%labubu%' OR email LIKE '%labubu%' OR name LIKE '%labubu%'
UNION ALL
SELECT 'residents', resident_id, username, name, email, 'resident', is_archived, approval_status
FROM residents
WHERE username LIKE '%labubu%' OR email LIKE '%labubu%' OR name LIKE '%labubu%';

-- 3) What is registered for "Steven" (username, e-mail, name)?
SELECT 'users' AS source, user_id AS id, username, name, email, role, preferred_truck, is_archived, approval_status
FROM users
WHERE username LIKE '%steven%' OR email LIKE '%steven%' OR name LIKE '%steven%'
UNION ALL
SELECT 'residents', resident_id, username, name, email, 'resident', NULL, is_archived, approval_status
FROM residents
WHERE username LIKE '%steven%' OR email LIKE '%steven%' OR name LIKE '%steven%';

-- 4) Usernames/e-mails that exist in BOTH tables (ambiguous identities).
SELECT u.username, u.user_id AS users_id, r.resident_id AS residents_id
FROM users u
JOIN residents r ON LOWER(r.username) = LOWER(u.username);
SELECT u.email, u.user_id AS users_id, r.resident_id AS residents_id
FROM users u
JOIN residents r ON LOWER(r.email) = LOWER(u.email) AND u.email <> '';

-- 5) Numeric id collisions between drivers/admins and residents (matters for the app's
--    saved profiles, which key on the number only).
SELECT u.user_id AS shared_id, u.username AS user_account, r.username AS resident_account
FROM users u
JOIN residents r ON r.resident_id = u.user_id;

-- 6) Collation of the login columns (case / trailing-space rules of "=").
SELECT COLUMN_NAME, COLLATION_NAME
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME IN ('users', 'residents')
  AND COLUMN_NAME IN ('username', 'email');
