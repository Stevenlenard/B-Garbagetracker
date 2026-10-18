<?php
/**
 * Server-side AI (Gemini) configuration. Contains NO secret.
 *
 * AI is DISABLED unless ALL of these are set:
 *   enabled = true, api_key = non-empty, model = non-empty.
 *
 * Sources (first found wins):
 *  1. Environment variables: GT_AI_ENABLED (true/1), GT_GEMINI_API_KEY, GT_GEMINI_MODEL.
 *  2. A private PHP file OUTSIDE the public web root, never in git:
 *       <site folder>/gt_private/ai_config.php   (one level above public_html)
 *     returning ['enabled' => false, 'api_key' => '', 'model' => ''].
 *     See deploy_prep/hostinger/gt_private/ai_config.example.php.
 *
 * The key is never echoed, logged or returned to clients.
 */

function gt_ai_private_config_path(): string
{
    // backend/ -> public_html/ -> site folder (not served by the web server)
    return dirname(__DIR__, 2) . DIRECTORY_SEPARATOR . 'gt_private' . DIRECTORY_SEPARATOR . 'ai_config.php';
}

function gt_ai_config(): array
{
    static $cfg = null;
    if ($cfg !== null) return $cfg;

    $enabled = getenv('GT_AI_ENABLED');
    $key = getenv('GT_GEMINI_API_KEY');
    $model = getenv('GT_GEMINI_MODEL');
    $source = 'environment';

    if ($key === false || $key === '') {
        $source = 'none';
        $path = gt_ai_private_config_path();
        if (is_file($path)) {
            $file = @include $path;
            if (is_array($file)) {
                $enabled = $file['enabled'] ?? false;
                $key = $file['api_key'] ?? '';
                $model = $file['model'] ?? '';
                $source = 'private file';
            }
        }
    }

    $on = filter_var($enabled, FILTER_VALIDATE_BOOLEAN);
    $key = is_string($key) ? trim($key) : '';
    $model = is_string($model) ? trim($model) : '';
    $cfg = [
        'enabled' => $on && $key !== '' && $model !== '' && preg_match('/^[a-z0-9.\-]+$/', $model) === 1,
        'api_key' => $key,
        'model' => $model,
        'source' => $source,
    ];
    return $cfg;
}

/** Endpoint URL for a configured model (the key goes in a header, not the URL). */
function gt_ai_endpoint(array $cfg): string
{
    return 'https://generativelanguage.googleapis.com/v1beta/models/' . rawurlencode($cfg['model']) . ':generateContent';
}

/** Private folder for AI results and the daily counter (outside the web root, next to ai_config.php). */
function gt_ai_cache_dir(): ?string
{
    $d = dirname(gt_ai_private_config_path()) . DIRECTORY_SEPARATOR . 'ai_cache';
    if (!is_dir($d) && !@mkdir($d, 0700, true)) return null;
    return $d;
}

const GT_AI_CACHE_TTL = 21600;     // 6 h: the same numbers reuse the saved text, no new request
const GT_AI_FAIL_PAUSE = 600;      // 10 min without asking again after a failed request (e.g. limit reached)
const GT_AI_DAILY_CAP = 15;        // real requests per day, under the free tier's daily limit

/**
 * One bounded call. Returns the text or null. Never throws, never retries, never exposes the
 * key or the raw provider response.
 *
 * Results are cached for GT_AI_CACHE_TTL (the volatile "timestamp" field is ignored when matching),
 * a failed request pauses further requests for GT_AI_FAIL_PAUSE, and at most GT_AI_DAILY_CAP real
 * requests are made per day, so the free-tier limit is never used up by page refreshes.
 */
function gt_ai_generate(array $cfg, string $prompt, array $generationConfig, int $timeoutSeconds = 10): ?string
{
    if (empty($cfg['enabled']) || !function_exists('curl_init')) return null;

    $dir = gt_ai_cache_dir();
    $keyBase = preg_replace('/"timestamp":"[^"]*"/', '', $prompt) . '|' . $cfg['model'] . '|' . json_encode($generationConfig);
    $cacheFile = $dir ? $dir . DIRECTORY_SEPARATOR . 'r_' . hash('sha256', $keyBase) . '.json' : null;
    $stateFile = $dir ? $dir . DIRECTORY_SEPARATOR . 'state.json' : null;
    if ($cacheFile && is_file($cacheFile)) {
        $c = json_decode((string)@file_get_contents($cacheFile), true);
        if (is_array($c) && isset($c['t'], $c['text']) && time() - (int)$c['t'] < GT_AI_CACHE_TTL) return (string)$c['text'];
    }
    $state = ['day' => date('Y-m-d'), 'count' => 0, 'pause_until' => 0];
    if ($stateFile && is_file($stateFile)) {
        $st = json_decode((string)@file_get_contents($stateFile), true);
        if (is_array($st)) $state = array_merge($state, $st);
    }
    if ($state['day'] !== date('Y-m-d')) { $state['day'] = date('Y-m-d'); $state['count'] = 0; }
    if ((int)$state['pause_until'] > time() || (int)$state['count'] >= GT_AI_DAILY_CAP) return null;
    $state['count'] = (int)$state['count'] + 1;
    if ($stateFile) @file_put_contents($stateFile, json_encode($state), LOCK_EX);

    $ch = curl_init(gt_ai_endpoint($cfg));
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_POST, true);
    curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode([
        'contents' => [['parts' => [['text' => $prompt]]]],
        'generationConfig' => $generationConfig,
    ]));
    curl_setopt($ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json', 'x-goog-api-key: ' . $cfg['api_key']]);
    curl_setopt($ch, CURLOPT_TIMEOUT, $timeoutSeconds);
    $resp = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($code !== 200 || !is_string($resp)) {
        error_log('AI request failed (HTTP ' . $code . ')'); // no key, no body
        $state['pause_until'] = time() + GT_AI_FAIL_PAUSE;
        if ($stateFile) @file_put_contents($stateFile, json_encode($state), LOCK_EX);
        return null;
    }
    $data = json_decode($resp, true);
    $text = $data['candidates'][0]['content']['parts'][0]['text'] ?? '';
    $text = is_string($text) ? trim($text) : '';
    if ($text === '') return null;
    if ($cacheFile) @file_put_contents($cacheFile, json_encode(['t' => time(), 'text' => $text]), LOCK_EX);
    return $text;
}
