-- Rollback of 07_create_route_assignments.NOT_APPLIED.sql.
-- WARNING: deletes every route assignment and trip link. Export the three tables first
-- (phpMyAdmin > Export) if any assignments were created.
-- Existing tables (users, driver_trip_history, ...) are not touched. save_trip_history.php
-- keeps working without these tables (assignment linking is skipped).

DROP TABLE IF EXISTS `route_assignment_trips`;
DROP TABLE IF EXISTS `route_assignment_areas`;
DROP TABLE IF EXISTS `route_assignments`;
