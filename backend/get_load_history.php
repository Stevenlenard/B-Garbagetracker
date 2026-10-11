<?php
/**
 * GET WASTE COLLECTION LOAD HISTORY & METRICS
 * Returns period summary, yearly monthly trend chart data (with 'No data' flag), and detailed trip records.
 */

header("Content-Type: application/json");
require_once 'db_config.php';

$start_date = $_GET['start_date'] ?? null;
$end_date = $_GET['end_date'] ?? null;
$truck_id = $_GET['truck_id'] ?? null;

// Resolve default date range if empty (Last 30 days)
if (empty($start_date)) {
    $start_date = date("Y-m-d", strtotime("-30 days"));
}
if (empty($end_date)) {
    $end_date = date("Y-m-d");
}

try {
    // 1. Calculate days selected
    $sTime = strtotime($start_date);
    $eTime = strtotime($end_date);
    $days_selected = max(1, (int)round(($eTime - $sTime) / 86400) + 1);
    $selected_year = (int)date("Y", $sTime);

    // 2. Query trip history table and driver_routes table
    $trips = [];
    $rawTrips = [];

    $tableCheck = $conn->query("SHOW TABLES LIKE 'driver_trip_history'");
    if ($tableCheck->rowCount() > 0) {
        $where = ["(UPPER(h.route_status) IN ('FULL', 'COMPLETED', 'FINISHED', 'ACTIVE') OR h.full_time IS NOT NULL)"];
        $params = [];

        if (!empty($start_date)) {
            $where[] = "DATE(COALESCE(h.full_time, h.start_time, h.created_at)) >= ?";
            $params[] = $start_date;
        }
        if (!empty($end_date)) {
            $where[] = "DATE(COALESCE(h.full_time, h.start_time, h.created_at)) <= ?";
            $params[] = $end_date;
        }
        if (!empty($truck_id) && $truck_id !== 'all' && $truck_id !== 'All Trucks') {
            $where[] = "h.truck_id = ?";
            $params[] = $truck_id;
        }

        $sql = "SELECT h.*, COALESCE(h.truck_id, u.preferred_truck, 'Truck not recorded') as truck_id
                FROM driver_trip_history h
                LEFT JOIN users u ON h.driver_id = u.user_id
                WHERE " . implode(" AND ", $where) . "
                ORDER BY COALESCE(h.full_time, h.start_time, h.created_at) DESC";
        $stmt = $conn->prepare($sql);
        $stmt->execute($params);
        $rawTrips = $stmt->fetchAll(PDO::FETCH_ASSOC);
    }

    // Also merge driver_routes table if present
    $driverRoutesCheck = $conn->query("SHOW TABLES LIKE 'driver_routes'");
    if ($driverRoutesCheck->rowCount() > 0) {
        $drWhere = ["(UPPER(dr.route_status) IN ('FULL', 'COMPLETED', 'FINISHED', 'ACTIVE') OR dr.total_distance_km >= 0.01)"];
        $drParams = [];
        if (!empty($start_date)) {
            $drWhere[] = "DATE(COALESCE(dr.route_date, dr.created_at)) >= ?";
            $drParams[] = $start_date;
        }
        if (!empty($end_date)) {
            $drWhere[] = "DATE(COALESCE(dr.route_date, dr.created_at)) <= ?";
            $drParams[] = $end_date;
        }

        $sqlDR = "SELECT dr.route_id as trip_id, dr.driver_id, COALESCE(dr.driver_name, u.name, 'Driver') as driver_name, dr.route_name, dr.route_date, dr.total_distance_km, dr.total_stops as detected_stops_count, dr.route_status, dr.created_at as start_time, COALESCE(u.preferred_truck, 'Truck not recorded') as truck_id FROM driver_routes dr LEFT JOIN users u ON dr.driver_id = u.user_id WHERE " . implode(" AND ", $drWhere) . " ORDER BY dr.created_at DESC";
        $stmtDR = $conn->prepare($sqlDR);
        $stmtDR->execute($drParams);
        $legacyRoutes = $stmtDR->fetchAll(PDO::FETCH_ASSOC);

        $existingIds = array_column($rawTrips, 'trip_id');
        foreach ($legacyRoutes as $lr) {
            if (!in_array($lr['trip_id'], $existingIds)) {
                $rawTrips[] = $lr;
            }
        }
    }

    // Deduplicate records by trip_id
    $seenTripIds = [];
    foreach ($rawTrips as $r) {
        $tid = $r['trip_id'];
        if (!in_array($tid, $seenTripIds)) {
            $seenTripIds[] = $tid;
            $trips[] = $r;
        }
    }

    // 3. Process period metrics
    $total_trips = count($trips);
    $total_weight_kg = 0.0;
    $estimated_trips_count = 0;
    $measured_trips_count = 0;

    $formatted_trips = [];
    $trip_index = $total_trips;

    foreach ($trips as $t) {
        $wKg = isset($t['weight_kg']) && is_numeric($t['weight_kg']) ? (float)$t['weight_kg'] : 5000.0;
        $wType = strtoupper($t['weight_type'] ?? 'ESTIMATED');
        if ($wType !== 'MEASURED') {
            $wType = 'ESTIMATED';
        }

        $total_weight_kg += $wKg;
        if ($wType === 'MEASURED') {
            $measured_trips_count++;
        } else {
            $estimated_trips_count++;
        }

        // FULL event timestamp & date
        $fullTimeRaw = $t['full_time'] ?? $t['end_time'] ?? $t['start_time'] ?? $t['created_at'];
        $fullTs = strtotime($fullTimeRaw);
        $fullDateStr = $fullTs ? date("M d, Y", $fullTs) : date("M d, Y");
        $fullTimeStr = $fullTs ? date("g:i A", $fullTs) : "Not recorded";

        // Start time & duration
        $startTimeRaw = $t['start_time'] ?? null;
        $durationStr = "Not recorded";
        if (!empty($startTimeRaw) && $startTimeRaw !== '0000-00-00 00:00:00') {
            $startTs = strtotime($startTimeRaw);
            if ($startTs && $fullTs && $fullTs > $startTs) {
                $diffSec = $fullTs - $startTs;
                // Subtract stopped time if recorded
                $stoppedSec = isset($t['stopped_time_seconds']) ? (int)$t['stopped_time_seconds'] : 0;
                $netSec = max(60, $diffSec - $stoppedSec);

                $hours = floor($netSec / 3600);
                $mins = floor(($netSec % 3600) / 60);
                if ($hours > 0) {
                    $durationStr = "{$hours}h {$mins}m";
                } else {
                    $durationStr = "{$mins} mins";
                }
            }
        }

        // Distance display
        $dist = isset($t['total_distance_km']) ? (float)$t['total_distance_km'] : 0.0;
        $distStr = $dist > 0.01 ? number_format($dist, 1) . " km" : "Unavailable";

        // Areas visited
        $areasStr = $t['areas_visited'] ?? $t['route_name'] ?? "Not recorded";
        if (empty($areasStr) || $areasStr === "Collection Route") {
            $areasStr = "Not recorded";
        }

        $formatted_trips[] = [
            "trip_id" => (string)$t['trip_id'],
            "trip_number" => "Trip " . $trip_index,
            "driver_id" => $t['driver_id'] ?? 0,
            "driver_name" => $t['driver_name'] ?? "Driver",
            "truck_id" => $t['truck_id'] ?? "Truck not recorded",
            "full_time" => $fullTimeStr,
            "full_date" => $fullDateStr,
            "raw_full_time" => $fullTimeRaw,
            "start_time" => $startTimeRaw,
            "duration" => $durationStr,
            "areas_visited" => $areasStr,
            "total_distance_km" => $dist,
            "distance_display" => $distStr,
            "weight_kg" => $wKg,
            "weight_tons" => round($wKg / 1000.0, 2),
            "weight_type" => $wType,
            "is_measured" => ($wType === 'MEASURED')
        ];

        $trip_index--;
    }

    $total_weight_tons = round($total_weight_kg / 1000.0, 2);

    // 4. Yearly Monthly Bar Chart Data for $selected_year (Jan..Dec)
    $months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    $yearly_chart_data = [];

    // Query all trips in the selected year
    $yearlyTrips = [];
    if ($tableCheck->rowCount() > 0) {
        $stmtYear = $conn->prepare("
            SELECT COALESCE(full_time, start_time, created_at) as event_date, weight_kg, weight_type
            FROM driver_trip_history
            WHERE YEAR(COALESCE(full_time, start_time, created_at)) = ?
              AND (UPPER(route_status) IN ('FULL', 'COMPLETED', 'FINISHED') OR full_time IS NOT NULL)
        ");
        $stmtYear->execute([$selected_year]);
        $yearlyTrips = $stmtYear->fetchAll(PDO::FETCH_ASSOC);
    }

    // Group by month 1..12
    $monthlyTotals = array_fill(1, 12, 0.0);
    $monthlyCounts = array_fill(1, 12, 0);

    foreach ($yearlyTrips as $yt) {
        $m = (int)date("n", strtotime($yt['event_date']));
        $w = isset($yt['weight_kg']) && is_numeric($yt['weight_kg']) ? (float)$yt['weight_kg'] : 5000.0;
        $monthlyTotals[$m] += $w;
        $monthlyCounts[$m]++;
    }

    for ($m = 1; $m <= 12; $m++) {
        $hasData = ($monthlyCounts[$m] > 0);
        $tons = $hasData ? round($monthlyTotals[$m] / 1000.0, 2) : 0.0;

        $yearly_chart_data[] = [
            "month_number" => $m,
            "month_label" => $months[$m - 1],
            "has_data" => $hasData,
            "trip_count" => $monthlyCounts[$m],
            "total_weight_kg" => $monthlyTotals[$m],
            "total_weight_tons" => $tons,
            "display_label" => $hasData ? "{$tons} tons" : "No data"
        ];
    }

    echo json_encode([
        "success" => true,
        "selected_period" => [
            "start_date" => $start_date,
            "end_date" => $end_date,
            "days_selected" => $days_selected,
            "selected_year" => $selected_year
        ],
        "summary" => [
            "total_trips" => $total_trips,
            "total_weight_kg" => $total_weight_kg,
            "total_weight_tons" => $total_weight_tons,
            "estimated_trips_count" => $estimated_trips_count,
            "measured_trips_count" => $measured_trips_count,
            "is_all_estimated" => ($measured_trips_count === 0 && $total_trips > 0),
            "is_all_measured" => ($estimated_trips_count === 0 && $total_trips > 0)
        ],
        "yearly_chart" => [
            "year" => $selected_year,
            "months" => $yearly_chart_data
        ],
        "trips" => $formatted_trips
    ]);

} catch (PDOException $e) {
    echo json_encode(["success" => false, "message" => "Database Error: " . $e->getMessage()]);
}
?>
