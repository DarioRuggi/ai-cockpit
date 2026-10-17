<?php
// =============================================================================
// a2a_client.php — A2A Client for Cockpit
// Dario Ruggi / Cockpit
//
// Lets Cockpit call external A2A-compatible agents. Used by:
//   - The orchestrator (delegate subtasks to remote agents)
//   - Anywhere relay (call rig agents from a lite device)
//   - Workers (external A2A agents as another supplier type)
//
// Endpoints:
//   POST ?action=discover   — fetch an agent's card
//   POST ?action=send       — send message to an A2A agent
//   POST ?action=status     — get task status from remote agent
//   POST ?action=cancel     — cancel a remote task
//   POST ?action=agents     — list configured remote agents
//   POST ?action=add        — register a remote A2A agent
//   POST ?action=remove     — remove a registered agent
// =============================================================================

header('Content-Type: application/json');
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) {
    header('Content-Type: application/json');
    $__demoAction = $_GET['action'] ?? $_POST['action'] ?? '';
    if ($__demoAction === 'agents') {
        echo json_encode(['ok'=>true,'agents'=>[
            'demo-remote-1' => ['id'=>'demo-remote-1','name'=>'Home Server Agent','url'=>'https://example-remote.local:8443','description'=>'A second Cockpit instance on another machine.','encrypted'=>true,'added_at'=>'2026-06-01T00:00:00Z'],
        ]]); exit;
    }
    ed_demo_stub();
}

// --- Dario-10S cipher (for encrypted transport to remote agents) ------------

function a2a_client_encrypt(string $data, string $key, int $keyNum): string {
    $kl = strlen($key); $out = '';
    for ($i = 0, $n = strlen($data); $i < $n; $i++)
        $out .= chr(((ord($data[$i]) ^ ord($key[$i % $kl])) + $keyNum) % 256);
    return base64_encode($out);
}
function a2a_client_decrypt(string $b64, string $key, int $keyNum): string {
    $kl = strlen($key); $raw = base64_decode($b64); $out = '';
    for ($i = 0, $n = strlen($raw); $i < $n; $i++)
        $out .= chr(((ord($raw[$i]) - $keyNum + 256) % 256) ^ ord($key[$i % $kl]));
    return $out;
}

// --- Remote agents registry -------------------------------------------------

function a2a_agents_file(): string {
    global $PATHS;
    return $PATHS['cockpit_data'] . '/a2a_agents.json';
}

function a2a_load_agents(): array {
    $f = a2a_agents_file();
    if (!is_readable($f)) return [];
    $j = json_decode((string)file_get_contents($f), true);
    return is_array($j) ? $j : [];
}

function a2a_save_agents(array $agents): void {
    file_put_contents(a2a_agents_file(), json_encode($agents, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
}

// --- HTTP helper (with optional Dario-10S encryption) -----------------------

function a2a_request(string $url, array $payload, ?array $transport_key = null, int $timeout = 120): array {
    $json = json_encode($payload, JSON_UNESCAPED_UNICODE);
    $headers = ['Content-Type: application/json'];

    if ($transport_key) {
        $json = a2a_client_encrypt($json, $transport_key['key'], $transport_key['keynum']);
        $headers[] = 'X-Cockpit-Encrypted: 1';
    }

    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => $json,
        CURLOPT_HTTPHEADER     => $headers,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => $timeout,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_MAXREDIRS      => 3,
    ]);
    $resp = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $err  = curl_error($ch);
    curl_close($ch);

    if ($resp === false) return ['ok' => false, 'error' => 'cURL: ' . $err];

    // Decrypt if encrypted transport
    if ($transport_key) {
        $resp = a2a_client_decrypt(trim($resp), $transport_key['key'], $transport_key['keynum']);
    }

    $data = json_decode($resp, true);
    if (!is_array($data)) return ['ok' => false, 'error' => 'Invalid JSON response (HTTP ' . $code . ')'];

    return ['ok' => true, 'code' => $code, 'data' => $data];
}

// --- Actions ----------------------------------------------------------------

$in = json_decode((string)file_get_contents('php://input'), true) ?: [];
$action = $_GET['action'] ?? $in['action'] ?? '';

// Discover: fetch agent card
if ($action === 'discover') {
    $url = trim($in['url'] ?? '');
    if ($url === '') { echo json_encode(['ok' => false, 'error' => 'Missing url'], JSON_UNESCAPED_UNICODE); exit; }

    // Try well-known path first, then ?ep=agent-card
    $card_url = rtrim($url, '/');
    if (strpos($card_url, '?') === false) $card_url .= '?ep=agent-card';

    $r = a2a_request($card_url, [], null, 10);
    echo json_encode($r, JSON_UNESCAPED_UNICODE); exit;
}

// Send message to remote agent
if ($action === 'send') {
    $agent_id = $in['agent_id'] ?? '';
    $agents = a2a_load_agents();
    $agent = $agents[$agent_id] ?? null;

    if (!$agent) { echo json_encode(['ok' => false, 'error' => 'Unknown agent: ' . $agent_id], JSON_UNESCAPED_UNICODE); exit; }

    $url = rtrim($agent['url'], '/') . '?ep=message/send';
    $transport_key = !empty($agent['encrypted']) ? ['key' => $agent['key'], 'keynum' => $agent['keynum']] : null;

    $payload = [
        'message' => [
            'message_id' => sprintf('%04x%04x', mt_rand(0, 0xffff), mt_rand(0, 0xffff)),
            'role'       => 'user',
            'parts'      => $in['parts'] ?? [['text' => $in['text'] ?? '']],
            'context_id' => $in['context_id'] ?? null,
            'task_id'    => $in['task_id'] ?? null,
            'metadata'   => $in['metadata'] ?? [],
        ],
        'configuration' => $in['configuration'] ?? [],
        'metadata'      => $in['request_metadata'] ?? [],
    ];

    $r = a2a_request($url, $payload, $transport_key);
    echo json_encode($r, JSON_UNESCAPED_UNICODE); exit;
}

// Get task status from remote agent
if ($action === 'status') {
    $agent_id = $in['agent_id'] ?? '';
    $task_id  = $in['task_id'] ?? '';
    $agents = a2a_load_agents();
    $agent = $agents[$agent_id] ?? null;
    if (!$agent) { echo json_encode(['ok' => false, 'error' => 'Unknown agent'], JSON_UNESCAPED_UNICODE); exit; }

    $url = rtrim($agent['url'], '/') . '?ep=tasks/' . urlencode($task_id);
    $transport_key = !empty($agent['encrypted']) ? ['key' => $agent['key'], 'keynum' => $agent['keynum']] : null;

    $r = a2a_request($url, [], $transport_key, 10);
    echo json_encode($r, JSON_UNESCAPED_UNICODE); exit;
}

// Cancel remote task
if ($action === 'cancel') {
    $agent_id = $in['agent_id'] ?? '';
    $task_id  = $in['task_id'] ?? '';
    $agents = a2a_load_agents();
    $agent = $agents[$agent_id] ?? null;
    if (!$agent) { echo json_encode(['ok' => false, 'error' => 'Unknown agent'], JSON_UNESCAPED_UNICODE); exit; }

    $url = rtrim($agent['url'], '/') . '?ep=tasks/' . urlencode($task_id) . '/cancel';
    $transport_key = !empty($agent['encrypted']) ? ['key' => $agent['key'], 'keynum' => $agent['keynum']] : null;

    $r = a2a_request($url, [], $transport_key, 10);
    echo json_encode($r, JSON_UNESCAPED_UNICODE); exit;
}

// List registered remote agents
if ($action === 'agents') {
    $agents = a2a_load_agents();
    $safe = [];
    foreach ($agents as $id => $a) {
        $safe[$id] = [
            'id'          => $id,
            'name'        => $a['name'] ?? $id,
            'url'         => $a['url'],
            'description' => $a['description'] ?? '',
            'encrypted'   => !empty($a['encrypted']),
            'added_at'    => $a['added_at'] ?? '',
        ];
    }
    echo json_encode(['ok' => true, 'agents' => $safe], JSON_UNESCAPED_UNICODE); exit;
}

// Register a remote A2A agent
if ($action === 'add') {
    $id   = preg_replace('/[^a-zA-Z0-9_-]/', '', $in['id'] ?? '');
    $url  = trim($in['url'] ?? '');
    $name = trim($in['name'] ?? $id);
    if ($id === '' || $url === '') { echo json_encode(['ok' => false, 'error' => 'Missing id or url'], JSON_UNESCAPED_UNICODE); exit; }

    $agents = a2a_load_agents();
    $agents[$id] = [
        'name'        => $name,
        'url'         => $url,
        'description' => $in['description'] ?? '',
        'encrypted'   => !empty($in['encrypted']),
        'key'         => $in['key'] ?? '',
        'keynum'      => (int)($in['keynum'] ?? 15),
        'added_at'    => gmdate('Y-m-d\TH:i:s\Z'),
    ];
    a2a_save_agents($agents);
    echo json_encode(['ok' => true, 'id' => $id], JSON_UNESCAPED_UNICODE); exit;
}

// Remove a remote agent
if ($action === 'remove') {
    $id = $in['id'] ?? '';
    $agents = a2a_load_agents();
    unset($agents[$id]);
    a2a_save_agents($agents);
    echo json_encode(['ok' => true], JSON_UNESCAPED_UNICODE); exit;
}

echo json_encode(['ok' => false, 'error' => 'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
