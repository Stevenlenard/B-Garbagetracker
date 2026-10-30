<?php
/**
 * AI explanation of the predictive models (Admin).
 *
 * The app sends ONLY the evaluation numbers it already shows (MAE, RMSE, R², sample counts, the live-rule comparison
 * and the moving-average results); no names, places or records. The model explains them in plain words, in English
 * or Tagalog (lang=tl), says why the results look this way and what would improve them. The predictions themselves
 * stay statistical: the AI only interprets them. Answers are cached by the AI loader, so the same numbers cost no
 * second request.
 *
 * POST JSON {lang: "en"|"tl", arrival: {...}, load: {...}}  ->  {success, ai, arrival: {...}, load: {...}}
 */
header("Content-Type: application/json");
header("Cache-Control: no-store");
require_once 'db_config.php';
require_once 'auth_token.php';
$gtAuth = gt_guard(['admin']);

require_once 'ai_config_loader.php';

/** Keeps only the listed numeric fields, rounded; anything else in the request is ignored. */
function gt_explain_numbers($in, array $fields): array
{
    $out = [];
    if (!is_array($in)) return $out;
    foreach ($fields as $f) {
        if (!isset($in[$f]) || !is_numeric($in[$f])) continue;
        $v = (float)$in[$f];
        if (!is_finite($v)) continue;
        $out[$f] = round($v, 3);
    }
    return $out;
}

function gt_explain_clip($s, int $max): string
{
    $s = trim(preg_replace('/\s+/u', ' ', (string)$s));
    if ((function_exists('mb_strlen') ? mb_strlen($s, 'UTF-8') : strlen($s)) <= $max) return $s;
    return (function_exists('mb_substr') ? mb_substr($s, 0, $max, 'UTF-8') : substr($s, 0, $max)) . '…';
}

function gt_explain_part($p): ?array
{
    if (!is_array($p)) return null;
    $meaning = gt_explain_clip($p['meaning'] ?? '', 700);
    if ($meaning === '') return null;
    $rel = strtolower((string)($p['reliability'] ?? ''));
    return [
        'meaning' => $meaning,
        'why' => gt_explain_clip($p['why'] ?? '', 700),
        'next' => array_values(array_filter(array_map(fn($x) => gt_explain_clip(is_string($x) ? $x : '', 260), array_slice((array)($p['next'] ?? []), 0, 4)))),
        'reliability' => in_array($rel, ['low', 'medium', 'high'], true) ? $rel : 'low',
        'reliability_note' => gt_explain_clip($p['reliability_note'] ?? '', 300),
    ];
}

$body = json_decode(file_get_contents('php://input'), true);
$lang = (is_array($body) && ($body['lang'] ?? '') === 'tl') ? 'tl' : 'en';
$arrival = gt_explain_numbers($body['arrival'] ?? null, [
    'recorded_trips', 'samples', 'test_samples', 'mae_min', 'rmse_min', 'r2', 'intercept_min', 'slope_min_per_km',
    'live_rule_mae_min', 'live_rule_rmse_min', 'live_rule_r2', 'resident_estimates_checked', 'resident_estimates_mae_min',
]);
$load = gt_explain_numbers($body['load'] ?? null, [
    'window_days', 'days_in_period', 'days_with_loads', 'checked_days', 'mae_kg', 'rmse_kg', 'r2', 'next_day_forecast_kg',
]);

$out = ['success' => true, 'ai' => false, 'lang' => $lang];
$ai_cfg = gt_ai_config();
if (!$ai_cfg['enabled'] || (!$arrival && !$load)) {
    echo json_encode($out);
    exit;
}

$language = $lang === 'tl'
    ? "Write in simple Filipino (Tagalog) that barangay staff can easily understand; keep common technical words such as MAE, RMSE, R², " .
      "regression, trip and GPS in English (natural Taglish). Avoid deep or formal Tagalog words."
    : "Write in plain, simple English that barangay staff without a statistics background can understand.";

$prompt = "You explain the predictive models of a barangay garbage truck tracking system to its administrator. " .
    "Model 1, arrival time: a linear regression that predicts how many minutes the truck needs to reach a collection area from its distance " .
    "(minutes = intercept + slope x distance), tested on trips it did not learn from, and compared with the live rule (distance divided by recent " .
    "speed) on the same samples. Model 2, collected load: a moving average of the daily collected weight, checked by forecasting each day from the " .
    "days before it. MAE is the average error, RMSE punishes big misses more, R² compares the model with always predicting the average " .
    "(1 is perfect, 0 is no better than the average, below 0 is worse than the average). " .
    "Using ONLY the numbers below, explain for each model: what the numbers mean in everyday words with the actual values, why the results look " .
    "this way (for example few trips, short test trips, few days with loads), 2 to 4 practical next steps that the barangay staff and drivers " .
    "themselves can do (such as recording more real collection trips with GPS on, recording the scale weight of each load, or relying on the " .
    "better of the two methods for now), and how much the administrator can rely on it now. Do not suggest changing algorithms or software. " .
    "Do not invent numbers, targets, dates, places or causes that the numbers do not support; when a value is missing, say there is not enough " .
    "data yet. $language " .
    "Reply with JSON only, in this shape: {\"arrival\":{\"meaning\":\"2-3 sentences\",\"why\":\"1-2 sentences\",\"next\":[\"step\"]," .
    "\"reliability\":\"low|medium|high\",\"reliability_note\":\"1 sentence\"},\"load\":{same fields}}. " .
    "Arrival time numbers: " . json_encode($arrival ?: (object)[]) . ". Collected load numbers: " . json_encode($load ?: (object)[]) . ".";

$text = gt_ai_generate($ai_cfg, $prompt, ['responseMimeType' => 'application/json', 'temperature' => 0.3, 'maxOutputTokens' => 1600], 15);
$data = $text !== null ? json_decode(preg_replace('/^```(?:json)?\s*|\s*```$/', '', trim($text)), true) : null;
if (is_array($data)) {
    $a = $arrival ? gt_explain_part($data['arrival'] ?? null) : null;
    $l = $load ? gt_explain_part($data['load'] ?? null) : null;
    if ($a) $out['arrival'] = $a;
    if ($l) $out['load'] = $l;
    $out['ai'] = (bool)($a || $l);
}
echo json_encode($out);
