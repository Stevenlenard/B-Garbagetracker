<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';
require_once 'assignment_lib.php';

// Admin: all assignments (optional driver/truck/status filters). Driver: ONLY their own.
// A verified token is always required (no legacy token-less access for this feature).
$auth = gt_require_verified_role(['admin', 'driver']);

$in = json_decode(file_get_contents('php://input'), true);
if (!is_array($in)) $in = array_merge($_GET, $_POST);

$today = gt_manila_today();
$start = (string)($in['start_date'] ?? $today);
$end = (string)($in['end_date'] ?? $start);
if (!gt_valid_date($start) || !gt_valid_date($end) || $start > $end) {
    echo json_encode(["success" => false, "message" => "A valid date range is required."]);
    exit;
}
$span = (new DateTimeImmutable($start))->diff(new DateTimeImmutable($end))->days;
if ($span > 366) {
    echo json_encode(["success" => false, "message" => "The date range is limited to one year."]);
    exit;
}

try {
    if (!gt_assignment_tables_exist($conn)) {
        echo json_encode(["success" => false, "available" => false, "message" => "Route assignments are not set up on this server yet."]);
        exit;
    }

    $sql = "SELECT * FROM route_assignments WHERE assignment_date >= ? AND assignment_date <= ?";
    $params = [$start, $end];
    if ($auth['role'] === 'driver') {
        $sql .= " AND driver_id = ?";
        $params[] = (int)$auth['sub'];
    } else {
        if (!empty($in['driver_id'])) { $sql .= " AND driver_id = ?"; $params[] = (int)$in['driver_id']; }
        if (!empty($in['truck_id'])) { $sql .= " AND truck_id = ?"; $params[] = trim((string)$in['truck_id']); }
    }
    $sql .= " ORDER BY assignment_date DESC";
    $q = $conn->prepare($sql);
    $q->execute($params);
    $items = gt_decorate_assignments($conn, $q->fetchAll(PDO::FETCH_ASSOC));

    // Summary over ALL assignments in the range (before an optional status filter).
    $summary = gt_assignment_summary($items, $today);
    $statusFilter = strtoupper(trim((string)($in['status'] ?? '')));
    if ($statusFilter !== '') {
        $items = array_values(array_filter($items, function ($i) use ($statusFilter) { return $i['status'] === $statusFilter; }));
    }

    echo json_encode([
        "success" => true,
        "available" => true,
        "today" => $today,
        "summary" => $summary,
        "data" => $items,
    ]);
} catch (PDOException $e) {
    error_log("get_assignments.php: " . $e->getMessage());
    echo json_encode(["success" => false, "message" => "Assignments could not be loaded."]);
}
