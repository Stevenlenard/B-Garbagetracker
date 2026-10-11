<?php
header("Content-Type: application/json");
require_once 'db_config.php';

$trip_id = $_GET['trip_id'] ?? null;

if (empty($trip_id)) {
    echo json_encode(["success" => false, "message" => "Missing required parameter trip_id"]);
    exit;
}

try {
    $trip = null;
    $points = [];
    $events = [];

    // Query trip metadata
    $historyCheck = $conn->query("SHOW TABLES LIKE 'driver_trip_history'");
    if ($historyCheck->rowCount() > 0) {
        $stmt = $conn->prepare("SELECT h.*, COALESCE(h.truck_id, u.preferred_truck, 'Truck not recorded') as truck_id FROM driver_trip_history h LEFT JOIN users u ON h.driver_id = u.user_id WHERE h.trip_id = ?");
        $stmt->execute([$trip_id]);
        $trip = $stmt->fetch(PDO::FETCH_ASSOC);
    }

    if (!$trip) {
        $routesCheck = $conn->query("SHOW TABLES LIKE 'driver_routes'");
        if ($routesCheck->rowCount() > 0) {
            $stmt = $conn->prepare("SELECT dr.route_id as trip_id, dr.driver_id, dr.route_name, dr.route_date, dr.total_distance_km, dr.total_stops as detected_stops_count, dr.route_status, dr.created_at as start_time, COALESCE(u.preferred_truck, 'Truck not recorded') as truck_id FROM driver_routes dr LEFT JOIN users u ON dr.driver_id = u.user_id WHERE dr.route_id = ?");
            $stmt->execute([$trip_id]);
            $trip = $stmt->fetch(PDO::FETCH_ASSOC);
        }
    }

    // Query points
    $pointsCheck = $conn->query("SHOW TABLES LIKE 'driver_trip_gps_points'");
    if ($pointsCheck->rowCount() > 0) {
        $pStmt = $conn->prepare("SELECT point_id, trip_id, driver_id, truck_id, latitude, longitude, speed_kmh, heading, accuracy_m, status, recorded_at FROM driver_trip_gps_points WHERE trip_id = ? ORDER BY recorded_at ASC");
        $pStmt->execute([$trip_id]);
        $points = $pStmt->fetchAll(PDO::FETCH_ASSOC);
    }

    // Query events
    $eventsCheck = $conn->query("SHOW TABLES LIKE 'driver_trip_events'");
    if ($eventsCheck->rowCount() > 0) {
        $eStmt = $conn->prepare("SELECT event_id, trip_id, driver_id, event_type, description, latitude, longitude, recorded_at FROM driver_trip_events WHERE trip_id = ? ORDER BY recorded_at ASC");
        $eStmt->execute([$trip_id]);
        $events = $eStmt->fetchAll(PDO::FETCH_ASSOC);
    }

    echo json_encode([
        "success" => true,
        "trip" => $trip,
        "points_count" => count($points),
        "points" => $points,
        "events_count" => count($events),
        "events" => $events
    ]);

} catch (PDOException $e) {
    echo json_encode(["success" => false, "message" => "Database Error: " . $e->getMessage()]);
}
?>
