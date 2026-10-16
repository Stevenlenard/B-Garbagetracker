-- Migration 09: saved sign-in sessions (one new table; nothing else changes).
-- Rollback: DROP TABLE `auth_sessions`;  (10_rollback_auth_sessions.sql)
CREATE TABLE IF NOT EXISTS `auth_sessions` (
  `session_id`    CHAR(32)    NOT NULL,
  `user_id`       INT(11)     NOT NULL,
  `role`          VARCHAR(16) NOT NULL,
  `salt`          CHAR(32)    NOT NULL,
  `generation`    INT(11)     NOT NULL DEFAULT 1,
  `rotated_at`    DATETIME    DEFAULT NULL,
  `pw_marker`     CHAR(64)    NOT NULL,
  `persistent`    TINYINT(1)  NOT NULL DEFAULT 1,
  `platform`      VARCHAR(16) NOT NULL DEFAULT 'android',
  `created_at`    DATETIME    NOT NULL,
  `last_used_at`  DATETIME    NOT NULL,
  `revoked_at`    DATETIME    DEFAULT NULL,
  `revoke_reason` VARCHAR(32) DEFAULT NULL,
  PRIMARY KEY (`session_id`),
  KEY `idx_auth_sessions_account` (`role`, `user_id`, `revoked_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
