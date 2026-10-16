<?php
/**
 * Complaint Center (resident complaints in MySQL), read-only.
 *
 *   action=list (default, Admin): one page of Active (pending + in progress) or Resolved
 *     complaints, newest first, filtered on the server.
 *     scope=active|resolved, status=pending|in_progress (active only), q (complaint id such as
 *     "43" / "#043", or complainant name / category), category, location, date_from/date_to
 *     (YYYY-MM-DD; Resolved Archive filters by resolution date), page (1..), per_page (5..50).
 *     Returns data, total (all matches), page, per_page, has_more and counts (real totals per
 *     state across ALL complaints, not just this page).
 *
 *   action=detail&complaint_id=N (Admin, or the complaining Resident): the complaint and its
 *     status history.
 */
header("Content-Type: application/json");
header("Cache-Control: no-store");
require_once 'db_config.php';
require_once 'auth_token.php';
require_once 'complaint_lib.php';

$json = json_decode(file_get_contents('php://input'), true);
$in = array_merge($_GET, $_POST, is_array($json) ? $json : []);
$action = (string)($in['action'] ?? 'list');

try {
    $cols = gt_complaint_columns($conn);
    $features = [
        'status_history' => gt_complaint_table_exists($conn, 'complaint_status_history'),
        'resolved_at' => isset($cols['resolved_at']),
        'resolved_by' => isset($cols['resolved_by_name']),
    ];

    if ($action === 'detail') {
        $auth = gt_require_role(['admin', 'resident']);
        $id = (string)($in['complaint_id'] ?? '');
        if (!ctype_digit($id)) {
            echo json_encode(["success" => false, "message" => "Missing complaint id."]);
            exit;
        }
        $row = gt_complaint_fetch($conn, $cols, (int)$id);
        // A resident may only open their own complaint (same answer as "not found").
        if (!$row || ($auth !== null && $auth['role'] === 'resident' && (string)$row['resident_id'] !== (string)$auth['sub'])) {
            echo json_encode(["success" => false, "message" => "Complaint not found."]);
            exit;
        }
        $complaint = gt_complaint_present($row);
        echo json_encode(["success" => true, "data" => $complaint,
                          "history" => gt_complaint_history($conn, $complaint), "features" => $features]);
        exit;
    }

    if ($action !== 'list') {
        echo json_encode(["success" => false, "message" => "Unknown action."]);
        exit;
    }

    gt_require_role(['admin']);
    $f = gt_complaint_filters($in);
    [$from, $where, $params, $order] = gt_complaint_list_parts($cols, $f);

    $countSt = $conn->prepare("SELECT /*gt:complaint_center*/ COUNT(*) AS total $from WHERE $where");
    $countSt->execute($params);
    $total = (int)(($countSt->fetch(PDO::FETCH_ASSOC) ?: [])['total'] ?? 0);

    $limit = (int)$f['per_page'];
    $offset = ((int)$f['page'] - 1) * $limit;
    $rows = [];
    if ($offset < $total) {
        // LIMIT/OFFSET are validated integers (bound LIMIT values break under emulated prepares).
        $st = $conn->prepare("SELECT /*gt:complaint_center*/ " . gt_complaint_select($cols) . " $from WHERE $where ORDER BY $order LIMIT $limit OFFSET $offset");
        $st->execute($params);
        $rows = array_map('gt_complaint_present', $st->fetchAll(PDO::FETCH_ASSOC));
    }

    echo json_encode([
        "success" => true,
        "data" => $rows,
        "total" => $total,
        "page" => (int)$f['page'],
        "per_page" => $limit,
        "has_more" => $offset + count($rows) < $total,
        "counts" => gt_complaint_counts($conn),
        "filters" => $f,
        "features" => $features,
    ]);
} catch (Throwable $e) {
    error_log("complaint_center.php: " . $e->getMessage());
    echo json_encode(["success" => false, "message" => "Complaints could not be loaded. Please try again."]);
}
?>
