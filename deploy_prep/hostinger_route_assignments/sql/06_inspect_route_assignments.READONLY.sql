-- READ-ONLY pre-check for the route assignment migration. Changes nothing.
-- Run in phpMyAdmin (Hostinger) and keep the output with the deployment notes.

-- 1. Server version / engine (UNIQUE indexes on nullable columns are used; any MySQL 5.7+/MariaDB 10.2+ is fine).
SELECT VERSION() AS server_version, @@default_storage_engine AS default_engine;

-- 2. Time zone of the server (assignment dates are computed in PHP as Asia/Manila; this is informational).
SELECT @@global.time_zone AS global_tz, @@session.time_zone AS session_tz, @@system_time_zone AS system_tz, NOW() AS server_now;

-- 3. The new tables must NOT exist yet (expect an empty result).
SHOW TABLES LIKE 'route_assignment%';

-- 4. Tables the feature reads (expect both).
SHOW TABLES LIKE 'users';
SHOW TABLES LIKE 'driver_trip_history';

-- 5. Column types the new tables must match (users.user_id INT, driver_trip_history.trip_id VARCHAR(100)).
SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, CHARACTER_SET_NAME, COLLATION_NAME
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE()
  AND ((TABLE_NAME = 'users' AND COLUMN_NAME IN ('user_id', 'role', 'is_archived'))
    OR (TABLE_NAME = 'driver_trip_history' AND COLUMN_NAME IN ('trip_id', 'driver_id', 'route_status', 'start_time')));

-- 6. Legacy, currently UNUSED tables (not reused by this feature; counts only, for the record).
SELECT 'routes' AS tbl, COUNT(*) AS row_count FROM routes
UNION ALL SELECT 'route_areas', COUNT(*) FROM route_areas;
