<?php
/**
 * DB SCHEMA MIGRATION: Waste Collection Load History & Trip Weights
 * Adds weight, weight_type, full_time, and areas_visited columns to driver_trip_history.
 */

require_once 'db_config.php';

try {
    $tableCheck = $conn->query("SHOW TABLES LIKE 'driver_trip_history'");
    if ($tableCheck->rowCount() == 0) {
        // Create driver_trip_history if not existing
        $conn->exec("CREATE TABLE IF NOT EXISTS `driver_trip_history` (
          `trip_id` varchar(100) NOT NULL,
          `driver_id` int(11) NOT NULL,
          `driver_name` varchar(150) DEFAULT NULL,
          `truck_id` varchar(50) DEFAULT NULL,
          `route_name` varchar(150) DEFAULT NULL,
          `route_status` varchar(30) DEFAULT 'ACTIVE',
          `start_time` datetime DEFAULT NULL,
          `end_time` datetime DEFAULT NULL,
          `full_time` datetime DEFAULT NULL,
          `start_lat` decimal(10,7) DEFAULT NULL,
          `start_lng` decimal(10,7) DEFAULT NULL,
          `finish_lat` decimal(10,7) DEFAULT NULL,
          `finish_lng` decimal(10,7) DEFAULT NULL,
          `total_distance_km` decimal(10,2) DEFAULT 0.00,
          `moving_time_seconds` int(11) DEFAULT 0,
          `stopped_time_seconds` int(11) DEFAULT 0,
          `detected_stops_count` int(11) DEFAULT 0,
          `weight_kg` decimal(10,2) DEFAULT 5000.00,
          `weight_type` enum('ESTIMATED','MEASURED') DEFAULT 'ESTIMATED',
          `areas_visited` text DEFAULT NULL,
          `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (`trip_id`),
          KEY `idx_driver_id` (`driver_id`),
          KEY `idx_truck_id` (`truck_id`),
          KEY `idx_start_time` (`start_time`),
          KEY `idx_route_status` (`route_status`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;");
    } else {
        // Inspect columns and alter table safely
        $stmt = $conn->query("DESCRIBE driver_trip_history");
        $cols = array_column($stmt->fetchAll(PDO::FETCH_ASSOC), 'Field');

        if (!in_array('weight_kg', $cols)) {
            $conn->exec("ALTER TABLE `driver_trip_history` ADD COLUMN `weight_kg` decimal(10,2) DEFAULT 5000.00");
        }
        if (!in_array('weight_type', $cols)) {
            $conn->exec("ALTER TABLE `driver_trip_history` ADD COLUMN `weight_type` enum('ESTIMATED','MEASURED') DEFAULT 'ESTIMATED'");
        }
        if (!in_array('full_time', $cols)) {
            $conn->exec("ALTER TABLE `driver_trip_history` ADD COLUMN `full_time` datetime DEFAULT NULL");
        }
        if (!in_array('areas_visited', $cols)) {
            $conn->exec("ALTER TABLE `driver_trip_history` ADD COLUMN `areas_visited` text DEFAULT NULL");
        }
    }

    echo json_encode(["success" => true, "message" => "driver_trip_history schema updated successfully."]);
} catch (PDOException $e) {
    echo json_encode(["success" => false, "message" => "Database schema migration failed: " . $e->getMessage()]);
}
?>
