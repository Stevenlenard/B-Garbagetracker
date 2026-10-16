<?php
header("Content-Type: application/json");
header("Cache-Control: no-store");
require_once 'db_config.php';
require_once 'auth_token.php';
require_once 'complaint_lib.php';

// Only an administrator may review/resolve complaints.
$gtAuth = gt_require_role(['admin']);

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $json = json_decode(file_get_contents('php://input'), true);
    $complaint_id = $_POST['complaint_id'] ?? $json['complaint_id'] ?? $_REQUEST['complaint_id'] ?? null;
    $status = $_POST['status'] ?? $json['status'] ?? $_REQUEST['status'] ?? null;
    $admin_response = $_POST['admin_response'] ?? $json['admin_response'] ?? $_REQUEST['admin_response'] ?? null;

    if ($complaint_id && $status && ctype_digit((string)$complaint_id)) {
        try {
            // Conditional, single transition; the complainant's notification is written here
            // (server side) only for the request that actually changed the status.
            // `previous_status` is kept for older Admin apps, which skip their own
            // notification when it is already resolved.
            echo json_encode(gt_complaint_transition($conn, (int)$complaint_id, $status, $admin_response, $gtAuth));
        } catch (Throwable $e) {
            error_log("update_complaint.php: " . $e->getMessage());
            echo json_encode(["success" => false, "message" => "The complaint could not be updated. Please try again."]);
        }
    } else {
        echo json_encode(["success" => false, "message" => "Missing data"]);
    }
} else {
    echo json_encode(["success" => false, "message" => "Invalid request method"]);
}
?>
