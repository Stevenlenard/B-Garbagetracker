<?php
// TEST STUB for backend/auth_config.php (server-only file in production).
if (getenv('GT_TEST_AUTH_SECRET')) {
    define('GT_AUTH_SECRET', getenv('GT_TEST_AUTH_SECRET'));
}
if (getenv('GT_TEST_AUTH_ENFORCE') === '1') {
    define('GT_AUTH_ENFORCE', true);
}
