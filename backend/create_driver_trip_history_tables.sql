-- Driver Trip History & GPS Route Logging Migration
-- This file defines durable SQL storage for driver route activities.
-- DO NOT RUN AGAINST PRODUCTION/HOSTINGER WITHOUT REVIEW.

CREATE TABLE IF NOT EXISTS `driver_trip_history` (
  `trip_id` varchar(100) NOT NULL,
  `driver_id` int(11) NOT NULL,
  `driver_name` varchar(150) DEFAULT NULL,
  `truck_id` varchar(50) DEFAULT NULL,
  `route_name` varchar(150) DEFAULT NULL,
  `route_status` varchar(30) DEFAULT 'ACTIVE',
  `start_time` datetime DEFAULT NULL,
  `end_time` datetime DEFAULT NULL,
  `start_lat` decimal(10,7) DEFAULT NULL,
  `start_lng` decimal(10,7) DEFAULT NULL,
  `finish_lat` decimal(10,7) DEFAULT NULL,
  `finish_lng` decimal(10,7) DEFAULT NULL,
  `total_distance_km` decimal(10,2) DEFAULT 0.00,
  `moving_time_seconds` int(11) DEFAULT 0,
  `stopped_time_seconds` int(11) DEFAULT 0,
  `detected_stops_count` int(11) DEFAULT 0,
  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`trip_id`),
  KEY `idx_driver_id` (`driver_id`),
  KEY `idx_truck_id` (`truck_id`),
  KEY `idx_start_time` (`start_time`),
  KEY `idx_route_status` (`route_status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS `driver_trip_gps_points` (
  `point_id` bigint(20) NOT NULL AUTO_INCREMENT,
  `trip_id` varchar(100) NOT NULL,
  `driver_id` int(11) DEFAULT NULL,
  `truck_id` varchar(50) DEFAULT NULL,
  `latitude` decimal(10,7) NOT NULL,
  `longitude` decimal(10,7) NOT NULL,
  `speed_kmh` float DEFAULT 0,
  `heading` float DEFAULT 0,
  `accuracy_m` float DEFAULT 0,
  `status` varchar(30) DEFAULT 'ACTIVE',
  `recorded_at` datetime NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`point_id`),
  KEY `idx_trip_id` (`trip_id`),
  KEY `idx_recorded_at` (`recorded_at`),
  CONSTRAINT `fk_trip_gps_points` FOREIGN KEY (`trip_id`) REFERENCES `driver_trip_history` (`trip_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS `driver_trip_events` (
  `event_id` bigint(20) NOT NULL AUTO_INCREMENT,
  `trip_id` varchar(100) NOT NULL,
  `driver_id` int(11) DEFAULT NULL,
  `event_type` varchar(50) NOT NULL,
  `description` text DEFAULT NULL,
  `latitude` decimal(10,7) DEFAULT NULL,
  `longitude` decimal(10,7) DEFAULT NULL,
  `recorded_at` datetime NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`event_id`),
  KEY `idx_event_trip_id` (`trip_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;
