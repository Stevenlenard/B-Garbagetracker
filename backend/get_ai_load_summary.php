<?php
/**
 * AUTOMATICALLY GENERATED LOAD SUMMARY & YEARLY TREND (GEMINI AI INTEGRATED)
 * Evaluates saved trip data and generates a concise, accurate operational summary.
 */

header("Content-Type: application/json");
require_once 'db_config.php';

$gemini_api_key = "AIzaSyCPng8Ef9-AsuUiagku1FAQOowQniZYkOo";

$start_date = $_GET['start_date'] ?? date("Y-m-d", strtotime("-30 days"));
$end_date = $_GET['end_date'] ?? date("Y-m-d");
$truck_id = $_GET['truck_id'] ?? null;

try {
    // 1. Gather trip statistics
    $where = ["(UPPER(h.route_status) IN ('FULL', 'COMPLETED', 'FINISHED') OR h.full_time IS NOT NULL)"];
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

    $stmt = $conn->prepare("
        SELECT
            COUNT(*) as total_trips,
            COALESCE(SUM(weight_kg), 0) as total_weight_kg,
            SUM(CASE WHEN weight_type = 'MEASURED' THEN 1 ELSE 0 END) as measured_count,
            SUM(CASE WHEN weight_type = 'ESTIMATED' OR weight_type IS NULL THEN 1 ELSE 0 END) as estimated_count
        FROM driver_trip_history h
        WHERE " . implode(" AND ", $where)
    );
    $stmt->execute($params);
    $stats = $stmt->fetch(PDO::FETCH_ASSOC);

    $total_trips = (int)($stats['total_trips'] ?? 0);
    $total_weight_kg = (float)($stats['total_weight_kg'] ?? 0.0);
    $total_weight_tons = round($total_weight_kg / 1000.0, 1);
    $measured_count = (int)($stats['measured_count'] ?? 0);
    $estimated_count = (int)($stats['estimated_count'] ?? 0);

    // 2. Count active months with data in current year
    $selected_year = (int)date("Y", strtotime($start_date));
    $stmtYear = $conn->prepare("
        SELECT COUNT(DISTINCT MONTH(COALESCE(full_time, start_time, created_at))) as active_months
        FROM driver_trip_history
        WHERE YEAR(COALESCE(full_time, start_time, created_at)) = ?
          AND (UPPER(route_status) IN ('FULL', 'COMPLETED', 'FINISHED') OR full_time IS NOT NULL)
    ");
    $stmtYear->execute([$selected_year]);
    $active_months = (int)($stmtYear->fetchColumn() ?? 0);

    // Construct Rule-Based Fallback Summary
    $weightDesc = ($measured_count == 0)
        ? "At the default 5 tons per trip, estimated waste is {$total_weight_tons} tons."
        : "Recorded waste total is {$total_weight_tons} tons ({$measured_count} measured, {$estimated_count} estimated).";

    $trendDesc = ($active_months < 3)
        ? "More complete months are needed to identify a yearly increase."
        : "Yearly collection trend shows activity across {$active_months} months.";

    $fallback_summary = "{$total_trips} FULL trips recorded. {$weightDesc} {$trendDesc}";

    // 3. Attempt Gemini API Call if Key Present
    $ai_summary = null;
    if (!empty($gemini_api_key)) {
        try {
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

            $url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=" . $gemini_api_key;
            $request_body = json_encode([
                "contents" => [
                    ["parts" => [["text" => $prompt]]]
                ],
                "generationConfig" => [
                    "temperature" => 0.2,
                    "maxOutputTokens" => 150
                ]
            ]);

            $ch = curl_init($url);
            curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
            curl_setopt($ch, CURLOPT_POST, true);
            curl_setopt($ch, CURLOPT_POSTFIELDS, $request_body);
            curl_setopt($ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);
            curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
            curl_setopt($ch, CURLOPT_TIMEOUT, 5);

            $api_response = curl_exec($ch);
            $http_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
            curl_close($ch);

            if ($http_code === 200) {
                $respData = json_decode($api_response, true);
                $aiText = $respData['candidates'][0]['content']['parts'][0]['text'] ?? '';
                if (!empty(trim($aiText))) {
                    $ai_summary = trim($aiText);
                }
            }
        } catch (Exception $e) {
            // Fallback used
        }
    }

    if (empty($ai_summary)) {
        $ai_summary = $fallback_summary;
    }

    echo json_encode([
        "success" => true,
        "summary" => $ai_summary,
        "is_ai_generated" => (!empty($gemini_api_key) && $ai_summary !== $fallback_summary),
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
