<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';

// Monthly Mapbox request budget shared by every device. The app asks here BEFORE each Mapbox
// request; the request is sent only when "allowed" is true. Counting and the limit live on the
// server, so no number of phones or browsers can push a month past the limit.
// A verified token is always required. Table: deploy_prep/hostinger_mapbox_quota/01_create_mapbox_usage.sql
gt_require_verified_role(['admin', 'driver', 'resident']);

const GT_MAPBOX_MONTHLY_LIMITS = ['map_matching' => 50000];

$in = json_decode(file_get_contents('php://input'), true);
if (!is_array($in)) $in = $_POST;
$service = (string)($in['service'] ?? '');
$count = max(1, min(10, (int)($in['count'] ?? 1)));
if (!isset(GT_MAPBOX_MONTHLY_LIMITS[$service])) {
    http_response_code(400);
    echo json_encode(["success" => false, "allowed" => false, "message" => "Unknown service."]);
    exit;
}
$limit = GT_MAPBOX_MONTHLY_LIMITS[$service];
$month = gmdate('Y-m');

try {
    $conn->prepare("INSERT IGNORE INTO mapbox_usage (service, month, requests) VALUES (?, ?, 0)")->execute([$service, $month]);
    // One atomic statement: the row only grows while it stays within the limit.
    $take = $conn->prepare("UPDATE mapbox_usage SET requests = requests + ? WHERE service = ? AND month = ? AND requests + ? <= ?");
    $take->execute([$count, $service, $month, $count, $limit]);
    $allowed = $take->rowCount() === 1;
    $read = $conn->prepare("SELECT requests FROM mapbox_usage WHERE service = ? AND month = ?");
    $read->execute([$service, $month]);
    $used = (int)$read->fetchColumn();
    echo json_encode(["success" => true, "allowed" => $allowed, "used" => $used, "limit" => $limit, "month" => $month]);
} catch (PDOException $e) {
    // Missing table or database trouble: refuse, so nothing is sent to Mapbox uncounted.
    echo json_encode(["success" => false, "allowed" => false, "message" => "Mapbox budget is not available on this server."]);
}
