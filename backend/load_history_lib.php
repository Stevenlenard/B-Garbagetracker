<?php
/**
 * Pure helpers for Load History / Waste Collection Summary (no database access).
 *
 * One load record = ONE finalized collection trip (FULL, or a legacy COMPLETED trip).
 * Unfinished (ACTIVE/PAUSED/INTERRUPTED) trips are never loads, and a trip appears once
 * however many tables/rows mention it.
 */

/** FULL (or later) means the collection was finalized. */
function gt_is_finalized_trip(array $row)
{
    $status = strtoupper((string)($row['route_status'] ?? ''));
    if (in_array($status, ['FULL', 'COMPLETED', 'FINISHED'], true)) return true;
    return !empty($row['full_time']) && $row['full_time'] !== '0000-00-00 00:00:00';
}

/** Rows -> finalized, unique per trip_id (the richest row wins: FULL time + load known). */
function gt_unique_finalized_trips(array $rows)
{
    $byId = [];
    foreach ($rows as $r) {
        if (!gt_is_finalized_trip($r)) continue;
        $id = (string)($r['trip_id'] ?? '');
        if ($id === '') continue;
        if (!isset($byId[$id])) {
            $byId[$id] = $r;
            continue;
        }
        $score = function ($x) {
            return (empty($x['full_time']) ? 0 : 2) + (isset($x['weight_kg']) ? 1 : 0)
                 + ((float)($x['total_distance_km'] ?? 0) > 0 ? 1 : 0);
        };
        if ($score($r) > $score($byId[$id])) $byId[$id] = $r;
    }
    return array_values($byId);
}

/** Weight of one load in kg: the stored estimate/measurement, otherwise the 5 t default. */
function gt_trip_weight_kg(array $t)
{
    return (isset($t['weight_kg']) && is_numeric($t['weight_kg'])) ? (float)$t['weight_kg'] : 5000.0;
}

function gt_trip_weight_type(array $t)
{
    return strtoupper((string)($t['weight_type'] ?? 'ESTIMATED')) === 'MEASURED' ? 'MEASURED' : 'ESTIMATED';
}

/** Period summary over finalized unique trips. */
function gt_summarize_loads(array $trips)
{
    $kg = 0.0;
    $measured = 0;
    $estimated = 0;
    foreach ($trips as $t) {
        $kg += gt_trip_weight_kg($t);
        if (gt_trip_weight_type($t) === 'MEASURED') $measured++; else $estimated++;
    }
    $n = count($trips);
    return [
        'total_trips' => $n,
        'total_weight_kg' => $kg,
        'total_weight_tons' => round($kg / 1000.0, 2),
        'estimated_trips_count' => $estimated,
        'measured_trips_count' => $measured,
        'is_all_estimated' => ($measured === 0 && $n > 0),
        'is_all_measured' => ($estimated === 0 && $n > 0),
    ];
}

/** Jan..Dec buckets for one year over finalized unique trips (same trip never twice). */
function gt_monthly_buckets(array $trips, $year)
{
    $labels = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    $kg = array_fill(1, 12, 0.0);
    $cnt = array_fill(1, 12, 0);
    foreach ($trips as $t) {
        $when = $t['full_time'] ?? $t['start_time'] ?? $t['created_at'] ?? null;
        $ts = $when ? strtotime((string)$when) : false;
        if (!$ts || (int)date('Y', $ts) !== (int)$year) continue;
        $m = (int)date('n', $ts);
        $kg[$m] += gt_trip_weight_kg($t);
        $cnt[$m]++;
    }
    $out = [];
    for ($m = 1; $m <= 12; $m++) {
        $has = $cnt[$m] > 0;
        $tons = $has ? round($kg[$m] / 1000.0, 2) : 0.0;
        $out[] = [
            'month_number' => $m,
            'month_label' => $labels[$m - 1],
            'has_data' => $has,
            'trip_count' => $cnt[$m],
            'total_weight_kg' => $kg[$m],
            'total_weight_tons' => $tons,
            'display_label' => $has ? "{$tons} tons" : "No data",
        ];
    }
    return $out;
}
