<?php
// =============================================================================
// a2a.php — A2A (Agent-to-Agent) Protocol Server for Cockpit
// Dario Ruggi / Cockpit
//
// Implements Google's A2A protocol (simplified REST subset) so Cockpit's agents
// can be reached by external agents or remote Cockpit instances.
//
// Endpoints (matches A2A spec):
//   POST /a2a.php?ep=agent-card          — public agent card (discovery)
//   POST /a2a.php?ep=message/send        — send message → create/continue task
//   POST /a2a.php?ep=message/stream      — streaming variant (SSE)
//   GET  /a2a.php?ep=tasks/{id}          — get task state
//   POST /a2a.php?ep=tasks/{id}/cancel   — cancel a task
//
// Transport modes:
//   Plain JSON   — for local/trusted callers (same machine, LAN)
//   Encrypted    — Dario-10S cipher wrap for Anywhere relay traffic
//                  Header: X-Cockpit-Encrypted: 1
//                  Body: base64(Dario10S_enc(JSON))
//                  Response: same format
// =============================================================================

header('Content-Type: application/json');
require_once __DIR__ . '/paths.php';

// ── Who may call this ───────────────────────────────────────────────────────
// A2A is OFF until the person turns it on in the app (Hive → A2A). Then a peer
// authenticates with the install's token AND must come from an allowed address;
// everything else still needs a normal Cockpit session. Before 2026-09-22 the
// file simply required a session, so no external agent could ever use it — the
// protocol server existed with no way in and no way to switch it on.
$A2A_CFG_F = rtrim((string)$PATHS['cockpit_data'], '/') . '/a2a_config.json';
$A2A_CFG   = is_readable($A2A_CFG_F) ? (json_decode((string)file_get_contents($A2A_CFG_F), true) ?: []) : [];
function a2a_ip_allowed(array $cfg): bool {
    $ip = (string)($_SERVER['REMOTE_ADDR'] ?? '');
    if ($ip === '') return false;
    foreach ((array)($cfg['allow'] ?? ['127.0.0.1', '::1']) as $rule) {
        $rule = trim((string)$rule);
        if ($rule === '' ) continue;
        if ($rule === '*' || $rule === $ip) return true;
        if (str_contains($rule, '/')) {                       // CIDR (IPv4)
            [$net, $bits] = explode('/', $rule, 2);
            $bits = (int)$bits;
            if (filter_var($net, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) && filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) && $bits >= 0 && $bits <= 32) {
                $mask = $bits === 0 ? 0 : (~0 << (32 - $bits)) & 0xFFFFFFFF;
                if ((ip2long($ip) & $mask) === (ip2long($net) & $mask)) return true;
            }
        }
    }
    return false;
}
$_a2aTok = (string)($_SERVER['HTTP_X_COCKPIT_A2A_TOKEN'] ?? '');
if ($_a2aTok === '' && preg_match('/Bearer\s+(\S+)/i', (string)($_SERVER['HTTP_AUTHORIZATION'] ?? ''), $_m)) $_a2aTok = $_m[1];
$A2A_PEER = !empty($A2A_CFG['enabled']) && !empty($A2A_CFG['token']) && $_a2aTok !== ''
            && hash_equals((string)$A2A_CFG['token'], $_a2aTok) && a2a_ip_allowed($A2A_CFG);
if (!$A2A_PEER) {
    require_once __DIR__ . '/auth.php';   // no valid peer token → ordinary session rules
}

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) ed_demo_stub();

// ── Config API for the app (session only) ───────────────────────────────────
if (!$A2A_PEER && isset($_GET['action'])) {
    $act = $_GET['action'];
    $in  = json_decode((string)file_get_contents('php://input'), true) ?: [];
    $save = function (array $c) use ($A2A_CFG_F) {
        $ok = @file_put_contents($A2A_CFG_F, json_encode($c, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES), LOCK_EX) !== false;
        if ($ok) @chmod($A2A_CFG_F, 0660);
        return $ok;
    };
    if ($act === 'config') {
        $url = (($_SERVER['HTTPS'] ?? '') ? 'https' : 'http') . '://' . ($_SERVER['HTTP_HOST'] ?? 'localhost')
             . dirname((string)($_SERVER['SCRIPT_NAME'] ?? '/cockpit/a2a.php')) . '/a2a.php';
        echo json_encode(['ok' => true, 'enabled' => !empty($A2A_CFG['enabled']),
            'has_token' => !empty($A2A_CFG['token']), 'token' => (string)($A2A_CFG['token'] ?? ''),
            'allow' => (array)($A2A_CFG['allow'] ?? ['127.0.0.1', '::1']), 'url' => $url,
            'calls' => (array)($A2A_CFG['calls'] ?? [])], JSON_UNESCAPED_UNICODE);
        exit;
    }
    if ($act === 'set_config') {
        $c = $A2A_CFG;
        if (isset($in['enabled'])) $c['enabled'] = (bool)$in['enabled'];
        if (isset($in['allow']) && is_array($in['allow'])) {
            $c['allow'] = array_values(array_filter(array_map(fn($x) => preg_replace('/[^0-9a-fA-F:.\/*]/', '', (string)$x), $in['allow'])));
        }
        if (!empty($in['regenerate']) || (!empty($c['enabled']) && empty($c['token']))) $c['token'] = bin2hex(random_bytes(24));
        $c['updated'] = date('c');
        echo json_encode(['ok' => $save($c), 'enabled' => !empty($c['enabled']), 'token' => (string)($c['token'] ?? ''),
                          'allow' => (array)($c['allow'] ?? [])], JSON_UNESCAPED_UNICODE);
        exit;
    }
}

// --- Dario-10S cipher (same as encryptester.php) ----------------------------

function a2a_encrypt(string $data, string $key, int $keyNum): string {
    $kl = strlen($key); $out = '';
    for ($i = 0, $n = strlen($data); $i < $n; $i++)
        $out .= chr(((ord($data[$i]) ^ ord($key[$i % $kl])) + $keyNum) % 256);
    return base64_encode($out);
}
function a2a_decrypt(string $b64, string $key, int $keyNum): string {
    $kl = strlen($key); $raw = base64_decode($b64); $out = '';
    for ($i = 0, $n = strlen($raw); $i < $n; $i++)
        $out .= chr(((ord($raw[$i]) - $keyNum + 256) % 256) ^ ord($key[$i % $kl]));
    return $out;
}

// --- Transport: decrypt incoming / encrypt outgoing -------------------------

function a2a_load_transport_key(): ?array {
    global $PATHS;
    $f = $PATHS['cockpit_data'] . '/a2a_key.json';
    if (!is_readable($f)) return null;
    $j = json_decode((string)file_get_contents($f), true);
    if (!is_array($j) || empty($j['key']) || !isset($j['keynum'])) return null;
    return ['key' => (string)$j['key'], 'keynum' => (int)$j['keynum']];
}

$_a2a_encrypted = !empty($_SERVER['HTTP_X_COCKPIT_ENCRYPTED']);
$_a2a_key = null;

function a2a_read_body(): string {
    global $_a2a_encrypted, $_a2a_key;
    $raw = (string)file_get_contents('php://input');
    if (!$_a2a_encrypted) return $raw;
    $_a2a_key = a2a_load_transport_key();
    if (!$_a2a_key) { http_response_code(403); echo '{"error":"No transport key configured"}'; exit; }
    return a2a_decrypt(trim($raw), $_a2a_key['key'], $_a2a_key['keynum']);
}

function a2a_respond(array $data): void {
    global $_a2a_encrypted, $_a2a_key;
    $json = json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    if ($_a2a_encrypted && $_a2a_key) {
        echo a2a_encrypt($json, $_a2a_key['key'], $_a2a_key['keynum']);
    } else {
        echo $json;
    }
    exit;
}

function a2a_error(int $code, string $msg): void {
    http_response_code($code);
    a2a_respond(['error' => $msg]);
}

// --- Task storage -----------------------------------------------------------

function a2a_tasks_dir(): string {
    global $PATHS;
    $d = $PATHS['cockpit_data'] . '/a2a_tasks';
    if (!is_dir($d)) @mkdir($d, 0775, true);
    return $d;
}

function a2a_task_path(string $id): string {
    $safe = preg_replace('/[^a-zA-Z0-9_-]/', '', $id);
    return a2a_tasks_dir() . '/' . $safe . '.json';
}

function a2a_load_task(string $id): ?array {
    $f = a2a_task_path($id);
    if (!is_readable($f)) return null;
    return json_decode((string)file_get_contents($f), true);
}

function a2a_save_task(array $task): void {
    file_put_contents(a2a_task_path($task['id']), json_encode($task, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
}

function a2a_gen_id(): string {
    return sprintf('%04x%04x-%04x-%04x-%04x-%04x%04x%04x',
        mt_rand(0, 0xffff), mt_rand(0, 0xffff),
        mt_rand(0, 0xffff),
        mt_rand(0, 0x0fff) | 0x4000,
        mt_rand(0, 0x3fff) | 0x8000,
        mt_rand(0, 0xffff), mt_rand(0, 0xffff), mt_rand(0, 0xffff));
}

function a2a_now(): string {
    return gmdate('Y-m-d\TH:i:s\Z');
}

// --- Agent Card (discovery) -------------------------------------------------

function a2a_agent_card(): array {
    return [
        'name'        => 'AI Cockpit',
        'description' => 'Multi-agent orchestration cockpit with Claude, Gemini, Ollama, and HTTP Workers.',
        'url'         => (isset($_SERVER['HTTPS']) ? 'https' : 'http') . '://' .
                         ($_SERVER['HTTP_HOST'] ?? 'localhost') . '/cockpit/a2a.php',
        'version'     => '1.0.0',
        'protocol_version' => '0.2',
        'capabilities' => [
            'streaming'          => true,
            'push_notifications' => false,
        ],
        'default_input_modes'  => ['text/plain', 'application/json'],
        'default_output_modes' => ['text/plain', 'application/json'],
        'skills' => [
            [
                'id'          => 'chat',
                'name'        => 'Chat',
                'description' => 'Send a message to any Cockpit agent (Claude, Gemini, Ollama, Workers).',
                'tags'        => ['chat', 'ai', 'multi-agent'],
            ],
            [
                'id'          => 'orchestrate',
                'name'        => 'Orchestrate',
                'description' => 'Plan and execute multi-step tasks using the Cockpit orchestrator.',
                'tags'        => ['planning', 'orchestration', 'multi-agent'],
            ],
            [
                'id'          => 'tool',
                'name'        => 'Run Tool',
                'description' => 'Execute a local tool (ffmpeg, whisper, vision, etc.) on a file.',
                'tags'        => ['tools', 'media', 'vision', 'transcription'],
            ],
        ],
    ];
}

// --- Dispatch message to Cockpit agent via bridge.php -----------------------

function a2a_dispatch_to_agent(array $message, string $task_id, ?string $agent = null): array {
    global $PATHS;

    // Extract text from message parts
    $text = '';
    foreach (($message['parts'] ?? []) as $part) {
        if (isset($part['text'])) $text .= $part['text'] . "\n";
        elseif (isset($part['data'])) $text .= json_encode($part['data'], JSON_UNESCAPED_UNICODE) . "\n";
    }
    $text = trim($text);
    if ($text === '') return ['error' => 'Empty message'];

    // Determine agent (default: claude)
    $agent = $agent ?: ($message['metadata']['agent'] ?? 'claude');
    $valid = ['claude', 'gemini', 'ollama', 'workers'];
    if (!in_array($agent, $valid)) $agent = 'claude';

    // Submit via bridge.php (streaming mode)
    $bridge_url = 'http://127.0.0.1/cockpit/bridge.php';
    $payload = json_encode([
        'agent'  => $agent,
        'prompt' => $text,
        'mode'   => 'submit',
        'model'  => $message['metadata']['model'] ?? null,
    ], JSON_UNESCAPED_UNICODE);

    $ch = curl_init($bridge_url);
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => $payload,
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 5,
    ]);
    $resp = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);

    if ($code !== 200) return ['error' => 'Bridge error: HTTP ' . $code];
    $data = json_decode((string)$resp, true);
    if (!is_array($data) || !isset($data['token'])) return ['error' => 'Bridge error: ' . ($data['error'] ?? 'no token')];

    return ['token' => $data['token'], 'agent' => $agent];
}

// --- Poll bridge for response -----------------------------------------------

function a2a_poll_bridge(string $token): array {
    $url = 'http://127.0.0.1/cockpit/bridge.php';
    $payload = json_encode(['mode' => 'poll', 'token' => $token, 'offset' => 0], JSON_UNESCAPED_UNICODE);
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => $payload,
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 120,
    ]);
    $resp = curl_exec($ch);
    curl_close($ch);
    return json_decode((string)$resp, true) ?: [];
}

// --- Endpoint routing -------------------------------------------------------

$ep = $_GET['ep'] ?? $_POST['ep'] ?? '';

// Agent Card (discovery)
if ($ep === 'agent-card' || $ep === '.well-known/agent.json') {
    a2a_respond(a2a_agent_card());
}

// Send Message
if ($ep === 'message/send') {
    $body = json_decode(a2a_read_body(), true);
    if (!is_array($body) || empty($body['message'])) a2a_error(400, 'Missing message');

    $msg = $body['message'];
    $task_id = $msg['task_id'] ?? null;
    $context_id = $msg['context_id'] ?? a2a_gen_id();

    // Resume existing task or create new
    $task = $task_id ? a2a_load_task($task_id) : null;
    if (!$task) {
        $task_id = a2a_gen_id();
        $task = [
            'id'         => $task_id,
            'context_id' => $context_id,
            'status'     => ['state' => 'submitted', 'timestamp' => a2a_now()],
            'artifacts'  => [],
            'history'    => [],
            'metadata'   => $body['metadata'] ?? [],
        ];
    }

    // Add incoming message to history
    $msg['message_id'] = $msg['message_id'] ?? a2a_gen_id();
    $msg['role'] = 'user';
    $task['history'][] = $msg;
    $task['status'] = ['state' => 'working', 'timestamp' => a2a_now()];
    a2a_save_task($task);

    // Dispatch to agent
    $result = a2a_dispatch_to_agent($msg, $task_id, $body['metadata']['agent'] ?? null);
    if (isset($result['error'])) {
        $task['status'] = ['state' => 'failed', 'message' => ['role' => 'agent', 'parts' => [['text' => $result['error']]]], 'timestamp' => a2a_now()];
        a2a_save_task($task);
        a2a_respond(['task' => $task]);
    }

    // Store bridge token for polling
    $task['metadata']['_bridge_token'] = $result['token'];
    $task['metadata']['_agent'] = $result['agent'];
    a2a_save_task($task);

    // If return_immediately, respond now
    $config = $body['configuration'] ?? [];
    if (!empty($config['return_immediately'])) {
        a2a_respond(['task' => $task]);
    }

    // Otherwise wait for completion (sync mode, up to 120s)
    $deadline = time() + 120;
    $full_text = '';
    while (time() < $deadline) {
        usleep(500000);
        $poll = a2a_poll_bridge($result['token']);
        if (!empty($poll['chunk'])) $full_text .= $poll['chunk'];
        if (!empty($poll['done'])) break;
    }

    // Build response
    $agent_msg = [
        'message_id' => a2a_gen_id(),
        'role'       => 'agent',
        'parts'      => [['text' => $full_text]],
    ];
    $task['history'][] = $agent_msg;
    $task['artifacts'] = [[
        'artifact_id' => a2a_gen_id(),
        'name'        => 'response',
        'parts'       => [['text' => $full_text]],
    ]];
    $task['status'] = [
        'state'     => $full_text !== '' ? 'completed' : 'failed',
        'timestamp' => a2a_now(),
    ];
    unset($task['metadata']['_bridge_token']);
    a2a_save_task($task);
    a2a_respond(['task' => $task]);
}

// Stream Message (SSE)
if ($ep === 'message/stream') {
    header('Content-Type: text/event-stream');
    header('Cache-Control: no-cache');
    header('Connection: keep-alive');

    $body = json_decode(a2a_read_body(), true);
    if (!is_array($body) || empty($body['message'])) {
        echo "data: " . json_encode(['error' => 'Missing message'], JSON_UNESCAPED_UNICODE) . "\n\n";
        exit;
    }

    $msg = $body['message'];
    $task_id = a2a_gen_id();
    $context_id = $msg['context_id'] ?? a2a_gen_id();
    $task = [
        'id' => $task_id, 'context_id' => $context_id,
        'status' => ['state' => 'submitted', 'timestamp' => a2a_now()],
        'artifacts' => [], 'history' => [$msg], 'metadata' => $body['metadata'] ?? [],
    ];
    a2a_save_task($task);

    // Send initial status
    echo "data: " . json_encode(['status_update' => ['task_id' => $task_id, 'context_id' => $context_id, 'status' => $task['status']]], JSON_UNESCAPED_UNICODE) . "\n\n";
    ob_flush(); flush();

    // Dispatch
    $result = a2a_dispatch_to_agent($msg, $task_id, $body['metadata']['agent'] ?? null);
    if (isset($result['error'])) {
        $task['status'] = ['state' => 'failed', 'timestamp' => a2a_now()];
        echo "data: " . json_encode(['status_update' => ['task_id' => $task_id, 'context_id' => $context_id, 'status' => $task['status']]], JSON_UNESCAPED_UNICODE) . "\n\n";
        a2a_save_task($task);
        exit;
    }

    // Working
    $task['status'] = ['state' => 'working', 'timestamp' => a2a_now()];
    echo "data: " . json_encode(['status_update' => ['task_id' => $task_id, 'context_id' => $context_id, 'status' => $task['status']]], JSON_UNESCAPED_UNICODE) . "\n\n";
    ob_flush(); flush();

    // Poll and stream chunks
    $offset = 0;
    $deadline = time() + 120;
    while (time() < $deadline) {
        usleep(300000);
        $poll_url = 'http://127.0.0.1/cockpit/bridge.php';
        $ch = curl_init($poll_url);
        curl_setopt_array($ch, [
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => json_encode(['mode' => 'poll', 'token' => $result['token'], 'offset' => $offset], JSON_UNESCAPED_UNICODE),
            CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
            CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 5,
        ]);
        $resp = json_decode((string)curl_exec($ch), true) ?: [];
        curl_close($ch);

        if (!empty($resp['chunk'])) {
            $offset += strlen($resp['chunk']);
            echo "data: " . json_encode(['artifact_update' => [
                'task_id' => $task_id, 'context_id' => $context_id,
                'artifact' => ['artifact_id' => 'stream', 'parts' => [['text' => $resp['chunk']]]],
            ]], JSON_UNESCAPED_UNICODE) . "\n\n";
            ob_flush(); flush();
        }
        if (!empty($resp['done'])) break;
    }

    // Completed
    $task['status'] = ['state' => 'completed', 'timestamp' => a2a_now()];
    echo "data: " . json_encode(['status_update' => ['task_id' => $task_id, 'context_id' => $context_id, 'status' => $task['status']]], JSON_UNESCAPED_UNICODE) . "\n\n";
    a2a_save_task($task);
    exit;
}

// Get Task
if (preg_match('#^tasks/([a-zA-Z0-9_-]+)$#', $ep, $m)) {
    $task = a2a_load_task($m[1]);
    if (!$task) a2a_error(404, 'Task not found');
    a2a_respond($task);
}

// Cancel Task
if (preg_match('#^tasks/([a-zA-Z0-9_-]+)/cancel$#', $ep, $m)) {
    $task = a2a_load_task($m[1]);
    if (!$task) a2a_error(404, 'Task not found');
    $task['status'] = ['state' => 'canceled', 'timestamp' => a2a_now()];
    a2a_save_task($task);
    a2a_respond($task);
}

// List Tasks
if ($ep === 'tasks') {
    $dir = a2a_tasks_dir();
    $tasks = [];
    foreach (glob($dir . '/*.json') as $f) {
        $t = json_decode((string)file_get_contents($f), true);
        if ($t) {
            unset($t['metadata']['_bridge_token']);
            $tasks[] = $t;
        }
    }
    // Filter by context_id if provided
    $ctx = $_GET['context_id'] ?? null;
    if ($ctx) $tasks = array_values(array_filter($tasks, fn($t) => ($t['context_id'] ?? '') === $ctx));
    // Filter by state
    $state = $_GET['status'] ?? null;
    if ($state) $tasks = array_values(array_filter($tasks, fn($t) => ($t['status']['state'] ?? '') === $state));

    a2a_respond(['tasks' => array_slice($tasks, 0, 50), 'total_size' => count($tasks)]);
}

a2a_error(400, 'Unknown endpoint: ' . $ep);
