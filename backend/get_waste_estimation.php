<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';
require_once 'waste_estimation_lib.php';

// Admin only. Read-only: the configured parameters of the area-based waste ESTIMATION (Objective 2.2).
// These are estimates of waste generated; they are never part of Load History or the capacity-equivalent total.
gt_guard(['admin']);

try {
    if (!gt_we_tables_exist($conn)) {
        echo json_encode(["success" => true, "available" => false, "settings" => null, "areas" => []]);
        exit;
    }
    $settings = $conn->query("SELECT * FROM waste_estimation_settings WHERE id = 1")->fetch(PDO::FETCH_ASSOC) ?: null;
    $areas = $conn->query("SELECT * FROM waste_estimation_areas ORDER BY area_name")->fetchAll(PDO::FETCH_ASSOC);
    echo json_encode(["success" => true, "available" => true, "settings" => $settings, "areas" => $areas]);
} catch (Throwable $e) {
    error_log('[get_waste_estimation] ' . $e->getMessage());
    http_response_code(500);
    echo json_encode(["success" => false, "message" => "Could not load the waste estimation settings."]);
}
