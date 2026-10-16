<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';

// An administrator may delete any complaint; a resident only their own.
$gtAuth = gt_require_role(['admin', 'resident']);

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $json = json_decode(file_get_contents('php://input'), true);
    $complaint_id = $_POST['complaint_id'] ?? $json['complaint_id'] ?? $_REQUEST['complaint_id'] ?? null;

    if ($complaint_id) {
        try {
            $columns = $conn->query("DESCRIBE complaints")->fetchAll(PDO::FETCH_COLUMN);
            $id_col = in_array('complaint_id', $columns) ? 'complaint_id' : 'id';

            if ($gtAuth !== null && $gtAuth['role'] === 'resident') {
                $own = $conn->prepare("SELECT resident_id FROM complaints WHERE $id_col = ?");
                $own->execute([$complaint_id]);
                $row = $own->fetch(PDO::FETCH_ASSOC);
                if (!$row || (string)$row['resident_id'] !== (string)$gtAuth['sub']) {
                    gt_auth_fail(403, "You can only delete your own complaints.");
                }
            }

            // Explicit, user-initiated hard delete (never automatic)
            $query = "DELETE FROM complaints WHERE $id_col = ?";
            $stmt = $conn->prepare($query);
            $stmt->execute([$complaint_id]);

            echo json_encode(["success" => true, "message" => "Complaint permanently deleted"]);
        } catch (PDOException $e) {
            echo json_encode(["success" => false, "message" => "Database Error: " . $e->getMessage()]);
        }
    } else {
        echo json_encode(["success" => false, "message" => "Missing complaint_id"]);
    }
} else {
    echo json_encode(["success" => false, "message" => "Invalid request method"]);
}
?>
