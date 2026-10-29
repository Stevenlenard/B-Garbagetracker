<?php
/**
 * Server-side AI configuration: Gemini first, Groq as the backup. Contains NO secret.
 *
 * AI is DISABLED unless enabled = true and at least one provider has both a key and a model.
 * When Gemini fails (quota used up, error, daily cap reached), the same request goes to Groq.
 *
 * Sources (first found wins):
 *  1. Environment variables: GT_AI_ENABLED (true/1), GT_GEMINI_API_KEY, GT_GEMINI_MODEL,
 *     GT_GROQ_API_KEY, GT_GROQ_MODEL.
 *  2. A private PHP file OUTSIDE the public web root, never in git:
 *       <site folder>/gt_private/ai_config.php   (one level above public_html)
 *     returning ['enabled' => false, 'api_key' => '', 'model' => '', 'groq_api_key' => '', 'groq_model' => ''].
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
    $groqKey = getenv('GT_GROQ_API_KEY');
    $groqModel = getenv('GT_GROQ_MODEL');
    $source = 'environment';

    if (($key === false || $key === '') && ($groqKey === false || $groqKey === '')) {
        $source = 'none';
        $path = gt_ai_private_config_path();
        if (is_file($path)) {
            $file = @include $path;
            if (is_array($file)) {
                $enabled = $file['enabled'] ?? false;
                $key = $file['api_key'] ?? '';
                $model = $file['model'] ?? '';
                $groqKey = $file['groq_api_key'] ?? '';
                $groqModel = $file['groq_model'] ?? '';
                $source = 'private file';
            }
        }
    }

    $on = filter_var($enabled, FILTER_VALIDATE_BOOLEAN);
    $key = is_string($key) ? trim($key) : '';
    $model = is_string($model) ? trim($model) : '';
    $groqKey = is_string($groqKey) ? trim($groqKey) : '';
    $groqModel = is_string($groqModel) ? trim($groqModel) : '';
    $gemini = $on && $key !== '' && $model !== '' && preg_match('/^[a-z0-9.\-]+$/', $model) === 1;
    $groq = $on && $groqKey !== '' && $groqModel !== '' && preg_match('/^[a-z0-9.\-\/]+$/', $groqModel) === 1;
    $cfg = [
        'enabled' => $gemini || $groq,
        'gemini' => $gemini,
        'groq' => $groq,
        'api_key' => $key,
        'model' => $model,
        'groq_api_key' => $groqKey,
        'groq_model' => $groqModel,
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
const GT_AI_DAILY_CAP = 15;        // real Gemini requests per day, under the free tier's daily limit
const GT_AI_GROQ_DAILY_CAP = 100;  // real Groq requests per day (backup only)
const GT_AI_GROQ_ENDPOINT = 'https://api.groq.com/openai/v1/chat/completions';

/**
 * One bounded call. Returns the text or null. Never throws, never exposes the key or the raw provider response.
 *
 * Results are cached for GT_AI_CACHE_TTL (the volatile "timestamp" field is ignored when matching).
 * Gemini is asked first; when it is not configured, paused after a failure, over its daily cap, or the
 * request fails, the same prompt goes to Groq once. Each provider has its own daily cap and pause, so the
 * free-tier limits are never used up by page refreshes. The provider that answered is in $GLOBALS['gt_ai_provider'].
 */
function gt_ai_generate(array $cfg, string $prompt, array $generationConfig, int $timeoutSeconds = 10): ?string
{
    $GLOBALS['gt_ai_provider'] = null;
    if (empty($cfg['enabled']) || !function_exists('curl_init')) return null;

    $dir = gt_ai_cache_dir();
    $keyBase = preg_replace('/"timestamp":"[^"]*"/', '', $prompt) . '|' . json_encode($generationConfig);
    $cacheFile = $dir ? $dir . DIRECTORY_SEPARATOR . 'r_' . hash('sha256', $keyBase) . '.json' : null;
    if ($cacheFile && is_file($cacheFile)) {
        $c = json_decode((string)@file_get_contents($cacheFile), true);
        if (is_array($c) && isset($c['t'], $c['text']) && time() - (int)$c['t'] < GT_AI_CACHE_TTL) {
            $GLOBALS['gt_ai_provider'] = $c['provider'] ?? 'gemini';
            return (string)$c['text'];
        }
    }

    $text = null;
    $provider = null;
    if (!empty($cfg['gemini']) && gt_ai_take_slot($dir, 'state.json', GT_AI_DAILY_CAP)) {
        $text = gt_ai_call_gemini($cfg, $prompt, $generationConfig, $timeoutSeconds);
        if ($text === null) gt_ai_pause($dir, 'state.json');
        else $provider = 'gemini';
    }
    if ($text === null && !empty($cfg['groq']) && gt_ai_take_slot($dir, 'state_groq.json', GT_AI_GROQ_DAILY_CAP)) {
        $text = gt_ai_call_groq($cfg, $prompt, $generationConfig, $timeoutSeconds);
        if ($text === null) gt_ai_pause($dir, 'state_groq.json');
        else $provider = 'groq';
    }
    if ($text === null) return null;
    $GLOBALS['gt_ai_provider'] = $provider;
    if ($cacheFile) @file_put_contents($cacheFile, json_encode(['t' => time(), 'text' => $text, 'provider' => $provider]), LOCK_EX);
    return $text;
}

/** Counts one real request for a provider; false while it is paused or over its daily cap. */
function gt_ai_take_slot(?string $dir, string $file, int $cap): bool
{
    $stateFile = $dir ? $dir . DIRECTORY_SEPARATOR . $file : null;
    $state = ['day' => date('Y-m-d'), 'count' => 0, 'pause_until' => 0];
    if ($stateFile && is_file($stateFile)) {
        $st = json_decode((string)@file_get_contents($stateFile), true);
        if (is_array($st)) $state = array_merge($state, $st);
    }
    if ($state['day'] !== date('Y-m-d')) { $state['day'] = date('Y-m-d'); $state['count'] = 0; }
    if ((int)$state['pause_until'] > time() || (int)$state['count'] >= $cap) return false;
    $state['count'] = (int)$state['count'] + 1;
    if ($stateFile) @file_put_contents($stateFile, json_encode($state), LOCK_EX);
    return true;
}

/** After a failed request, the provider is not asked again for GT_AI_FAIL_PAUSE. */
function gt_ai_pause(?string $dir, string $file): void
{
    $stateFile = $dir ? $dir . DIRECTORY_SEPARATOR . $file : null;
    if (!$stateFile) return;
    $state = is_file($stateFile) ? json_decode((string)@file_get_contents($stateFile), true) : null;
    if (!is_array($state)) $state = ['day' => date('Y-m-d'), 'count' => 0];
    $state['pause_until'] = time() + GT_AI_FAIL_PAUSE;
    @file_put_contents($stateFile, json_encode($state), LOCK_EX);
}

/** POSTs JSON; returns the decoded body of a 200 response, else null (the key and body are never logged). */
function gt_ai_post(string $url, array $headers, array $body, int $timeoutSeconds, string $name): ?array
{
    $ch = curl_init($url);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_POST, true);
    curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body));
    curl_setopt($ch, CURLOPT_HTTPHEADER, array_merge(['Content-Type: application/json'], $headers));
    curl_setopt($ch, CURLOPT_TIMEOUT, $timeoutSeconds);
    $resp = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($code !== 200 || !is_string($resp)) {
        error_log($name . ' request failed (HTTP ' . $code . ')');
        return null;
    }
    $data = json_decode($resp, true);
    return is_array($data) ? $data : null;
}

function gt_ai_call_gemini(array $cfg, string $prompt, array $generationConfig, int $timeoutSeconds): ?string
{
    // 2.5 Flash thinks before answering by default, and the thinking counts against maxOutputTokens:
    // with the short limits used here it could leave no room for the answer.
    if (strpos($cfg['model'], '2.5-flash') !== false && !isset($generationConfig['thinkingConfig'])) {
        $generationConfig['thinkingConfig'] = ['thinkingBudget' => 0];
    }
    $data = gt_ai_post(gt_ai_endpoint($cfg), ['x-goog-api-key: ' . $cfg['api_key']], [
        'contents' => [['parts' => [['text' => $prompt]]]],
        'generationConfig' => $generationConfig,
    ], $timeoutSeconds, 'Gemini');
    $text = $data['candidates'][0]['content']['parts'][0]['text'] ?? '';
    $text = is_string($text) ? trim($text) : '';
    return $text === '' ? null : $text;
}

/** Groq speaks the OpenAI chat format; the Gemini generation settings are mapped onto it. */
function gt_ai_call_groq(array $cfg, string $prompt, array $generationConfig, int $timeoutSeconds): ?string
{
    $body = ['model' => $cfg['groq_model'], 'messages' => [['role' => 'user', 'content' => $prompt]]];
    if (isset($generationConfig['temperature'])) $body['temperature'] = $generationConfig['temperature'];
    if (isset($generationConfig['maxOutputTokens'])) $body['max_tokens'] = $generationConfig['maxOutputTokens'];
    if (strpos($cfg['groq_model'], 'gpt-oss') !== false) {
        // reasoning models: keep the thinking short and out of the answer, and leave room for it in the token limit
        $body['reasoning_effort'] = 'low';
        $body['include_reasoning'] = false;
        if (isset($body['max_tokens'])) $body['max_tokens'] += 1024;
    }
    if (($generationConfig['responseMimeType'] ?? '') === 'application/json') $body['response_format'] = ['type' => 'json_object'];
    $data = gt_ai_post(GT_AI_GROQ_ENDPOINT, ['Authorization: Bearer ' . $cfg['groq_api_key']], $body, $timeoutSeconds, 'Groq');
    $text = $data['choices'][0]['message']['content'] ?? '';
    $text = is_string($text) ? trim($text) : '';
    return $text === '' ? null : $text;
}
