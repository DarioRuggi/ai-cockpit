<?php
if (!function_exists('mb_strlen'))  { function mb_strlen($s, $e=null)  { return strlen($s); } }
if (!function_exists('mb_substr'))  { function mb_substr($s,$st,$l=null,$e=null) { return $l===null ? substr($s,$st) : substr($s,$st,$l); } }
// =============================================================================
// orchestrator.php — Cockpit Plan & Execute backend
//
// Two systems unified under one endpoint:
//
//   PLANNER ── given a goal, generates a step-by-step plan. By default uses
//              "consensus voting": each of Claude/Gemini/Ollama produces a
//              plan, then a synthesizer merges them into one ranked plan.
//
//   ORCHESTRATOR ── given a plan, runs each step on the assigned agent. Uses
//              the same submit/poll machinery as bridge.php so streaming and
//              cancellation Just Work. Honors auto_run_mode for approval gates.
//
// Storage:
//   <project>/plans/                       — directory of plans for the project
//     plan_<id>.json                       — full plan artifact
//
// Endpoints (all return JSON):
//   POST ?action=create_plan         — start voting; returns plan id + 3 tokens
//                                       to poll (one per voter agent)
//   POST ?action=synthesize_plan     — once all votes are in, merge them into
//                                       the canonical plan
//   GET  ?action=list&project=X&chat=Y    — list plans in this chat
//   GET  ?action=get&id=plan_xxx          — load a single plan
//   POST ?action=update              — save edits to a plan
//   POST ?action=delete&id=plan_xxx       — delete a plan
//   POST ?action=run_step            — execute step N of plan, return token
//   POST ?action=set_step_output     — store the output of a finished step
//   POST ?action=set_step_status     — pause/skip/done a step manually
//   POST ?action=settings_set        — chat or project orchestrator settings
//   GET  ?action=settings_get        — return effective settings (chat>project)
// =============================================================================

ini_set('display_errors', '0');
error_reporting(0);
header('Content-Type: application/json');
header('Cache-Control: no-store');

register_shutdown_function(function() {
    $err = error_get_last();
    if ($err && in_array($err['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR], true)) {
        if (!headers_sent()) header('Content-Type: application/json');
        echo json_encode(['ok'=>false,'error'=>'Internal: '.$err['message']], JSON_UNESCAPED_UNICODE);
    }
});

// =============================================================================
// Configuration & helpers
// =============================================================================

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) {
    header('Content-Type: application/json');
    $__demoAction = $_GET['action'] ?? $_POST['action'] ?? '';
    if ($__demoAction === 'list') {
        echo json_encode(['ok'=>true,'plans'=>[
            ['id'=>'plan-1','goal'=>'Add dark mode toggle to the settings page','status'=>'complete','created_at'=>'2026-06-13T09:00:00Z','step_count'=>4],
        ]]); exit;
    }
    ed_demo_stub();
}
$PROJECTS_ROOT = $PATHS['projects_root'];

function safe_project($s) {
    return preg_match('/^(?!.*\\.\\.)(?![.])[\\p{L}\\p{N}_][\\p{L}\\p{N}\\p{M}_. -]{0,127}$/u', (string)$s) ? $s : null;
}
function safe_chat($s) {
    return preg_match('/^(?!.*\\.\\.)(?![.])[\\p{L}\\p{N}_][\\p{L}\\p{N}\\p{M}_. -]{0,127}$/u', (string)$s) ? $s : null;
}
function safe_plan_id($s) {
    return preg_match('/^plan_[A-Za-z0-9_-]+$/', (string)$s) ? $s : null;
}
function safe_agent($s) {
    if (in_array($s, ['claude','gemini','ollama'], true)) return $s;
    // A2A remote agents: "a2a:agent_id"
    if (preg_match('/^a2a:[a-zA-Z0-9_-]+$/', (string)$s)) return $s;
    return null;
}

// Submit a prompt to a remote A2A agent, poll until done or timeout.
function a2a_submit(string $agent_id, string $prompt, int $timeout = 300): array {
    $client = __DIR__ . '/a2a_client.php';
    if (!is_file($client)) return ['ok'=>false,'error'=>'a2a_client.php not found'];

    // Send message
    $send_resp = json_decode((string)@file_get_contents(
        'http://localhost/cockpit/a2a_client.php?action=send', false,
        stream_context_create(['http'=>[
            'method'=>'POST',
            'header'=>'Content-Type: application/json',
            'content'=>json_encode(['agent_id'=>$agent_id,
                'parts'=>[['text'=>$prompt]]], JSON_UNESCAPED_UNICODE),
            'timeout'=>30,
        ]])), true);

    if (empty($send_resp['ok'])) {
        return ['ok'=>false,'error'=>'A2A send failed: '.($send_resp['error'] ?? $send_resp['data']['error'] ?? 'unknown')];
    }

    $task_id = $send_resp['data']['result']['id'] ?? $send_resp['data']['id'] ?? '';
    if (!$task_id) {
        // Some A2A agents return inline result
        $text = '';
        foreach (($send_resp['data']['result']['history'] ?? []) as $msg) {
            foreach ($msg['parts'] ?? [] as $p) {
                if (!empty($p['text'])) $text .= $p['text'] . "\n";
            }
        }
        if ($text) return ['ok'=>true,'text'=>trim($text),'source'=>'a2a:'.$agent_id];
        return ['ok'=>false,'error'=>'A2A: no task_id and no inline result'];
    }

    // Poll for completion
    $start = time();
    while ((time() - $start) < $timeout) {
        sleep(3);
        $status_resp = json_decode((string)@file_get_contents(
            'http://localhost/cockpit/a2a_client.php?action=status', false,
            stream_context_create(['http'=>[
                'method'=>'POST',
                'header'=>'Content-Type: application/json',
                'content'=>json_encode(['agent_id'=>$agent_id,'task_id'=>$task_id], JSON_UNESCAPED_UNICODE),
                'timeout'=>10,
            ]])), true);

        $task_status = $status_resp['data']['status']['state'] ?? '';
        if (in_array($task_status, ['completed','failed','canceled','rejected'], true)) {
            if ($task_status !== 'completed') {
                return ['ok'=>false,'error'=>'A2A task '.$task_status];
            }
            $text = '';
            foreach (($status_resp['data']['result']['history'] ?? $status_resp['data']['history'] ?? []) as $msg) {
                if (($msg['role'] ?? '') !== 'agent') continue;
                foreach ($msg['parts'] ?? [] as $p) {
                    if (!empty($p['text'])) $text .= $p['text'] . "\n";
                }
            }
            return ['ok'=>true,'text'=>trim($text),'source'=>'a2a:'.$agent_id,'task_id'=>$task_id];
        }
    }
    return ['ok'=>false,'error'=>'A2A timeout ('.$timeout.'s)','task_id'=>$task_id];
}

function read_json($path) {
    if (!is_file($path)) return null;
    $j = json_decode((string)file_get_contents($path), true);
    return is_array($j) ? $j : null;
}
function write_json($path, $data) {
    // HIGH-102 fix: atomic .tmp + rename to avoid lost-update if two requests
    // hit the same plan file simultaneously. Still last-write-wins, but no
    // partial JSON corruption.
    $dir = dirname($path);
    if (!is_dir($dir)) @mkdir($dir, 0775, true);
    $tmp = $path . '.tmp';
    if (@file_put_contents($tmp, json_encode($data, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE)) === false) return false;
    @chmod($tmp, 0664);
    if (!@rename($tmp, $path)) { @unlink($tmp); return false; }
    return true;
}

function plans_dir($project, $projects_root) {
    return $projects_root . '/' . $project . '/plans';
}
function plan_path($project, $plan_id, $projects_root) {
    return plans_dir($project, $projects_root) . '/' . $plan_id . '.json';
}

// Settings resolution: chat-level overrides project-level overrides global default
function effective_settings($project, $chat, $projects_root) {
    $defaults = [
        'auto_run_mode'  => 'approve_destructive',  // approve_each | approve_destructive | auto | manual_only
        'planner_mode'   => 'consensus',            // consensus | claude | gemini | ollama
        'synthesizer'    => 'claude',               // which agent merges votes when planner_mode=consensus
    ];
    $proj_path = $projects_root . '/' . $project . '/orchestrator.json';
    $chat_meta = $projects_root . '/' . $project . '/chat_' . $chat . '.json';

    $settings = $defaults;
    $proj = read_json($proj_path);
    if ($proj && isset($proj['settings']) && is_array($proj['settings'])) {
        $settings = array_merge($settings, $proj['settings']);
    }
    $chat_data = read_json($chat_meta);
    if ($chat_data && isset($chat_data['orchestrator']) && is_array($chat_data['orchestrator'])) {
        $settings = array_merge($settings, $chat_data['orchestrator']);
    }
    return $settings;
}

// Build a Plan-and-Sequence planner prompt — atomic, verifiable steps for weak executors
function build_sequence_planner_prompt($goal, $available_caps) {
    $cap_hint = $available_caps
        ? 'Capabilities available: ' . implode(', ', $available_caps) . '.'
        : 'No special capabilities — assume basic file and shell access only.';
    return <<<TXT
You are a planner decomposing a goal into ATOMIC, independently-verifiable steps for a WEAK local model executor.

GOAL:
{$goal}

CONTEXT:
{$cap_hint}

CRITICAL RULES:
- Each step must be ATOMIC: one tool, one clear outcome, independently verifiable.
- Each step must be STATELESS: carry its own inputs, never reference prior step context.
- Each step must have a VERIFICATION check — a deterministic test (command, file check, regex).
- Steps must be ORDERED — each depends only on prior steps completing, not on shared state.
- 3 to 12 steps. Fewer is better.
- The executor is a small model — keep instructions extremely clear and specific.

OUTPUT — return ONLY a JSON object:
{
  "summary": "<one-sentence approach>",
  "steps": [
    {
      "description": "<precise imperative instruction, one paragraph max>",
      "agent": "ollama",
      "inputs": { "<key>": "<value scoped to THIS step>" },
      "verification": {
        "type": "command|regex|file_exists",
        "check": "<the shell command to run, regex pattern, or file path>",
        "expect": "<expected substring in output (for command type)>"
      },
      "halt_condition": "<when to stop retrying, e.g. 'if verification fails twice'>"
    }
  ]
}

VERIFICATION TYPES:
- "command": run a shell command, check exit code or look for "expect" in output
- "regex": match a regex against the step's output text
- "file_exists": check that a file was created at the given path

Return valid JSON. No backticks, no commentary.
TXT;
}

// Build the standard "planner" prompt — a single string we send to each voter
function build_planner_prompt($goal, $available_caps) {
    $cap_hint = $available_caps
        ? 'Capabilities available in this project: ' . implode(', ', $available_caps) . '.'
        : 'No special capabilities are wired up — assume basic file reading and shell access only.';
    return <<<TXT
You are a software-engineering planner. Convert the user's goal into a concrete, executable plan.

USER GOAL:
{$goal}

CONTEXT:
{$cap_hint}

OUTPUT FORMAT — return ONLY a JSON object (no prose, no markdown fence):
{
  "summary": "<one-sentence approach summary>",
  "steps": [
    {
      "description": "<what to do, imperative voice, one paragraph max>",
      "agent": "<claude|gemini|ollama — which agent should execute this step>",
      "capabilities": ["<capability_id>", ...],
      "destructive": <true|false — true if step writes files, modifies git, runs network commands, or has any side effect>
    }
  ]
}

RULES:
- 3 to 8 steps. Fewer is better when fewer suffice.
- Assign each step to the agent whose strengths fit best:
    claude  — analysis, refactoring, architecture, careful reasoning
    gemini  — broad knowledge lookups, summarization, fast iteration
    ollama  — local-only privacy work, simple transforms, quick scripts
- Mark destructive=true for: file writes, git commit/push, network requests beyond GET, ssh.
- Each step must be runnable with the agent's prompt alone (don't reference unstated context).
- Return valid JSON. No backticks, no commentary.
TXT;
}

function build_synthesizer_prompt($goal, $votes) {
    $votes_json = json_encode($votes, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE);

    // List available A2A remote agents for the synthesizer
    $a2a_agents_info = '';
    $a2a_file = $GLOBALS['PATHS']['cockpit_data'] . '/a2a_agents.json';
    if (is_readable($a2a_file)) {
        $a2a = json_decode((string)file_get_contents($a2a_file), true);
        if (is_array($a2a) && count($a2a) > 0) {
            $lines = [];
            foreach ($a2a as $id => $a) {
                $lines[] = '  - a2a:' . $id . ' — ' . ($a['description'] ?: $a['name'] ?? $id);
            }
            $a2a_agents_info = "\n\nAVAILABLE REMOTE A2A AGENTS (use \"a2a:<id>\" as agent):\n" . implode("\n", $lines);
        }
    }

    return <<<TXT
You are a synthesizer. Three planner agents each proposed a plan for this goal:

GOAL: {$goal}

VOTES (one plan per agent):
{$votes_json}

Produce the BEST merged plan. You may pick the best version of each step from any voter, combine compatible ideas, drop weak suggestions, or reorder. Aim for the shortest plan that fully achieves the goal.

AVAILABLE LOCAL AGENTS: claude, gemini, ollama{$a2a_agents_info}

OUTPUT — return ONLY a JSON object (no prose, no markdown):
{
  "summary": "<one-sentence merged approach>",
  "steps": [
    { "description": "...", "agent": "...", "capabilities": [...], "destructive": <bool> }
  ]
}
TXT;
}

// =============================================================================
// Submit a prompt to bridge.php (used by orchestrator to dispatch steps)
// Returns the streaming token that the frontend can poll.
// =============================================================================
// Retry wrapper — calls $fn up to $max times with exponential backoff.
function with_retry(callable $fn, int $max = 3, int $base_delay = 2): array {
    for ($attempt = 1; $attempt <= $max; $attempt++) {
        $result = $fn($attempt);
        if (!empty($result['ok'])) return $result;
        if ($attempt < $max) sleep($base_delay * $attempt);
    }
    $result['_retries'] = $max;
    return $result;
}

function bridge_submit($agent, $prompt, $project, $chat, $models = []) {
    $payload = [
        'mode'    => 'submit',
        'agent'   => $agent,
        'prompt'  => $prompt,
        'project' => $project,
        'chat'    => $chat,
    ];
    if ($agent === 'claude' && !empty($models['claude'])) {
        $payload['claude_model'] = $models['claude'];
    }
    if ($agent === 'gemini' && !empty($models['gemini'])) {
        $payload['gemini_model'] = $models['gemini'];
    }
    if ($agent === 'ollama' && !empty($models['ollama'])) {
        $payload['model'] = $models['ollama'];
    }

    $ch = curl_init();
    curl_setopt_array($ch, [
        CURLOPT_URL            => 'http://localhost/cockpit/bridge.php',
        CURLOPT_POST           => true,
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
        CURLOPT_POSTFIELDS     => json_encode($payload, JSON_UNESCAPED_UNICODE),
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 15,
    ]);
    $resp = curl_exec($ch);
    curl_close($ch);
    return json_decode($resp, true) ?: ['ok'=>false,'error'=>'no response from bridge'];
}

// =============================================================================
// Dispatch
// =============================================================================

$action = $_GET['action'] ?? '';
$in     = json_decode(file_get_contents('php://input'), true) ?: [];

// =============================================================================
// Action: create_plan — fan out the goal to N voter agents
// =============================================================================
if ($action === 'create_plan') {
    $project = safe_project($in['project'] ?? '');
    $chat    = safe_chat($in['chat'] ?? '');
    $goal    = trim((string)($in['goal'] ?? ''));
    if (!$project || !$chat || $goal === '') {
        echo json_encode(['ok'=>false,'error'=>'Missing project/chat/goal'], JSON_UNESCAPED_UNICODE); exit;
    }

    $settings = effective_settings($project, $chat, $PROJECTS_ROOT);

    // Determine voters
    $voters = ($settings['planner_mode'] === 'consensus')
        ? ['claude', 'gemini', 'ollama']
        : [$settings['planner_mode']];
    // the agents ticked in the Agents row are the only voters (an empty or unknown list leaves the default)
    if (!empty($in['agents']) && is_array($in['agents'])) { $pick = array_values(array_intersect($voters, array_map('strval', $in['agents']))); if ($pick) $voters = $pick; }

    // Discover capabilities available in this project (from capabilities.php
    // staging, if it exists). Fall back to no-caps if missing.
    $caps = [];
    $proj_caps = read_json($PROJECTS_ROOT . '/' . $project . '/capabilities.json');
    if ($proj_caps && is_array($proj_caps['enabled'] ?? null)) {
        $caps = $proj_caps['enabled'];
    }

    $prompt = build_planner_prompt($goal, $caps);

    // Submit to each voter — collect tokens for the frontend to poll
    $tokens = [];
    foreach ($voters as $a) {
        $r = bridge_submit($a, $prompt, $project, $chat,
            ['claude' => $in['claude_model'] ?? 'sonnet',
             'gemini' => $in['gemini_model'] ?? 'auto',
             'ollama' => $in['ollama_model'] ?? '']);
        if (!empty($r['ok'])) {
            $tokens[$a] = $r['short'] ?? $r['token'] ?? null;
        } else {
            $tokens[$a] = null;
        }
    }

    // Create the plan stub — no steps yet, votes empty until synthesize is called
    $now = date('c');
    $plan_id = 'plan_' . preg_replace('/[^a-zA-Z0-9-]/', '-', date('Y-m-d_H-i-s')) . '_' . substr(md5($goal . microtime()), 0, 6);
    $plan = [
        'id'             => $plan_id,
        'project'        => $project,
        'chat'           => $chat,
        'goal'           => $goal,
        'created_at'     => $now,
        'planner_mode'   => $settings['planner_mode'],
        'auto_run_mode'  => $settings['auto_run_mode'],
        'workflow'       => trim((string)($in['workflow'] ?? 'auto')),
        'status'         => 'voting',   // voting | draft | running | paused | complete | failed
        'current_step'   => 0,
        'steps'          => [],
        'votes'          => array_fill_keys($voters, ['token'=>null,'plan'=>null,'error'=>null]),
        'voter_tokens'   => $tokens,
    ];
    foreach ($voters as $a) {
        $plan['votes'][$a]['token'] = $tokens[$a];
    }

    write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);

    echo json_encode([
        'ok'       => true,
        'plan_id'  => $plan_id,
        'voters'   => $voters,
        'tokens'   => $tokens,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: synthesize_plan — once votes are collected, merge them
// Frontend submits the collected vote outputs (already polled via bridge.php)
// =============================================================================
if ($action === 'synthesize_plan') {
    $project = safe_project($in['project'] ?? '');
    $plan_id = safe_plan_id($in['plan_id'] ?? '');
    $votes   = $in['votes'] ?? null;  // { claude: "<raw output>", gemini: "...", ollama: "..." }
    if (!$project || !$plan_id || !is_array($votes)) {
        echo json_encode(['ok'=>false,'error'=>'Missing args'], JSON_UNESCAPED_UNICODE); exit;
    }

    $plan = read_json(plan_path($project, $plan_id, $PROJECTS_ROOT));
    if (!$plan) { echo json_encode(['ok'=>false,'error'=>'Plan not found'], JSON_UNESCAPED_UNICODE); exit; }

    // Parse each vote — extract the JSON object from the agent's text output
    $parsed_votes = [];
    foreach ($votes as $agent => $raw) {
        $a = safe_agent($agent);
        if (!$a) continue;
        $parsed = extract_plan_json($raw);
        $parsed_votes[$a] = [
            'raw'   => $raw,
            'plan'  => $parsed,
            'error' => $parsed ? null : 'Could not parse JSON from voter output',
        ];
        $plan['votes'][$a]['plan']  = $parsed;
        $plan['votes'][$a]['error'] = $parsed ? null : 'parse_failed';
    }

    // Decide synthesis path:
    //   If only 1 voter (planner_mode != consensus) — its plan IS the plan
    //   If 3 voters but only 1 produced valid JSON — use that one
    //   Otherwise — call the synthesizer agent
    $valid = array_filter($parsed_votes, fn($v) => $v['plan'] !== null);
    if (count($valid) === 0) {
        $plan['status'] = 'failed';
        $plan['error']  = 'All voters failed to produce valid JSON plans';
        write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
        echo json_encode(['ok'=>false,'error'=>$plan['error'],'plan'=>$plan], JSON_UNESCAPED_UNICODE);
        exit;
    }
    if (count($valid) === 1) {
        $only = array_values($valid)[0]['plan'];
        $plan['steps']   = annotate_steps($only['steps'] ?? []);
        $plan['summary'] = $only['summary'] ?? '';
        $plan['status']  = 'draft';
        write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
        echo json_encode(['ok'=>true,'plan'=>$plan,'synthesized'=>false], JSON_UNESCAPED_UNICODE);
        exit;
    }

    // Multiple valid votes — submit synthesis prompt to the configured synthesizer
    $settings = effective_settings($project, $plan['chat'], $PROJECTS_ROOT);
    $synth_agent = safe_agent($settings['synthesizer']) ?: 'claude';
    $vote_subset = [];
    foreach ($valid as $a => $v) $vote_subset[$a] = $v['plan'];
    $synth_prompt = build_synthesizer_prompt($plan['goal'], $vote_subset);

    $sub = bridge_submit($synth_agent, $synth_prompt, $project, $plan['chat'],
        ['claude'=>'sonnet','gemini'=>'auto']);
    if (empty($sub['ok'])) {
        // Fall back: pick the longest valid plan (more thorough usually wins)
        $best = null;
        foreach ($valid as $a => $v) {
            $count = count($v['plan']['steps'] ?? []);
            if (!$best || $count > count($best['plan']['steps'] ?? [])) $best = $v;
        }
        $plan['steps']   = annotate_steps($best['plan']['steps'] ?? []);
        $plan['summary'] = $best['plan']['summary'] ?? '';
        $plan['status']  = 'draft';
        $plan['synth_fallback'] = true;
        write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
        echo json_encode(['ok'=>true,'plan'=>$plan,'synthesized'=>false,'fallback'=>true], JSON_UNESCAPED_UNICODE);
        exit;
    }

    // Synthesizer is running — return its token; frontend polls and then calls
    // a follow-up endpoint (synthesize_finalize) once it has the synthesizer's output
    $plan['synth_token'] = $sub['short'] ?? $sub['token'];
    $plan['synth_agent'] = $synth_agent;
    $plan['status']      = 'synthesizing';
    write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);

    echo json_encode([
        'ok'             => true,
        'synth_token'    => $plan['synth_token'],
        'synth_agent'    => $synth_agent,
        'plan'           => $plan,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: synthesize_finalize — once frontend has polled the synth output
// =============================================================================
if ($action === 'synthesize_finalize') {
    $project = safe_project($in['project'] ?? '');
    $plan_id = safe_plan_id($in['plan_id'] ?? '');
    $synth_output = (string)($in['synth_output'] ?? '');
    if (!$project || !$plan_id || $synth_output === '') {
        echo json_encode(['ok'=>false,'error'=>'Missing args'], JSON_UNESCAPED_UNICODE); exit;
    }

    $plan = read_json(plan_path($project, $plan_id, $PROJECTS_ROOT));
    if (!$plan) { echo json_encode(['ok'=>false,'error'=>'Plan not found'], JSON_UNESCAPED_UNICODE); exit; }

    $merged = extract_plan_json($synth_output);
    if (!$merged) {
        // Fall back to longest valid voter plan (same as in synthesize_plan)
        $valid = array_filter($plan['votes'], fn($v) => !empty($v['plan']));
        $best = null;
        foreach ($valid as $a => $v) {
            $count = count($v['plan']['steps'] ?? []);
            if (!$best || $count > count($best['plan']['steps'] ?? [])) $best = $v['plan'];
        }
        if ($best) {
            $plan['steps']          = annotate_steps($best['steps'] ?? []);
            $plan['summary']        = $best['summary'] ?? '';
            $plan['status']         = 'draft';
            $plan['synth_fallback'] = true;
        } else {
            $plan['status'] = 'failed';
            $plan['error']  = 'Synth output unparseable and no fallback available';
        }
    } else {
        $plan['steps']   = annotate_steps($merged['steps'] ?? []);
        $plan['summary'] = $merged['summary'] ?? '';
        $plan['status']  = 'draft';
    }

    write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
    echo json_encode(['ok'=>true,'plan'=>$plan], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: list — plans for a chat
// =============================================================================
if ($action === 'list') {
    $project = safe_project($_GET['project'] ?? '');
    $chat    = safe_chat($_GET['chat'] ?? '');
    if (!$project || !$chat) { echo json_encode(['ok'=>false,'error'=>'Missing project/chat'], JSON_UNESCAPED_UNICODE); exit; }

    $dir = plans_dir($project, $PROJECTS_ROOT);
    $items = [];
    if (is_dir($dir)) {
        foreach (glob($dir . '/plan_*.json') ?: [] as $f) {
            $p = read_json($f);
            if (!$p) continue;
            if (($p['chat'] ?? '') !== $chat) continue;
            $items[] = [
                'id'         => $p['id'],
                'goal'       => $p['goal'],
                'status'     => $p['status'],
                'created_at' => $p['created_at'],
                'step_count' => count($p['steps'] ?? []),
            ];
        }
        usort($items, fn($a, $b) => strcmp($b['created_at'], $a['created_at']));
    }
    echo json_encode(['ok'=>true, 'plans'=>$items], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: get — single plan
// =============================================================================
if ($action === 'get') {
    $project = safe_project($_GET['project'] ?? '');
    $plan_id = safe_plan_id($_GET['id'] ?? '');
    if (!$project || !$plan_id) { echo json_encode(['ok'=>false,'error'=>'Missing args'], JSON_UNESCAPED_UNICODE); exit; }
    $plan = read_json(plan_path($project, $plan_id, $PROJECTS_ROOT));
    if (!$plan) { echo json_encode(['ok'=>false,'error'=>'Not found'], JSON_UNESCAPED_UNICODE); exit; }
    echo json_encode(['ok'=>true,'plan'=>$plan], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: update — save edits (steps, status, etc.)
// =============================================================================
if ($action === 'update') {
    $project = safe_project($in['project'] ?? '');
    $plan_id = safe_plan_id($in['plan_id'] ?? '');
    $patch   = $in['patch'] ?? [];
    if (!$project || !$plan_id || !is_array($patch)) {
        echo json_encode(['ok'=>false,'error'=>'Missing args'], JSON_UNESCAPED_UNICODE); exit;
    }
    $plan = read_json(plan_path($project, $plan_id, $PROJECTS_ROOT));
    if (!$plan) { echo json_encode(['ok'=>false,'error'=>'Not found'], JSON_UNESCAPED_UNICODE); exit; }

    // Whitelisted fields that the frontend may patch
    $allow = ['steps','status','current_step','goal','summary','auto_run_mode'];
    foreach ($allow as $k) {
        if (array_key_exists($k, $patch)) $plan[$k] = $patch[$k];
    }
    if (isset($plan['steps']) && is_array($plan['steps'])) {
        $plan['steps'] = annotate_steps($plan['steps']);
    }
    write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
    echo json_encode(['ok'=>true,'plan'=>$plan], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: delete
// =============================================================================
if ($action === 'delete') {
    $project = safe_project($_GET['project'] ?? $in['project'] ?? '');
    $plan_id = safe_plan_id($_GET['id'] ?? $in['plan_id'] ?? '');
    if (!$project || !$plan_id) { echo json_encode(['ok'=>false,'error'=>'Missing args'], JSON_UNESCAPED_UNICODE); exit; }
    @unlink(plan_path($project, $plan_id, $PROJECTS_ROOT));
    echo json_encode(['ok'=>true], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: run_step — submit step N's prompt to its assigned agent
// Returns a polling token for the frontend
// =============================================================================
if ($action === 'run_step') {
    $project = safe_project($in['project'] ?? '');
    $plan_id = safe_plan_id($in['plan_id'] ?? '');
    $step_n  = isset($in['step']) ? intval($in['step']) : -1;
    if (!$project || !$plan_id || $step_n < 0) {
        echo json_encode(['ok'=>false,'error'=>'Missing args'], JSON_UNESCAPED_UNICODE); exit;
    }

    $plan = read_json(plan_path($project, $plan_id, $PROJECTS_ROOT));
    if (!$plan) { echo json_encode(['ok'=>false,'error'=>'Plan not found'], JSON_UNESCAPED_UNICODE); exit; }
    if (!isset($plan['steps'][$step_n])) {
        echo json_encode(['ok'=>false,'error'=>'Step out of range'], JSON_UNESCAPED_UNICODE); exit;
    }

    $step  = $plan['steps'][$step_n];
    $agent = safe_agent($step['agent'] ?? '') ?: 'claude';

    // Build the step prompt: include the goal, prior step outputs, and this
    // step's description. The agent gets full context but is instructed to
    // produce ONLY the work for this step.
    $context_lines = ["GOAL: " . $plan['goal']];
    if (!empty($plan['summary'])) $context_lines[] = "APPROACH: " . $plan['summary'];

    if ($step_n > 0) {
        $context_lines[] = "\nPRIOR STEPS (already completed):";
        for ($i = 0; $i < $step_n; $i++) {
            $s = $plan['steps'][$i];
            $context_lines[] = "  [" . ($i+1) . "] (" . ($s['agent'] ?? '?') . ") " . ($s['description'] ?? '');
            if (!empty($s['output'])) {
                $excerpt = mb_substr($s['output'], 0, 800);
                $context_lines[] = "      OUTPUT: " . $excerpt . (strlen($s['output']) > 800 ? ' [...truncated]' : '');
            }
        }
    }
    $context_lines[] = "\nCURRENT STEP (your task):";
    $context_lines[] = "  " . $step['description'];
    $context_lines[] = "\nDo this step's work directly. Be concise. Do not restate the plan.";

    $prompt = implode("\n", $context_lines);

    // Mark step as running and persist
    $plan['steps'][$step_n]['status']     = 'running';
    $plan['steps'][$step_n]['started_at'] = date('c');
    $plan['current_step']                 = $step_n;
    $plan['status']                       = 'running';
    write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);

    // A2A remote agents: synchronous send+poll, return text directly
    if (str_starts_with($agent, 'a2a:')) {
        $a2a_id = substr($agent, 4);
        $max_retries = (int)($in['retries'] ?? 2);
        $sub = with_retry(fn($att) => a2a_submit($a2a_id, $prompt), $max_retries);
        if (empty($sub['ok'])) {
            $plan['steps'][$step_n]['status'] = 'failed';
            $plan['steps'][$step_n]['error']  = $sub['error'] ?? 'A2A failed';
            $plan['steps'][$step_n]['ended_at'] = date('c');
            write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
            echo json_encode(['ok'=>false,'error'=>$plan['steps'][$step_n]['error']], JSON_UNESCAPED_UNICODE); exit;
        }
        $plan['steps'][$step_n]['status']  = 'done';
        $plan['steps'][$step_n]['output']  = $sub['text'];
        $plan['steps'][$step_n]['source']  = $sub['source'] ?? $agent;
        $plan['steps'][$step_n]['ended_at'] = date('c');
        write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
        echo json_encode(['ok'=>true,'step'=>$step_n,'agent'=>$agent,'done'=>true,'text'=>$sub['text']], JSON_UNESCAPED_UNICODE); exit;
    }

    // Local agents: submit via bridge with retry
    $max_retries = (int)($in['retries'] ?? 2);
    $sub = with_retry(fn($att) => bridge_submit($agent, $prompt, $project, $plan['chat'],
        ['claude' => $in['claude_model'] ?? 'sonnet',
         'gemini' => $in['gemini_model'] ?? 'auto',
         'ollama' => $in['ollama_model'] ?? '']), $max_retries);
    if (empty($sub['ok'])) {
        $plan['steps'][$step_n]['status'] = 'failed';
        $plan['steps'][$step_n]['error']  = $sub['error'] ?? 'submit failed';
        $plan['steps'][$step_n]['ended_at'] = date('c');
        write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
        echo json_encode(['ok'=>false,'error'=>$plan['steps'][$step_n]['error']], JSON_UNESCAPED_UNICODE);
        exit;
    }

    $plan['steps'][$step_n]['token'] = $sub['short'] ?? $sub['token'];
    write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);

    echo json_encode([
        'ok'    => true,
        'token' => $plan['steps'][$step_n]['token'],
        'agent' => $agent,
        'step'  => $step_n,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: set_step_output — frontend sends the streamed output back when done
// =============================================================================
if ($action === 'set_step_output') {
    $project = safe_project($in['project'] ?? '');
    $plan_id = safe_plan_id($in['plan_id'] ?? '');
    $step_n  = isset($in['step']) ? intval($in['step']) : -1;
    $output  = (string)($in['output'] ?? '');
    $status  = $in['status'] ?? 'done';   // done|failed

    if (!$project || !$plan_id || $step_n < 0) {
        echo json_encode(['ok'=>false,'error'=>'Missing args'], JSON_UNESCAPED_UNICODE); exit;
    }
    $plan = read_json(plan_path($project, $plan_id, $PROJECTS_ROOT));
    if (!$plan) { echo json_encode(['ok'=>false,'error'=>'Plan not found'], JSON_UNESCAPED_UNICODE); exit; }
    if (!isset($plan['steps'][$step_n])) {
        echo json_encode(['ok'=>false,'error'=>'Step out of range'], JSON_UNESCAPED_UNICODE); exit;
    }
    // MED-105: cap step output to keep plan JSON size sane (1MB hard limit)
    if (strlen($output) > 1048576) $output = substr($output, 0, 1048576) . "\n\n[... output truncated at 1MB]";

    $plan['steps'][$step_n]['output']   = $output;
    $plan['steps'][$step_n]['status']   = in_array($status, ['done','failed','skipped'], true) ? $status : 'done';
    $plan['steps'][$step_n]['ended_at'] = date('c');

    // If this was the last step and it's done/skipped, mark plan complete
    $remaining = 0;
    foreach ($plan['steps'] as $s) {
        if (!in_array($s['status'] ?? 'pending', ['done','skipped','failed'], true)) {
            $remaining++;
        }
    }
    if ($remaining === 0) $plan['status'] = 'complete';
    elseif ($status === 'failed') $plan['status'] = 'paused';

    write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
    echo json_encode(['ok'=>true,'plan'=>$plan], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: set_step_status — manual status changes (skip, mark done, etc.)
// =============================================================================
if ($action === 'set_step_status') {
    $project = safe_project($in['project'] ?? '');
    $plan_id = safe_plan_id($in['plan_id'] ?? '');
    $step_n  = isset($in['step']) ? intval($in['step']) : -1;
    $status  = $in['status'] ?? '';
    $allowed = ['pending','running','done','skipped','failed'];
    if (!$project || !$plan_id || $step_n < 0 || !in_array($status, $allowed, true)) {
        echo json_encode(['ok'=>false,'error'=>'Missing/invalid args'], JSON_UNESCAPED_UNICODE); exit;
    }
    $plan = read_json(plan_path($project, $plan_id, $PROJECTS_ROOT));
    if (!$plan) { echo json_encode(['ok'=>false,'error'=>'Plan not found'], JSON_UNESCAPED_UNICODE); exit; }
    if (!isset($plan['steps'][$step_n])) {
        echo json_encode(['ok'=>false,'error'=>'Step out of range'], JSON_UNESCAPED_UNICODE); exit;
    }
    $plan['steps'][$step_n]['status'] = $status;
    write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
    echo json_encode(['ok'=>true,'plan'=>$plan], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: settings_get — return effective orchestrator settings
// =============================================================================
if ($action === 'settings_get') {
    $project = safe_project($_GET['project'] ?? '');
    $chat    = safe_chat($_GET['chat'] ?? '');
    if (!$project || !$chat) { echo json_encode(['ok'=>false,'error'=>'Missing args'], JSON_UNESCAPED_UNICODE); exit; }
    echo json_encode([
        'ok'       => true,
        'settings' => effective_settings($project, $chat, $PROJECTS_ROOT),
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: settings_set — write to chat OR project orchestrator settings
// =============================================================================
if ($action === 'settings_set') {
    $project = safe_project($in['project'] ?? '');
    $chat    = safe_chat($in['chat'] ?? '');
    $scope   = $in['scope'] ?? 'chat';   // 'chat' | 'project'
    $patch   = $in['patch'] ?? [];
    if (!$project || ($scope === 'chat' && !$chat) || !is_array($patch)) {
        echo json_encode(['ok'=>false,'error'=>'Missing args'], JSON_UNESCAPED_UNICODE); exit;
    }

    if ($scope === 'project') {
        $path = $PROJECTS_ROOT . '/' . $project . '/orchestrator.json';
        $cur  = read_json($path) ?: ['settings' => []];
        $cur['settings'] = array_merge($cur['settings'] ?? [], $patch);
        write_json($path, $cur);
    } else {
        $path = $PROJECTS_ROOT . '/' . $project . '/chat_' . $chat . '.json';
        $cur  = read_json($path) ?: [];
        $cur['orchestrator'] = array_merge($cur['orchestrator'] ?? [], $patch);
        write_json($path, $cur);
    }

    echo json_encode([
        'ok'       => true,
        'settings' => effective_settings($project, $chat ?: '', $PROJECTS_ROOT),
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: run_sequence — Plan-and-Sequence: automated step-by-step execution
// with verification gates, step-cap, failure-halt, and loop detection.
// Used for unattended/overnight runs with weak local models.
// =============================================================================
if ($action === 'run_sequence') {
    $project = safe_project($in['project'] ?? '');
    $plan_id = safe_plan_id($in['plan_id'] ?? '');
    if (!$project || !$plan_id) {
        echo json_encode(['ok'=>false,'error'=>'Missing project/plan_id'], JSON_UNESCAPED_UNICODE); exit;
    }

    $plan = read_json(plan_path($project, $plan_id, $PROJECTS_ROOT));
    if (!$plan) { echo json_encode(['ok'=>false,'error'=>'Plan not found'], JSON_UNESCAPED_UNICODE); exit; }

    // Guardrail config — defaults, overridable per-plan
    $guardrails = array_merge([
        'step_cap'              => 20,
        'max_consecutive_fails' => 3,
        'loop_similarity_threshold' => 0.85,
        'loop_window'           => 3,
        'log_file'              => null,
    ], $plan['guardrails'] ?? [], $in['guardrails'] ?? []);

    // Determine log path
    $log_dir = plans_dir($project, $PROJECTS_ROOT) . '/logs';
    if (!is_dir($log_dir)) @mkdir($log_dir, 0775, true);
    $log_file = $guardrails['log_file'] ?: $log_dir . '/' . $plan_id . '_run_' . date('Ymd_His') . '.jsonl';

    // Save sequence config into plan
    $plan['sequence_config'] = [
        'guardrails'  => $guardrails,
        'log_file'    => $log_file,
        'started_at'  => date('c'),
        'executor_model' => $in['executor_model'] ?? '',
    ];
    $plan['status'] = 'sequencing';
    write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);

    // Return immediately — actual execution happens via run_sequence_tick
    echo json_encode([
        'ok'         => true,
        'plan_id'    => $plan_id,
        'status'     => 'sequencing',
        'guardrails' => $guardrails,
        'log_file'   => $log_file,
        'next_action'=> 'Call run_sequence_tick to advance one step at a time',
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: run_sequence_tick — advance one step of a Plan-and-Sequence run.
// Caller (UI or scheduler) calls this repeatedly until plan status != sequencing.
// =============================================================================
if ($action === 'run_sequence_tick') {
    $project = safe_project($in['project'] ?? '');
    $plan_id = safe_plan_id($in['plan_id'] ?? '');
    if (!$project || !$plan_id) {
        echo json_encode(['ok'=>false,'error'=>'Missing args'], JSON_UNESCAPED_UNICODE); exit;
    }

    $plan = read_json(plan_path($project, $plan_id, $PROJECTS_ROOT));
    if (!$plan) { echo json_encode(['ok'=>false,'error'=>'Plan not found'], JSON_UNESCAPED_UNICODE); exit; }
    if (($plan['status'] ?? '') !== 'sequencing') {
        echo json_encode(['ok'=>false,'error'=>'Plan not in sequencing state','status'=>$plan['status']], JSON_UNESCAPED_UNICODE); exit;
    }

    $cfg = $plan['sequence_config'] ?? [];
    $guardrails = $cfg['guardrails'] ?? ['step_cap'=>20,'max_consecutive_fails'=>3,'loop_window'=>3,'loop_similarity_threshold'=>0.85];
    $log_file = $cfg['log_file'] ?? '';
    $steps = $plan['steps'] ?? [];

    // Find next pending step
    $next_idx = -1;
    $completed_count = 0;
    $consecutive_fails = 0;
    $recent_outputs = [];
    foreach ($steps as $i => $s) {
        $st = $s['status'] ?? 'pending';
        if ($st === 'done' || $st === 'skipped') {
            $completed_count++;
            $consecutive_fails = 0;
            if (!empty($s['output'])) $recent_outputs[] = $s['output'];
        } elseif ($st === 'failed') {
            $completed_count++;
            $consecutive_fails++;
            if (!empty($s['output'])) $recent_outputs[] = $s['output'];
        } elseif ($st === 'pending' && $next_idx === -1) {
            $next_idx = $i;
        }
    }
    // Keep only last N outputs for loop detection
    $win = (int)$guardrails['loop_window'];
    if (count($recent_outputs) > $win) $recent_outputs = array_slice($recent_outputs, -$win);

    // Guardrail: step-cap
    if ($completed_count >= (int)$guardrails['step_cap']) {
        $plan['status'] = 'halted';
        $plan['halt_reason'] = 'step_cap_reached';
        _seq_log($log_file, 'halt', ['reason'=>'step_cap','completed'=>$completed_count,'cap'=>$guardrails['step_cap']]);
        write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
        echo json_encode(['ok'=>true,'status'=>'halted','reason'=>'step_cap_reached'], JSON_UNESCAPED_UNICODE); exit;
    }

    // Guardrail: failure-halt
    if ($consecutive_fails >= (int)$guardrails['max_consecutive_fails']) {
        $plan['status'] = 'halted';
        $plan['halt_reason'] = 'consecutive_failures';
        _seq_log($log_file, 'halt', ['reason'=>'consecutive_failures','count'=>$consecutive_fails]);
        write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
        echo json_encode(['ok'=>true,'status'=>'halted','reason'=>'consecutive_failures'], JSON_UNESCAPED_UNICODE); exit;
    }

    // No more steps
    if ($next_idx === -1) {
        $plan['status'] = 'complete';
        _seq_log($log_file, 'complete', ['total_steps'=>count($steps),'completed'=>$completed_count]);
        write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
        echo json_encode(['ok'=>true,'status'=>'complete'], JSON_UNESCAPED_UNICODE); exit;
    }

    $step = $steps[$next_idx];

    // Build ISOLATED context for this step (weak model gets minimal context)
    $step_prompt_lines = [];
    $step_prompt_lines[] = "TASK: " . ($step['description'] ?? '');
    if (!empty($step['inputs'])) {
        $step_prompt_lines[] = "\nINPUTS:";
        foreach ((array)$step['inputs'] as $k => $v) {
            $step_prompt_lines[] = "  {$k}: " . (is_string($v) ? $v : json_encode($v, JSON_UNESCAPED_UNICODE));
        }
    }
    $step_prompt_lines[] = "\nDo exactly this one task. Be concise. Return only the result.";
    $step_prompt = implode("\n", $step_prompt_lines);

    // Determine executor agent/model
    $executor_agent = safe_agent($step['agent'] ?? '') ?: 'ollama';
    $executor_model = $cfg['executor_model'] ?? '';

    // Mark running
    $plan['steps'][$next_idx]['status'] = 'running';
    $plan['steps'][$next_idx]['started_at'] = date('c');
    $plan['current_step'] = $next_idx;
    write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);

    _seq_log($log_file, 'step_start', ['step'=>$next_idx,'description'=>$step['description']??'','agent'=>$executor_agent]);

    // A2A remote agents: synchronous — submit, poll, return result inline
    if (str_starts_with($executor_agent, 'a2a:')) {
        $a2a_id = substr($executor_agent, 4);
        $sub = with_retry(fn($att) => a2a_submit($a2a_id, $step_prompt), 2);
        if (empty($sub['ok'])) {
            $plan['steps'][$next_idx]['status'] = 'failed';
            $plan['steps'][$next_idx]['error'] = $sub['error'] ?? 'A2A failed';
            $plan['steps'][$next_idx]['ended_at'] = date('c');
            _seq_log($log_file, 'step_fail', ['step'=>$next_idx,'error'=>$sub['error']??'A2A failed']);
            write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
            echo json_encode(['ok'=>false,'error'=>'A2A step failed','step'=>$next_idx], JSON_UNESCAPED_UNICODE); exit;
        }
        $plan['steps'][$next_idx]['status'] = 'done';
        $plan['steps'][$next_idx]['output'] = $sub['text'];
        $plan['steps'][$next_idx]['source'] = $sub['source'] ?? $executor_agent;
        $plan['steps'][$next_idx]['ended_at'] = date('c');
        _seq_log($log_file, 'step_done_a2a', ['step'=>$next_idx,'chars'=>strlen($sub['text'])]);
        write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
        echo json_encode(['ok'=>true,'step'=>$next_idx,'agent'=>$executor_agent,'status'=>'done_inline','text'=>$sub['text']], JSON_UNESCAPED_UNICODE); exit;
    }

    // Submit to bridge with retry
    $sub = with_retry(fn($att) => bridge_submit($executor_agent, $step_prompt, $project, $plan['chat'],
        ['ollama' => $executor_model, 'claude' => 'sonnet', 'gemini' => 'auto']), 2);

    if (empty($sub['ok'])) {
        $plan['steps'][$next_idx]['status'] = 'failed';
        $plan['steps'][$next_idx]['error'] = $sub['error'] ?? 'submit failed';
        $plan['steps'][$next_idx]['ended_at'] = date('c');
        _seq_log($log_file, 'step_fail', ['step'=>$next_idx,'error'=>$sub['error']??'submit failed']);
        write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
        echo json_encode(['ok'=>false,'error'=>'Step submit failed','step'=>$next_idx], JSON_UNESCAPED_UNICODE); exit;
    }

    $plan['steps'][$next_idx]['token'] = $sub['short'] ?? $sub['token'];
    write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);

    echo json_encode([
        'ok'    => true,
        'step'  => $next_idx,
        'token' => $plan['steps'][$next_idx]['token'],
        'agent' => $executor_agent,
        'status'=> 'running',
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: verify_step — run a verification check on a completed step's output.
// Called after polling confirms step output is ready.
// =============================================================================
if ($action === 'verify_step') {
    $project = safe_project($in['project'] ?? '');
    $plan_id = safe_plan_id($in['plan_id'] ?? '');
    $step_n  = isset($in['step']) ? intval($in['step']) : -1;
    $output  = (string)($in['output'] ?? '');

    if (!$project || !$plan_id || $step_n < 0) {
        echo json_encode(['ok'=>false,'error'=>'Missing args'], JSON_UNESCAPED_UNICODE); exit;
    }

    $plan = read_json(plan_path($project, $plan_id, $PROJECTS_ROOT));
    if (!$plan || !isset($plan['steps'][$step_n])) {
        echo json_encode(['ok'=>false,'error'=>'Plan/step not found'], JSON_UNESCAPED_UNICODE); exit;
    }

    $step = $plan['steps'][$step_n];
    $verification = $step['verification'] ?? null;
    $cfg = $plan['sequence_config'] ?? [];
    $log_file = $cfg['log_file'] ?? '';

    // Store the output
    if (strlen($output) > 1048576) $output = substr($output, 0, 1048576) . "\n[truncated]";
    $plan['steps'][$step_n]['output'] = $output;

    // Loop detection: compare output against recent outputs
    $guardrails = $cfg['guardrails'] ?? [];
    $loop_detected = false;
    if ($step_n > 0) {
        $threshold = (float)($guardrails['loop_similarity_threshold'] ?? 0.85);
        $window = (int)($guardrails['loop_window'] ?? 3);
        $recent = [];
        for ($i = max(0, $step_n - $window); $i < $step_n; $i++) {
            if (!empty($plan['steps'][$i]['output'])) $recent[] = $plan['steps'][$i]['output'];
        }
        foreach ($recent as $prev) {
            if (_text_similarity($output, $prev) >= $threshold) {
                $loop_detected = true;
                break;
            }
        }
    }

    if ($loop_detected) {
        $plan['steps'][$step_n]['status'] = 'failed';
        $plan['steps'][$step_n]['error'] = 'Loop detected: output near-identical to a recent step';
        $plan['steps'][$step_n]['ended_at'] = date('c');
        _seq_log($log_file, 'loop_detected', ['step'=>$step_n]);
        write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
        echo json_encode(['ok'=>true,'verified'=>false,'reason'=>'loop_detected','step'=>$step_n], JSON_UNESCAPED_UNICODE); exit;
    }

    // Run verification if defined
    $verified = true;
    $verify_detail = 'no verification defined';

    if ($verification && is_array($verification)) {
        $vtype = $verification['type'] ?? 'none';
        $check = $verification['check'] ?? '';
        $expect = $verification['expect'] ?? '';

        if ($vtype === 'command' && $check !== '') {
            $cmd_out = [];
            $rc = 0;
            exec(cockpit_timeout_cmd(30) . $check . ' 2>&1', $cmd_out, $rc);
            $cmd_str = implode("\n", $cmd_out);
            if ($expect !== '') {
                $verified = stripos($cmd_str, $expect) !== false;
                $verify_detail = $verified ? 'Command passed (found expected output)' : 'Expected "'.$expect.'" not found in output';
            } else {
                $verified = $rc === 0;
                $verify_detail = $verified ? 'Command exit code 0' : 'Command failed (rc='.$rc.')';
            }
        } elseif ($vtype === 'regex' && $check !== '') {
            $verified = (bool)preg_match('/' . $check . '/s', $output);
            $verify_detail = $verified ? 'Output matches regex' : 'Output does not match regex /'.$check.'/';
        } elseif ($vtype === 'file_exists' && $check !== '') {
            $verified = is_file($check);
            $verify_detail = $verified ? 'File exists: '.$check : 'File not found: '.$check;
        }
    }

    $plan['steps'][$step_n]['status'] = $verified ? 'done' : 'failed';
    $plan['steps'][$step_n]['ended_at'] = date('c');
    $plan['steps'][$step_n]['verification_result'] = [
        'passed' => $verified,
        'detail' => $verify_detail,
    ];

    _seq_log($log_file, $verified ? 'step_pass' : 'step_fail', [
        'step'=>$step_n, 'verified'=>$verified, 'detail'=>$verify_detail]);

    // Check if all steps done
    $remaining = 0;
    foreach ($plan['steps'] as $s) {
        if (!in_array($s['status'] ?? 'pending', ['done','skipped','failed'], true)) $remaining++;
    }
    if ($remaining === 0) $plan['status'] = 'complete';

    write_json(plan_path($project, $plan_id, $PROJECTS_ROOT), $plan);
    echo json_encode(['ok'=>true, 'verified'=>$verified, 'detail'=>$verify_detail, 'step'=>$step_n,
        'plan_status'=>$plan['status']], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: sequence_log — read the JSONL run log for a plan sequence
// =============================================================================
if ($action === 'sequence_log') {
    $project = safe_project($_GET['project'] ?? '');
    $plan_id = safe_plan_id($_GET['id'] ?? '');
    if (!$project || !$plan_id) { echo json_encode(['ok'=>false,'error'=>'Missing args'], JSON_UNESCAPED_UNICODE); exit; }

    $plan = read_json(plan_path($project, $plan_id, $PROJECTS_ROOT));
    if (!$plan) { echo json_encode(['ok'=>false,'error'=>'Plan not found'], JSON_UNESCAPED_UNICODE); exit; }

    $log_file = $plan['sequence_config']['log_file'] ?? '';
    $entries = [];
    if ($log_file && is_file($log_file)) {
        foreach (file($log_file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
            $e = json_decode($line, true);
            if ($e) $entries[] = $e;
        }
    }
    echo json_encode(['ok'=>true, 'log'=>$entries], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok'=>false,'error'=>'Unknown action: '.$action], JSON_UNESCAPED_UNICODE);

// =============================================================================
// Helpers
// =============================================================================

function _seq_log($file, $event, $data = []) {
    if (!$file) return;
    $entry = array_merge(['ts'=>date('c'), 'event'=>$event], $data);
    @file_put_contents($file, json_encode($entry, JSON_UNESCAPED_UNICODE) . "\n", FILE_APPEND | LOCK_EX);
}

function _text_similarity($a, $b) {
    $a = trim(mb_substr($a, 0, 2000));
    $b = trim(mb_substr($b, 0, 2000));
    if ($a === '' || $b === '') return 0.0;
    if ($a === $b) return 1.0;
    similar_text($a, $b, $pct);
    return $pct / 100.0;
}

// Extract the JSON object from an agent's text output. Agents sometimes wrap
// JSON in markdown fences or prose despite instructions; we strip those.
function extract_plan_json($raw) {
    if (!is_string($raw)) return null;
    // Try direct parse first
    $j = json_decode(trim($raw), true);
    if (is_array($j) && isset($j['steps'])) return normalize_plan($j);

    // Try to find a code-fenced JSON block
    if (preg_match('#```(?:json)?\s*(\{.*?\})\s*```#is', $raw, $m)) {
        $j = json_decode($m[1], true);
        if (is_array($j) && isset($j['steps'])) return normalize_plan($j);
    }
    // Try to find the first balanced { ... } that contains "steps":
    $start = strpos($raw, '{');
    while ($start !== false) {
        $depth = 0;
        for ($i = $start; $i < strlen($raw); $i++) {
            $c = $raw[$i];
            if ($c === '{') $depth++;
            elseif ($c === '}') {
                $depth--;
                if ($depth === 0) {
                    $candidate = substr($raw, $start, $i - $start + 1);
                    $j = json_decode($candidate, true);
                    if (is_array($j) && isset($j['steps'])) return normalize_plan($j);
                    break;
                }
            }
        }
        $start = strpos($raw, '{', $start + 1);
    }
    return null;
}

function normalize_plan($p) {
    $out = [
        'summary' => is_string($p['summary'] ?? null) ? $p['summary'] : '',
        'steps'   => [],
    ];
    foreach (($p['steps'] ?? []) as $s) {
        if (!is_array($s)) continue;
        $out['steps'][] = [
            'description'  => (string)($s['description'] ?? ''),
            'agent'        => safe_agent($s['agent'] ?? '') ?: 'claude',
            'capabilities' => is_array($s['capabilities'] ?? null) ? array_values(array_filter($s['capabilities'], 'is_string')) : [],
            'destructive'  => !empty($s['destructive']),
        ];
    }
    return $out;
}

// Add bookkeeping fields to each step so the orchestrator can track state
function annotate_steps($steps) {
    if (!is_array($steps)) return [];
    $out = [];
    foreach ($steps as $i => $s) {
        if (!is_array($s)) continue;
        $out[] = array_merge([
            'id'           => $s['id']           ?? ('s' . ($i + 1)),
            'description'  => $s['description']  ?? '',
            'agent'        => safe_agent($s['agent'] ?? '') ?: 'claude',
            'capabilities' => $s['capabilities'] ?? [],
            'destructive'  => !empty($s['destructive']),
            'status'       => $s['status']       ?? 'pending',
            'output'       => $s['output']       ?? null,
            'started_at'   => $s['started_at']   ?? null,
            'ended_at'     => $s['ended_at']     ?? null,
            'error'        => $s['error']        ?? null,
            'token'        => $s['token']        ?? null,
        ], []);
    }
    return $out;
}
