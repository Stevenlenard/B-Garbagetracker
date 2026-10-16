<?php
// TEST STUB for the optional, server-only backend/approval_config.php.
if (getenv('GT_TEST_GRACE_OFF') === '1') {
    define('APPROVAL_LEGACY_GRACE', false);
}
