<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';

// Administrators get the full account lists. Residents and drivers get a minimal, redacted
// view (driver rows without contact details; no resident rows) that the dashboards need for
// driver counts and truck names. Accounts are never deleted by this read endpoint.
$gtAuth = gt_require_role(['admin', 'resident', 'driver']);
$gtFullAccess = ($gtAuth === null) || ($gtAuth['role'] === 'admin');

try {
    // Fetch Residents (Confirmed accounts in residents table)
    $resQuery = "SELECT resident_id as user_id, username, name, email, 'resident' as role, phone, purok, complete_address, created_at, is_archived FROM residents";
    $resStmt = $conn->prepare($resQuery);
    $resStmt->execute();
    $residents = $resStmt->fetchAll(PDO::FETCH_ASSOC);

    // Fetch Drivers and Admins
    $userQuery = "SELECT user_id, username, name, email, role, phone, license_number, preferred_truck, created_at, is_archived FROM users";
    $userStmt = $conn->prepare($userQuery);
    $userStmt->execute();
    $users = $userStmt->fetchAll(PDO::FETCH_ASSOC);

    if (!$gtFullAccess) {
        $allowed = ['user_id' => 1, 'name' => 1, 'role' => 1, 'preferred_truck' => 1, 'is_archived' => 1];
        $drivers = [];
        foreach ($users as $u) {
            if (strtolower((string)($u['role'] ?? '')) !== 'driver') continue;
            $drivers[] = array_intersect_key($u, $allowed);
        }
        $residents = [];
        $users = $drivers;
    }

    echo json_encode([
        "success" => true,
        "residents" => $residents,
        "users" => $users
    ]);

} catch (PDOException $e) {
    echo json_encode(["success" => false, "message" => "Database Error: " . $e->getMessage()]);
}
?>
