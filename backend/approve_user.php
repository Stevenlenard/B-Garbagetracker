<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';

// Only an administrator may approve accounts.
gt_require_role(['admin']);

$data = json_decode(file_get_contents("php://input"));

if (!$data) {
    echo json_encode(["success" => false, "message" => "No data received"]);
    exit;
}

if (!empty($data->user_id) && !empty($data->role)) {
    try {
        $user_id = $data->user_id;
        $role = strtolower($data->role);

        $table = ($role === 'resident') ? 'residents' : 'users';
        $id_col = ($role === 'resident') ? 'resident_id' : 'user_id';

        $exists = $conn->prepare("SELECT 1 FROM $table WHERE $id_col = ?");
        $exists->execute([$user_id]);
        if (!$exists->fetch()) {
            echo json_encode(["success" => false, "message" => "User not found."]);
            exit;
        }

        // Approval is recorded in approval_status (what registration and the admin
        // list use) as well as clearing the archive flag. Older databases without the
        // status columns fall back to the archive flag only.
        try {
            $stmt = $conn->prepare("UPDATE $table SET is_archived = 0, approval_status = 'approved', account_status = 'active' WHERE $id_col = ?");
            $stmt->execute([$user_id]);
        } catch (PDOException $e) {
            $stmt = $conn->prepare("UPDATE $table SET is_archived = 0 WHERE $id_col = ?");
            $stmt->execute([$user_id]);
        }

        echo json_encode(["success" => true, "message" => "Account approved and activated successfully."]);

    } catch (PDOException $e) {
        error_log("approve_user.php: " . $e->getMessage());
        echo json_encode(["success" => false, "message" => "Could not approve the account. Please try again."]);
    }
} else {
    echo json_encode(["success" => false, "message" => "Incomplete data"]);
}
?>
