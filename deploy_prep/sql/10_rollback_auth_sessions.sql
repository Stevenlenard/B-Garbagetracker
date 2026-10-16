-- Rollback for 09_create_auth_sessions.NOT_APPLIED.sql.
-- Effect: every saved sign-in ends; login.php falls back to the legacy token automatically.
-- Users who chose "Stay signed in" will be asked for their password on next refresh.
DROP TABLE IF EXISTS `auth_sessions`;
