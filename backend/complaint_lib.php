<?php
/**
 * Complaint lifecycle helpers shared by complaint_center.php and update_complaint.php.
 *
 * Lifecycle: PENDING -> IN PROGRESS -> RESOLVED (a Pending complaint may also be resolved
 * directly; Resolved is final, reopening is not supported). The status column keeps the
 * values the apps already write ('pending', 'in_progress', 'resolved'); older spellings
 * ('In Progress', 'completed', ...) are read as the same three states.
 *
 * Schema-aware: the optional lifecycle columns (in_progress_at, resolved_at, resolved_by,
 * resolved_by_name, updated_at) and the complaint_status_history table from
 * deploy_prep/sql/11_complaint_lifecycle.NOT_APPLIED.sql are used only when they exist,
 * so these endpoints work before and after that migration.
 */

const GT_FIREBASE_DB_URL = 'https://garbagesis-78d39-default-rtdb.asia-southeast1.firebasedatabase.app';
const GT_COMPLAINT_PROGRESS = ['in_progress', 'in progress', 'in-progress', 'under review', 'under_review', 'processing', 'ongoing'];
const GT_COMPLAINT_RESOLVED = ['resolved', 'completed', 'closed'];
const GT_COMPLAINT_NOTE_MIN = 10;
const GT_COMPLAINT_NOTE_MAX = 2000;

/** 'pending' | 'in_progress' | 'resolved' for any stored or requested spelling. */
function gt_complaint_canonical($raw)
{
    $s = strtolower(trim((string)$raw));
    if (in_array($s, GT_COMPLAINT_RESOLVED, true)) return 'resolved';
    if (in_array($s, GT_COMPLAINT_PROGRESS, true) || strpos($s, 'progress') !== false) return 'in_progress';
    return 'pending';
}

/** The spellings of [$values] as they may be stored (case variants for case-sensitive collations). */
function gt_complaint_spellings(array $values)
{
    $out = [];
    foreach ($values as $v) {
        foreach ([$v, strtoupper($v), ucwords($v), ucfirst($v), ucwords(str_replace('_', ' ', $v))] as $s) {
            $out[$s] = true;
        }
    }
    return array_keys($out);
}

function gt_complaint_text_len($s)
{
    return function_exists('mb_strlen') ? mb_strlen($s, 'UTF-8') : strlen($s);
}

/** Column names of the complaints table, as a set. */
function gt_complaint_columns($conn)
{
    $cols = $conn->query("DESCRIBE complaints")->fetchAll(PDO::FETCH_COLUMN);
    return array_fill_keys($cols, true);
}

function gt_complaint_table_exists($conn, $table)
{
    try {
        $st = $conn->query("SHOW TABLES LIKE '" . preg_replace('/[^a-z_]/', '', $table) . "'");
        return $st->rowCount() > 0 || $st->fetch() !== false;
    } catch (Throwable $e) {
        return false;
    }
}

function gt_complaint_id_col(array $cols)
{
    return isset($cols['complaint_id']) ? 'complaint_id' : 'id';
}

function gt_complaint_owner_col(array $cols)
{
    return isset($cols['resident_id']) ? 'resident_id' : 'user_id';
}

/**
 * The value to store for a canonical status. When the column is an ENUM the matching
 * member is used (whatever its spelling); otherwise the canonical value.
 */
function gt_complaint_storage_value($conn, $canonical)
{
    try {
        $row = $conn->query("SHOW COLUMNS FROM complaints LIKE 'status'")->fetch(PDO::FETCH_ASSOC);
        $type = is_array($row) ? (string)($row['Type'] ?? $row['type'] ?? '') : '';
        if (preg_match("/^enum\((.*)\)$/i", $type, $m)) {
            foreach (str_getcsv($m[1], ',', "'", '') as $member) {
                if (gt_complaint_canonical($member) === $canonical
                    && ($canonical !== 'pending' || strtolower(trim($member)) === 'pending')) {
                    return $member;
                }
            }
        }
    } catch (Throwable $e) {
        // Unknown column type: fall back to the canonical value the apps already write.
    }
    return $canonical;
}

/** SQL condition (alias c) for a canonical status, or for 'active' (= not resolved). */
function gt_complaint_status_sql($which, array &$params)
{
    $in = function (array $values) use (&$params) {
        $sp = gt_complaint_spellings($values);
        foreach ($sp as $v) $params[] = $v;
        return '(' . implode(',', array_fill(0, count($sp), '?')) . ')';
    };
    switch ($which) {
        case 'resolved':
            return 'c.status IN ' . $in(GT_COMPLAINT_RESOLVED);
        case 'in_progress':
            return 'c.status IN ' . $in(GT_COMPLAINT_PROGRESS);
        case 'pending':
            return '(c.status IS NULL OR c.status NOT IN ' . $in(array_merge(GT_COMPLAINT_PROGRESS, GT_COMPLAINT_RESOLVED)) . ')';
        default: // active
            return '(c.status IS NULL OR c.status NOT IN ' . $in(GT_COMPLAINT_RESOLVED) . ')';
    }
}

function gt_complaint_valid_date($s)
{
    if (!is_string($s) || !preg_match('/^\d{4}-\d{2}-\d{2}$/', $s)) return null;
    [$y, $m, $d] = array_map('intval', explode('-', $s));
    return checkdate($m, $d, $y) ? $s : null;
}

/** Normalized, whitelisted list filters from request input. */
function gt_complaint_filters(array $in)
{
    $str = function ($k, $max = 100) use ($in) {
        $v = isset($in[$k]) ? trim((string)$in[$k]) : '';
        return function_exists('mb_substr') ? mb_substr($v, 0, $max, 'UTF-8') : substr($v, 0, $max);
    };
    $scope = ($in['scope'] ?? '') === 'resolved' ? 'resolved' : 'active';
    $status = $str('status', 20);
    $status = in_array($status, ['pending', 'in_progress'], true) && $scope === 'active' ? $status : '';
    $perPage = (int)($in['per_page'] ?? 15);
    $perPage = max(5, min(50, $perPage ?: 15));
    $from = gt_complaint_valid_date($in['date_from'] ?? null);
    $to = gt_complaint_valid_date($in['date_to'] ?? null);
    if ($from !== null && $to !== null && $from > $to) [$from, $to] = [$to, $from];
    // location: one area name, or up to 6 alias terms separated by "|" (e.g. "central|purok 1"),
    // because stored puroks use several spellings of the same area.
    $terms = [];
    foreach (explode('|', $str('location', 250)) as $t) {
        $t = trim($t);
        if ($t !== '' && strlen($t) <= 60 && count($terms) < 6) $terms[] = $t;
    }
    return [
        'scope' => $scope,
        'status' => $status,
        'q' => $str('q'),
        'category' => $str('category'),
        'location' => $terms,
        'date_from' => $from,
        'date_to' => $to,
        'page' => max(1, (int)($in['page'] ?? 1)),
        'per_page' => $perPage,
    ];
}

function gt_complaint_like($s)
{
    return '%' . strtr($s, ['\\' => '\\\\', '%' => '\\%', '_' => '\\_']) . '%';
}

/**
 * FROM/WHERE/ORDER for the Complaint Center list (alias c = complaints, r = residents).
 * Every value is a bound parameter; only whitelisted column names are interpolated.
 * Returns [from, where, params, order].
 */
function gt_complaint_list_parts(array $cols, array $f, $onlyId = null)
{
    $id = 'c.' . gt_complaint_id_col($cols);
    $owner = 'c.' . gt_complaint_owner_col($cols);
    $from = "FROM complaints c LEFT JOIN residents r ON $owner = r.resident_id";
    $where = [];
    $params = [];

    // Archived complaints (test or invalid records) are kept in the table but never listed.
    // (A complaint fetched by its id is still found, so an archived record can be opened or restored.)
    if (isset($cols['is_archived']) && $onlyId === null) $where[] = '(c.is_archived IS NULL OR c.is_archived = 0)';

    if ($onlyId !== null) {
        $where[] = "$id = ?";
        $params[] = (int)$onlyId;
    } else {
        $where[] = gt_complaint_status_sql($f['scope'] === 'resolved' ? 'resolved' : ($f['status'] !== '' ? $f['status'] : 'active'), $params);

        if ($f['q'] !== '') {
            if (preg_match('/^#?0*(\d{1,9})$/', $f['q'], $m)) {
                $where[] = "($id = ? OR r.name LIKE ?)";
                $params[] = (int)$m[1];
                $params[] = gt_complaint_like($f['q']);
            } else {
                $where[] = "(r.name LIKE ? OR c.category LIKE ?)";
                $params[] = gt_complaint_like($f['q']);
                $params[] = gt_complaint_like($f['q']);
            }
        }
        if ($f['category'] !== '') {
            $where[] = 'c.category = ?';
            $params[] = $f['category'];
        }
        if ($f['location']) {
            $parts = [];
            foreach ($f['location'] as $term) {
                $like = gt_complaint_like($term);
                if (isset($cols['purok'])) { $parts[] = 'c.purok LIKE ?'; $params[] = $like; }
                if (isset($cols['location'])) { $parts[] = 'c.location LIKE ?'; $params[] = $like; }
                $parts[] = isset($cols['purok']) ? "((c.purok IS NULL OR c.purok = '') AND r.purok LIKE ?)" : 'r.purok LIKE ?';
                $params[] = $like;
            }
            $where[] = '(' . implode(' OR ', $parts) . ')';
        }
        if (isset($cols['created_at']) && ($f['date_from'] !== null || $f['date_to'] !== null)) {
            // Resolved Archive filters by resolution date; complaints resolved before the
            // lifecycle migration have no resolved_at and use their submission date.
            $range = function ($col) use ($f, &$params) {
                $c = [];
                if ($f['date_from'] !== null) { $c[] = "$col >= ?"; $params[] = $f['date_from'] . ' 00:00:00'; }
                if ($f['date_to'] !== null) { $c[] = "$col < ?"; $params[] = date('Y-m-d', strtotime($f['date_to'] . ' +1 day')) . ' 00:00:00'; }
                return implode(' AND ', $c);
            };
            if ($f['scope'] === 'resolved' && isset($cols['resolved_at'])) {
                $a = $range('c.resolved_at');
                $b = $range('c.created_at');
                $where[] = "(($a) OR (c.resolved_at IS NULL AND $b))";
            } else {
                $where[] = '(' . $range('c.created_at') . ')';
            }
        }
    }

    if ($f['scope'] === 'resolved' && isset($cols['resolved_at']) && isset($cols['created_at'])) {
        $order = "COALESCE(c.resolved_at, c.created_at) DESC, $id DESC";
    } elseif (isset($cols['created_at'])) {
        $order = "c.created_at DESC, $id DESC";
    } else {
        $order = "$id DESC";
    }
    return [$from, implode(' AND ', $where), $params, $order];
}

/** SELECT list for one complaint row (simple column references only). */
function gt_complaint_select(array $cols)
{
    $id = 'c.' . gt_complaint_id_col($cols);
    $owner = 'c.' . gt_complaint_owner_col($cols);
    $items = ["$id AS id", "$owner AS resident_id", 'c.category AS category', 'c.description AS description', 'c.status AS status',
              'r.name AS r_name', 'r.purok AS r_purok'];
    foreach (['admin_response', 'created_at', 'purok', 'location', 'updated_at', 'in_progress_at', 'resolved_at', 'resolved_by', 'resolved_by_name'] as $c) {
        if (isset($cols[$c])) $items[] = "c.$c AS $c";
    }
    return implode(', ', $items);
}

/** The API shape of a complaint row (same field names the apps already read). */
function gt_complaint_present(array $row)
{
    $purok = trim((string)($row['purok'] ?? ''));
    if ($purok === '') $purok = trim((string)($row['r_purok'] ?? ''));
    $status = gt_complaint_canonical($row['status'] ?? '');
    return [
        'id' => (int)$row['id'],
        'complaint_id' => (int)$row['id'],
        'resident_id' => $row['resident_id'] ?? null,
        'user_id' => $row['resident_id'] ?? null,
        'source' => 'resident',
        'category' => $row['category'] ?? '',
        'description' => $row['description'] ?? '',
        'status' => $status,
        'status_raw' => $row['status'] ?? null,
        'admin_response' => $row['admin_response'] ?? '',
        'created_at' => $row['created_at'] ?? null,
        'updated_at' => $row['updated_at'] ?? null,
        'in_progress_at' => $row['in_progress_at'] ?? null,
        'resolved_at' => $row['resolved_at'] ?? null,
        'resolved_by' => $row['resolved_by'] ?? null,
        'resolved_by_name' => $row['resolved_by_name'] ?? null,
        'full_name' => ($row['r_name'] ?? null) ?: 'Unknown Resident',
        'purok' => $purok !== '' ? $purok : 'Unknown',
        'location' => $row['location'] ?? '',
    ];
}

/** Real database counts per lifecycle state (never limited to one page). */
function gt_complaint_counts($conn)
{
    $counts = ['pending' => 0, 'in_progress' => 0, 'resolved' => 0];
    $archived = $conn->query("SHOW COLUMNS FROM complaints LIKE 'is_archived'")->fetch(PDO::FETCH_ASSOC);
    $notArchived = $archived ? ' WHERE (c.is_archived IS NULL OR c.is_archived = 0)' : '';
    $rows = $conn->query("SELECT c.status AS status, COUNT(*) AS n FROM complaints c /*gt:complaint_counts*/" . $notArchived . " GROUP BY c.status")->fetchAll(PDO::FETCH_ASSOC);
    foreach ($rows as $r) $counts[gt_complaint_canonical($r['status'] ?? '')] += (int)($r['n'] ?? 0);
    return $counts;
}

function gt_complaint_fetch($conn, array $cols, $id)
{
    [$from, $where, $params] = gt_complaint_list_parts($cols, gt_complaint_filters([]), $id);
    $st = $conn->prepare("SELECT /*gt:complaint_center*/ " . gt_complaint_select($cols) . " $from WHERE $where LIMIT 1");
    $st->execute($params);
    $row = $st->fetch(PDO::FETCH_ASSOC);
    return $row ?: null;
}

// ------------------------------------------------------------------ notifications

/** One notification record per complaint and state; the key makes delivery idempotent. */
function gt_complaint_notification_key($complaintId, $canonical)
{
    return ($canonical === 'resolved' ? 'complaint_resolved_' : 'complaint_in_progress_') . (int)$complaintId;
}

function gt_complaint_label($complaintId)
{
    return '#' . str_pad((string)(int)$complaintId, 3, '0', STR_PAD_LEFT);
}

function gt_complaint_notification_payload(array $complaint, $canonical)
{
    $id = (int)$complaint['id'];
    $label = gt_complaint_label($id);
    $resolved = $canonical === 'resolved';
    return [
        'type' => $resolved ? 'COMPLAINT_RESOLVED' : 'COMPLAINT_IN_PROGRESS',
        'title' => $resolved ? 'Complaint Resolved' : 'Complaint In Progress',
        'message' => $resolved
            ? "Your complaint $label has been marked as resolved. Tap to view the resolution details."
            : "Your complaint $label is now being reviewed by the barangay administrator. You can check its progress in Complaint History.",
        // Private: only the complaining resident's apps show it (targetRole + resident_id).
        'targetRole' => 'resident',
        'resident_id' => (string)$complaint['resident_id'],
        'complaint_id' => $id,
        'relatedId' => $id,
        'status' => $canonical,
        'category' => (string)($complaint['category'] ?? ''),
        'timestamp' => ['.sv' => 'timestamp'],
        'isRead' => false,
    ];
}

/** Firebase REST call. Returns ['ok' => bool, 'body' => string]. */
function gt_firebase_request($method, $url, $body = null)
{
    if (!function_exists('curl_init')) return ['ok' => false, 'body' => ''];
    try {
        $ch = curl_init($url);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_TIMEOUT, 5);
        if ($method !== 'GET') {
            curl_setopt($ch, CURLOPT_CUSTOMREQUEST, $method);
            curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
            curl_setopt($ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);
        }
        $out = curl_exec($ch);
        $code = function_exists('curl_getinfo') ? (int)curl_getinfo($ch, CURLINFO_HTTP_CODE) : 200;
        curl_close($ch);
        $ok = $out !== false && $code >= 200 && $code < 300 && strpos((string)$out, '"error"') === false;
        return ['ok' => $ok, 'body' => $ok ? (string)$out : ''];
    } catch (Throwable $e) {
        return ['ok' => false, 'body' => ''];
    }
}

/**
 * Writes the complainant's in-app notification for [$canonical] unless it already exists.
 * Returns 'sent' | 'already' | 'failed' | 'skipped'. A failure never undoes the status change;
 * it is logged and reported so the Admin can retry (retrying re-checks the same key).
 */
function gt_complaint_notify(array $complaint, $canonical)
{
    if (!in_array($canonical, ['in_progress', 'resolved'], true)) return 'skipped';
    $rid = trim((string)($complaint['resident_id'] ?? ''));
    if ($rid === '' || $rid === '0') return 'skipped';
    $key = gt_complaint_notification_key($complaint['id'], $canonical);
    $url = GT_FIREBASE_DB_URL . "/notifications/$key.json";

    $existing = gt_firebase_request('GET', $url);
    if ($existing['ok'] && trim($existing['body']) !== '' && trim($existing['body']) !== 'null') return 'already';

    $put = gt_firebase_request('PUT', $url, json_encode(gt_complaint_notification_payload($complaint, $canonical)));
    if ($put['ok']) return 'sent';
    error_log("complaint_lib: complainant notification $key was not accepted by Firebase");
    return 'failed';
}

// ------------------------------------------------------------------ transitions

/** Display name of the acting admin (token subject), or null. */
function gt_complaint_actor_name($conn, $auth)
{
    if (!is_array($auth) || ($auth['role'] ?? '') !== 'admin') return null;
    try {
        $st = $conn->prepare("SELECT name FROM users WHERE user_id = ?");
        $st->execute([$auth['sub']]);
        $row = $st->fetch(PDO::FETCH_ASSOC);
        return $row && !empty($row['name']) ? (string)$row['name'] : null;
    } catch (Throwable $e) {
        return null;
    }
}

/**
 * Applies one lifecycle transition. Only the request whose conditional UPDATE changes the row
 * performs the transition (double clicks, retries and parallel admins cannot repeat it);
 * the notification follows only from that persisted change.
 */
function gt_complaint_transition($conn, $complaintId, $requested, $note, $auth)
{
    $target = gt_complaint_canonical($requested);
    $req = strtolower(trim((string)$requested));
    if ($target === 'pending') {
        return ['success' => false, 'message' => $req === 'pending' || $req === ''
            ? 'A complaint cannot be moved back to Pending.' : 'Unsupported status.'];
    }
    $note = trim((string)$note);
    if (gt_complaint_text_len($note) > GT_COMPLAINT_NOTE_MAX) {
        return ['success' => false, 'message' => 'The note is too long (maximum ' . GT_COMPLAINT_NOTE_MAX . ' characters).'];
    }
    $cols = gt_complaint_columns($conn);
    $idCol = gt_complaint_id_col($cols);
    $row = gt_complaint_fetch($conn, $cols, $complaintId);
    if (!$row) return ['success' => false, 'message' => 'Complaint not found.'];
    $previousRaw = (string)($row['status'] ?? '');
    $previous = gt_complaint_canonical($previousRaw);

    if ($previous === $target) {
        // Already there (double click, retry or another admin): no second transition. The
        // notification is re-checked, so a delivery that failed earlier can be retried.
        return ['success' => true, 'changed' => false, 'message' => $target === 'resolved'
                    ? 'This complaint is already resolved.' : 'This complaint is already in progress.',
                'previous_status' => $previousRaw, 'status' => $target,
                'notification' => gt_complaint_notify($row, $target)];
    }
    if ($previous === 'resolved') {
        return ['success' => false, 'code' => 'ALREADY_RESOLVED', 'previous_status' => $previousRaw,
                'message' => 'This complaint is already resolved. Reopening is not supported.'];
    }
    // Checked only for a real transition, so retrying the notification of an already
    // resolved complaint does not need the note again.
    if ($target === 'resolved' && gt_complaint_text_len($note) < GT_COMPLAINT_NOTE_MIN) {
        return ['success' => false, 'code' => 'NOTE_REQUIRED',
                'message' => 'Please enter a resolution note (at least ' . GT_COMPLAINT_NOTE_MIN . ' characters) describing the action taken.'];
    }

    $actorName = gt_complaint_actor_name($conn, $auth);
    $set = ['status = ?'];
    $params = [gt_complaint_storage_value($conn, $target)];
    // admin_response always existed for this endpoint (the previous version wrote it
    // unconditionally); it holds the resolution note.
    if ($target === 'resolved') { $set[] = 'admin_response = ?'; $params[] = $note; }
    else { $set[] = 'admin_response = COALESCE(?, admin_response)'; $params[] = $note !== '' ? $note : null; }
    if (isset($cols['updated_at'])) $set[] = 'updated_at = NOW()';
    if ($target === 'in_progress' && isset($cols['in_progress_at'])) $set[] = 'in_progress_at = NOW()';
    if ($target === 'resolved') {
        if (isset($cols['resolved_at'])) $set[] = 'resolved_at = NOW()';
        if (isset($cols['resolved_by'])) { $set[] = 'resolved_by = ?'; $params[] = is_array($auth) ? (int)$auth['sub'] : null; }
        if (isset($cols['resolved_by_name'])) { $set[] = 'resolved_by_name = ?'; $params[] = $actorName; }
    }
    $params[] = (int)$complaintId;
    $guard = [];
    $guardSql = gt_complaint_status_sql($target === 'resolved' ? 'active' : 'pending', $guard);
    $sql = "UPDATE complaints SET " . implode(', ', $set) . " WHERE $idCol = ? AND " . str_replace('c.status', 'status', $guardSql);

    $historyTable = gt_complaint_table_exists($conn, 'complaint_status_history');
    $conn->beginTransaction();
    try {
        $st = $conn->prepare($sql);
        $st->execute(array_merge($params, $guard));
        if ($st->rowCount() < 1) {
            $conn->rollBack();
            $now = gt_complaint_fetch($conn, $cols, $complaintId);
            $nowState = $now ? gt_complaint_canonical($now['status'] ?? '') : null;
            if ($nowState === $target) {
                return ['success' => true, 'changed' => false, 'message' => 'Another administrator already made this change.',
                        'previous_status' => (string)($now['status'] ?? ''), 'status' => $target,
                        'notification' => gt_complaint_notify($now, $target)];
            }
            return ['success' => false, 'code' => 'CONFLICT',
                    'message' => 'This complaint was changed by another administrator. Please refresh and try again.'];
        }
        if ($historyTable) {
            $h = $conn->prepare("INSERT INTO complaint_status_history (complaint_id, from_status, to_status, note, changed_by_role, changed_by_id, changed_by_name) VALUES (?, ?, ?, ?, ?, ?, ?)");
            $h->execute([(int)$complaintId, $previous, $target, $note !== '' ? $note : null,
                         is_array($auth) ? (string)$auth['role'] : 'admin', is_array($auth) ? (int)$auth['sub'] : null, $actorName]);
        }
        $conn->commit();
    } catch (Throwable $e) {
        if ($conn->inTransaction()) $conn->rollBack();
        throw $e;
    }

    $row['status'] = $target;
    return ['success' => true, 'changed' => true,
            'message' => $target === 'resolved' ? 'Complaint resolved.' : 'Complaint marked as in progress.',
            'previous_status' => $previousRaw, 'status' => $target,
            'notification' => gt_complaint_notify($row, $target)];
}

/** Status history for the details view: stored events, or events derived from timestamps. */
function gt_complaint_history($conn, array $complaint)
{
    $events = [];
    if (!empty($complaint['created_at'])) {
        $events[] = ['to_status' => 'pending', 'from_status' => null, 'at' => $complaint['created_at'], 'note' => null, 'by' => null, 'derived' => true];
    }
    if (gt_complaint_table_exists($conn, 'complaint_status_history')) {
        $st = $conn->prepare("SELECT from_status, to_status, note, changed_by_name, created_at FROM complaint_status_history WHERE complaint_id = ? ORDER BY history_id ASC");
        $st->execute([(int)$complaint['id']]);
        foreach ($st->fetchAll(PDO::FETCH_ASSOC) as $h) {
            $events[] = ['to_status' => gt_complaint_canonical($h['to_status'] ?? ''), 'from_status' => $h['from_status'] ?? null,
                         'at' => $h['created_at'] ?? null, 'note' => $h['note'] ?? null, 'by' => $h['changed_by_name'] ?? null, 'derived' => false];
        }
        if (count($events) > 1) return $events;
    }
    if (!empty($complaint['in_progress_at'])) {
        $events[] = ['to_status' => 'in_progress', 'from_status' => 'pending', 'at' => $complaint['in_progress_at'], 'note' => null, 'by' => null, 'derived' => true];
    }
    if (!empty($complaint['resolved_at'])) {
        $events[] = ['to_status' => 'resolved', 'from_status' => null, 'at' => $complaint['resolved_at'],
                     'note' => $complaint['admin_response'] ?? null, 'by' => $complaint['resolved_by_name'] ?? null, 'derived' => true];
    }
    return $events;
}
