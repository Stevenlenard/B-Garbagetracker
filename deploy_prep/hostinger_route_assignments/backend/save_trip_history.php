<?php
header("Content-Type: application/json");
require_once 'db_config.php';

/**
 * Merges an incoming trip-history write with the stored row.
 *
 * FULL finalizes the collection (distance, end point, FULL time, estimated load and
 * visited areas). Later writes - the COMPLETED unloading confirmation, a retry, or an
 * older app that keeps accumulating distance - must not change those values or move
 * the status backwards. Pure function: no database access.
 *
 * @param array|null $existing stored row (assoc) or null when the trip is new
 * @param array      $in       incoming values
 * @return array values to store
 */
function gt_merge_trip_history($existing, array $in)
{
    $terminal = ['COMPLETED', 'FINISHED', 'INTERRUPTED'];
    $out = $in;
    if (!is_array($existing)) {
        return $out;
    }

    $old = strtoupper((string)($existing['route_status'] ?? ''));
    $new = strtoupper((string)($in['route_status'] ?? ''));
    $oldFinal = ($old === 'FULL' || in_array($old, $terminal, true));

    // Status never moves backwards (FULL/COMPLETED -> ACTIVE).
    if ($oldFinal && !in_array($new, $terminal, true) && $new !== 'FULL') {
        $out['route_status'] = $old;
    }
    if (in_array($old, $terminal, true) && $new === 'FULL') {
        $out['route_status'] = $old;
    }

    if ($oldFinal) {
        // The finalized collection is frozen.
        foreach (['total_distance_km', 'finish_lat', 'finish_lng', 'full_time', 'weight_kg', 'weight_type', 'areas_visited'] as $k) {
            if (array_key_exists($k, $existing) && $existing[$k] !== null && $existing[$k] !== '') {
                $out[$k] = $existing[$k];
            }
        }
        // A generic route name must not replace the visited-area name stored at FULL.
        $oldName = (string)($existing['route_name'] ?? '');
        if ($oldName !== '' && $oldName !== 'Collection Route' && ($in['route_name'] ?? '') === 'Collection Route') {
            $out['route_name'] = $oldName;
        }
    }

    // Never wipe measured values with the zero defaults of a partial write.
    foreach (['moving_time_seconds', 'stopped_time_seconds', 'detected_stops_count'] as $k) {
        if ((int)($in[$k] ?? 0) === 0 && isset($existing[$k])) {
            $out[$k] = $existing[$k];
        }
    }
    if (($out['end_time'] ?? null) === null && !empty($existing['end_time'])) {
        $out['end_time'] = $existing['end_time'];
    }
    return $out;
}

/**
 * Links this trip to the driver's route assignment and records its latest status.
 *
 * Runs ONLY for a request carrying a VERIFIED driver token whose subject is the trip's driver.
 * Token-less (legacy) saves keep working exactly as before and never write assignment data,
 * so this adds no unauthenticated write path. Skipped silently when the assignment tables do
 * not exist yet. Returns the link result, or null when skipped.
 */
function gt_trip_history_assignment_link($conn, $data, $tripId, $driverId, $truckId, $routeStatus, $existing)
{
    try {
        if (!function_exists('gt_verify_token')) require_once 'auth_token.php';
        $auth = gt_verify_token(gt_request_token());
        if ($auth === null || $auth['role'] !== 'driver' || (string)$auth['sub'] !== (string)$driverId || (int)$driverId <= 0) {
            return null;
        }
        require_once 'assignment_lib.php';
        if (!gt_assignment_tables_exist($conn)) return null;
        if (is_array($existing) && !empty($existing['driver_id']) && (int)$existing['driver_id'] !== (int)$driverId) {
            return null; // the stored trip belongs to another driver
        }
        // Trip start: the app sends local (Asia/Manila) ISO time without an offset; a stored
        // row's start_time was written in the server's own time zone.
        $startTs = null;
        if (!empty($data->start_time)) {
            try {
                $startTs = (new DateTimeImmutable((string)$data->start_time, new DateTimeZone(GT_ASSIGNMENT_TZ)))->getTimestamp();
            } catch (Exception $e) {
                $startTs = null;
            }
        }
        if ($startTs === null && is_array($existing) && !empty($existing['start_time'])) {
            $t = strtotime((string)$existing['start_time']);
            $startTs = $t === false ? null : $t;
        }
        if ($startTs === null) return null;
        return gt_link_trip($conn, (int)$driverId, $tripId, (string)$truckId, $startTs, 'TRIP_HISTORY', $routeStatus);
    } catch (Throwable $e) {
        error_log("save_trip_history.php assignment link skipped: " . $e->getMessage());
        return null;
    }
}

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
    $full_time = isset($data->full_time) ? date("Y-m-d H:i:s", strtotime($data->full_time)) : null;
    $weight_kg = isset($data->weight_kg) && is_numeric($data->weight_kg) ? floatval($data->weight_kg) : null;
    $weight_type = isset($data->weight_type) ? strtoupper((string)$data->weight_type) : null;
    if ($weight_type !== null && !in_array($weight_type, ['ESTIMATED', 'MEASURED'], true)) {
        $weight_type = 'ESTIMATED';
    }
    $areas_visited = isset($data->areas_visited) ? (string)$data->areas_visited : null;

    // Check if table exists
    $tableCheck = $conn->query("SHOW TABLES LIKE 'driver_trip_history'");
    if ($tableCheck->rowCount() > 0) {
        // Columns added by update_load_history_schema.php may not exist on older databases.
        $cols = array_column($conn->query("DESCRIBE driver_trip_history")->fetchAll(PDO::FETCH_ASSOC), 'Field');
        $has = function ($c) use ($cols) { return in_array($c, $cols, true); };

        $sel = $conn->prepare("SELECT * FROM driver_trip_history WHERE trip_id = ?");
        $sel->execute([$trip_id]);
        $existing = $sel->fetch(PDO::FETCH_ASSOC);

        $values = gt_merge_trip_history($existing ?: null, [
            'driver_id' => $driver_id,
            'driver_name' => $driver_name,
            'truck_id' => $truck_id,
            'route_name' => $route_name,
            'route_status' => $route_status,
            'start_time' => $start_time,
            'end_time' => $end_time,
            'start_lat' => $start_lat,
            'start_lng' => $start_lng,
            'finish_lat' => $finish_lat,
            'finish_lng' => $finish_lng,
            'total_distance_km' => $total_distance_km,
            'moving_time_seconds' => $moving_time_seconds,
            'stopped_time_seconds' => $stopped_time_seconds,
            'detected_stops_count' => $detected_stops_count,
            'full_time' => $full_time,
            'weight_kg' => $weight_kg,
            'weight_type' => $weight_type,
            'areas_visited' => $areas_visited,
        ]);
        $route_status = strtoupper((string)$values['route_status']);

        $optional = ['full_time', 'weight_kg', 'weight_type', 'areas_visited'];
        $writeCols = ['driver_id', 'driver_name', 'truck_id', 'route_name', 'route_status', 'end_time',
                      'finish_lat', 'finish_lng', 'total_distance_km', 'moving_time_seconds',
                      'stopped_time_seconds', 'detected_stops_count'];
        foreach ($optional as $c) {
            if ($has($c) && $values[$c] !== null) $writeCols[] = $c;
        }

        $upsert = function () use ($conn, $trip_id, $values, $writeCols) {
            $sets = [];
            $params = [];
            foreach ($writeCols as $c) {
                if ($c === 'driver_id' || $c === 'end_time' || $c === 'finish_lat' || $c === 'finish_lng') {
                    // keep a stored value when the write has none
                    $sets[] = "$c = COALESCE(?, $c)";
                } else {
                    $sets[] = "$c = ?";
                }
                $params[] = $values[$c];
            }
            $params[] = $trip_id;
            $conn->prepare("UPDATE driver_trip_history SET " . implode(', ', $sets) . " WHERE trip_id = ?")->execute($params);
        };

        if ($existing) {
            $upsert();
        } else {
            $insCols = array_merge(['trip_id', 'start_time', 'start_lat', 'start_lng'], $writeCols);
            $ph = implode(', ', array_fill(0, count($insCols), '?'));
            $insParams = [$trip_id, $values['start_time'], $values['start_lat'], $values['start_lng']];
            foreach ($writeCols as $c) $insParams[] = $values[$c];
            try {
                $conn->prepare("INSERT INTO driver_trip_history (" . implode(', ', $insCols) . ") VALUES ($ph)")->execute($insParams);
            } catch (PDOException $dup) {
                // A concurrent request created the row first: merge into it instead.
                if ($dup->getCode() !== '23000') throw $dup;
                $upsert();
            }
        }

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

        // No automatic deletion: completed trips are kept for Analytics, Route History and
        // route assignments. (The former 200-trips-per-month purge deleted history rows,
        // their GPS points and events.)
    }

    // Route assignment link (optional feature, never blocks the history save).
    $assignmentLink = gt_trip_history_assignment_link($conn, $data, $trip_id, $driver_id, $truck_id, $route_status, $existing ?? null);

    echo json_encode(array_merge(
        ["success" => true, "message" => "Trip history saved successfully"],
        $assignmentLink === null ? [] : ["assignment_link" => $assignmentLink]
    ));
} catch (PDOException $e) {
    error_log("save_trip_history.php: " . $e->getMessage());
    echo json_encode(["success" => false, "message" => "The trip history could not be saved."]);
}
?>
