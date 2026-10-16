-- READ-ONLY. Run in phpMyAdmin on the production database. Changes nothing.
-- 1. Is the complaint in MySQL at all? (newest first)
SELECT complaint_id, resident_id, category, LEFT(description, 60) AS description, status, created_at
FROM complaints ORDER BY complaint_id DESC LIMIT 10;

-- 2. Which columns does the deployed table really have? (purok/location/created_at/is_archived)
DESCRIBE complaints;

-- 3. Does the submitting resident exist and is it active? (replace 123 with the resident id)
SELECT resident_id, username, purok, is_archived, approval_status, account_status
FROM residents WHERE resident_id = 123;
