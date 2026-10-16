<?php
/**
 * Ends a saved sign-in on the server (Logout / Forget Account).
 * Body: { role, user_id, client: "android"|"web", refresh_token (Android only) }
 * Web: the credential comes from the HttpOnly cookie, which is always deleted;
 * X-GT-CSRF: 1 is required. Always answers success (idempotent).
 */
header("Content-Type: application/json");
header("Cache-Control: no-store");
date_default_timezone_set('Asia/Manila');
require_once 'db_config.php';
require_once 'auth_session_lib.php';

error_reporting(0);
ini_set('display_errors', 0);

[$role, $id, $platform, $credential] = gt_session_request_input();
if ($role === null || $id === null) {
    http_response_code(400);
    echo json_encode(["success" => false, "message" => "Incomplete data"]);
    exit;
}
if ($platform === 'web' && !gt_session_csrf_ok()) {
    http_response_code(403);
    echo json_encode(["success" => false, "message" => "Request refused."]);
    exit;
}

$revoked = false;
if (gt_sessions_available($conn)) {
    try {
        $revoked = gt_session_logout($conn, $role, $id, $credential);
    } catch (Exception $e) {
        $revoked = false;
    }
}
if ($platform === 'web') gt_session_set_cookie($role, $id, null, false);
echo json_encode(["success" => true, "revoked" => $revoked]);
