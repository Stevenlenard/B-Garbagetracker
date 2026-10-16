-- NOT APPLIED. Optional, additive migration for the Complaint Center lifecycle.
-- Review 11_inspect_complaint_lifecycle.READONLY.sql first; take a phpMyAdmin export of
-- `complaints` before running. Rollback: 13_rollback_complaint_lifecycle.sql.
--
-- What it does (nothing is deleted, renamed or rewritten; complaint IDs are untouched):
--   * complaints: adds nullable in_progress_at, resolved_at, resolved_by, resolved_by_name
--     and updated_at (only if missing). Existing rows keep NULL there; the API then falls back
--     to created_at (e.g. the Resolved Archive date filter) and derives history from timestamps.
--   * complaint_status_history: one row per Admin status transition (audit trail).
--   * indexes for the Complaint Center queries (status + date, resolved date, category).
--
-- The PHP endpoints work WITHOUT this migration (they detect the columns/table), so it can be
-- applied before or after uploading the PHP files. Existing status values are NOT converted:
-- the API maps old spellings ('In Progress', 'completed', ...) to the three lifecycle states.
--
-- Uses information_schema checks so re-running it is harmless (MySQL 5.7/8 and MariaDB).

DELIMITER //

DROP PROCEDURE IF EXISTS gt_add_column //
CREATE PROCEDURE gt_add_column(IN p_table VARCHAR(64), IN p_column VARCHAR(64), IN p_definition VARCHAR(255))
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.COLUMNS
                   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = p_table AND COLUMN_NAME = p_column) THEN
        SET @gt_sql = CONCAT('ALTER TABLE `', p_table, '` ADD COLUMN `', p_column, '` ', p_definition);
        PREPARE gt_stmt FROM @gt_sql;
        EXECUTE gt_stmt;
        DEALLOCATE PREPARE gt_stmt;
    END IF;
END //

DROP PROCEDURE IF EXISTS gt_add_index //
CREATE PROCEDURE gt_add_index(IN p_table VARCHAR(64), IN p_index VARCHAR(64), IN p_columns VARCHAR(255))
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.STATISTICS
                   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = p_table AND INDEX_NAME = p_index) THEN
        SET @gt_sql = CONCAT('ALTER TABLE `', p_table, '` ADD INDEX `', p_index, '` (', p_columns, ')');
        PREPARE gt_stmt FROM @gt_sql;
        EXECUTE gt_stmt;
        DEALLOCATE PREPARE gt_stmt;
    END IF;
END //

DELIMITER ;

CALL gt_add_column('complaints', 'updated_at', 'DATETIME NULL DEFAULT NULL');
CALL gt_add_column('complaints', 'in_progress_at', 'DATETIME NULL DEFAULT NULL');
CALL gt_add_column('complaints', 'resolved_at', 'DATETIME NULL DEFAULT NULL');
CALL gt_add_column('complaints', 'resolved_by', 'INT NULL DEFAULT NULL');
CALL gt_add_column('complaints', 'resolved_by_name', 'VARCHAR(100) NULL DEFAULT NULL');

-- Complaint Center: Active/Resolved + newest first, Archive by resolution date, category filter.
CALL gt_add_index('complaints', 'idx_complaints_status_created', '`status`, `created_at`');
CALL gt_add_index('complaints', 'idx_complaints_resolved_at', '`resolved_at`');
CALL gt_add_index('complaints', 'idx_complaints_category', '`category`');

CREATE TABLE IF NOT EXISTS complaint_status_history (
    history_id      INT AUTO_INCREMENT PRIMARY KEY,
    complaint_id    INT NOT NULL,
    from_status     VARCHAR(20) NULL,
    to_status       VARCHAR(20) NOT NULL,
    note            TEXT NULL,
    changed_by_role VARCHAR(20) NULL,
    changed_by_id   INT NULL,
    changed_by_name VARCHAR(100) NULL,
    created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_complaint_history_complaint (complaint_id, history_id)
);

DROP PROCEDURE IF EXISTS gt_add_column;
DROP PROCEDURE IF EXISTS gt_add_index;

-- Verify:
--   SHOW CREATE TABLE complaints;
--   SHOW CREATE TABLE complaint_status_history;
