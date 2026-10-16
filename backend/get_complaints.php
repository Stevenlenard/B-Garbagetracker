<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';

// Administrators see every complaint. A resident (valid token) sees ONLY their own.
// Without a token the legacy behaviour is kept until the server enforces authorization.
$gtAuth = gt_require_role(['admin', 'resident']);
$gtOnlyResident = ($gtAuth !== null && $gtAuth['role'] === 'resident') ? (string)$gtAuth['sub'] : null;

try {
    // Only select columns that exist in the deployed table.
    $columns_check = $conn->query("DESCRIBE complaints")->fetchAll(PDO::FETCH_COLUMN);
    $has = function ($c) use ($columns_check) { return in_array($c, $columns_check, true); };

    $id_col = $has('complaint_id') ? 'c.complaint_id' : 'c.id';
    $res_id_col = $has('resident_id') ? 'c.resident_id' : 'c.user_id';

    $archived_val = $has('is_archived') ? 'c.is_archived' : '0 as is_archived';
    $deleted_val = $has('deleted_by_resident') ? 'c.deleted_by_resident' : '0 as deleted_by_resident';
    $response_val = $has('admin_response') ? 'c.admin_response' : "'' as admin_response";
    $created_val = $has('created_at') ? 'c.created_at' : 'NULL as created_at';
    // The complaint's own area/location (what the resident chose) wins over the account's purok.
    $purok_val = $has('purok')
        ? "COALESCE(NULLIF(c.purok, ''), r.purok, 'Unknown') as purok"
        : "COALESCE(r.purok, 'Unknown') as purok";
    $location_val = $has('location') ? 'c.location as location' : "'' as location";
    // Optional lifecycle timestamps (deploy_prep/sql/11_complaint_lifecycle); NULL before that migration.
    $lifecycle_val = '';
    foreach (['updated_at', 'in_progress_at', 'resolved_at'] as $lc) {
        $lifecycle_val .= $has($lc) ? ", c.$lc as $lc" : ", NULL as $lc";
    }
    $order = $has('created_at') ? "c.created_at DESC, $id_col DESC" : "$id_col DESC";

    $where = '';
    $params = [];
    if ($gtOnlyResident !== null) {
        $where = " WHERE $res_id_col = ?";
        $params[] = $gtOnlyResident;
    }

    $query = "SELECT
                $id_col as id,
                $id_col as complaint_id,
                $res_id_col as user_id,
                $res_id_col as resident_id,
                c.category,
                c.description,
                c.status,
                $response_val,
                $created_val,
                $archived_val,
                $deleted_val,
                $location_val$lifecycle_val,
                COALESCE(r.name, 'Unknown Resident') as full_name,
                $purok_val
              FROM complaints c
              LEFT JOIN residents r ON $res_id_col = r.resident_id" . $where . "
              ORDER BY $order";

    $stmt = $conn->prepare($query);
    $stmt->execute($params);
    $complaints = $stmt->fetchAll(PDO::FETCH_ASSOC);

    echo json_encode([
        "success" => true,
        "data" => $complaints,
        "debug_info" => [
            "has_archived" => $has('is_archived'),
            "has_deleted" => $has('deleted_by_resident')
        ]
    ]);
} catch (PDOException $e) {
    error_log("get_complaints.php: " . $e->getMessage());
    echo json_encode(["success" => false, "message" => "Complaints could not be loaded. Please try again."]);
}
?>
