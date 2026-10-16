<?php
/**
 * Small server-side rate limiter (brute force / OTP abuse protection).
 *
 * Counts events per (bucket, key) in short JSON files outside the web root when possible
 * (falls back to the system temp dir). No database table is needed.
 *
 *   gt_rl_blocked($bucket, $key, $max, $windowSec)  -> seconds to wait (0 = allowed)
 *   gt_rl_hit($bucket, $key, $windowSec)             record one event
 *   gt_rl_clear($bucket, $key)                       forget (e.g. after a successful login)
 */

function gt_rl_dir()
{
    static $dir = null;
    if ($dir !== null) return $dir;
    $candidates = [dirname(__DIR__, 2) . DIRECTORY_SEPARATOR . 'gt_private' . DIRECTORY_SEPARATOR . 'ratelimit',
                   rtrim(sys_get_temp_dir(), '/\\') . DIRECTORY_SEPARATOR . 'gt_ratelimit'];
    foreach ($candidates as $c) {
        if ((is_dir($c) || @mkdir($c, 0700, true)) && is_writable($c)) {
            return $dir = $c;
        }
    }
    return $dir = '';
}

function gt_rl_file($bucket, $key)
{
    $d = gt_rl_dir();
    if ($d === '') return null;
    return $d . DIRECTORY_SEPARATOR . preg_replace('/[^a-z_]/', '', $bucket) . '_' . hash('sha256', strtolower(trim((string)$key))) . '.json';
}

/** Timestamps of events still inside the window. */
function gt_rl_events($file, $windowSec, $now)
{
    if ($file === null || !is_file($file)) return [];
    $raw = @file_get_contents($file);
    $list = $raw ? json_decode($raw, true) : [];
    if (!is_array($list)) return [];
    return array_values(array_filter($list, function ($t) use ($now, $windowSec) { return is_int($t) && $t > $now - $windowSec; }));
}

function gt_rl_blocked($bucket, $key, $max, $windowSec)
{
    $now = time();
    $events = gt_rl_events(gt_rl_file($bucket, $key), $windowSec, $now);
    if (count($events) < $max) return 0;
    sort($events);
    // Wait until the oldest counted event leaves the window.
    return max(1, $events[count($events) - $max] + $windowSec - $now);
}

function gt_rl_hit($bucket, $key, $windowSec)
{
    $file = gt_rl_file($bucket, $key);
    if ($file === null) return;
    $now = time();
    $events = gt_rl_events($file, $windowSec, $now);
    $events[] = $now;
    @file_put_contents($file, json_encode(array_slice($events, -100)), LOCK_EX);
}

function gt_rl_clear($bucket, $key)
{
    $file = gt_rl_file($bucket, $key);
    if ($file !== null && is_file($file)) @unlink($file);
}

function gt_client_ip()
{
    return (string)($_SERVER['REMOTE_ADDR'] ?? 'unknown');
}

/** "3 minutes" / "1 minute" */
function gt_rl_wait_text($sec)
{
    $m = (int)ceil($sec / 60);
    return $m <= 1 ? '1 minute' : "$m minutes";
}
