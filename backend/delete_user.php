<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';

// An administrator may delete any account. A resident or driver may delete ONLY their own
// account (the in-app "delete my account" action). No token is accepted only while the
// server is not enforcing authorization (see auth_token.php rollout modes).
$gtAuth = gt_require_role(['admin', 'resident', 'driver']);

$data = json_decode(file_get_contents("php://input"));

if (!$data || !isset($data->user_id) || !isset($data->role)) {
    echo json_encode(["success" => false, "message" => "Invalid parameters"]);
    exit;
}

$user_id = $data->user_id;
$role = $data->role;

if ($gtAuth !== null && $gtAuth['role'] !== 'admin') {
    if ((string)$gtAuth['sub'] !== (string)$user_id || $gtAuth['role'] !== strtolower((string)$role)) {
        gt_auth_fail(403, "You can only delete your own account.");
    }
}

try {
    if ($role === 'resident') {
        $query = "DELETE FROM residents WHERE resident_id = ?";
    } else {
        $query = "DELETE FROM users WHERE user_id = ?";
    }

    $stmt = $conn->prepare($query);
    $stmt->execute([$user_id]);

    if ($stmt->rowCount() > 0) {
        echo json_encode(["success" => true, "message" => "User deleted permanently"]);
    } else {
        echo json_encode(["success" => false, "message" => "User not found"]);
    }

} catch (PDOException $e) {
    echo json_encode(["success" => false, "message" => "Database Error: " . $e->getMessage()]);
}
?>
