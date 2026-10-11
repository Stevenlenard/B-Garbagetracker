<?php
header("Content-Type: application/json");
require_once 'db_config.php';

$data = json_decode(file_get_contents("php://input"));

if (!$data) {
    echo json_encode(["success" => false, "message" => "No data received"]);
    exit;
}

if (!empty($data->user_id) && !empty($data->role)) {
    try {
        $user_id = $data->user_id;
        $role = strtolower($data->role);

        if ($role === 'resident') {
            $query = "UPDATE residents SET approval_status = 'rejected' WHERE resident_id = ?";
        } else {
            $query = "UPDATE users SET approval_status = 'rejected' WHERE user_id = ?";
        }

        $stmt = $conn->prepare($query);
        $stmt->execute([$user_id]);

        if ($stmt->rowCount() > 0) {
            echo json_encode(["success" => true, "message" => "Registration rejected successfully."]);
        } else {
            echo json_encode(["success" => false, "message" => "User not found."]);
        }

    } catch (PDOException $e) {
        echo json_encode(["success" => false, "message" => "Database Error: " . $e->getMessage()]);
    }
} else {
    echo json_encode(["success" => false, "message" => "Incomplete data"]);
}
?>
