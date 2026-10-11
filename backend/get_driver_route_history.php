<?php
header("Content-Type: application/json");
require_once 'db_config.php';

$start_date = $_GET['start_date'] ?? null;
$end_date = $_GET['end_date'] ?? null;
$driver_id = $_GET['driver_id'] ?? null;
$truck_id = $_GET['truck_id'] ?? null;
$area = $_GET['area'] ?? null;
$status = $_GET['status'] ?? null;

try {
    $trips = [];
    $tableCheck = $conn->query("SHOW TABLES LIKE 'driver_trip_history'");
    if ($tableCheck->rowCount() > 0) {
        $where = ["h.total_distance_km >= 0.015"];
        $params = [];

        if (!empty($start_date)) {
            $where[] = "DATE(h.start_time) >= ?";
            $params[] = $start_date;
        }
        if (!empty($end_date)) {
            $where[] = "DATE(h.start_time) <= ?";
            $params[] = $end_date;
        }
        if (!empty($driver_id) && $driver_id !== 'all') {
            $where[] = "h.driver_id = ?";
            $params[] = intval($driver_id);
        }
        if (!empty($truck_id) && $truck_id !== 'all') {
            $where[] = "(h.truck_id = ? OR u.preferred_truck = ?)";
            $params[] = $truck_id;
            $params[] = $truck_id;
        }
        if (!empty($area) && $area !== 'all') {
            $where[] = "h.route_name LIKE ?";
            $params[] = "%" . $area . "%";
        }
        if (!empty($status) && $status !== 'all') {
            $where[] = "UPPER(h.route_status) = ?";
            $params[] = strtoupper($status);
        }

        $sql = "SELECT h.*, COALESCE(h.truck_id, u.preferred_truck, 'Truck not recorded') as truck_id FROM driver_trip_history h LEFT JOIN users u ON h.driver_id = u.user_id WHERE " . implode(" AND ", $where) . " ORDER BY h.start_time DESC";
        $stmt = $conn->prepare($sql);
        $stmt->execute($params);
        $trips = $stmt->fetchAll(PDO::FETCH_ASSOC);
    }

    // Also fetch driver_routes table if present
    $driverRoutesCheck = $conn->query("SHOW TABLES LIKE 'driver_routes'");
    if ($driverRoutesCheck->rowCount() > 0) {
        $drWhere = ["dr.total_distance_km >= 0.015"];
        $drParams = [];
        if (!empty($start_date)) {
            $drWhere[] = "dr.route_date >= ?";
            $drParams[] = $start_date;
        }
        if (!empty($end_date)) {
            $drWhere[] = "dr.route_date <= ?";
            $drParams[] = $end_date;
        }
        if (!empty($driver_id) && $driver_id !== 'all') {
            $drWhere[] = "dr.driver_id = ?";
            $drParams[] = intval($driver_id);
        }
        if (!empty($status) && $status !== 'all') {
            $drWhere[] = "UPPER(dr.route_status) = ?";
            $drParams[] = strtoupper($status);
        }

        $sqlDR = "SELECT dr.route_id as trip_id, dr.driver_id, dr.route_name, dr.route_date, dr.total_distance_km, dr.total_stops as detected_stops_count, dr.route_status, dr.created_at as start_time, COALESCE(u.preferred_truck, 'Truck not recorded') as truck_id, COALESCE(h.weight_kg, 5000.00) as weight_kg, COALESCE(h.weight_type, 'ESTIMATED') as weight_type FROM driver_routes dr LEFT JOIN users u ON dr.driver_id = u.user_id LEFT JOIN driver_trip_history h ON CAST(dr.route_id AS CHAR) = CAST(h.trip_id AS CHAR) WHERE " . implode(" AND ", $drWhere) . " ORDER BY dr.created_at DESC";
        $stmtDR = $conn->prepare($sqlDR);
        $stmtDR->execute($drParams);
        $legacyRoutes = $stmtDR->fetchAll(PDO::FETCH_ASSOC);

        // Merge without duplicates
        $existingIds = array_column($trips, 'trip_id');
        foreach ($legacyRoutes as $lr) {
            if (!in_array($lr['trip_id'], $existingIds)) {
                $trips[] = $lr;
            }
        }
    }

    echo json_encode([
        "success" => true,
        "count" => count($trips),
        "trips" => $trips
    ]);

} catch (PDOException $e) {
    echo json_encode(["success" => false, "message" => "Database Error: " . $e->getMessage()]);
}
?>
