<?php
header("Content-Type: application/json");
require_once 'db_config.php';
require_once 'auth_token.php';
require_once 'assignment_lib.php';

// Admin only. Creates an assignment, or edits one that is still PENDING.
$auth = gt_require_verified_role(['admin']);

$in = json_decode(file_get_contents('php://input'), true);
if (!is_array($in)) $in = $_POST;

function gt_assign_reply($ok, $msg, $extra = [], $code = 200)
{
    if ($code !== 200) http_response_code($code);
    echo json_encode(array_merge(["success" => $ok, "message" => $msg], $extra));
    exit;
}

try {
    if (!gt_assignment_tables_exist($conn)) {
        gt_assign_reply(false, "Route assignments are not set up on this server yet.", ["available" => false]);
    }
    $v = gt_validate_assignment_input($in, $conn);
    if (isset($v['error'])) gt_assign_reply(false, $v['error']);

    $editId = (int)($in['assignment_id'] ?? 0);
    if ($editId > 0) {
        $current = gt_load_assignment($conn, $editId);
        if (!$current) gt_assign_reply(false, "Assignment not found.", [], 404);
        if ($current['status'] !== 'PENDING') {
            gt_assign_reply(false, "Only pending assignments can be edited.", [], 409);
        }
    }

    // One live assignment per driver per day and per truck per day. The keys are NULL once an
    // assignment is cancelled; their UNIQUE indexes also stop concurrent duplicates.
    $driverKey = $v['driver_id'] . '|' . $v['date'];
    $truckKey = gt_norm_truck($v['truck_id']) . '|' . $v['date'];
    $q = $conn->prepare("SELECT assignment_id FROM route_assignments WHERE driver_day_key = ?");
    $q->execute([$driverKey]);
    foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $r) {
        if ((int)$r['assignment_id'] !== $editId) gt_assign_reply(false, "This driver already has an assignment on that date.", [], 409);
    }
    $q = $conn->prepare("SELECT assignment_id FROM route_assignments WHERE truck_day_key = ?");
    $q->execute([$truckKey]);
    foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $r) {
        if ((int)$r['assignment_id'] !== $editId) gt_assign_reply(false, "This truck already has an assignment on that date.", [], 409);
    }

    $conn->beginTransaction();
    try {
        if ($editId > 0) {
            $conn->prepare("UPDATE route_assignments SET assignment_date = ?, driver_id = ?, truck_id = ?, notes = ?, driver_day_key = ?, truck_day_key = ? WHERE assignment_id = ?")
                ->execute([$v['date'], $v['driver_id'], $v['truck_id'], $v['notes'], $driverKey, $truckKey, $editId]);
            $conn->prepare("DELETE FROM route_assignment_areas WHERE assignment_id = ?")->execute([$editId]);
            $id = $editId;
        } else {
            $conn->prepare("INSERT INTO route_assignments (assignment_date, driver_id, truck_id, notes, created_by, driver_day_key, truck_day_key) VALUES (?, ?, ?, ?, ?, ?, ?)")
                ->execute([$v['date'], $v['driver_id'], $v['truck_id'], $v['notes'], (int)$auth['sub'], $driverKey, $truckKey]);
            $id = (int)$conn->lastInsertId();
        }
        $ins = $conn->prepare("INSERT INTO route_assignment_areas (assignment_id, area_key, area_name, sequence_order) VALUES (?, ?, ?, ?)");
        foreach ($v['areas'] as $a) $ins->execute([$id, $a['key'], $a['name'], $a['order']]);
        $conn->commit();
    } catch (PDOException $e) {
        $conn->rollBack();
        if ($e->getCode() === '23000') gt_assign_reply(false, "The driver or truck already has an assignment on that date.", [], 409);
        throw $e;
    }

    gt_assign_reply(true, $editId > 0 ? "Assignment updated." : "Assignment created.", ["data" => gt_load_assignment($conn, $id)]);
} catch (PDOException $e) {
    error_log("save_assignment.php: " . $e->getMessage());
    gt_assign_reply(false, "The assignment could not be saved.");
}
