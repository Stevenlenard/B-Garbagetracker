<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';
require_once 'assignment_lib.php';

// Driver only, own trips only. Called by the Driver app once its trip has opened or resumed
// (automatic start is unchanged). The driver identity comes from the verified token, never
// from the request body.
$auth = gt_require_verified_role(['driver']);
$driverId = (int)$auth['sub'];

$in = json_decode(file_get_contents('php://input'), true);
if (!is_array($in)) $in = $_POST;
$tripId = trim((string)($in['trip_id'] ?? ''));
$truckId = trim((string)($in['truck_id'] ?? ''));
$startMs = (int)($in['trip_started_at_ms'] ?? 0);

$now = gt_now_ts();
$startTs = intdiv($startMs, 1000);
// Only a trip that started recently can be linked (no back-dated links).
if ($tripId === '' || $truckId === '' || $startTs <= 0 || $startTs > $now + 600 || $startTs < $now - 36 * 3600) {
    echo json_encode(["success" => false, "linked" => false, "reason" => "invalid_request", "message" => "A recent trip id, truck and start time are required."]);
    exit;
}

try {
    if (!gt_assignment_tables_exist($conn)) {
        echo json_encode(["success" => true, "linked" => false, "reason" => "not_available"]);
        exit;
    }
    // A trip already recorded for another driver can never be linked by this driver.
    if ($conn->query("SHOW TABLES LIKE 'driver_trip_history'")->rowCount() > 0) {
        $q = $conn->prepare("SELECT driver_id FROM driver_trip_history WHERE trip_id = ?");
        $q->execute([$tripId]);
        $h = $q->fetch(PDO::FETCH_ASSOC);
        if ($h && (int)$h['driver_id'] > 0 && (int)$h['driver_id'] !== $driverId) {
            http_response_code(403);
            echo json_encode(["success" => false, "linked" => false, "reason" => "not_owner", "message" => "You can only link your own trips."]);
            exit;
        }
    }
    $r = gt_link_trip($conn, $driverId, $tripId, $truckId, $startTs, 'DRIVER_APP');
    echo json_encode(["success" => true] + $r);
} catch (PDOException $e) {
    error_log("link_assignment_trip.php: " . $e->getMessage());
    echo json_encode(["success" => false, "linked" => false, "reason" => "error", "message" => "The trip could not be linked."]);
}
