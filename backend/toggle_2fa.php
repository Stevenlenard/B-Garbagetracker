<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';
$gtAuth = gt_guard(['admin', 'driver', 'resident']); // Bundle 1: login + role required
gt_require_post();

$data = json_decode(file_get_contents("php://input"));
if (is_object($data)) { list(, $data->user_id) = gt_acting_account($gtAuth, $data->user_id ?? null); }
if ($gtAuth['role'] !== 'admin') { gt_auth_fail(403, "Two-factor sign-in is managed for administrator accounts."); }

if (!empty($data->user_id) && isset($data->enabled)) {
    try {
        $enabled = $data->enabled ? 1 : 0;
        $stmt = $conn->prepare("UPDATE users SET two_factor_enabled = ? WHERE user_id = ?");
        $stmt->execute([$enabled, $data->user_id]);

        echo json_encode([
            "success" => true,
            "message" => "Two-Factor Authentication " . ($enabled ? "enabled" : "disabled")
        ]);
    } catch (PDOException $e) {
        echo json_encode(["success" => false, "message" => "Database Error: " . $e->getMessage()]);
    }
} else {
    echo json_encode(["success" => false, "message" => "Incomplete data"]);
}
?>