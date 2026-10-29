<?php
/**
 * AUTOMATICALLY GENERATED LOAD SUMMARY & YEARLY TREND (GEMINI AI INTEGRATED)
 * Evaluates saved trip data and generates a concise, accurate operational summary.
 */

header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';
$gtAuth = gt_guard(['admin']); // Bundle 1: login + role required

require_once 'ai_config_loader.php';
$ai_cfg = gt_ai_config(); // AI disabled unless configured outside the web root

$start_date = $_GET['start_date'] ?? date("Y-m-d", strtotime("-30 days"));
$end_date = $_GET['end_date'] ?? date("Y-m-d");
$truck_id = $_GET['truck_id'] ?? null;

try {
    // Older servers lack full_time / weight_kg / weight_type (update_load_history_schema.php):
    // build the SQL from the columns that exist. A missing weight is an ESTIMATED 5,000 kg
    // load (same rule as Load History), never a recorded zero.
    $hCols = [];
    foreach ($conn->query("DESCRIBE driver_trip_history")->fetchAll(PDO::FETCH_ASSOC) as $c) $hCols[] = $c['Field'] ?? '';
    $hasFull = in_array('full_time', $hCols, true);
    $hasWeight = in_array('weight_kg', $hCols, true);
    $hasType = in_array('weight_type', $hCols, true);
    $when = $hasFull ? "COALESCE(h.full_time, h.start_time, h.created_at)" : "COALESCE(h.start_time, h.created_at)";

    // 1. Gather trip statistics
    $where = [$hasFull
        ? "(UPPER(h.route_status) IN ('FULL', 'COMPLETED', 'FINISHED') OR h.full_time IS NOT NULL)"
        : "UPPER(h.route_status) IN ('FULL', 'COMPLETED', 'FINISHED')"];
    $params = [];

    if (!empty($start_date)) {
        $where[] = "DATE($when) >= ?";
        $params[] = $start_date;
    }
    if (!empty($end_date)) {
        $where[] = "DATE($when) <= ?";
        $params[] = $end_date;
    }
    if (!empty($truck_id) && $truck_id !== 'all' && $truck_id !== 'All Trucks') {
        $where[] = "h.truck_id = ?";
        $params[] = $truck_id;
    }

    $weightSum = $hasWeight ? "COALESCE(SUM(COALESCE(h.weight_kg, 5000)), 0)" : "COUNT(*) * 5000";
    $measured = ($hasWeight && $hasType) ? "SUM(CASE WHEN h.weight_type = 'MEASURED' AND h.weight_kg IS NOT NULL THEN 1 ELSE 0 END)" : "0";
    $stmt = $conn->prepare("
        SELECT
            COUNT(*) as total_trips,
            $weightSum as total_weight_kg,
            $measured as measured_count
        FROM driver_trip_history h
        WHERE " . implode(" AND ", $where)
    );
    $stmt->execute($params);
    $stats = $stmt->fetch(PDO::FETCH_ASSOC);

    $total_trips = (int)($stats['total_trips'] ?? 0);
    $total_weight_kg = (float)($stats['total_weight_kg'] ?? 0.0);
    $total_weight_tons = round($total_weight_kg / 1000.0, 1);
    $measured_count = (int)($stats['measured_count'] ?? 0);
    $estimated_count = max(0, $total_trips - $measured_count);

    // 2. Count active months with data in current year
    $selected_year = (int)date("Y", strtotime($start_date));
    $yWhen = $hasFull ? "COALESCE(full_time, start_time, created_at)" : "COALESCE(start_time, created_at)";
    $yFinal = $hasFull
        ? "(UPPER(route_status) IN ('FULL', 'COMPLETED', 'FINISHED') OR full_time IS NOT NULL)"
        : "UPPER(route_status) IN ('FULL', 'COMPLETED', 'FINISHED')";
    $stmtYear = $conn->prepare("
        SELECT COUNT(DISTINCT MONTH($yWhen)) as active_months
        FROM driver_trip_history
        WHERE YEAR($yWhen) = ?
          AND $yFinal
    ");
    $stmtYear->execute([$selected_year]);
    $active_months = (int)($stmtYear->fetchColumn() ?? 0);

    // Construct Rule-Based Fallback Summary
    $weightDesc = ($measured_count == 0)
        ? "No measured weights: at the default 5 tons per trip, ESTIMATED waste is {$total_weight_tons} tons."
        : "Recorded waste total is {$total_weight_tons} tons ({$measured_count} measured, {$estimated_count} estimated).";

    $trendDesc = ($active_months < 3)
        ? "More complete months are needed to identify a yearly increase."
        : "Yearly collection trend shows activity across {$active_months} months.";

    $fallback_summary = "{$total_trips} FULL trips recorded. {$weightDesc} {$trendDesc}";

    // 3. Attempt Gemini API Call if Key Present
    $ai_summary = null;
    if ($ai_cfg['enabled']) {
        $promptPayload = [
            "period" => "{$start_date} to {$end_date}",
            "total_full_trips" => $total_trips,
            "total_waste_tons" => $total_weight_tons,
            "measured_trips" => $measured_count,
            "estimated_trips" => $estimated_count,
            "active_months_in_year" => $active_months
        ];
        $prompt = "You are an AI Municipal Operations Auditor for GarbageTracker. " .
                  "Summarize the following waste load collection data: " . json_encode($promptPayload) . ". " .
                  "Provide a concise 2-sentence summary explaining the recorded trip count and waste volume, whether data suggests an increase or decrease, and any limits (such as default estimates or incomplete months). Never claim an increase/decrease unless active_months_in_year >= 3. Do not invent scale weights.";
        $ai_summary = gt_ai_generate($ai_cfg, $prompt, ['temperature' => 0.2, 'maxOutputTokens' => 150], 5);
    }

    if (empty($ai_summary)) {
        $ai_summary = $fallback_summary;
    }

    echo json_encode([
        "success" => true,
        "summary" => $ai_summary,
        "is_ai_generated" => ($ai_cfg['enabled'] && $ai_summary !== $fallback_summary),
        "metrics" => [
            "total_trips" => $total_trips,
            "total_weight_tons" => $total_weight_tons,
            "measured_count" => $measured_count,
            "estimated_count" => $estimated_count,
            "active_months" => $active_months
        ]
    ]);

} catch (PDOException $e) {
    echo json_encode(["success" => false, "message" => "Database Error: " . $e->getMessage()]);
}
?>
