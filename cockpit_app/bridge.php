<?php
if (!function_exists('mb_strlen'))  { function mb_strlen($s, $e=null)  { return strlen($s); } }
if (!function_exists('mb_substr'))  { function mb_substr($s,$st,$l=null,$e=null) { return $l===null ? substr($s,$st) : substr($s,$st,$l); } }
// =============================================================================
// bridge.php - Triple-Agent Bridge v5 (file queue + streaming poll)
// Dario Ruggi / Cockpit
//
// Architecture:
//   Two operating modes, selected by the request:
//
//   1. SYNCHRONOUS (legacy, default if no `mode` field):
//      PHP writes a prompt file, polls for the done flag, returns full response.
//      Used by code that doesn't care about streaming.
//
//   2. STREAMING (mode='submit' to enqueue, mode='poll' to read chunks):
//      'submit' enqueues the prompt and returns the token immediately.
//      'poll'   reads the current size of the .out file from a given offset
//               and returns the new bytes plus a 'done' flag. The frontend
//               calls 'poll' every 200ms until done=true, then reads any final
//               bytes and finishes.
//
// File layout (unchanged):
//   queue/{agent}_prompt_{token}.txt   — prompt for the agent
//   queue/{token}_meta.json            — project/chat/model metadata
//   queue/{token}_model.txt            — Ollama model selection
//   responses/{token}.out              — agent stdout (grows as agent writes)
//   responses/{token}.done             — created by agent_loop when complete
// =============================================================================

header('Content-Type: application/json');

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) ed_demo_stub();

define('QUEUE_DIR',    $PATHS['queue_dir']);
define('RESPONSE_DIR', $PATHS['response_dir']);
define('TMUX_SOCKET',  $PATHS['tmux_socket']);
define('TMUX_CMD',     'tmux -S ' . TMUX_SOCKET . ' ');
require_once __DIR__ . '/session_backend.php';      // who hosts the agent loops: tmux (default) or aicsupervisor (opt-in)
define('POLL_INTERVAL', 500000);  // 0.5 seconds (sync mode only)
define('MAX_WAIT',      120);     // seconds (sync mode only)
define('STALE_AGE_SEC', 600);     // any .out/.done older than 10 min is fair game
define('OLLAMA_LOG',   $PATHS['ollama_log']);

// logOllamaUsage() removed 2026-05-26 — agent_loop.sh is the canonical writer
// (correct model, real total_ms, accurate token estimates). bridge.php sees
// model.txt and prompt.txt AFTER agent_loop has already consumed them, so
// any record written here was always model="unknown" and total_ms=0.

// =============================================================================
// Sweep abandoned response files
//
// Trigger: every submit and every poll. We delete:
//   - Any .done flag older than STALE_AGE_SEC (the frontend never read it)
//     plus its matching .out file
//   - Any .out file older than 2× STALE_AGE_SEC with NO .done partner
//     (the agent died or the loop crashed)
// Cheap to run because we only touch entries older than the threshold.
// =============================================================================
function sweepStaleResponses() {
    $dir = RESPONSE_DIR;
    if (!is_dir($dir)) return;
    $now      = time();
    $cutoff   = $now - STALE_AGE_SEC;
    $cutoffO  = $now - (STALE_AGE_SEC * 2);

    foreach (glob($dir . '/*.done') ?: [] as $done) {
        if (filemtime($done) < $cutoff) {
            $token = basename($done, '.done');
            @unlink($dir . '/' . $token . '.out');
            @unlink($dir . '/' . $token . '.out.err');
            @unlink($dir . '/' . $token . '.out.payload');
            @unlink($done);
            // HIGH-14: also clean matching queue files
            @unlink(QUEUE_DIR . '/' . $token . '_meta.json');
            @unlink(QUEUE_DIR . '/' . $token . '_model.txt');
            foreach (glob(QUEUE_DIR . '/*_prompt_' . $token . '.txt') ?: [] as $p) @unlink($p);
        }
    }
    foreach (glob($dir . '/*.out') ?: [] as $out) {
        if (filemtime($out) < $cutoffO) {
            $token = basename($out, '.out');
            // Only delete orphans (no matching .done)
            if (!file_exists($dir . '/' . $token . '.done')) {
                @unlink($out);
            }
        }
    }
    // HIGH-14: sweep orphan queue files (meta/model/prompt) — these accumulate
    // from sync-mode timeouts and aborted submits.
    if (is_dir(QUEUE_DIR)) {
        foreach (glob(QUEUE_DIR . '/*_meta.json') ?: [] as $q) {
            if (filemtime($q) < $cutoffO) @unlink($q);
        }
        foreach (glob(QUEUE_DIR . '/*_model.txt') ?: [] as $q) {
            if (filemtime($q) < $cutoffO) @unlink($q);
        }
        foreach (glob(QUEUE_DIR . '/*_prompt_*.txt') ?: [] as $q) {
            if (filemtime($q) < $cutoffO) @unlink($q);
        }
    }
}

// =============================================================================
// Strip terminal escape sequences and control chars from a chunk
// =============================================================================
function cleanChunk($s) {
    $s = preg_replace('/\x1B\[[0-9;?]*[a-zA-Z]/', '', $s);
    $s = preg_replace('/\x1B[=>]/',                '', $s);
    $s = preg_replace('/\r/',                      '', $s);
    $s = preg_replace('/\[\?[0-9]+[hl]/',          '', $s);
    $s = preg_replace('/\[[0-9]*[ABCDGJKM]/',      '', $s);
    $s = preg_replace('/\?[0-9]+[hl]/',            '', $s);
    $s = preg_replace('/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/', '', $s);
    // Strip Ollama's braille progress-spinner characters (U+2800..U+28FF)
    // along with the surrounding spaces. These appear at the start of every
    // Ollama response while the model loads and serve no purpose in chat.
    $s = preg_replace('/[\x{2800}-\x{28FF}]+\s*/u', '', $s);
    return $s;
}

// =============================================================================
// Apply Protanopia-safe diff replacement (only when actual diff detected)
// =============================================================================
function diffSafe($output) {
    if (preg_match('/^@@\s+-\d+/m', $output)) {
        $output = preg_replace('/^(\s*)\+(?!\+)/m', '$1[ADDED] ',   $output);
        $output = preg_replace('/^(\s*)-(?!-)/m',   '$1[REMOVED] ', $output);
    }
    return $output;
}

// --- 1. Parse and validate input ---
$raw = file_get_contents('php://input');
$in  = json_decode($raw, true);

if (!is_array($in)) {
    echo json_encode(['error' => true, 'response' => '[ERROR] Invalid request body'], JSON_UNESCAPED_UNICODE);
    exit;
}

$mode = $in['mode'] ?? 'sync';   // 'sync' | 'submit' | 'poll' | 'cleanup'

// =============================================================================
// MODE: cleanup — explicit per-token cleanup. Frontend calls this when it
// gives up on a request (cancel, page close handler). Idempotent — safe to
// call multiple times for the same token.
// =============================================================================
if ($mode === 'cleanup') {
    $token = preg_replace('/[^a-zA-Z0-9_.]/', '', $in['token'] ?? '');
    // Real stop: if the agent is mid-generation, SIGINT (Ctrl-C) its tmux pane to
    // interrupt the running CLI — not just abandon the client poll.
    $cancelAgent = $in['agent'] ?? '';
    if (in_array($cancelAgent, ['claude', 'gemini', 'ollama'], true)) {
        ck_agent_interrupt($cancelAgent);      // supervisor: SIGINT to the running CLI only; tmux: Ctrl-C into the pane (as before)
    }
    if ($token) {
        // Two situations must NOT throw away the answer the agent is still writing (2026-10-16):
        //  * the page is being reloaded or closed ("unload": the answer is not abandoned, the loop finishes it and saves it to the chat), and
        //  * the person pressed Stop (an agent is named): the loop keeps what was generated so far and saves that.
        // Before, both deleted the .out file under the loop's feet, so the chat got "[model returned nothing]" instead of the answer.
        $keepAnswer = !empty($in['unload']) || in_array($cancelAgent, ['claude', 'gemini', 'ollama'], true);
        if (!$keepAnswer) {
            @unlink(RESPONSE_DIR . '/' . $token . '.out');
            @unlink(RESPONSE_DIR . '/' . $token . '.done');
            @unlink(QUEUE_DIR    . '/' . $token . '_meta.json');
            @unlink(QUEUE_DIR    . '/' . $token . '_model.txt');
        }
        // A prompt that has not been picked up yet is withdrawn on Stop (a reload leaves it to run)
        if (empty($in['unload'])) {
            foreach (glob(QUEUE_DIR . '/*_prompt_' . $token . '.txt') ?: [] as $p) {
                @unlink($p);
            }
        }
    }
    sweepStaleResponses();
    echo json_encode(['ok' => true], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// MODE: poll — return new bytes from a specific offset
// =============================================================================
if ($mode === 'poll') {
    $token  = preg_replace('/[^a-zA-Z0-9_.]/', '', $in['token']  ?? '');
    $offset = max(0, intval($in['offset'] ?? 0));
    if (!$token) { echo json_encode(['error'=>true,'message'=>'Missing token'], JSON_UNESCAPED_UNICODE); exit; }

    $outFile  = RESPONSE_DIR . '/' . $token . '.out';
    $doneFile = RESPONSE_DIR . '/' . $token . '.done';

    clearstatcache(true, $outFile);
    clearstatcache(true, $doneFile);

    $exists = file_exists($outFile);
    $size   = $exists ? filesize($outFile) : 0;
    $done   = file_exists($doneFile);
    $chunk  = '';

    $rawLen = 0;
    if ($exists && $size > $offset) {
        $fh = fopen($outFile, 'rb');
        if ($fh) {
            fseek($fh, $offset);
            $chunk = fread($fh, $size - $offset);
            $rawLen = strlen($chunk);   // bytes actually consumed — cleanChunk() may change the length
            fclose($fh);
            $chunk = cleanChunk($chunk);
        }
    }

    // If complete, clean up the response files (after returning the final chunk)
    if ($done) {
        // Re-read final size to make sure we caught any last writes
        clearstatcache(true, $outFile);
        $finalSize = $exists ? filesize($outFile) : 0;
        if ($finalSize > $offset + $rawLen) {
            // There were last bytes added between our read and the done flag
            $fh = fopen($outFile, 'rb');
            if ($fh) {
                fseek($fh, $offset + $rawLen);
                $chunk .= cleanChunk(fread($fh, $finalSize - $offset - $rawLen));
                fclose($fh);
            }
            $size = $finalSize;
        }
        // Apply diff replacement only on full output (not partial chunks)
        // We can't really do it incrementally — best effort: apply at done
        if ($chunk !== '') $chunk = diffSafe($chunk);

        @unlink($doneFile);
        @unlink($outFile);
    }

    $resp = [
        'ok'     => true,
        'chunk'  => $chunk,
        'offset' => $size,
        'done'   => $done,
    ];
    if (!$done && !empty($in['agent'])) {
        // Who hosts the loop (session_backend.php): the supervisor when it is on and answers, tmux otherwise. This used to ask tmux alone, so
        // under the supervisor (no tmux sessions) every answer that took more than an instant was reported "Agent session died mid-response".
        $agentName = preg_replace('/[^a-z]/', '', $in['agent']);
        if (function_exists('ck_agent_alive')) {
            $_al = ck_agent_alive($agentName);
            if (!$_al['ok']) $resp['session_dead'] = true;
        } else {
            $sess = 'cockpit_' . $agentName;
            exec(TMUX_CMD . 'has-session -t ' . escapeshellarg($sess) . ' 2>&1', $_hOut, $_hRet);
            if ($_hRet !== 0 || !empty($_hOut)) $resp['session_dead'] = true;
        }
    }
    echo json_encode($resp, JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// SYNCHRONOUS or SUBMIT mode — both need agent + prompt
// =============================================================================
auth_require_writer();
if (empty($in['prompt']) || empty($in['agent'])) {
    echo json_encode(['response' => '[ERROR] Missing prompt or agent.', 'error' => true], JSON_UNESCAPED_UNICODE);
    exit;
}

$prompt = $in['prompt'];
$agent  = $in['agent']; // 'claude', 'gemini', 'ollama'

// --- 1b. Dispatch policy: sensitivity gate, free-only switch, monthly paid-prompt budget ---------
// Runs BEFORE anything is queued, so a refused prompt leaves no file behind. Local agents are
// never gated (nothing leaves the machine). See policy_lib.php for the rules and their limits.
require_once __DIR__ . '/policy_lib.php';
$_pol = policy_check($prompt, preg_replace('/[^a-z0-9_]/', '', strtolower((string)$agent)), (array)($in['policy'] ?? []));
if (!$_pol['allow']) {
    echo json_encode(['ok' => false, 'policy' => $_pol['policy']], JSON_UNESCAPED_UNICODE);
    exit;
}
$prompt = $_pol['prompt'];          // redacted when the person (or their setting) said so
$policyNotes = $_pol['notes'];      // said back to them in the chat, never silent

// --- 2. Check tmux session is alive ---
$session = 'cockpit_' . $agent;
$_alive = ck_agent_alive($agent);
if (!$_alive['ok']) {
    echo json_encode([
        'response' => '[ERROR] Session "' . $session . '" is not running. Start with: ~/scripts/cockpit_start.sh',
        'error'    => true
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// --- 3. Determine project and chat from request or state file ---
// HIGH-13 fix: read paths.json instead of hardcoding the projects root.
// HIGH-12 fix: allow Unicode chars (Hebrew/Spanish/etc.) in project/chat names.
$cockpitRoot = $PATHS['projects_root'];
$projectName = 'default';
$chatName    = 'default';

// Read state file for defaults
$stateFile = __DIR__ . '/project_state.json';
if (file_exists($stateFile)) {
    $state = json_decode(file_get_contents($stateFile), true);
    if (is_array($state)) {
        $projectName = $state['project_name'] ?? 'default';
        $chatName    = $state['chat_name']    ?? 'default';
    }
}

// Sanitize identifier: allow Unicode letters/digits + space/_/-/. — but no
// path separators or control bytes. The /u modifier enables Unicode property
// classes. Length-capped to prevent runaway names.
$_clean_id = function(string $s): string {
    $s = (string)preg_replace('/[\/\\\\\x00-\x1f]/u', '', $s);
    $s = (string)preg_replace('/\.\.+/u', '.', $s);   // collapse .. to .
    return mb_substr(trim($s), 0, 128);
};
// Frontend overrides state file
if (!empty($in['project'])) {
    $projectName = $_clean_id($in['project']);
    if ($projectName === '') $projectName = 'default';
}
if (!empty($in['chat'])) {
    $chatName = $_clean_id($in['chat']);
    if ($chatName === '') $chatName = 'default';
}

// Build chat file path
$projectDir = $cockpitRoot . '/' . $projectName;
$chatFile   = $projectDir . '/chat_' . $chatName . '.json';

// --- 4. Build the prompt and write the queue files ---
$token       = uniqid($agent . '_', true);
$promptFile  = QUEUE_DIR . '/' . $agent . '_prompt_' . $token . '.txt';
$outFile     = RESPONSE_DIR . '/' . $token . '.out';
$doneFile    = RESPONSE_DIR . '/' . $token . '.done';

if (!is_dir(QUEUE_DIR))    @mkdir(QUEUE_DIR,    0775, true);
if (!is_dir(RESPONSE_DIR)) @mkdir(RESPONSE_DIR, 0775, true);

// The prompt file is what agent_loop polls for (every 0.5s), so it must be the LAST
// thing published, and published atomically. It used to be written here, first,
// with the metadata (project, chat, per-user root, models) written ~35ms later after
// the capability apply and RAG. A loop pass that landed in that gap found a prompt
// with no metadata, silently fell back to the SHARED root and default models, and
// saved the turn to the wrong chat file — measured 2026-10-01: a turn answered and
// shown correctly, then written to LocalAIProjs/default/ instead of
// users/dario/default/, so it vanished from the chat on the next load. About 7% of
// turns since build 144, which tripled the gap by making the apply call do real
// work. The .part suffix is invisible to the loop's *_prompt_*.txt glob; rename()
// below makes the finished file appear in one step.
file_put_contents($promptFile . '.part', $prompt);
@chmod($promptFile . '.part', 0664);

// --- 4.5 Apply capabilities for this project ---
// Trigger capabilities.php to refresh the project's MCP configs and Ollama
// shim system-prompt before the agent starts working on the prompt. This is
// idempotent (cheap to re-run) and ensures we always launch with the
// up-to-date capability set even if the user toggled them mid-session.
$capsApplyResult = null;
if (function_exists('curl_init')) {
    // This call carried no session cookie, so capabilities.php answered 401 to
    // every single one of them and the staging step never ran. Found 2026-09-30:
    // .cockpit_caps on this rig was last written on 21 September, nine days of
    // prompts launched with a frozen capability set, and every toggle since had
    // no effect on the agents. It was invisible because the call is best-effort
    // by design and nothing looked at the answer.
    //
    // Releasing the session lock FIRST is not optional. PHP holds the session
    // file exclusively for the life of a request, so an authenticated inner call
    // would block until this request finishes while this request waits on it --
    // the same deadlock dossier.php hit, where it looked like every search had
    // silently timed out. Nothing here writes $_SESSION after this point.
    if (session_status() === PHP_SESSION_ACTIVE) session_write_close();
    $ch = curl_init();
    curl_setopt_array($ch, [
        CURLOPT_URL            => 'http://localhost/cockpit/capabilities.php?action=apply',
        CURLOPT_POST           => true,
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json',
                                   'Cookie: ' . ($_SERVER['HTTP_COOKIE'] ?? '')],
        CURLOPT_POSTFIELDS     => json_encode(['project' => $projectName], JSON_UNESCAPED_UNICODE),
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 5,
    ]);
    $resp = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    curl_close($ch);
    $capsApplyResult = json_decode($resp, true);
    // Still best-effort -- a failure here must never block the agent -- but no
    // longer silent: nine days of 401s went unnoticed precisely because nothing
    // recorded them.
    if ($code !== 200 || empty($capsApplyResult['ok'])) {
        error_log('bridge: capabilities apply failed (HTTP ' . $code . ') — agents run with the previously staged set');
    }
}
// Capabilities are best-effort — if PHP fails to apply them, we still let the
// agent run (without the capabilities). This is logged in agent_loop's stderr
// for debugging but never blocks the user.

// --- 5. Build meta data so agent_loop knows what to do ---
$claudeModel = preg_replace('/[^a-zA-Z0-9_:\-]/', '', $in['claude_model'] ?? 'sonnet');
$geminiModel = preg_replace('/[^a-zA-Z0-9_:\-\.]/', '', $in['gemini_model'] ?? 'auto');
// Supplier-control prompt_prefix (effort, etc.) arrives base64-encoded so the
// option text survives the pipeline. Validate it's base64 and pass it through;
// agent_loop decodes and prepends it to the prompt.
$b64 = fn($s) => (is_string($s) && preg_match('#^[A-Za-z0-9+/=]*$#', $s)) ? $s : '';
$claudeEffort = $b64($in['claude_effort'] ?? '');
$geminiEffort = $b64($in['gemini_effort'] ?? '');
$claudeArgs   = $b64($in['claude_args'] ?? '');   // cli_args (e.g. --effort high)
$geminiArgs   = $b64($in['gemini_args'] ?? '');
// Working-style + multi-agent mode active when the user sent this prompt.
// Persisted per exchange so reloaded history can show which model/task combo
// produced each answer (e.g. [CLAUDE · Sonnet 4.6 · Single · Chat]).
$style = preg_replace('/[^a-z]/', '', strtolower($in['style'] ?? ''));
// 'mode' is the transport action (submit/poll); the multi-agent mode travels as ma_mode.
// Multi-agent mode (single/broadcast) travels as ma_mode — kept in its OWN
// variable: $mode is the TRANSPORT action (submit/poll/sync) and overwriting it
// here made the 'submit' branch below unreachable, so every prompt silently fell
// through to the blocking sync path (and its reply carries no 'rag' field).
$maMode = preg_replace('/[^a-z]/', '', strtolower($in['ma_mode'] ?? ''));
// Push-RAG: when the "RAG Search" capability is on, the best matching snippets /
// library notes / sources for this prompt ride along with the dispatch. base64 so
// the multi-line block survives agent_loop's naive json_get (2026-09-22).
// Images the agent takes on its own command line (catalog image_mode 'flag').
// Paths only, and only ones that exist and live under a directory this user's
// Cockpit owns — a queue file is not a place to accept arbitrary filesystem
// paths from a browser.
$imagePaths = [];
foreach ((array)($in['images'] ?? []) as $_p) {
    if (!is_string($_p) || $_p === '') continue;
    $rp = realpath($_p);
    if ($rp === false || !is_file($rp)) continue;
    $okRoot = false;
    foreach ([(string)$PATHS['cockpit_data'], (string)$cockpitRoot] as $root) {
        $root = rtrim((string)$root, '/');
        if ($root !== '' && str_starts_with($rp, $root . '/')) { $okRoot = true; break; }
    }
    if (!$okRoot) continue;
    $imagePaths[] = $rp;
    if (count($imagePaths) >= 8) break;     // a prompt is not a photo album
}

require_once __DIR__ . '/rag_lib.php';
[$ragBlock, $ragTitles, $ragInfo] = rag_context($prompt, (string)$PATHS['cockpit_data'], (string)$cockpitRoot, (string)$projectName);

$metaData = json_encode([
    'project'       => $projectName,
    'chat'          => $chatName,
    // Per-user projects root (paths.php scopes this to /users/<user> when logged
    // in). agent_loop is a session-less daemon that would otherwise write to the
    // SHARED root — so it must write the chat where THIS user's UI reads it.
    'projects_root' => $cockpitRoot,
    // Per-user cockpit_data dir — lets the session-less worker_relay (invoked by
    // agent_loop) read THIS user's encrypted worker keys (workers_keys.enc)
    // instead of the shared root's.
    'cockpit_data'  => $PATHS['cockpit_data'],
    // Web root so agent_loop can locate worker_relay.php (docroot varies per
    // distro; the old hardcoded /cockpit/v2/ path did not exist on this install).
    'web_root'      => $PATHS['web_root'],
    'style'         => $style,
    'mode'          => $maMode,
    'claude_model'  => $claudeModel,
    'gemini_model'  => $geminiModel,
    'claude_effort' => $claudeEffort,
    'gemini_effort' => $geminiEffort,
    'claude_args'   => $claudeArgs,
    'gemini_args'   => $geminiArgs,
    'rag'           => $ragBlock === '' ? '' : base64_encode($ragBlock),
    // Newline-free, single line: agent_loop's json_get is a grep/sed pair that
    // cannot read a multi-line value.
    'images'        => implode('|', $imagePaths)
// UNESCAPED_SLASHES is CRITICAL: projects_root/web_root/cockpit_data are absolute
// paths, and agent_loop's json_get is a naive grep/sed that does NOT un-escape.
// Without this, "\/home\/…" reaches agent_loop as literal backslashes → a bad
// relative path resolved under COCKPIT_ROOT (doubled/garbage dir) → chats saved
// to the wrong place, so the UI's real chat file stayed empty.
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
file_put_contents(QUEUE_DIR . '/' . $token . '_meta.json', $metaData);

// For Ollama, also write the model selection
if ($agent === 'ollama' && !empty($in['model'])) {
    $modelRaw = $in['model'];
    if (preg_match('#^[a-zA-Z0-9_./:\-]+$#', $modelRaw)) {
        file_put_contents(QUEUE_DIR . '/' . $token . '_model.txt', $modelRaw);
    }
}

// Everything the loop needs now exists: publish the prompt, last.
if (!@rename($promptFile . '.part', $promptFile)) {
    @unlink($promptFile . '.part');
    @unlink(QUEUE_DIR . '/' . $token . '_meta.json');
    @unlink(QUEUE_DIR . '/' . $token . '_model.txt');
    http_response_code(500);
    echo json_encode(['ok' => false, 'error' => 'Could not queue the prompt (queue directory not writable?)'], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// MODE: submit — return the token and let the frontend poll
// =============================================================================
if ($mode === 'submit') {
    sweepStaleResponses();   // opportunistic cleanup of abandoned files
    echo json_encode([
        'ok'    => true,
        'token' => basename($promptFile, '.txt'),  // matches what agent_loop expects
        'short' => $token,                          // shorter id for UI
        'agent' => $agent,
        'rag'   => $ragTitles,                      // what push-RAG added, so the chat can say so
        // How many near misses the relevance floor turned away -- reported ONLY when
        // nothing was injected, because that is the one case that needs explaining: the
        // library had loosely related items and none covered the question. Without this
        // a refusal looks identical to "the library has nothing at all".
        'rag_declined' => ($ragTitles ? 0 : (int)($ragInfo['declined'] ?? 0)),
        'policy_notes' => $policyNotes ?? [],        // redaction / budget lines for the chat
        // Retrieval only helps if the model can read prose. Warn when the chosen
        // local model cannot, rather than letting it answer badly from good
        // context — which looks like the Library failing.
        'rag_warn' => ($ragTitles && $agent === 'ollama' && !empty($in['model']))
                        ? rag_model_fit((string)$in['model']) : null,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// MODE: sync (legacy) — wait for done and return full response
// =============================================================================

// --- 6. Poll for done file ---
$maxCycles = MAX_WAIT * (1000000 / POLL_INTERVAL);
$cycles    = 0;

while (!file_exists($doneFile) && $cycles < $maxCycles) {
    usleep(POLL_INTERVAL);
    clearstatcache(true, $doneFile);
    $cycles++;
}

if (!file_exists($doneFile)) {
    // HIGH-14 fix: clean up ALL queue files for this token, not just the prompt.
    // Previously $meta.json and $model.txt leaked on every sync-mode timeout.
    @unlink($promptFile);
    @unlink(QUEUE_DIR . '/' . $token . '_meta.json');
    @unlink(QUEUE_DIR . '/' . $token . '_model.txt');
    echo json_encode([
        'response' => '[ERROR] Timeout: agent did not respond within ' . MAX_WAIT . ' seconds. '
                    . 'Check the session: tmux -S ' . TMUX_SOCKET . ' attach -t ' . $session,
        'error'    => true
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// --- 7. Read response ---
$output = file_exists($outFile) ? file_get_contents($outFile) : '';
@unlink($doneFile);
@unlink($outFile);

// --- 8. Clean and apply diff-safe ---
$output = cleanChunk($output);
$output = trim($output);

if ($output === '') {
    $output = '[WARNING] Agent returned empty response. Check: tmux -S ' . TMUX_SOCKET . ' attach -t ' . $session;
}

$output = diffSafe($output);

echo json_encode(['response' => $output, 'error' => false, 'agent' => $agent], JSON_UNESCAPED_UNICODE);
?>
