-- Route assignments migration. NOT APPLIED. Review 06_inspect_route_assignments.READONLY.sql output first.
-- Additive only: creates three new tables; no existing table or row is modified.
-- Rollback: 08_rollback_route_assignments.sql
--
-- Design notes
--  * Status is derived by the PHP endpoints; only cancellation is stored.
--  * driver_day_key / truck_day_key hold "<driver>|<date>" and "<TRUCK>|<date>" while the
--    assignment is live and NULL once cancelled. Their UNIQUE indexes enforce one live
--    assignment per driver per day and per truck per day (several NULLs are allowed).
--    To allow several assignments per day later: add a `shift_no` column and include it in
--    both keys, and make trip linking pick the assignment by shift/time window.
--  * No foreign key to users: deleting a user account must not delete or block the
--    assignment history (assignments keep the driver_id as recorded).
--  * route_assignment_trips.trip_id is the PRIMARY KEY: a trip can belong to at most one
--    assignment, so it can never be counted twice. trip_status is a snapshot of the latest
--    reported trip status (kept when driver_trip_history retention purges old trips).

CREATE TABLE IF NOT EXISTS `route_assignments` (
  `assignment_id`   INT(11) NOT NULL AUTO_INCREMENT,
  `assignment_date` DATE NOT NULL COMMENT 'Asia/Manila collection day',
  `driver_id`       INT(11) NOT NULL,
  `truck_id`        VARCHAR(50) NOT NULL COMMENT 'same identifier as users.preferred_truck / trip truck_id',
  `notes`           VARCHAR(255) DEFAULT NULL,
  `created_by`      INT(11) NOT NULL,
  `created_at`      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`      TIMESTAMP NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
  `cancelled_at`    DATETIME DEFAULT NULL,
  `cancelled_by`    INT(11) DEFAULT NULL,
  `driver_day_key`  VARCHAR(40) DEFAULT NULL,
  `truck_day_key`   VARCHAR(80) DEFAULT NULL,
  PRIMARY KEY (`assignment_id`),
  UNIQUE KEY `uq_assignment_driver_day` (`driver_day_key`),
  UNIQUE KEY `uq_assignment_truck_day` (`truck_day_key`),
  KEY `idx_assignment_date` (`assignment_date`),
  KEY `idx_assignment_driver_date` (`driver_id`, `assignment_date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS `route_assignment_areas` (
  `assignment_id`  INT(11) NOT NULL,
  `area_key`       VARCHAR(80) NOT NULL COMMENT 'Firebase puroks key',
  `area_name`      VARCHAR(120) NOT NULL COMMENT 'name snapshot at assignment time',
  `sequence_order` INT(11) NOT NULL DEFAULT 0,
  PRIMARY KEY (`assignment_id`, `area_key`),
  CONSTRAINT `fk_assignment_areas` FOREIGN KEY (`assignment_id`) REFERENCES `route_assignments` (`assignment_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS `route_assignment_trips` (
  `trip_id`       VARCHAR(100) NOT NULL,
  `assignment_id` INT(11) NOT NULL,
  `link_source`   ENUM('DRIVER_APP', 'TRIP_HISTORY', 'ADMIN') NOT NULL,
  `trip_status`   VARCHAR(30) DEFAULT NULL,
  `linked_at`     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`trip_id`),
  KEY `idx_assignment_trips_assignment` (`assignment_id`),
  CONSTRAINT `fk_assignment_trips` FOREIGN KEY (`assignment_id`) REFERENCES `route_assignments` (`assignment_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
