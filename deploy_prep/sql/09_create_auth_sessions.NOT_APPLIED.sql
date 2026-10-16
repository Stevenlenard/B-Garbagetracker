-- Saved sign-in ("Stay signed in") sessions. NOT APPLIED.
-- Additive only: creates one new table; no existing table or row is modified.
-- Rollback: 10_rollback_auth_sessions.sql
--
-- Requires GT_AUTH_SECRET in backend/auth_config.php. Until this table exists, login.php
-- keeps issuing the legacy token (or none), so applying it can be done at any time.
--
-- Design notes
--  * One row per signed-in device. The refresh credential is "<session_id>.<generation>.<mac>"
--    with mac = HMAC(GT_AUTH_SECRET, session_id|salt|generation); it is NEVER stored here
--    (it lives in the Android keystore or in a Secure HttpOnly Web cookie). The salt alone
--    is useless without the server secret.
--  * No expiry column on purpose: a persistent ("Stay signed in") session lasts until it
--    is revoked (logout, forget account, password change, archive/delete/suspend/reject,
--    or reuse of an already-rotated refresh secret). Non-persistent sessions end after
--    12 h without use (checked in PHP from last_used_at).
--  * generation increases on every refresh (rotation). An older generation presented again
--    after the 120 s race window (rotated_at) proves a copied credential: the session is revoked.
--  * pw_marker is an HMAC of the password hash at sign-in: any password change ends
--    every existing session of that account at its next refresh.
--  * No foreign key: users and residents are separate tables keyed by (role, user_id).
--  * Revoked rows can be purged at any time (they are never reused), e.g.:
--      DELETE FROM auth_sessions WHERE revoked_at IS NOT NULL AND revoked_at < NOW() - INTERVAL 90 DAY;

CREATE TABLE IF NOT EXISTS `auth_sessions` (
  `session_id`        CHAR(32)    NOT NULL COMMENT 'random, public part of the refresh credential',
  `user_id`           INT(11)     NOT NULL COMMENT 'users.user_id or residents.resident_id (see role)',
  `role`              VARCHAR(16) NOT NULL COMMENT 'admin | driver | resident',
  `salt`              CHAR(32)    NOT NULL COMMENT 'random, per session (input of the credential mac)',
  `generation`        INT(11)     NOT NULL DEFAULT 1 COMMENT 'current credential generation; +1 per refresh',
  `rotated_at`        DATETIME    DEFAULT NULL,
  `pw_marker`         CHAR(64)    NOT NULL COMMENT 'HMAC of the password hash at sign-in',
  `persistent`        TINYINT(1)  NOT NULL DEFAULT 1 COMMENT '1 = Stay signed in (no expiry)',
  `platform`          VARCHAR(16) NOT NULL DEFAULT 'android' COMMENT 'android | web',
  `created_at`        DATETIME    NOT NULL,
  `last_used_at`      DATETIME    NOT NULL,
  `revoked_at`        DATETIME    DEFAULT NULL,
  `revoke_reason`     VARCHAR(32) DEFAULT NULL,
  PRIMARY KEY (`session_id`),
  KEY `idx_auth_sessions_account` (`role`, `user_id`, `revoked_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
