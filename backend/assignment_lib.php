<?php
/**
 * Route assignments: shared rules for the assignment endpoints and save_trip_history.php.
 *
 * Tables (deploy_prep/sql/07_create_route_assignments.NOT_APPLIED.sql):
 *   route_assignments        one row per Admin assignment (driver, truck, Manila date)
 *   route_assignment_areas   assigned service areas (Firebase `puroks` key + name snapshot)
 *   route_assignment_trips   trip_id -> assignment (a trip belongs to at most one assignment)
 *
 * Status is DERIVED on read; only cancellation is stored:
 *   CANCELLED    cancelled_at set
 *   PENDING      no linked trip, date today or later
 *   IN_PROGRESS  >= 1 linked trip not finalized (ACTIVE / PAUSED / IDLE / FULL: FULL stops
 *                collection but the trip is not finished until COMPLETED)
 *   COMPLETED    linked trip(s) all finalized (COMPLETED / FINISHED; INTERRUPTED is counted
 *                separately) -- operational closure only, NOT proof that every assigned
 *                area was serviced (area coverage comes from verified GPS visits)
 *   MISSED       date passed with no linked trip (never while a linked trip is open)
 *
 * All dates are Asia/Manila calendar dates.
 */

const GT_ASSIGNMENT_TZ = 'Asia/Manila';
const GT_TRIP_FINAL_STATUSES = ['COMPLETED', 'FINISHED', 'INTERRUPTED'];

/** Current epoch seconds (the test harness may pin it; production never defines GT_TEST_HARNESS). */
function gt_now_ts()
{
    $t = getenv('GT_ASSIGNMENT_TEST_NOW');
    if (defined('GT_TEST_HARNESS') && $t !== false && $t !== '') return (int)$t;
    return time();
}

function gt_manila_date($ts)
{
    return (new DateTimeImmutable('@' . (int)$ts))->setTimezone(new DateTimeZone(GT_ASSIGNMENT_TZ))->format('Y-m-d');
}

function gt_manila_today()
{
    return gt_manila_date(gt_now_ts());
}

function gt_valid_date($d)
{
    if (!is_string($d) || !preg_match('/^\d{4}-\d{2}-\d{2}$/', $d)) return false;
    $p = DateTimeImmutable::createFromFormat('!Y-m-d', $d, new DateTimeZone(GT_ASSIGNMENT_TZ));
    return $p !== false && $p->format('Y-m-d') === $d;
}

function gt_norm_truck($t)
{
    return strtoupper(trim((string)$t));
}

function gt_assignment_tables_exist($conn)
{
    foreach (['route_assignments', 'route_assignment_areas', 'route_assignment_trips'] as $t) {
        if ($conn->query("SHOW TABLES LIKE '$t'")->rowCount() === 0) return false;
    }
    return true;
}

/**
 * Derived status of one assignment.
 * @param array $a        route_assignments row
 * @param array $tripStatuses trip_id => latest known route status ('' when not yet reported)
 */
function gt_assignment_status(array $a, array $tripStatuses, $today)
{
    if (!empty($a['cancelled_at'])) return 'CANCELLED';
    if (!$tripStatuses) {
        return ((string)$a['assignment_date'] >= $today) ? 'PENDING' : 'MISSED';
    }
    foreach ($tripStatuses as $st) {
        if (!in_array(strtoupper((string)$st), GT_TRIP_FINAL_STATUSES, true)) return 'IN_PROGRESS';
    }
    return 'COMPLETED';
}

/**
 * Analytics over assignments already filtered to a date range. Due = not cancelled and
 * dated today or earlier. Rate is null when nothing is due (shown as "Not available").
 * Assigned-area coverage is NOT computed here: it needs verified GPS visits (client side).
 */
function gt_assignment_summary(array $items, $today)
{
    $s = ['total' => 0, 'due' => 0, 'completed' => 0, 'in_progress' => 0, 'pending' => 0, 'missed' => 0,
          'cancelled' => 0, 'completion_rate' => null];
    foreach ($items as $it) {
        $s['total']++;
        $st = $it['status'];
        $key = strtolower($st);
        if (isset($s[$key])) $s[$key]++;
        if ($st !== 'CANCELLED' && (string)$it['assignment_date'] <= $today) $s['due']++;
    }
    $dueCompleted = 0;
    foreach ($items as $it) {
        if ($it['status'] === 'COMPLETED' && (string)$it['assignment_date'] <= $today) $dueCompleted++;
    }
    if ($s['due'] > 0) $s['completion_rate'] = round($dueCompleted * 100 / $s['due'], 1);
    return $s;
}

/** Validated assignment input, or ['error' => message]. */
function gt_validate_assignment_input($in, $conn)
{
    $date = (string)($in['assignment_date'] ?? '');
    if (!gt_valid_date($date)) return ['error' => 'A valid collection date (YYYY-MM-DD) is required.'];
    if ($date < gt_manila_today()) return ['error' => 'Assignments cannot be created or moved to a past date.'];

    $driverId = (int)($in['driver_id'] ?? 0);
    if ($driverId <= 0) return ['error' => 'A driver is required.'];
    $q = $conn->prepare("SELECT user_id, role, is_archived FROM users WHERE user_id = ?");
    $q->execute([$driverId]);
    $u = $q->fetch(PDO::FETCH_ASSOC);
    if (!$u || strtolower((string)$u['role']) !== 'driver') return ['error' => 'The selected driver does not exist.'];
    if ((int)($u['is_archived'] ?? 0) === 1) return ['error' => 'The selected driver is archived.'];

    $truck = trim((string)($in['truck_id'] ?? ''));
    if ($truck === '' || strlen($truck) > 50) return ['error' => 'A truck is required.'];

    $areas = [];
    foreach ((array)($in['areas'] ?? []) as $i => $a) {
        $a = (array)$a;
        $key = trim((string)($a['key'] ?? ''));
        $name = trim((string)($a['name'] ?? ''));
        if ($key === '' || $name === '' || strlen($key) > 80 || strlen($name) > 120) {
            return ['error' => 'Each area needs a key and a name.'];
        }
        $areas[$key] = ['key' => $key, 'name' => $name, 'order' => count($areas)];
    }
    if (!$areas) return ['error' => 'Select at least one service area.'];
    if (count($areas) > 30) return ['error' => 'Too many areas in one assignment.'];

    $notes = trim((string)($in['notes'] ?? ''));
    return ['date' => $date, 'driver_id' => $driverId, 'truck_id' => $truck, 'areas' => array_values($areas),
            'notes' => $notes === '' ? null : substr($notes, 0, 255)];
}

/** trip_id => status for the linked trips: driver_trip_history first, link snapshot as fallback. */
function gt_trip_statuses($conn, array $links)
{
    $out = [];
    foreach ($links as $l) $out[(string)$l['trip_id']] = (string)($l['trip_status'] ?? '');
    if (!$out) return $out;
    try {
        if ($conn->query("SHOW TABLES LIKE 'driver_trip_history'")->rowCount() > 0) {
            $ids = array_keys($out);
            $q = $conn->prepare("SELECT trip_id, route_status FROM driver_trip_history WHERE trip_id IN (" . implode(',', array_fill(0, count($ids), '?')) . ")");
            $q->execute($ids);
            foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $r) {
                if (($r['route_status'] ?? '') !== '') $out[(string)$r['trip_id']] = strtoupper((string)$r['route_status']);
            }
        }
    } catch (PDOException $e) {
        error_log('assignment_lib trip statuses: ' . $e->getMessage());
    }
    return $out;
}

/** One assignment with its areas, linked trips and derived status. */
function gt_load_assignment($conn, $id)
{
    $q = $conn->prepare("SELECT * FROM route_assignments WHERE assignment_id = ?");
    $q->execute([(int)$id]);
    $a = $q->fetch(PDO::FETCH_ASSOC);
    if (!$a) return null;
    return gt_decorate_assignments($conn, [$a])[0];
}

function gt_decorate_assignments($conn, array $rows)
{
    if (!$rows) return [];
    $ids = array_map(function ($r) { return (int)$r['assignment_id']; }, $rows);
    $ph = implode(',', array_fill(0, count($ids), '?'));
    $areas = [];
    $q = $conn->prepare("SELECT * FROM route_assignment_areas WHERE assignment_id IN ($ph)");
    $q->execute($ids);
    foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $r) $areas[(int)$r['assignment_id']][] = $r;
    $links = [];
    $q = $conn->prepare("SELECT * FROM route_assignment_trips WHERE assignment_id IN ($ph)");
    $q->execute($ids);
    foreach ($q->fetchAll(PDO::FETCH_ASSOC) as $r) $links[(int)$r['assignment_id']][] = $r;

    $today = gt_manila_today();
    $out = [];
    foreach ($rows as $a) {
        $id = (int)$a['assignment_id'];
        $myAreas = $areas[$id] ?? [];
        usort($myAreas, function ($x, $y) { return (int)$x['sequence_order'] <=> (int)$y['sequence_order']; });
        $statuses = gt_trip_statuses($conn, $links[$id] ?? []);
        $out[] = [
            'assignment_id' => $id,
            'assignment_date' => (string)$a['assignment_date'],
            'driver_id' => (int)$a['driver_id'],
            'truck_id' => (string)$a['truck_id'],
            'notes' => $a['notes'] ?? null,
            'status' => gt_assignment_status($a, $statuses, $today),
            'areas' => array_map(function ($r) { return ['key' => $r['area_key'], 'name' => $r['area_name']]; }, $myAreas),
            'trips' => array_map(function ($tid) use ($statuses) { return ['trip_id' => $tid, 'status' => $statuses[$tid] ?: 'ACTIVE']; }, array_keys($statuses)),
            'trips_interrupted' => count(array_filter($statuses, function ($s) { return $s === 'INTERRUPTED'; })),
            'cancelled_at' => $a['cancelled_at'] ?? null,
            'created_at' => $a['created_at'] ?? null,
        ];
    }
    return $out;
}

/**
 * Links [$tripId] of the AUTHENTICATED driver [$driverId] to that driver's assignment for the
 * Manila date of [$tripStartTs]. Idempotent. Never links across drivers, dates or trucks.
 *
 * @return array ['linked' => bool, 'reason' => string, 'assignment_id' => int|null]
 */
function gt_link_trip($conn, $driverId, $tripId, $truckId, $tripStartTs, $source, $tripStatus = null, $retry = true)
{
    $tripId = trim((string)$tripId);
    if ($tripId === '' || strlen($tripId) > 100) return ['linked' => false, 'reason' => 'invalid_trip', 'assignment_id' => null];
    $date = gt_manila_date($tripStartTs);

    $q = $conn->prepare("SELECT * FROM route_assignments WHERE driver_id = ? AND assignment_date = ? AND cancelled_at IS NULL LIMIT 1");
    $q->execute([(int)$driverId, $date]);
    $a = $q->fetch(PDO::FETCH_ASSOC);
    if (!$a) return ['linked' => false, 'reason' => 'no_assignment', 'assignment_id' => null];
    if (gt_norm_truck($a['truck_id']) !== gt_norm_truck($truckId)) {
        return ['linked' => false, 'reason' => 'truck_mismatch', 'assignment_id' => (int)$a['assignment_id']];
    }
    $aid = (int)$a['assignment_id'];
    $status = $tripStatus === null ? null : strtoupper((string)$tripStatus);

    $q = $conn->prepare("SELECT * FROM route_assignment_trips WHERE trip_id = ?");
    $q->execute([$tripId]);
    $existing = $q->fetch(PDO::FETCH_ASSOC);
    if ($existing) {
        if ((int)$existing['assignment_id'] !== $aid) {
            // The trip is already attached elsewhere. The authenticated owner only takes it over
            // when the other assignment belongs to a DIFFERENT driver (a wrong earlier link).
            $o = $conn->prepare("SELECT driver_id FROM route_assignments WHERE assignment_id = ?");
            $o->execute([(int)$existing['assignment_id']]);
            $other = $o->fetch(PDO::FETCH_ASSOC);
            if ($other && (int)$other['driver_id'] === (int)$driverId) {
                return ['linked' => false, 'reason' => 'already_linked', 'assignment_id' => (int)$existing['assignment_id']];
            }
            $conn->prepare("UPDATE route_assignment_trips SET assignment_id = ?, link_source = ? WHERE trip_id = ?")
                ->execute([$aid, $source, $tripId]);
            error_log("assignment link: trip reassigned from assignment {$existing['assignment_id']} to $aid (owner request)");
        }
        if ($status !== null) {
            $conn->prepare("UPDATE route_assignment_trips SET trip_status = ? WHERE trip_id = ?")->execute([$status, $tripId]);
        }
        return ['linked' => true, 'reason' => 'linked', 'assignment_id' => $aid];
    }
    try {
        $conn->prepare("INSERT INTO route_assignment_trips (trip_id, assignment_id, link_source, trip_status) VALUES (?, ?, ?, ?)")
            ->execute([$tripId, $aid, $source, $status]);
    } catch (PDOException $e) {
        if ($e->getCode() !== '23000' || !$retry) throw $e;
        // A concurrent request linked it first: report what is stored.
        return gt_link_trip($conn, $driverId, $tripId, $truckId, $tripStartTs, $source, $tripStatus, false);
    }
    return ['linked' => true, 'reason' => 'linked', 'assignment_id' => $aid];
}
