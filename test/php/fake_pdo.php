<?php
/**
 * Minimal in-memory stand-in for PDO, just enough SQL for the account/complaint
 * endpoints. TEST ONLY: it never touches MySQL, Hostinger or Firebase.
 */

class FakeDuplicateException extends PDOException
{
    protected $code = '23000';
}

class FakeStmt
{
    private $rows = [];
    private $pos = 0;
    public $rowCountValue = 0;

    public function __construct(array $rows = [], int $rowCount = 0)
    {
        $this->rows = $rows;
        $this->rowCountValue = $rowCount;
    }
    public function execute($params = null) { return true; }
    public function fetch($mode = null)
    {
        if ($this->pos >= count($this->rows)) return false;
        return $this->rows[$this->pos++];
    }
    public function fetchAll($mode = null)
    {
        if ($mode === PDO::FETCH_COLUMN) {
            return array_map(function ($r) { return reset($r); }, $this->rows);
        }
        return $this->rows;
    }
    public function rowCount() { return $this->rowCountValue; }
    public function fetchColumn($i = 0) { $r = $this->fetch(); if (!is_array($r)) return false; $v = array_values($r); return $v[$i] ?? false; }
}

class FakeBoundStmt
{
    private $conn;
    private $sql;
    private $result;
    public function __construct($conn, $sql) { $this->conn = $conn; $this->sql = $sql; }
    public function execute($params = [])
    {
        $this->result = $this->conn->run($this->sql, array_values($params ?? []));
        return true;
    }
    public function fetch($mode = null) { return $this->result ? $this->result->fetch($mode) : false; }
    public function fetchAll($mode = null) { return $this->result ? $this->result->fetchAll($mode) : []; }
    public function rowCount() { return $this->result ? $this->result->rowCount() : 0; }
    public function fetchColumn($i = 0) { return $this->result ? $this->result->fetchColumn($i) : false; }
}

class FakeConn
{
    public $tables;
    private $stateFile;
    public $lastId = 0;
    /** @var array<string,string[]> */
    private $unique = [
        'users' => ['username', 'email'],
        'residents' => ['username', 'email'],
        'driver_trip_history' => ['trip_id'],
        'route_assignments' => ['driver_day_key', 'truck_day_key'],
        'route_assignment_trips' => ['trip_id'],
    ];
    private $inTx = false;
    private $txSnapshot = null;
    private $idCol = ['users' => 'user_id', 'residents' => 'resident_id', 'complaints' => 'complaint_id', 'access_logs' => 'log_id', 'driver_trip_history' => 'row_id', 'route_assignments' => 'assignment_id', 'route_assignment_areas' => 'row_id', 'route_assignment_trips' => 'row_id', 'auth_sessions' => 'row_id', 'complaint_status_history' => 'history_id'];

    public function __construct($stateFile)
    {
        $this->stateFile = $stateFile;
        $this->tables = is_file($stateFile) ? unserialize(file_get_contents($stateFile)) : [];
        foreach (['users', 'residents', 'complaints', 'access_logs', 'password_resets', 'driver_trip_history', 'route_assignments', 'route_assignment_areas', 'route_assignment_trips', 'auth_sessions', 'complaint_status_history'] as $t) {
            if (!isset($this->tables[$t])) $this->tables[$t] = [];
        }
        register_shutdown_function([$this, 'save']);
    }
    public function save() { file_put_contents($this->stateFile, serialize($this->tables)); }
    public function setAttribute($a, $v) {}
    public function exec($sql) { return 0; }
    public function lastInsertId() { return (string)$this->lastId; }
    public function beginTransaction()
    {
        // GT_FAKE_RACE_STATUS: another administrator commits a complaint status change after
        // this request read the row and before its transaction starts.
        if (getenv('GT_FAKE_RACE_STATUS')) {
            foreach ($this->tables['complaints'] as $i => $row) $this->tables['complaints'][$i]['status'] = getenv('GT_FAKE_RACE_STATUS');
        }
        $this->inTx = true;
        $this->txSnapshot = $this->tables;
        return true;
    }
    public function commit() { $this->inTx = false; $this->txSnapshot = null; return true; }
    public function rollBack() { if ($this->txSnapshot !== null) $this->tables = $this->txSnapshot; $this->inTx = false; $this->txSnapshot = null; return true; }
    public function inTransaction() { return $this->inTx; }

    public function prepare($sql) { return new FakeBoundStmt($this, $sql); }
    public function query($sql) { return $this->run($sql, []); }

    private function literal($tok, &$params)
    {
        $tok = trim($tok);
        if ($tok === '?') return array_shift($params);
        if (preg_match("/^'(.*)'$/s", $tok, $m)) return $m[1];
        if (is_numeric($tok)) return $tok + 0;
        if (strtoupper($tok) === 'NULL') return null;
        return $tok;
    }

    private function matches($row, $where, &$params)
    {
        return $this->evalExpr($row, $where, $params);
    }

    /** Splits on a top-level separator (" OR ", " AND " or ","), ignoring parentheses and quotes. */
    private function splitTop($expr, $sep)
    {
        $parts = [];
        $buf = '';
        $depth = 0;
        $inQ = false;
        $tok = $sep === ',' ? ',' : " $sep ";
        $n = strlen($expr);
        for ($i = 0; $i < $n; $i++) {
            $ch = $expr[$i];
            if ($ch === "'") $inQ = !$inQ;
            if (!$inQ) {
                if ($ch === '(') $depth++;
                elseif ($ch === ')') $depth--;
                elseif ($depth === 0 && strcasecmp(substr($expr, $i, strlen($tok)), $tok) === 0) {
                    $parts[] = trim($buf);
                    $buf = '';
                    $i += strlen($tok) - 1;
                    continue;
                }
            }
            $buf .= $ch;
        }
        $parts[] = trim($buf);
        return $parts;
    }

    /** "(x)" -> "x" when the outer parentheses enclose the whole term. */
    private function stripParens($t)
    {
        while (strlen($t) >= 2 && $t[0] === '(' && substr($t, -1) === ')') {
            $depth = 0;
            for ($i = 0, $n = strlen($t); $i < $n; $i++) {
                if ($t[$i] === '(') $depth++;
                elseif ($t[$i] === ')' && --$depth === 0 && $i < $n - 1) return $t;
            }
            $t = trim(substr($t, 1, -1));
        }
        return $t;
    }

    /** OR of ANDs with nested parentheses; every parameter is consumed in order. */
    private function evalExpr($row, $expr, &$params)
    {
        $any = false;
        foreach ($this->splitTop(trim($expr), 'OR') as $orPart) {
            $all = true;
            foreach ($this->splitTop($orPart, 'AND') as $cond) {
                if (!$this->evalCond($row, $cond, $params)) $all = false;
            }
            if ($all) $any = true;
        }
        return $any;
    }

    /** Column value; "alias.col" keys (joined rows) win over plain "col". */
    private function colVal($row, $alias, $col)
    {
        if ($alias !== '' && array_key_exists("$alias.$col", $row)) return $row["$alias.$col"];
        return $row[$col] ?? null;
    }

    private function evalCond($row, $cond, &$params)
    {
        $cond = trim($cond);
        $inner = $this->stripParens($cond);
        if ($inner !== $cond) return $this->evalExpr($row, $inner, $params);
        $C = '(?:(\w+)\.)?(\w+)';
        if (preg_match("/^$C\s+IS\s+(NOT\s+)?NULL$/i", $cond, $m)) {
            $v = $this->colVal($row, $m[1], $m[2]);
            $isNull = $v === null || $v === '';
            return empty($m[3]) ? $isNull : !$isNull;
        }
        if (preg_match("/^$C\s+LIKE\s+(.+)$/i", $cond, $m)) {
            $pat = (string)$this->literal($m[3], $params);
            $re = '/^' . str_replace('%', '.*', preg_quote(rtrim($pat, '%'), '/')) . (substr($pat, -1) === '%' ? '.*' : '') . '$/i';
            return (bool)preg_match($re, (string)($this->colVal($row, $m[1], $m[2]) ?? ''));
        }
        if (preg_match("/^$C\s+(NOT\s+)?IN\s*\((.*)\)$/i", $cond, $m)) {
            $found = false;
            foreach (explode(',', $m[4]) as $tok) {
                $v = $this->literal(trim($tok), $params);
                if ((string)($this->colVal($row, $m[1], $m[2]) ?? '') === (string)$v) $found = true;
            }
            return empty($m[3]) ? $found : !$found;
        }
        if (preg_match("/^$C\s*(>=|<=|>|<)\s*(.+)$/", $cond, $m)) {
            $val = (string)$this->literal($m[4], $params);
            $cmp = strcmp((string)($this->colVal($row, $m[1], $m[2]) ?? ''), $val);
            return ['>' => $cmp > 0, '<' => $cmp < 0, '>=' => $cmp >= 0, '<=' => $cmp <= 0][$m[3]];
        }
        if (preg_match("/^$C\s*=\s*(.+)$/", $cond, $m)) {
            $val = $this->literal($m[3], $params);
            return (string)($this->colVal($row, $m[1], $m[2]) ?? '') === (string)$val;
        }
        throw new RuntimeException("Unsupported condition: $cond");
    }

    /** Value of "c.col", "col" or "COALESCE(a, b)" in a joined row. */
    private function refVal($row, $expr)
    {
        $expr = trim($expr);
        if (preg_match('/^COALESCE\((.*)\)$/i', $expr, $m)) {
            foreach ($this->splitTop($m[1], ',') as $part) {
                $v = $this->refVal($row, $part);
                if ($v !== null && $v !== '') return $v;
            }
            return null;
        }
        if (preg_match('/^(?:(\w+)\.)?(\w+)$/', $expr, $m)) return $this->colVal($row, $m[1], $m[2]);
        throw new RuntimeException("Unsupported expression: $expr");
    }

    /** complaint_center.php: complaints c LEFT JOIN residents r, WHERE / ORDER BY / LIMIT / COUNT. */
    private function complaintCenter($sql, array $params)
    {
        if (!preg_match('/^SELECT \/\*gt:complaint_center\*\/ (.*?) FROM complaints c LEFT JOIN residents r ON c\.(\w+) = r\.resident_id WHERE (.*?)(?: ORDER BY (.*?))?(?: LIMIT (\d+)(?: OFFSET (\d+))?)?$/i', $sql, $m)) {
            throw new RuntimeException("Unsupported complaint center SQL: $sql");
        }
        $owner = $m[2];
        $residents = [];
        foreach ($this->tables['residents'] as $r) $residents[(string)$r['resident_id']] = $r;
        $rows = [];
        foreach ($this->tables['complaints'] as $c) {
            $row = [];
            foreach ($c as $k => $v) { $row[$k] = $v; $row["c.$k"] = $v; }
            foreach ($residents[(string)($c[$owner] ?? '')] ?? [] as $k => $v) $row["r.$k"] = $v;
            foreach (['name', 'purok'] as $rk) if (!array_key_exists("r.$rk", $row)) $row["r.$rk"] = null;
            $p = $params;
            if ($this->evalExpr($row, $m[3], $p)) $rows[] = $row;
        }
        if (!empty($m[4])) {
            $order = [];
            foreach ($this->splitTop($m[4], ',') as $item) {
                preg_match('/^(.*?)(?:\s+(ASC|DESC))?$/i', trim($item), $om);
                $order[] = [$om[1], strtoupper($om[2] ?? 'ASC') === 'DESC' ? -1 : 1];
            }
            usort($rows, function ($a, $b) use ($order) {
                foreach ($order as [$expr, $dir]) {
                    $x = $this->refVal($a, $expr);
                    $y = $this->refVal($b, $expr);
                    $cmp = is_numeric($x) && is_numeric($y) ? ($x <=> $y) : strcmp((string)$x, (string)$y);
                    if ($cmp !== 0) return $cmp * $dir;
                }
                return 0;
            });
        }
        if (preg_match('/^COUNT\(\*\) AS (\w+)$/i', trim($m[1]), $cm)) {
            return new FakeStmt([[$cm[1] => count($rows)]]);
        }
        $rows = array_slice($rows, isset($m[6]) ? (int)$m[6] : 0, isset($m[5]) && $m[5] !== '' ? (int)$m[5] : null);
        $out = [];
        foreach ($rows as $row) {
            $proj = [];
            foreach ($this->splitTop($m[1], ',') as $item) {
                if (!preg_match('/^(.*?)\s+AS\s+(\w+)$/i', $item, $im)) throw new RuntimeException("Unsupported select item: $item");
                $proj[$im[2]] = $this->refVal($row, $im[1]);
            }
            $out[] = $proj;
        }
        return new FakeStmt($out);
    }

    public function run($sql, array $params)
    {
        $sql = trim(preg_replace('/\s+/', ' ', $sql));
        // Like MySQL: a SELECT naming a driver_trip_history column the (simulated older) server
        // does not have fails with "Unknown column".
        if (stripos($sql, 'SELECT') === 0 && !empty($GLOBALS['FAKE_MISSING_COLUMNS']) && stripos($sql, 'driver_trip_history h') !== false) {
            foreach ($GLOBALS['FAKE_MISSING_COLUMNS'] as $mc) {
                if (preg_match('/h\.' . preg_quote($mc, '/') . '/', $sql)) {
                    throw new PDOException("SQLSTATE[42S22]: Column not found: 1054 Unknown column 'h.$mc'");
                }
            }
        }

        if (preg_match("/^SHOW TABLES LIKE '(\w+)'$/i", $sql, $m)) {
            $known = ['users', 'residents', 'complaints', 'access_logs', 'password_resets', 'driver_trip_history'];
            if (getenv('GT_FAKE_NO_ASSIGNMENT_TABLES') !== '1') {
                $known = array_merge($known, ['route_assignments', 'route_assignment_areas', 'route_assignment_trips']);
            }
            if (getenv('GT_FAKE_NO_SESSION_TABLES') !== '1') $known[] = 'auth_sessions';
            // The complaint lifecycle migration is NOT applied in production; tests opt in.
            if (getenv('GT_FAKE_COMPLAINT_HISTORY') === '1') $known[] = 'complaint_status_history';
            return new FakeStmt([], in_array($m[1], $known, true) ? 1 : 0);
        }
        if (stripos($sql, 'GET_LOCK') !== false || stripos($sql, 'RELEASE_LOCK') !== false || stripos($sql, 'DATE_FORMAT') !== false) {
            return new FakeStmt();
        }

        if (preg_match("/^SHOW COLUMNS FROM complaints LIKE 'status'$/i", $sql)) {
            return new FakeStmt([['Field' => 'status', 'Type' => getenv('GT_FAKE_STATUS_TYPE') ?: 'varchar(20)']]);
        }
        if (preg_match("/^SHOW COLUMNS FROM complaints LIKE 'is_archived'$/i", $sql)) {
            $has = false;
            foreach ($this->tables['complaints'] as $c) if (array_key_exists('is_archived', $c)) $has = true;
            return new FakeStmt($has ? [['Field' => 'is_archived', 'Type' => 'tinyint(1)']] : []);
        }
        if (strpos($sql, '/*gt:complaint_counts*/') !== false) {
            $skipArchived = stripos($sql, 'is_archived') !== false;
            $by = [];
            foreach ($this->tables['complaints'] as $c) {
                if ($skipArchived && !empty($c['is_archived'])) continue;
                $k = (string)($c['status'] ?? ''); $by[$k] = ($by[$k] ?? 0) + 1;
            }
            $out = [];
            foreach ($by as $k => $n) $out[] = ['status' => $k, 'n' => $n];
            return new FakeStmt($out);
        }
        if (strpos($sql, '/*gt:complaint_center*/') !== false) {
            return $this->complaintCenter($sql, $params);
        }

        if (preg_match('/^DESCRIBE driver_trip_history$/i', $sql)) {
            $cols = ['trip_id', 'driver_id', 'driver_name', 'truck_id', 'route_name', 'route_status', 'start_time', 'end_time',
                     'full_time', 'start_lat', 'start_lng', 'finish_lat', 'finish_lng', 'total_distance_km',
                     'moving_time_seconds', 'stopped_time_seconds', 'detected_stops_count', 'weight_kg', 'weight_type',
                     'areas_visited', 'created_at'];
            $missing = $GLOBALS['FAKE_MISSING_COLUMNS'] ?? [];
            $cols = array_values(array_diff($cols, $missing));
            return new FakeStmt(array_map(function ($c) { return ['Field' => $c]; }, $cols));
        }

        if (preg_match('/^DESCRIBE (\w+)$/i', $sql, $m)) {
            $cols = [];
            foreach ($this->tables[$m[1]] as $r) { foreach (array_keys($r) as $c) $cols[$c] = true; }
            if (!$cols) $cols = array_fill_keys(['complaint_id', 'resident_id', 'category', 'description', 'status', 'admin_response', 'purok', 'location', 'created_at'], true);
            if ($m[1] === 'complaints') foreach (array_filter(explode(',', getenv('GT_FAKE_COMPLAINT_MISSING') ?: '')) as $missing) unset($cols[$missing]);
            return new FakeStmt(array_map(function ($c) { return ['Field' => $c]; }, array_keys($cols)));
        }

        if (preg_match('/^INSERT INTO (\w+) \((.*?)\) VALUES \((.*)\)$/i', $sql, $m)) {
            $table = $m[1];
            $cols = array_map('trim', explode(',', $m[2]));
            $vals = array_map('trim', explode(',', $m[3]));
            $row = [];
            foreach ($cols as $i => $c) $row[$c] = $this->literal($vals[$i], $params);
            foreach ($this->unique[$table] ?? [] as $u) {
                if (($row[$u] ?? '') === '' || $row[$u] === null) continue;
                foreach ($this->tables[$table] as $existing) {
                    if (($existing[$u] ?? null) === $row[$u]) throw new FakeDuplicateException("Duplicate entry for $u");
                }
            }
            $idc = $this->idCol[$table] ?? 'id';
            $this->lastId = count($this->tables[$table]) + 1;
            $row[$idc] = $this->lastId;
            $row['created_at'] = '2026-10-12 08:00:00';
            $this->tables[$table][] = $row;
            return new FakeStmt([], 1);
        }

        if (preg_match('/^DELETE FROM (\w+) WHERE (.*)$/i', $sql, $m)) {
            $removed = 0;
            foreach ($this->tables[$m[1]] as $i => $row) {
                $p = $params;
                if ($this->matches($row, $m[2], $p)) {
                    unset($this->tables[$m[1]][$i]);
                    $removed++;
                }
            }
            $this->tables[$m[1]] = array_values($this->tables[$m[1]]);
            return new FakeStmt([], $removed);
        }

        if (preg_match('/^UPDATE (\w+) SET (.*?) WHERE (.*)$/i', $sql, $m)) {
            $table = $m[1];
            $sets = array_map('trim', preg_split('/,(?![^()]*\))/', $m[2]));
            $assign = [];
            foreach ($sets as $s) {
                [$col, $tok] = array_map('trim', explode('=', $s, 2));
                if (preg_match('/^COALESCE\(\?, (\w+)\)$/', $tok, $cm)) {
                    $assign[$col] = ['__coalesce', array_shift($params), $cm[1]];
                } else {
                    $assign[$col] = $this->literal($tok, $params);
                }
            }
            if (!$this->tables[$table] && false) throw new PDOException('no table');
            // Unknown-column simulation for legacy schema tests.
            if (!empty($GLOBALS['FAKE_MISSING_COLUMNS'])) {
                foreach (array_keys($assign) as $c) {
                    if (in_array($c, $GLOBALS['FAKE_MISSING_COLUMNS'], true)) {
                        throw new PDOException("Unknown column '$c'");
                    }
                }
            }
            $changed = 0;
            foreach ($this->tables[$table] as $i => $row) {
                $p = $params;
                if ($this->matches($row, $m[3], $p)) {
                    foreach ($assign as $c => $v) {
                        if (is_array($v) && ($v[0] ?? null) === '__coalesce') {
                            $v = $v[1] !== null ? $v[1] : ($row[$v[2]] ?? null);
                        }
                        if (($row[$c] ?? null) !== $v) $changed++;
                        $this->tables[$table][$i][$c] = $v;
                    }
                }
            }
            return new FakeStmt([], $changed);
        }

        // get_complaints.php: complaints c LEFT JOIN residents r (optionally WHERE <resident col> = ?)
        if (preg_match('/FROM complaints c LEFT JOIN residents r ON (\S+) = r\.resident_id/i', $sql, $jm)) {
            // WHERE may hold the archived filter (admin list) and/or the resident filter, joined by AND.
            $jm[2] = preg_match('/ WHERE .*?(\w+\.\w+) = \?/i', $sql, $wm) ? $wm[1] : '';
            $skipArchived = stripos($sql, 'c.is_archived IS NULL') !== false;
            $missing = array_filter(explode(',', getenv('GT_FAKE_COMPLAINT_MISSING') ?: ''));
            $residents = [];
            foreach ($this->tables['residents'] as $r) $residents[(string)$r['resident_id']] = $r;
            $out = [];
            foreach ($this->tables['complaints'] as $c) {
                $rid = (string)($c['resident_id'] ?? '');
                if (!empty($jm[2]) && $rid !== (string)($params[0] ?? '')) continue;
                if ($skipArchived && !empty($c['is_archived'])) continue;
                $r = $residents[$rid] ?? null;
                $cPurok = in_array('purok', $missing, true) ? '' : ($c['purok'] ?? '');
                $out[] = [
                    'id' => $c['complaint_id'] ?? null,
                    'complaint_id' => $c['complaint_id'] ?? null,
                    'user_id' => $c['resident_id'] ?? null,
                    'resident_id' => $c['resident_id'] ?? null,
                    'category' => $c['category'] ?? null,
                    'description' => $c['description'] ?? null,
                    'status' => $c['status'] ?? null,
                    'admin_response' => $c['admin_response'] ?? '',
                    'created_at' => $c['created_at'] ?? null,
                    'is_archived' => $c['is_archived'] ?? 0,
                    'deleted_by_resident' => $c['deleted_by_resident'] ?? 0,
                    'location' => in_array('location', $missing, true) ? '' : ($c['location'] ?? ''),
                    'full_name' => $r['name'] ?? 'Unknown Resident',
                    'purok' => $cPurok !== '' ? $cPurok : ($r['purok'] ?? 'Unknown'),
                ];
            }
            usort($out, function ($a, $b) { return (int)$b['id'] <=> (int)$a['id']; });
            return new FakeStmt($out);
        }

        if (preg_match('/^SELECT (.*?) FROM (\w+)(?: (\w+))?(?: LEFT JOIN .*?)?(?: WHERE (.*?))?(?: ORDER BY .*?)?(?: LIMIT (\d+))?$/i', $sql, $m)) {
            [$all, $colsRaw, $table] = $m;
            $where = $m[4] ?? '';
            $limit = isset($m[5]) && $m[5] !== '' ? (int)$m[5] : PHP_INT_MAX;
            if (!empty($GLOBALS['FAKE_MISSING_COLUMNS'])) {
                foreach ($GLOBALS['FAKE_MISSING_COLUMNS'] as $c) {
                    if (preg_match('/\b' . preg_quote($c, '/') . '\b/', $colsRaw)) {
                        throw new PDOException("Unknown column '$c' (select from $table: " . substr($sql, 0, 160) . ")");
                    }
                }
            }
            $out = [];
            foreach ($this->tables[$table] as $row) {
                $p = $params;
                if ($where !== '' && !$this->matches($row, $where, $p)) continue;
                $proj = [];
                foreach (preg_split('/\s*,\s*/', $colsRaw) as $item) {
                    if ($item === '*') { $proj = $row; continue; }
                    if (preg_match("/^(.+?)\s+as\s+(\w+)$/i", $item, $im)) {
                        $src = trim($im[1]);
                        $proj[$im[2]] = preg_match("/^'(.*)'$/", $src, $lm) ? $lm[1] : ($row[$src] ?? null);
                    } elseif ($item === '1') {
                        $proj['1'] = 1;
                    } else {
                        $name = preg_replace('/^\w+\./', '', $item);
                        $proj[$name] = $row[$name] ?? null;
                    }
                }
                $out[] = $proj;
                if (count($out) >= $limit) break;
            }
            return new FakeStmt($out);
        }

        throw new RuntimeException("Unsupported SQL in fake PDO: $sql");
    }
}
