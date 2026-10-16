<?php
// TEST STUB: replaces backend/db_config.php. No MySQL, no Hostinger credentials.
require_once __DIR__ . '/../fake_pdo.php';
$conn = new FakeConn(getenv('GT_PHP_STATE'));
