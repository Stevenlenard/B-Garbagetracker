<?php
/**
 * Renews a short-lived access token from a "Stay signed in" (or in-use) session.
 * Body: { role, user_id, client: "android"|"web", refresh_token (Android only) }
 * Web: the refresh credential comes from the HttpOnly cookie; X-GT-CSRF: 1 is required.
 */
header("Content-Type: application/json");
header("Cache-Control: no-store");
date_default_timezone_set('Asia/Manila');
require_once 'db_config.php';
require_once 'auth_session_lib.php';

error_reporting(0);
ini_set('display_errors', 0);

if (!gt_sessions_available($conn)) {
    http_response_code(503);
    echo json_encode(["success" => false, "reason" => "unavailable", "message" => "Saved sign-in is not available on this server."]);
    exit;
}

[$role, $id, $platform, $credential] = gt_session_request_input();
if ($role === null || $id === null) {
    http_response_code(400);
    echo json_encode(["success" => false, "reason" => "invalid", "message" => "Incomplete data"]);
    exit;
}
if ($platform === 'web' && !gt_session_csrf_ok()) {
    http_response_code(403);
    echo json_encode(["success" => false, "reason" => "csrf", "message" => "Request refused."]);
    exit;
}

try {
    $r = gt_session_refresh($conn, $role, $id, $credential, $platform);
} catch (Exception $e) {
    http_response_code(500);
    echo json_encode(["success" => false, "reason" => "server", "message" => "Server error"]);
    exit;
}

if (!$r['ok']) {
    // A dead session must not leave a cookie behind on the browser.
    if ($platform === 'web' && $r['reason'] !== 'retry') gt_session_set_cookie($role, $id, null, false);
    http_response_code($r['code']);
    echo json_encode(["success" => false, "reason" => $r['reason'], "message" => $r['message']]);
    exit;
}

unset($r['ok']);
echo json_encode(["success" => true] + $r);
