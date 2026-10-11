<?php
header("Content-Type: application/json");
require_once 'db_config.php';

$data = json_decode(file_get_contents("php://input"));

if (!$data || empty($data->trip_id)) {
    echo json_encode(["success" => false, "message" => "Invalid or missing trip_id"]);
    exit;
}

// 1. ISOLATE MANUAL SIMULATION WRITES
if (!empty($data->is_simulation) || !empty($data->isSimulation)) {
    echo json_encode([
        "success" => true,
        "message" => "Simulation record isolated; skipped writing to production historical dataset."
    ]);
    exit;
}

try {
    $trip_id = $data->trip_id;
    $driver_id = isset($data->driver_id) ? intval($data->driver_id) : 0;
    $driver_name = $data->driver_name ?? "Driver";
    $truck_id = $data->truck_id ?? "Truck not recorded";
    $route_name = $data->route_name ?? "Collection Route";
    $route_status = strtoupper($data->route_status ?? "ACTIVE");
    $start_time = isset($data->start_time) ? date("Y-m-d H:i:s", strtotime($data->start_time)) : date("Y-m-d H:i:s");
    $end_time = isset($data->end_time) ? date("Y-m-d H:i:s", strtotime($data->end_time)) : null;
    $start_lat = isset($data->start_lat) ? floatval($data->start_lat) : null;
    $start_lng = isset($data->start_lng) ? floatval($data->start_lng) : null;
    $finish_lat = isset($data->finish_lat) ? floatval($data->finish_lat) : null;
    $finish_lng = isset($data->finish_lng) ? floatval($data->finish_lng) : null;
    $total_distance_km = isset($data->total_distance_km) ? floatval($data->total_distance_km) : 0.00;
    $moving_time_seconds = isset($data->moving_time_seconds) ? intval($data->moving_time_seconds) : 0;
    $stopped_time_seconds = isset($data->stopped_time_seconds) ? intval($data->stopped_time_seconds) : 0;
    $detected_stops_count = isset($data->detected_stops_count) ? intval($data->detected_stops_count) : 0;

    // Check if table exists
    $tableCheck = $conn->query("SHOW TABLES LIKE 'driver_trip_history'");
    if ($tableCheck->rowCount() > 0) {
        $stmt = $conn->prepare("
            INSERT INTO driver_trip_history (
                trip_id, driver_id, driver_name, truck_id, route_name, route_status,
                start_time, end_time, start_lat, start_lng, finish_lat, finish_lng,
                total_distance_km, moving_time_seconds, stopped_time_seconds, detected_stops_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE
                driver_name = VALUES(driver_name),
                truck_id = VALUES(truck_id),
                route_name = VALUES(route_name),
                route_status = VALUES(route_status),
                end_time = COALESCE(VALUES(end_time), end_time),
                finish_lat = COALESCE(VALUES(finish_lat), finish_lat),
                finish_lng = COALESCE(VALUES(finish_lng), finish_lng),
                total_distance_km = VALUES(total_distance_km),
                moving_time_seconds = VALUES(moving_time_seconds),
                stopped_time_seconds = VALUES(stopped_time_seconds),
                detected_stops_count = VALUES(detected_stops_count)
        ");
        $stmt->execute([
            $trip_id, $driver_id, $driver_name, $truck_id, $route_name, $route_status,
            $start_time, $end_time, $start_lat, $start_lng, $finish_lat, $finish_lng,
            $total_distance_km, $moving_time_seconds, $stopped_time_seconds, $detected_stops_count
        ]);

        // Insert Points if provided
        if (!empty($data->route_points) && is_array($data->route_points)) {
            $pointsCheck = $conn->query("SHOW TABLES LIKE 'driver_trip_gps_points'");
            if ($pointsCheck->rowCount() > 0) {
                $pointStmt = $conn->prepare("
                    INSERT INTO driver_trip_gps_points (
                        trip_id, driver_id, truck_id, latitude, longitude, speed_kmh, heading, accuracy_m, status, recorded_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ");
                foreach ($data->route_points as $pt) {
                    $lat = floatval($pt->latitude ?? $pt->lat ?? 0);
                    $lng = floatval($pt->longitude ?? $pt->lng ?? 0);
                    if ($lat == 0 && $lng == 0) continue;
                    $spd = floatval($pt->speed_kmh ?? $pt->speed ?? 0);
                    $hdg = floatval($pt->heading ?? 0);
                    $acc = floatval($pt->accuracy_m ?? $pt->accuracy ?? 0);
                    $st = $pt->status ?? "ACTIVE";
                    $recAt = isset($pt->recorded_at) ? date("Y-m-d H:i:s", strtotime($pt->recorded_at)) : (isset($pt->timestamp) ? date("Y-m-d H:i:s", intval($pt->timestamp / 1000)) : date("Y-m-d H:i:s"));

                    $pointStmt->execute([$trip_id, $driver_id, $truck_id, $lat, $lng, $spd, $hdg, $acc, $st, $recAt]);
                }
            }
        }

        // Insert Events if provided
        if (!empty($data->events) && is_array($data->events)) {
            $eventsCheck = $conn->query("SHOW TABLES LIKE 'driver_trip_events'");
            if ($eventsCheck->rowCount() > 0) {
                $evtStmt = $conn->prepare("
                    INSERT INTO driver_trip_events (trip_id, driver_id, event_type, description, latitude, longitude, recorded_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                ");
                foreach ($data->events as $evt) {
                    $eType = $evt->event_type ?? $evt->status ?? "ACTIVE";
                    $desc = $evt->description ?? "";
                    $eLat = isset($evt->latitude) ? floatval($evt->latitude) : null;
                    $eLng = isset($evt->longitude) ? floatval($evt->longitude) : null;
                    $eRecAt = isset($evt->recorded_at) ? date("Y-m-d H:i:s", strtotime($evt->recorded_at)) : date("Y-m-d H:i:s");

                    $evtStmt->execute([$trip_id, $driver_id, $eType, $desc, $eLat, $eLng, $eRecAt]);
                }
            }
        }

        // 2. BACKEND RETENTION AUTHORITY (Max 200 Finalized Real Movement Trips per Manila Calendar Month)
        if (in_array($route_status, ['COMPLETED', 'FINISHED', 'INTERRUPTED'])) {
            $conn->query("SELECT GET_LOCK('driver_trip_retention_lock', 10)");
            try {
                $monthKey = date("Y-m", strtotime($start_time));
                $purgeStmt = $conn->prepare("
                    SELECT trip_id FROM driver_trip_history
                    WHERE DATE_FORMAT(start_time, '%Y-%m') = ?
                      AND UPPER(route_status) IN ('COMPLETED', 'FINISHED', 'INTERRUPTED')
                      AND total_distance_km >= 0.015
                    ORDER BY start_time DESC, trip_id DESC
                    LIMIT 18446744073709551615 OFFSET 200
                ");
                $purgeStmt->execute([$monthKey]);
                $oldTripsToPurge = $purgeStmt->fetchAll(PDO::FETCH_COLUMN);

                if (!empty($oldTripsToPurge)) {
                    $inClause = implode(',', array_fill(0, count($oldTripsToPurge), '?'));

                    // Purge exclusively owned points & events
                    $delPoints = $conn->prepare("DELETE FROM driver_trip_gps_points WHERE trip_id IN ($inClause)");
                    $delPoints->execute($oldTripsToPurge);

                    $delEvents = $conn->prepare("DELETE FROM driver_trip_events WHERE trip_id IN ($inClause)");
                    $delEvents->execute($oldTripsToPurge);

                    // Purge finalized trips exceeding 200 limit
                    $delHistory = $conn->prepare("DELETE FROM driver_trip_history WHERE trip_id IN ($inClause)");
                    $delHistory->execute($oldTripsToPurge);
                }
            } finally {
                $conn->query("SELECT RELEASE_LOCK('driver_trip_retention_lock')");
            }
        }
    }

    echo json_encode(["success" => true, "message" => "Trip history saved successfully"]);
} catch (PDOException $e) {
    echo json_encode(["success" => false, "message" => "Database Error: " . $e->getMessage()]);
}
?>
