<?php
header("Content-Type: application/json");
require_once 'db_config.php';

$data = json_decode(file_get_contents("php://input"));

if (!$data || !isset($data->user_id) || !isset($data->role) || !isset($data->is_archived)) {
    echo json_encode(["success" => false, "message" => "Invalid parameters"]);
    exit;
}

$user_id = $data->user_id;
$role = $data->role;
$is_archived = $data->is_archived ? 1 : 0;
$account_status = $is_archived ? 'archived' : 'active';
$archived_at = $is_archived ? date("Y-m-d H:i:s") : null;

try {
    if ($role === 'resident') {
        $query = "UPDATE residents SET is_archived = ?, account_status = ?, archived_at = ? WHERE resident_id = ?";
        $params = [$is_archived, $account_status, $archived_at, $user_id];
    } else {
        $query = "UPDATE users SET is_archived = ?, account_status = ?, archived_at = ? WHERE user_id = ?";
        $params = [$is_archived, $account_status, $archived_at, $user_id];
    }

    $stmt = $conn->prepare($query);
    $stmt->execute($params);

    if ($stmt->rowCount() > 0) {
        $message = $is_archived ? "User archived successfully" : "User unarchived successfully";
        echo json_encode(["success" => true, "message" => $message]);
    } else {
        echo json_encode(["success" => false, "message" => "User not found or no change made"]);
    }

} catch (PDOException $e) {
    echo json_encode(["success" => false, "message" => "Database Error: " . $e->getMessage()]);
}
?>
