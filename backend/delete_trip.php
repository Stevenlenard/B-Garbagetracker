<?php
header("Content-Type: application/json");
header("Access-Control-Allow-Origin: *");
header("Access-Control-Allow-Headers: Content-Type");
header("Access-Control-Allow-Methods: POST, GET, OPTIONS");

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(200);
    exit;
}

require_once 'db_config.php';

$rawInput = file_get_contents("php://input");
$data = json_decode($rawInput, true);

$trip_id = $data['trip_id'] ?? $_GET['trip_id'] ?? $_POST['trip_id'] ?? null;

if (empty($trip_id)) {
    echo json_encode(["success" => false, "message" => "Trip ID is required."]);
    exit;
}

try {
    // Delete from driver_trip_gps_points
    $stmtPoints = $conn->prepare("DELETE FROM driver_trip_gps_points WHERE trip_id = ?");
    $stmtPoints->execute([$trip_id]);

    // Delete from driver_trip_events
    $stmtEvents = $conn->prepare("DELETE FROM driver_trip_events WHERE trip_id = ?");
    $stmtEvents->execute([$trip_id]);

    // Delete from driver_trip_history
    $stmtHistory = $conn->prepare("DELETE FROM driver_trip_history WHERE trip_id = ?");
    $stmtHistory->execute([$trip_id]);

    // Delete from driver_routes
    $stmtRoutes = $conn->prepare("DELETE FROM driver_routes WHERE route_id = ?");
    $stmtRoutes->execute([$trip_id]);

    echo json_encode([
        "success" => true,
        "message" => "Trip record successfully deleted.",
        "trip_id" => $trip_id
    ]);
} catch (PDOException $e) {
    echo json_encode([
        "success" => false,
        "message" => "Database Error: " . $e->getMessage()
    ]);
}
?>
