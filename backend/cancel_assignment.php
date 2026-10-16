<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';
require_once 'assignment_lib.php';

// Admin only. Cancels a PENDING assignment. Nothing is deleted: the row keeps
// cancelled_at/cancelled_by, and its driver/truck day keys are released.
$auth = gt_require_verified_role(['admin']);

$in = json_decode(file_get_contents('php://input'), true);
if (!is_array($in)) $in = $_POST;
$id = (int)($in['assignment_id'] ?? 0);

try {
    if (!gt_assignment_tables_exist($conn)) {
        echo json_encode(["success" => false, "available" => false, "message" => "Route assignments are not set up on this server yet."]);
        exit;
    }
    $a = $id > 0 ? gt_load_assignment($conn, $id) : null;
    if (!$a) {
        http_response_code(404);
        echo json_encode(["success" => false, "message" => "Assignment not found."]);
        exit;
    }
    if ($a['status'] !== 'PENDING') {
        http_response_code(409);
        echo json_encode(["success" => false, "message" => "Only pending assignments can be cancelled."]);
        exit;
    }
    $nowManila = (new DateTimeImmutable('@' . gt_now_ts()))->setTimezone(new DateTimeZone(GT_ASSIGNMENT_TZ))->format('Y-m-d H:i:s');
    $conn->prepare("UPDATE route_assignments SET cancelled_at = ?, cancelled_by = ?, driver_day_key = NULL, truck_day_key = NULL WHERE assignment_id = ?")
        ->execute([$nowManila, (int)$auth['sub'], $id]);
    echo json_encode(["success" => true, "message" => "Assignment cancelled.", "data" => gt_load_assignment($conn, $id)]);
} catch (PDOException $e) {
    error_log("cancel_assignment.php: " . $e->getMessage());
    echo json_encode(["success" => false, "message" => "The assignment could not be cancelled."]);
}
