<?php
// =============================================================================
// usage_parser.php — Real token usage from Claude Code + Gemini CLI log files
//
// ACTIONS (GET):
//   ?action=claude          — aggregate Claude JSONL logs
//   ?action=gemini          — aggregate Gemini JSONL logs
//   ?action=ollama          — read cockpit Ollama usage log
//   ?action=workers         — read workers_usage.json + quotas
//   ?action=all             — all four combined (for Usage panel)
//   ?action=claude_detail   — per-session breakdown for Claude
//   ?action=gemini_detail   — per-session breakdown for Gemini
//
// FILTER PARAMS:
//   &range=today|week|month|all   (default: today)
//   &project=<name>               (filter Claude by project path)
//
// DATA SOURCES:
//   Claude  : ~/.claude/projects/*/*.jsonl
//             parse lines where stop_reason is set
//             fields: message.usage.{input_tokens, output_tokens,
//                     cache_creation_input_tokens, cache_read_input_tokens}
//
//   Gemini  : ~/.gemini/tmp/*/chats/session-*.jsonl
//             parse lines where type === "assistant" and tokens present
//             fields: tokens.{input, output, cached, thoughts, tool, total}
//
//   Ollama  : /var/www/html/cockpit/ollama_usage.jsonl
//             written by cockpit ai_bridge when Ollama responds
//             fields: {ts, model, prompt_tokens, output_tokens,
//                      total_ms, project, chat}
//
//   Workers : ~/scripts/cockpit_data/workers_usage.json
//             ~/scripts/cockpit_data/workers_providers.json (quotas)
// =============================================================================

ini_set('display_errors', '0');
error_reporting(0);
header('Content-Type: application/json');
header('Cache-Control: no-store');

// =============================================================================
// Paths
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
$HOME         = $PATHS['home'];
$CLAUDE_DIR   = $HOME . '/.claude/projects';
$GEMINI_DIR   = $HOME . '/.gemini/tmp';
$OLLAMA_LOG   = $PATHS['ollama_log'];
$WORKERS_USG  = $CD . '/workers_usage.json';
$WORKERS_PRV  = $CD . '/workers_providers.json';
$WORKERS_QTA  = $CD . '/workers_quotas.json';

// =============================================================================
// Helpers
// =============================================================================
function load_json_up(string $path, $default = []) {
    if (!is_file($path)) return $default;
    $d = json_decode((string)file_get_contents($path), true);
    return is_array($d) ? $d : $default;
}

// Return unix timestamps for range boundaries
function range_bounds(string $range): array {
    $now = time();
    switch ($range) {
        case 'week':  return [$now - 86400 * 7,  $now];
        case 'month': return [$now - 86400 * 30, $now];
        case 'all':   return [0, $now];
        default:      // today
            return [strtotime('today midnight'), $now];
    }
}

// Parse ISO8601 or unix timestamp → unix int
function parse_ts($ts): int {
    if (is_numeric($ts)) return (int)$ts;
    $t = strtotime((string)$ts);
    return $t ?: 0;
}

// Format large numbers nicely
function fmt_tokens(int $n): string {
    if ($n >= 1000000) return round($n / 1000000, 2) . 'M';
    if ($n >= 1000)    return round($n / 1000, 1) . 'K';
    return (string)$n;
}

// =============================================================================
// ACTION: claude
// =============================================================================
function parse_claude(string $CLAUDE_DIR, string $range, string $project_filter): array {
    [$ts_from, $ts_to] = range_bounds($range);

    $totals = [
        'input'         => 0,
        'output'        => 0,
        'cache_create'  => 0,
        'cache_read'    => 0,
        'sessions'      => 0,
        'messages'      => 0,
        'by_day'        => [],
        'by_session'    => [],
    ];

    if (!is_dir($CLAUDE_DIR)) {
        $totals['note'] = 'Claude log directory not found at ' . $CLAUDE_DIR
                       . ' (CLI not run yet, or directory permissions prevent www-data from reading it).';
        return $totals;
    }
    if (!is_readable($CLAUDE_DIR)) {
        $totals['note'] = 'Claude log directory exists but is unreadable by www-data. '
                       . 'Fix: sudo setfacl -m u:www-data:rx ' . dirname($CLAUDE_DIR) . ' && '
                       . 'sudo setfacl -R -m u:www-data:rx ' . $CLAUDE_DIR;
        return $totals;
    }

    // Scan all project dirs
    foreach (scandir($CLAUDE_DIR) ?: [] as $proj_dir) {
        if ($proj_dir[0] === '.') continue;
        $proj_path = $CLAUDE_DIR . '/' . $proj_dir;
        if (!is_dir($proj_path)) continue;

        // HIGH-47 fix: anchor project_filter to delimiters so "test" doesn't
        // match "tester" or "pretest" (Claude encodes paths as dash-separated).
        if ($project_filter && !preg_match('/(^|-)' . preg_quote($project_filter, '/') . '($|-)/', $proj_dir)) continue;

        foreach (glob($proj_path . '/*.jsonl') ?: [] as $f) {
            $session_input   = 0;
            $session_output  = 0;
            $session_cc      = 0;
            $session_cr      = 0;
            $session_msgs    = 0;
            $session_ts      = 0;
            $has_data        = false;

            $fh = @fopen($f, 'r');
            if (!$fh) continue;

            while (($line = fgets($fh)) !== false) {
                $d = json_decode(trim($line), true);
                if (!is_array($d)) continue;

                // Only count assistant messages with stop_reason (completed turns)
                if (($d['type'] ?? '') !== 'assistant') continue;
                $msg = $d['message'] ?? [];
                if (empty($msg['stop_reason'])) continue;

                $usage = $msg['usage'] ?? [];
                if (empty($usage)) continue;

                // Timestamp from message
                $entry_ts = parse_ts($d['timestamp'] ?? 0);
                if ($entry_ts < $ts_from || $entry_ts > $ts_to) continue;

                $in  = (int)($usage['input_tokens']                 ?? 0);
                $out = (int)($usage['output_tokens']                ?? 0);
                $cc  = (int)($usage['cache_creation_input_tokens']  ?? 0);
                $cr  = (int)($usage['cache_read_input_tokens']      ?? 0);

                $session_input  += $in;
                $session_output += $out;
                $session_cc     += $cc;
                $session_cr     += $cr;
                $session_msgs++;
                $has_data = true;
                if ($entry_ts > $session_ts) $session_ts = $entry_ts;

                // Day bucket
                $day = date('Y-m-d', $entry_ts);
                if (!isset($totals['by_day'][$day])) {
                    $totals['by_day'][$day] = ['input'=>0,'output'=>0,'cache_create'=>0,'cache_read'=>0,'messages'=>0];
                }
                $totals['by_day'][$day]['input']        += $in;
                $totals['by_day'][$day]['output']       += $out;
                $totals['by_day'][$day]['cache_create'] += $cc;
                $totals['by_day'][$day]['cache_read']   += $cr;
                $totals['by_day'][$day]['messages']++;
            }
            fclose($fh);

            if ($has_data) {
                $totals['input']        += $session_input;
                $totals['output']       += $session_output;
                $totals['cache_create'] += $session_cc;
                $totals['cache_read']   += $session_cr;
                $totals['messages']     += $session_msgs;
                $totals['sessions']++;
                $totals['by_session'][] = [
                    'file'          => basename($f),
                    'project'       => $proj_dir,
                    'input'         => $session_input,
                    'output'        => $session_output,
                    'cache_create'  => $session_cc,
                    'cache_read'    => $session_cr,
                    'messages'      => $session_msgs,
                    'last_ts'       => $session_ts,
                ];
            }
        }
    }

    // Sort sessions newest first
    usort($totals['by_session'], fn($a,$b) => $b['last_ts'] <=> $a['last_ts']);

    // Add formatted totals
    $totals['total_tokens']      = $totals['input'] + $totals['output'];
    $totals['total_tokens_fmt']  = fmt_tokens($totals['total_tokens']);
    $totals['input_fmt']         = fmt_tokens($totals['input']);
    $totals['output_fmt']        = fmt_tokens($totals['output']);
    $totals['cache_create_fmt']  = fmt_tokens($totals['cache_create']);
    $totals['cache_read_fmt']    = fmt_tokens($totals['cache_read']);

    // Cache savings — cache_read is served at ~10% cost vs fresh input
    // Approximate: saved_tokens = cache_read * 0.9
    $totals['cache_savings_pct'] = $totals['input'] > 0
        ? round($totals['cache_read'] / ($totals['input'] + $totals['cache_read']) * 100, 1)
        : 0;

    return $totals;
}

// =============================================================================
// ACTION: gemini
// =============================================================================
function parse_gemini(string $GEMINI_DIR, string $range): array {
    [$ts_from, $ts_to] = range_bounds($range);

    $totals = [
        'input'      => 0,
        'output'     => 0,
        'cached'     => 0,
        'thoughts'   => 0,
        'tool'       => 0,
        'total'      => 0,
        'sessions'   => 0,
        'messages'   => 0,
        'by_day'     => [],
        'by_session' => [],
        'models'     => [],
    ];

    $tmp_dir = $GEMINI_DIR;
    if (!is_dir($tmp_dir)) {
        $totals['note'] = 'Gemini log directory not found at ' . $tmp_dir
                       . ' (CLI not run yet, or directory permissions prevent www-data from reading it).';
        return $totals;
    }
    if (!is_readable($tmp_dir)) {
        $totals['note'] = 'Gemini log directory exists but is unreadable by www-data. '
                       . 'Fix: sudo setfacl -m u:www-data:rx ' . dirname($tmp_dir) . ' && '
                       . 'sudo setfacl -R -m u:www-data:rx ' . $tmp_dir;
        return $totals;
    }

    foreach (scandir($tmp_dir) ?: [] as $proj) {
        if ($proj[0] === '.') continue;
        $chats_dir = $tmp_dir . '/' . $proj . '/chats';
        if (!is_dir($chats_dir)) continue;

        foreach (glob($chats_dir . '/session-*.jsonl') ?: [] as $f) {
            // Quick check: file mtime to pre-filter
            if (filemtime($f) < $ts_from - 3600) continue;

            $sess_in = $sess_out = $sess_cached = $sess_thoughts = $sess_tool = 0;
            $sess_msgs = 0;
            $sess_ts   = 0;
            $has_data  = false;
            $model     = '';

            $fh = @fopen($f, 'r');
            if (!$fh) continue;

            while (($line = fgets($fh)) !== false) {
                $d = json_decode(trim($line), true);
                if (!is_array($d)) continue;
                if (($d['type'] ?? '') !== 'assistant') continue;
                if (empty($d['tokens'])) continue;

                $entry_ts = parse_ts($d['timestamp'] ?? 0);
                if ($entry_ts < $ts_from || $entry_ts > $ts_to) continue;

                $tok = $d['tokens'];
                $in  = (int)($tok['input']    ?? 0);
                $out = (int)($tok['output']   ?? 0);
                $cac = (int)($tok['cached']   ?? 0);
                $tht = (int)($tok['thoughts'] ?? 0);
                $tol = (int)($tok['tool']     ?? 0);

                $sess_in       += $in;
                $sess_out      += $out;
                $sess_cached   += $cac;
                $sess_thoughts += $tht;
                $sess_tool     += $tol;
                $sess_msgs++;
                $has_data = true;
                if ($entry_ts > $sess_ts) $sess_ts = $entry_ts;
                if (!$model && !empty($d['model'])) $model = $d['model'];

                // Day bucket
                $day = date('Y-m-d', $entry_ts);
                if (!isset($totals['by_day'][$day])) {
                    $totals['by_day'][$day] = ['input'=>0,'output'=>0,'cached'=>0,'thoughts'=>0,'messages'=>0];
                }
                $totals['by_day'][$day]['input']    += $in;
                $totals['by_day'][$day]['output']   += $out;
                $totals['by_day'][$day]['cached']   += $cac;
                $totals['by_day'][$day]['thoughts'] += $tht;
                $totals['by_day'][$day]['messages']++;

                // Model tracking
                if ($model) {
                    if (!isset($totals['models'][$model])) $totals['models'][$model] = 0;
                    $totals['models'][$model] += ($in + $out + $cac + $tht + $tol);
                }
            }
            fclose($fh);

            if ($has_data) {
                $totals['input']    += $sess_in;
                $totals['output']   += $sess_out;
                $totals['cached']   += $sess_cached;
                $totals['thoughts'] += $sess_thoughts;
                $totals['tool']     += $sess_tool;
                $totals['total']    += $sess_in + $sess_out + $sess_cached + $sess_thoughts + $sess_tool;
                $totals['messages'] += $sess_msgs;
                $totals['sessions']++;
                $totals['by_session'][] = [
                    'file'     => basename($f),
                    'project'  => $proj,
                    'input'    => $sess_in,
                    'output'   => $sess_out,
                    'cached'   => $sess_cached,
                    'thoughts' => $sess_thoughts,
                    'messages' => $sess_msgs,
                    'model'    => $model,
                    'last_ts'  => $sess_ts,
                ];
            }
        }
    }

    usort($totals['by_session'], fn($a,$b) => $b['last_ts'] <=> $a['last_ts']);

    $totals['input_fmt']    = fmt_tokens($totals['input']);
    $totals['output_fmt']   = fmt_tokens($totals['output']);
    $totals['cached_fmt']   = fmt_tokens($totals['cached']);
    $totals['thoughts_fmt'] = fmt_tokens($totals['thoughts']);
    $totals['total_fmt']    = fmt_tokens($totals['total']);

    // Note: Gemini free tier (OAuth) doesn't expose cost data
    $totals['cost_note'] = 'OAuth free tier — cost data unavailable';

    return $totals;
}

// =============================================================================
// ACTION: ollama
// =============================================================================
function parse_ollama(string $OLLAMA_LOG, string $range): array {
    [$ts_from, $ts_to] = range_bounds($range);

    $totals = [
        'prompt_tokens'  => 0,
        'output_tokens'  => 0,
        'total_ms'       => 0,
        'calls'          => 0,
        'by_model'       => [],
        'by_day'         => [],
        'context_window' => 32768,  // qwen2.5-coder:1.5b default
    ];

    if (!is_file($OLLAMA_LOG)) {
        $totals['note'] = 'No Ollama usage log yet — log file will be created on first Ollama call';
        return $totals;
    }

    $fh = @fopen($OLLAMA_LOG, 'r');
    if (!$fh) return $totals;

    while (($line = fgets($fh)) !== false) {
        $d = json_decode(trim($line), true);
        if (!is_array($d)) continue;

        $entry_ts = parse_ts($d['ts'] ?? 0);
        if ($entry_ts < $ts_from || $entry_ts > $ts_to) continue;

        $pt  = (int)($d['prompt_tokens']  ?? 0);
        $ot  = (int)($d['output_tokens']  ?? 0);
        $ms  = (int)($d['total_ms']       ?? 0);
        $mdl = (string)($d['model']       ?? 'unknown');

        $totals['prompt_tokens']  += $pt;
        $totals['output_tokens']  += $ot;
        $totals['total_ms']       += $ms;
        $totals['calls']++;

        // Per-model breakdown
        if (!isset($totals['by_model'][$mdl])) {
            $totals['by_model'][$mdl] = ['prompt'=>0,'output'=>0,'calls'=>0,'ms'=>0];
        }
        $totals['by_model'][$mdl]['prompt'] += $pt;
        $totals['by_model'][$mdl]['output'] += $ot;
        $totals['by_model'][$mdl]['calls']++;
        $totals['by_model'][$mdl]['ms']     += $ms;

        // Day bucket
        $day = date('Y-m-d', $entry_ts);
        if (!isset($totals['by_day'][$day])) {
            $totals['by_day'][$day] = ['prompt'=>0,'output'=>0,'calls'=>0];
        }
        $totals['by_day'][$day]['prompt'] += $pt;
        $totals['by_day'][$day]['output'] += $ot;
        $totals['by_day'][$day]['calls']++;
    }
    fclose($fh);

    // Context window percentage (max prompt seen vs window size)
    $totals['prompt_tokens_fmt'] = fmt_tokens($totals['prompt_tokens']);
    $totals['output_tokens_fmt'] = fmt_tokens($totals['output_tokens']);
    $totals['avg_ms']            = $totals['calls'] > 0
        ? round($totals['total_ms'] / $totals['calls'])
        : 0;

    return $totals;
}

// =============================================================================
// ACTION: workers
// =============================================================================
function parse_workers(string $WORKERS_USG, string $WORKERS_QTA, string $WORKERS_PRV): array {
    $usage   = load_json_up($WORKERS_USG, []);
    $quotas  = load_json_up($WORKERS_QTA, []);
    $provs   = load_json_up($WORKERS_PRV, []);

    $result = ['providers' => []];

    // Merge usage + quota per provider — skip meta/comment keys.
    // workers_providers.json is an overlay file (format_version/user_added_models/etc.)
    // not a flat provider map, so don't use it as a source of provider IDs.
    $all_providers = array_unique(array_merge(
        array_keys($usage),
        array_keys($quotas)
    ));
    $all_providers = array_values(array_filter($all_providers, function($k) {
        return $k !== '' && $k[0] !== '_' && !in_array($k, ['format_version','user_added_models','custom_providers'], true);
    }));

    foreach ($all_providers as $prov) {
        $u = $usage[$prov]  ?? [];
        $q = $quotas[$prov] ?? [];
        $p = $provs[$prov]  ?? [];

        $calls_used  = (int)($u['calls']   ?? 0);
        $tokens_used = (int)($u['tokens']  ?? 0);
        $calls_limit = (int)($q['calls']   ?? 0);
        $token_limit = (int)($q['tokens']  ?? 0);
        $reset_type  = (string)($q['reset'] ?? 'daily');
        $last_reset  = parse_ts($u['last_reset'] ?? 0);

        // Calculate next reset time
        $now        = time();
        $reset_secs = match($reset_type) {
            'hourly'  => 3600,
            'daily'   => 86400,
            'weekly'  => 86400 * 7,
            'monthly' => 86400 * 30,
            default   => 86400,
        };
        $next_reset  = $last_reset + $reset_secs;
        $secs_until  = max(0, $next_reset - $now);
        $hrs_until   = floor($secs_until / 3600);
        $mins_until  = floor(($secs_until % 3600) / 60);

        $result['providers'][$prov] = [
            'name'         => $p['name']    ?? ucfirst($prov),
            'tier'         => $p['tier']    ?? 'free',
            'calls_used'   => $calls_used,
            'calls_limit'  => $calls_limit,
            'calls_pct'    => $calls_limit > 0 ? round($calls_used / $calls_limit * 100, 1) : 0,
            'tokens_used'  => $tokens_used,
            'token_limit'  => $token_limit,
            'tokens_pct'   => $token_limit > 0 ? round($tokens_used / $token_limit * 100, 1) : 0,
            'reset_type'   => $reset_type,
            'reset_in'     => $secs_until > 0
                ? ($hrs_until > 0 ? "{$hrs_until}h {$mins_until}m" : "{$mins_until}m")
                : 'now',
            'reset_ts'     => $next_reset,
        ];
    }

    return $result;
}

// =============================================================================
// Routing
// =============================================================================
$action  = trim((string)($_GET['action'] ?? 'all'));
$range   = trim((string)($_GET['range']  ?? 'today'));
$project = trim((string)($_GET['project'] ?? ''));

// Validate range
if (!in_array($range, ['today','week','month','all'])) $range = 'today';

switch ($action) {

    case 'claude':
        $data = parse_claude($CLAUDE_DIR, $range, $project);
        echo json_encode(['ok'=>true, 'range'=>$range, 'claude'=>$data], JSON_UNESCAPED_UNICODE);
        break;

    case 'gemini':
        $data = parse_gemini($GEMINI_DIR, $range);
        echo json_encode(['ok'=>true, 'range'=>$range, 'gemini'=>$data], JSON_UNESCAPED_UNICODE);
        break;

    case 'ollama':
        $data = parse_ollama($OLLAMA_LOG, $range);
        echo json_encode(['ok'=>true, 'range'=>$range, 'ollama'=>$data], JSON_UNESCAPED_UNICODE);
        break;

    case 'workers':
        $data = parse_workers($WORKERS_USG, $WORKERS_QTA, $WORKERS_PRV);
        echo json_encode(['ok'=>true, 'workers'=>$data], JSON_UNESCAPED_UNICODE);
        break;

    case 'claude_detail':
        $data = parse_claude($CLAUDE_DIR, $range, $project);
        // Return full session list
        echo json_encode(['ok'=>true, 'range'=>$range, 'sessions'=>$data['by_session'],
                          'totals'=>array_diff_key($data, ['by_session'=>1,'by_day'=>1])], JSON_UNESCAPED_UNICODE);
        break;

    case 'gemini_detail':
        $data = parse_gemini($GEMINI_DIR, $range);
        echo json_encode(['ok'=>true, 'range'=>$range, 'sessions'=>$data['by_session'],
                          'totals'=>array_diff_key($data, ['by_session'=>1,'by_day'=>1])], JSON_UNESCAPED_UNICODE);
        break;

    case 'all':
    default:
        $claude  = parse_claude($CLAUDE_DIR,  $range, $project);
        $gemini  = parse_gemini($GEMINI_DIR,  $range);
        $ollama  = parse_ollama($OLLAMA_LOG,  $range);
        $workers = parse_workers($WORKERS_USG, $WORKERS_QTA, $WORKERS_PRV);

        $spend_f = $CD . '/workers_spend.json';
        $spend = is_file($spend_f) ? (json_decode((string)file_get_contents($spend_f), true) ?: []) : [];
        $settings_f = $CD . '/settings.json';
        $settings = is_file($settings_f) ? (json_decode((string)file_get_contents($settings_f), true) ?: []) : [];
        $paid_spend = [
            'global_usd'       => (float)($spend['global_usd'] ?? 0),
            'by_model'         => $spend['by_model'] ?? [],
            'global_cap'       => (float)($settings['caps']['global_monthly_usd'] ?? 0),
            'per_model_caps'   => $settings['caps']['per_model_monthly_usd'] ?? [],
        ];

        echo json_encode([
            'ok'      => true,
            'range'   => $range,
            'claude'  => $claude,
            'gemini'  => $gemini,
            'ollama'  => $ollama,
            'workers' => $workers,
            'paid_spend' => $paid_spend,
        ], JSON_UNESCAPED_UNICODE);
        break;
}
