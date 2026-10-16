-- READ-ONLY. Run in phpMyAdmin on the production database before 12_. Changes nothing.

-- 1. Real column types (is `status` a VARCHAR or an ENUM? which members?).
SHOW CREATE TABLE complaints;

-- 2. Which status spellings exist today, and how many of each.
--    The new code reads pending / in_progress / "In Progress" / under review / resolved /
--    completed / closed (any case) as the three lifecycle states; anything else counts as Pending.
SELECT status, COUNT(*) AS n FROM complaints GROUP BY status ORDER BY n DESC;

-- 3. Existing indexes (avoid duplicating one in 12_).
SHOW INDEX FROM complaints;

-- 4. Total rows (expected size of the Resolved Archive).
SELECT COUNT(*) AS total_complaints FROM complaints;
