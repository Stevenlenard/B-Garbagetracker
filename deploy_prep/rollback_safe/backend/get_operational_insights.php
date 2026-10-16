<?php
/**
 * GEMINI-POWERED OPERATIONAL INSIGHTS API
 * Aggregates live system data (puro coverage, complaints, truck statuses)
 * and generates structured AI operational insights and transcripts.
 */

header("Content-Type: application/json");
require_once 'db_config.php';

require_once 'ai_config_loader.php';
$ai_cfg = gt_ai_config();
if (!$ai_cfg['enabled']) {
    // Fail safe: no AI call, no data aggregation, no error detail.
    echo json_encode(["success" => false, "ai_disabled" => true, "message" => "AI insights are disabled on this server."]);
    exit;
}

try {
    // 1. Gather Complaint Statistics by Status
    $stmt_complaints = $conn->query("SELECT status, COUNT(*) as count FROM complaints GROUP BY status");
    $complaints_by_status = $stmt_complaints->fetchAll(PDO::FETCH_ASSOC);

    // 2. Gather Complaint Breakdown by Purok
    $stmt_purok = $conn->query("
        SELECT COALESCE(r.purok, 'Unspecified') as purok, COUNT(c.id) as complaint_count, c.status
        FROM complaints c
        LEFT JOIN residents r ON c.resident_id = r.resident_id
        GROUP BY r.purok, c.status
    ");
    $complaints_by_purok = $stmt_purok->fetchAll(PDO::FETCH_ASSOC);

    // 3. Gather Fleet & Truck Location Status
    $stmt_trucks = $conn->query("SELECT truck_id, status, speed, updated_at FROM truck_locations");
    $trucks_data = $stmt_trucks->fetchAll(PDO::FETCH_ASSOC);

    // 4. Compile System Context Payload
    $system_context = [
        "timestamp" => date("Y-m-d H:i:s"),
        "complaints_summary_by_status" => $complaints_by_status,
        "complaints_by_purok" => $complaints_by_purok,
        "fleet_status" => $trucks_data
    ];

    $payload_json = json_encode($system_context, JSON_PRETTY_PRINT);

    // 5. Construct prompt
    $prompt = "You are an expert AI Municipal Operations Auditor for a Garbage Tracking System (GarbageTracker). " .
              "Analyze the following real-time JSON system data from our database: " . $payload_json . ". " .
              "Generate a comprehensive, detailed operational insights report and administrative transcript. " .
              "Your response MUST be valid JSON matching this exact structure: " .
              "{" .
              "  \"executive_summary\": \"Detailed summary of system performance, collection efficiency, and overall status.\"," .
              "  \"system_health_score\": 85," .
              "  \"puro_coverage_analysis\": [" .
              "    {" .
              "      \"purok_name\": \"Name of Purok\"," .
              "      \"collection_status\": \"Normal / Delayed / Critical\"," .
              "      \"notes\": \"Detailed analysis for this specific area based on complaints and truck movement.\"" .
              "    }" .
              "  ]," .
              "  \"complaints_transcript_breakdown\": \"Detailed narrative transcript analyzing the root causes of current pending and in-progress complaints.\"," .
              "  \"operational_gaps_and_shortfalls\": [" .
              "    \"Specific operational gap 1 (e.g., driver shortages, idle trucks, uncollected bins)\"" .
              "  ]," .
              "  \"actionable_recommendations\": [" .
              "    \"Concrete actionable step for the administrator to resolve today\"\n" .
              "  ]" .
              "}";

    // 6. One bounded call to the configured model (no key in the URL, no raw error echoed)
    $ai_json_string = gt_ai_generate($ai_cfg, $prompt, ["responseMimeType" => "application/json", "temperature" => 0.4], 15);
    if ($ai_json_string === null) {
        throw new Exception("AI service unavailable");
    }
    $insights = json_decode($ai_json_string, true);

    // 7. Output Final JSON Response
    echo json_encode([
        "success" => true,
        "generated_at" => date("Y-m-d H:i:s"),
        "insights" => $insights
    ]);

} catch (Exception $e) {
    http_response_code(500);
    echo json_encode([
        "success" => false,
        "message" => "Failed to generate operational insights."
    ]);
}
?>
