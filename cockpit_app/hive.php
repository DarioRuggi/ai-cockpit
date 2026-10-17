<?php
// =============================================================================
// hive.php — Cockpit's window onto the local HIVE agent bus (H4).
// Reads the shared file-bus (~/.cockpit/hive by default, or
// $HIVE_HOME / paths.php 'hive_home') and lets the Hive panel show the live
// agent roster + message flow, and send messages. Records are email-style
// (Key: value header lines, blank line, body) — same format the `hive` CLI writes.
//
//   GET  ?action=ps           → { ok, available, agents:[{slug,instance,state,kind,caps,age}] }
//   GET  ?action=log&n=40     → { ok, events:[…] }
//   POST ?action=send         → { to, type, subject, body, cmd } enqueues a message from "cockpit"
//
// SECURITY: this endpoint READS the bus and ENQUEUES messages. It never executes
// anything — a `call`/`wake` it sends is a proposal the broker surfaces for consent
// (see shared/DEPLOY_MECHANISM.md). Records are untrusted data, shown as data.
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
require_once __DIR__ . '/entitle.php';   // require_cap() — paid-tier gate (server-side truth)
header('Content-Type: application/json');
header('Cache-Control: no-store');

$TTL = 90;

function hive_home(): string {
    $h = getenv('HIVE_HOME');
    if ($h) return rtrim($h, '/');
    global $PATHS;
    if (!empty($PATHS['hive_home'])) return rtrim($PATHS['hive_home'], '/');
    return (getenv('HOME') ?: '/tmp') . '/.cockpit/hive';
}
$HIVE = hive_home();

if (!is_dir($HIVE)) { echo json_encode(['ok' => true, 'available' => false, 'agents' => [], 'events' => []]); exit; }

// Parse an email-style record file → [headers assoc, body string].
function hive_read_record(string $file): array {
    $raw = @file_get_contents($file);
    if ($raw === false) return [[], ''];
    $parts = preg_split("/\r?\n\r?\n/", $raw, 2);
    $head = []; foreach (explode("\n", $parts[0]) as $ln) {
        if (preg_match('/^([A-Za-z0-9_]+):\s?(.*)$/', $ln, $m)) $head[$m[1]] = $m[2];
    }
    return [$head, $parts[1] ?? ''];
}

function hive_liveness(int $last_seen, int $ttl): string {
    $age = time() - $last_seen;
    if ($age >= $ttl * 4) return 'down';
    if ($age >= $ttl)     return 'stale';
    return 'live';
}

// C4: capability router — pick the best agent on the bus for a needed capability.
// Ranks: live > stale/down, then prefer local/free (cost), then most-recent. Falls
// back to 'ollama' (always-available local) if nothing matches.
function hive_route(string $hive, string $cap, string $prefer = 'local'): string {
    $TTL = 90; $localSet = ['ollama', 'localai', 'aider', 'goose', 'opencode'];
    $cands = [];
    foreach (glob("$hive/registry/*/*.rec") ?: [] as $f) {
        $raw = @file_get_contents($f); if ($raw === false) continue;
        $slug = ''; $caps = ''; $ls = 0;
        foreach (explode("\n", $raw) as $ln) {
            if (preg_match('/^slug: (.*)$/', $ln, $m)) $slug = trim($m[1]);
            elseif (preg_match('/^caps: (.*)$/', $ln, $m)) $caps = trim($m[1]);
            elseif (preg_match('/^last_seen: (\d+)/', $ln, $m)) $ls = (int)$m[1];
        }
        if ($slug === '' || $slug === 'cockpit') continue;
        $capList = array_filter(array_map('trim', explode(',', $caps)));
        if ($cap !== '' && !in_array($cap, $capList, true)) continue;
        $age = time() - $ls;
        $cands[$slug] = ['slug' => $slug, 'live' => $age < $TTL ? 1 : 0, 'local' => in_array($slug, $localSet, true) ? 1 : 0, 'age' => $age];
    }
    if (!$cands) return 'ollama';
    usort($cands, function ($a, $b) use ($prefer) {
        if ($a['live'] !== $b['live']) return $b['live'] - $a['live'];
        if ($prefer !== 'any' && $a['local'] !== $b['local']) return $b['local'] - $a['local'];
        return $a['age'] - $b['age'];
    });
    return $cands[0]['slug'];
}

$action = $_GET['action'] ?? 'ps';

if ($action === 'avail') {
    // Ungated availability probe: does this machine HAVE a hive, and what is the
    // caller entitled to? The FAB uses this to decide whether to show (Basic+ can
    // reach the Cruise toggle) without hitting a paid-gated action. Reveals no bus
    // data — only booleans the client already learns from saas.php.
    echo json_encode(['ok' => true, 'available' => is_dir($HIVE),
        'can_cruise' => cap_allowed('cruise'), 'can_cognition' => cap_allowed('cognition')]);
    exit;
}

if ($action === 'ps') {
    require_cap('cognition');   // the bus roster is AutoCognition (Pro)
    // Best-effort: register Cockpit itself so other agents see it while the panel is open.
    $reg = "$HIVE/registry/cockpit";
    @mkdir($reg, 0777, true);
    $now = time();
    @file_put_contents("$reg/web.rec",
        "slug: cockpit\ninstance: web\npid: 0\nhost: " . gethostname() .
        "\nstarted: $now\nlast_seen: $now\ncaps: ui,dispatch,orchestrate\naccepts: info,ask\nlaunch: \nkind: web\n\n");

    $agents = [];
    foreach (glob("$HIVE/registry/*/*.rec") as $f) {
        [$h] = hive_read_record($f);
        if (empty($h['slug'])) continue;
        $ls = (int)($h['last_seen'] ?? 0);
        $agents[] = [
            'slug' => $h['slug'], 'instance' => $h['instance'] ?? '',
            'state' => hive_liveness($ls, $TTL), 'kind' => $h['kind'] ?? '',
            'caps' => array_values(array_filter(explode(',', $h['caps'] ?? ''))),
            'age' => max(0, time() - $ls),
        ];
    }
    usort($agents, fn($a, $b) => [$a['slug'], $a['instance']] <=> [$b['slug'], $b['instance']]);
    echo json_encode(['ok' => true, 'available' => true, 'agents' => $agents]);
    exit;
}

if ($action === 'route') {
    require_cap('cognition');   // manual capability routing (Pro)
    // C4: which agent would handle a given capability right now?
    $cap = preg_replace('/[^a-z0-9_.-]/i', '', (string)($_GET['cap'] ?? ''));
    echo json_encode(['ok' => true, 'available' => true, 'cap' => $cap, 'agent' => hive_route($HIVE, $cap, $_GET['prefer'] ?? 'local')]);
    exit;
}

if ($action === 'log') {
    require_cap('cognition');   // bus event log (Pro)
    $n = max(1, min(200, (int)($_GET['n'] ?? 40)));
    $logf = "$HIVE/log.txt";
    $events = [];
    if (is_file($logf)) {
        $lines = @file($logf, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
        foreach (array_slice($lines, -$n) as $ln) $events[] = $ln;
    }
    echo json_encode(['ok' => true, 'available' => true, 'events' => $events]);
    exit;
}

if ($action === 'send' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    require_cap('cognition');   // enqueue a bus message (Pro)
    $in = json_decode(file_get_contents('php://input'), true) ?: [];
    $to = preg_replace('/[^a-z0-9_.-]/i', '', (string)($in['to'] ?? ''));
    $type = in_array($in['type'] ?? 'info', ['info', 'ask', 'call', 'wake'], true) ? $in['type'] : 'info';
    if ($to === '') { echo json_encode(['ok' => false, 'error' => 'missing recipient']); exit; }
    $id = dechex((int)(microtime(true) * 1000)) . bin2hex(random_bytes(3));
    $subject = str_replace(["\r", "\n"], ' ', (string)($in['subject'] ?? ''));
    $corr = dechex((int)(microtime(true) * 1000)) . bin2hex(random_bytes(3));
    $lines = ["id: $id", 'ts: ' . time(), 'from: cockpit/web', "to: $to", "type: $type",
              "subject: $subject", "corr: $corr"];
    if ($type === 'call') {
        $cmd = str_replace(["\r", "\n"], ' ', (string)($in['cmd'] ?? ''));
        $lines[] = "action_cmd: $cmd"; $lines[] = 'action_cwd: '; $lines[] = 'needs_consent: true';
    }
    $body = (string)($in['body'] ?? '');
    $dir = "$HIVE/inbox/$to"; @mkdir($dir, 0777, true);
    $tmp = "$dir/$id.rec.tmp";
    @file_put_contents($tmp, implode("\n", $lines) . "\n\n" . $body);
    @rename($tmp, "$dir/$id.rec");
    @file_put_contents("$HIVE/log.txt",
        date('H:i:s') . ' ts=' . time() . " send from=cockpit/web to=$to type=$type id=$id subject=$subject\n",
        FILE_APPEND);
    echo json_encode(['ok' => true, 'id' => $id]);
    exit;
}

if ($action === 'broker_status') {
    require_cap('cognition');   // broker status (Pro)
    $pidf = "$HIVE/brokerd.pid";
    $running = false; $pid = 0;
    if (is_file($pidf)) {
        $pid = (int)trim((string)@file_get_contents($pidf));
        if ($pid > 0) $running = file_exists("/proc/$pid") || (function_exists('posix_kill') && @posix_kill($pid, 0));
    }
    echo json_encode(['ok' => true, 'available' => true, 'running' => $running, 'pid' => $running ? $pid : 0,
        'start_cmd' => 'setsid ' . $HIVE . '/bin/hive-brokerd --interval 5 >/dev/null 2>&1 &']);
    exit;
}

if ($action === 'pending') {
    require_cap('cognition');   // approvals queue (Pro)
    // Queued call/wake proposals across all inboxes — the approvals view.
    $items = [];
    foreach (glob("$HIVE/inbox/*/*.rec") as $f) {
        [$h] = hive_read_record($f);
        $ty = $h['type'] ?? ''; if (!in_array($ty, ['call', 'wake'], true)) continue;
        $items[] = ['id' => $h['id'] ?? '', 'from' => $h['from'] ?? '', 'to' => $h['to'] ?? '',
                    'type' => $ty, 'subject' => $h['subject'] ?? '', 'cmd' => $h['action_cmd'] ?? '',
                    'ts' => (int)($h['ts'] ?? 0)];
    }
    usort($items, fn($a, $b) => $b['ts'] <=> $a['ts']);
    echo json_encode(['ok' => true, 'available' => true, 'pending' => $items]);
    exit;
}

if ($action === 'decline' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    require_cap('cognition');   // decline a broker proposal (Pro)
    $in = json_decode(file_get_contents('php://input'), true) ?: [];
    $to = preg_replace('/[^a-z0-9_.-]/i', '', (string)($in['to'] ?? ''));
    $id = preg_replace('/[^a-f0-9]/i', '', (string)($in['id'] ?? ''));
    if ($to === '' || $id === '') { echo json_encode(['ok' => false, 'error' => 'missing id/to']); exit; }
    $src = "$HIVE/inbox/$to/$id.rec";
    if (!is_file($src)) { echo json_encode(['ok' => false, 'error' => 'not found (already handled?)']); exit; }
    $done = "$HIVE/inbox/$to/.done"; @mkdir($done, 0777, true);
    @rename($src, "$done/$id.rec");
    @file_put_contents("$HIVE/log.txt",
        date('H:i:s') . ' ts=' . time() . " decline id=$id to=$to by=cockpit/web\n", FILE_APPEND);
    echo json_encode(['ok' => true]);
    exit;
}

if ($action === 'chains') {
    require_cap('cognition');   // the manual chains board (Pro)
    // Durable task boards (H6) — list with progress.
    $out = [];
    foreach (glob("$HIVE/board/*/chain.rec") as $cf) {
        [$h] = hive_read_record($cf);
        $dir = dirname($cf);
        $steps = glob("$dir/steps/*.rec") ?: [];
        $done = 0; $interrupted = false;
        foreach ($steps as $sf) { [$sh] = hive_read_record($sf); $st = $sh['status'] ?? ''; if ($st === 'done') $done++; if ($st === 'running') $interrupted = true; }
        $out[] = ['id' => $h['id'] ?? '', 'goal' => $h['goal'] ?? '', 'status' => $h['status'] ?? '',
                  'done' => $done, 'total' => count($steps), 'interrupted' => $interrupted,
                  'created' => (int)($h['created'] ?? 0)];
    }
    usort($out, fn($a, $b) => $b['created'] <=> $a['created']);
    echo json_encode(['ok' => true, 'available' => true, 'chains' => $out]);
    exit;
}

if ($action === 'chain_result') {
    require_cap('cruise');   // Cruise reads its own chain's answer here
    $id = preg_replace('/[^a-f0-9]/i', '', (string)($_GET['id'] ?? ''));
    $dir = "$HIVE/board/$id";
    if ($id === '' || !is_dir($dir)) { echo json_encode(['ok' => false, 'error' => 'no such chain']); exit; }
    $outs = glob("$dir/steps/*.out") ?: []; sort($outs);
    echo json_encode(['ok' => true, 'output' => $outs ? (string)@file_get_contents(end($outs)) : '']);
    exit;
}

if ($action === 'chain') {
    require_cap('cognition');   // manual chain inspector (Pro)
    $id = preg_replace('/[^a-f0-9]/i', '', (string)($_GET['id'] ?? ''));
    $dir = "$HIVE/board/$id";
    if ($id === '' || !is_dir($dir)) { echo json_encode(['ok' => false, 'error' => 'no such chain']); exit; }
    [$ch] = hive_read_record("$dir/chain.rec");
    $steps = [];
    foreach (glob("$dir/steps/*.rec") ?: [] as $sf) {
        [$sh, $body] = hive_read_record($sf);
        $idx = $sh['idx'] ?? '';
        $ckpt = ''; $cf = "$dir/steps/$idx.ckpt";
        if (is_file($cf)) { $lines = @file($cf, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: []; if ($lines) $ckpt = preg_replace('/^\d+\|/', '', end($lines)); }
        $steps[] = ['idx' => $idx, 'agent' => $sh['agent'] ?? '',
                    'status' => $sh['status'] ?? '', 'action' => trim($body), 'checkpoint' => $ckpt,
                    'need' => $sh['need'] ?? '', 'parallel' => ($sh['parallel'] ?? 'no') === 'yes',
                    'quorum' => !empty($sh['quorum']) ? count(array_filter(explode(',', $sh['quorum']))) : 0];
    }
    echo json_encode(['ok' => true, 'available' => true,
        'chain' => ['id' => $ch['id'] ?? '', 'goal' => $ch['goal'] ?? '', 'status' => $ch['status'] ?? '',
                    'granularity' => $ch['granularity'] ?? 'normal', 'auto_resume' => $ch['auto_resume'] ?? 'on'],
        'steps' => $steps]);
    exit;
}

if ($action === 'chain_granularity' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    require_cap('cognition');   // manual per-chain granularity tuning (Pro)
    $in = json_decode(file_get_contents('php://input'), true) ?: [];
    $id = preg_replace('/[^a-f0-9]/i', '', (string)($in['id'] ?? ''));
    $g = in_array($in['granularity'] ?? '', ['fine', 'normal', 'coarse'], true) ? $in['granularity'] : 'normal';
    $cf = "$HIVE/board/$id/chain.rec";
    if ($id === '' || !is_file($cf)) { echo json_encode(['ok' => false, 'error' => 'no such chain']); exit; }
    $raw = (string)@file_get_contents($cf);
    if (preg_match('/^granularity: /m', $raw)) $raw = preg_replace('/^granularity: .*$/m', "granularity: $g", $raw, 1);
    else $raw = rtrim($raw, "\n") . "\ngranularity: $g\n";
    @file_put_contents($cf, $raw);
    @file_put_contents("$HIVE/log.txt", date('H:i:s') . ' ts=' . time() . " chain_granularity id=$id gran=$g by=cockpit/web\n", FILE_APPEND);
    echo json_encode(['ok' => true, 'granularity' => $g]);
    exit;
}

if ($action === 'chain_autoresume' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    require_cap('cruise');   // auto-resume of a Cruise chain
    $in = json_decode(file_get_contents('php://input'), true) ?: [];
    $id = preg_replace('/[^a-f0-9]/i', '', (string)($in['id'] ?? ''));
    $v = ($in['auto_resume'] ?? 'on') === 'off' ? 'off' : 'on';
    $cf = "$HIVE/board/$id/chain.rec";
    if ($id === '' || !is_file($cf)) { echo json_encode(['ok' => false, 'error' => 'no such chain']); exit; }
    $raw = (string)@file_get_contents($cf);
    if (preg_match('/^auto_resume: /m', $raw)) $raw = preg_replace('/^auto_resume: .*$/m', "auto_resume: $v", $raw, 1);
    else $raw = rtrim($raw, "\n") . "\nauto_resume: $v\n";
    @file_put_contents($cf, $raw);
    @file_put_contents("$HIVE/log.txt", date('H:i:s') . ' ts=' . time() . " chain_autoresume id=$id auto_resume=$v by=cockpit/web\n", FILE_APPEND);
    echo json_encode(['ok' => true, 'auto_resume' => $v]);
    exit;
}

if ($action === 'config') {
    require_cap('cruise');   // Cruise reads/sets its auto-resume default
    // Global default for new chains' auto-resume.
    $cfgf = "$HIVE/config.txt"; $def = 'on';
    if (is_file($cfgf) && preg_match('/^auto_resume_default:\s*(\S+)/m', (string)@file_get_contents($cfgf), $m)) $def = $m[1];
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        $in = json_decode(file_get_contents('php://input'), true) ?: [];
        $v = ($in['auto_resume_default'] ?? 'on') === 'off' ? 'off' : 'on';
        $raw = is_file($cfgf) ? (string)@file_get_contents($cfgf) : '';
        if (preg_match('/^auto_resume_default:/m', $raw)) $raw = preg_replace('/^auto_resume_default:.*$/m', "auto_resume_default: $v", $raw, 1);
        else $raw = rtrim($raw, "\n") . ($raw ? "\n" : '') . "auto_resume_default: $v\n";
        @file_put_contents($cfgf, $raw);
        @file_put_contents("$HIVE/log.txt", date('H:i:s') . ' ts=' . time() . " config auto_resume_default=$v by=cockpit/web\n", FILE_APPEND);
        echo json_encode(['ok' => true, 'auto_resume_default' => $v]); exit;
    }
    echo json_encode(['ok' => true, 'available' => true, 'auto_resume_default' => $def]);
    exit;
}

if ($action === 'chain_resume' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    require_cap('cruise');   // resume an interrupted Cruise chain
    $in = json_decode(file_get_contents('php://input'), true) ?: [];
    $id = preg_replace('/[^a-f0-9]/i', '', (string)($in['id'] ?? ''));
    $dir = "$HIVE/board/$id";
    if ($id === '' || !is_dir($dir)) { echo json_encode(['ok' => false, 'error' => 'no such chain']); exit; }
    // Reset any interrupted (running) step → pending; done steps + outputs untouched.
    $reset = 0;
    foreach (glob("$dir/steps/*.rec") ?: [] as $sf) {
        $raw = (string)@file_get_contents($sf);
        if (preg_match('/^status: running\s*$/m', $raw)) {
            $raw = preg_replace('/^status: running\s*$/m', 'status: pending', $raw, 1);
            @file_put_contents($sf, $raw); $reset++;
        }
    }
    $cf = "$dir/chain.rec"; $craw = (string)@file_get_contents($cf);
    $craw = preg_replace('/^status: .*$/m', 'status: running', $craw, 1);
    @file_put_contents($cf, $craw);
    @file_put_contents("$HIVE/log.txt",
        date('H:i:s') . ' ts=' . time() . " chain_resume id=$id reset=$reset by=cockpit/web\n", FILE_APPEND);
    echo json_encode(['ok' => true, 'reset' => $reset]);
    exit;
}

if ($action === 'plan' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    require_cap('cruise');   // the planner is the heart of Autopilot Cruise (Basic)
    // C3: the planner — a local model decomposes a GOAL into steps, and we draft a
    // (not-yet-running) chain the user reviews as a Proposal, then runs.
    require_once __DIR__ . '/combos_core.php';
    require_once __DIR__ . '/combos_lib.php';
    $in = json_decode(file_get_contents('php://input'), true) ?: [];
    $goal = trim((string)($in['goal'] ?? ''));
    if ($goal === '') { echo json_encode(['ok' => false, 'error' => 'empty goal']); exit; }
    $pm = is_array($in['planner_model'] ?? null) ? ($in['planner_model']['model'] ?? '') : (string)($in['planner_model'] ?? '');
    $pmodel = preg_replace('/[^a-z0-9_.:\/-]/i', '', $pm);
    // ---- Planner: fast model first, escalate only when its plan is unusable -----
    // Measured on this rig 2026-09-06: qwen2.5:7b plans in ~8-9s, qwen2.5:14b in ~25-38s
    // (2.66 tok/s, 12/49 layers on a 4GB card). In testing the 7b produced a usable plan
    // most of the time, so paying the 14b tax on EVERY goal is waste. Instead: plan with
    // the 7b, mechanically check the result, and re-plan with the 14b only if the check
    // fails. Costs the extra time exactly when it buys something.
    // A client that names a model explicitly keeps full control (no escalation).
    $PLANNER_PRIMARY  = 'qwen2.5:7b';
    $PLANNER_ESCALATE = 'qwen2.5:14b';
    $explicitModel = ($pmodel !== '' && strcasecmp($pmodel, 'Array') !== 0);

    $sys = "You are a task planner. Decompose the GOAL into 2 to 5 ordered steps a system will execute.\n" .
        "Rules:\n" .
        "- \"action\": one concrete imperative instruction (a single task).\n" .
        "- \"need\": EXACTLY ONE word from this set: text, code, reasoning, web, vision.\n" .
        "- Output ONLY a JSON array. No prose, no markdown, no code fences.\n" .
        "Example: [{\"need\":\"reasoning\",\"action\":\"Outline the key points\"},{\"need\":\"text\",\"action\":\"Write the final version\"}]\n" .
        "GOAL: " . $goal;

    // Run the planner once and parse it, exactly as before.
    $runPlanner = function (string $model) use ($sys) {
        $out = [];
        if (!function_exists('ollama_generate')) return $out;
        // 300s ceiling: a verbose 5-step plan is ~300 tokens; at the 14b's measured
        // 2.66 tok/s that is ~113s, too close to the old 120s limit.
        $r = ollama_generate($model, $sys, ['runner' => 'ollama', 'timeout' => 300]);
        if (empty($r['ok']) || !preg_match('/\[.*\]/s', (string)$r['text'], $mm)) return $out;
        $arr = json_decode($mm[0], true);
        if (!is_array($arr)) return $out;
        foreach ($arr as $s) {
            if (empty($s['action'])) continue;
            $need  = preg_replace('/[^a-z]/', '', strtolower((string)($s['need'] ?? '')));
            $valid = ['text', 'code', 'reasoning', 'web', 'vision'];
            if (!in_array($need, $valid, true)) {
                $need2 = ''; foreach ($valid as $vc) if (strpos($need, $vc) !== false) { $need2 = $vc; break; }
                $need = $need2;
            }
            $ag = preg_replace('/[^a-z0-9_.:-]/i', '', (string)($s['agent'] ?? ''));
            // Prefer capability routing: agent=auto + need. A concrete agent overrides.
            $out[] = ['agent' => $ag ?: 'auto', 'need' => $need, 'action' => (string)$s['action']];
        }
        return $out;
    };

    // "Unusable" = what a machine can actually tell: nothing parsed, a single step when
    // 2-5 were asked for, or a step whose need-tag did not survive the enum check.
    // (It cannot catch a plan that is valid but semantically incomplete — for that the
    // user re-plans from the panel with an explicit model.)
    $planUnusable = function (array $st) {
        if (count($st) < 2) return true;
        foreach ($st as $x) if (($x['need'] ?? '') === '') return true;
        return false;
    };

    $planner_used = ''; $escalated = false;
    if ($explicitModel) {
        $steps = $runPlanner($pmodel);
        $planner_used = $pmodel;
    } else {
        $steps = $runPlanner($PLANNER_PRIMARY);
        $planner_used = $PLANNER_PRIMARY;
        if ($planUnusable($steps)) {
            $bigger = $runPlanner($PLANNER_ESCALATE);
            if (!$planUnusable($bigger) || (!$steps && $bigger)) {
                $steps = $bigger; $planner_used = $PLANNER_ESCALATE; $escalated = true;
            }
        }
    }
    @file_put_contents("$HIVE/log.txt", date('H:i:s') . ' ts=' . time() .
        " chain_planner model=$planner_used escalated=" . ($escalated ? '1' : '0') . "\n", FILE_APPEND);

    if (!$steps) $steps = [['agent' => 'auto', 'need' => 'text', 'action' => $goal]];   // fallback: single routed step

    $arDef = 'on'; $cfgf = "$HIVE/config.txt";
    if (is_file($cfgf) && preg_match('/^auto_resume_default:\s*(\S+)/m', (string)@file_get_contents($cfgf), $m)) $arDef = $m[1];
    $cid = dechex((int)(microtime(true) * 1000)) . bin2hex(random_bytes(3));
    $dir = "$HIVE/board/$cid"; @mkdir("$dir/steps", 0777, true);
    @file_put_contents("$dir/chain.rec",
        "id: $cid\ngoal: " . str_replace(["\r", "\n"], ' ', $goal) . "\ncreated_by: cockpit/web\nstatus: building\ncursor: 0" .
        "\ngranularity: normal\nauto_resume: $arDef\npattern: sequential\nfrom_planner: 1\ncreated: " . time() . "\n");
    $i = 0;
    foreach ($steps as $s) {
        $idx = sprintf('%03d', $i++);
        $model = ($s['agent'] === 'ollama' || $s['agent'] === 'auto') ? $pmodel : '';
        @file_put_contents("$dir/steps/$idx.rec",
            "idx: $idx\nagent: {$s['agent']}\nstatus: pending\nmodel: $model\nparallel: no\nneed: " . ($s['need'] ?? '') . "\nts: " . time() . "\n\n" .
            ($idx === '000' ? $s['action'] : '%PREV%' . "\n\n" . $s['action']));
    }
    @file_put_contents("$HIVE/log.txt", date('H:i:s') . ' ts=' . time() . " chain_plan id=$cid steps=$i by=cockpit/web\n", FILE_APPEND);
    echo json_encode(['ok' => true, 'chain_id' => $cid, 'steps' => $steps, 'count' => $i,
                     'planner_used' => $planner_used, 'escalated' => $escalated]);
    exit;
}

if ($action === 'chain_run_group' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    require_cap('cognition');   // concurrent/parallel execution is AutoCognition (Pro)
    // C1c: run a group of consecutive parallel-pending steps CONCURRENTLY (curl_multi)
    // for local runners; non-local steps in the group are routed to their agent via the
    // bus (consent path) and left pending. Falls back to a single step if the next isn't parallel.
    require_once __DIR__ . '/combos_core.php';
    require_once __DIR__ . '/combos_lib.php';
    $in = json_decode(file_get_contents('php://input'), true) ?: [];
    $id = preg_replace('/[^a-f0-9]/i', '', (string)($in['id'] ?? ''));
    $dir = "$HIVE/board/$id";
    if ($id === '' || !is_dir($dir)) { echo json_encode(['ok' => false, 'error' => 'no such chain']); exit; }

    $files = glob("$dir/steps/*.rec") ?: []; sort($files);
    $prevOut = ''; $group = [];
    foreach ($files as $f) {
        [$h, $body] = hive_read_record($f);
        $st = $h['status'] ?? '';
        if ($st === 'done') { $o = @file_get_contents("$dir/steps/{$h['idx']}.out"); if ($o !== false) $prevOut = $o; continue; }
        if ($st === 'pending') {
            if (($h['parallel'] ?? 'no') === 'yes') { $group[] = [$f, $h, $body]; continue; }
            if (empty($group)) $group[] = [$f, $h, $body];   // single non-parallel step
            break;
        }
        if ($st === 'running') { $group[] = [$f, $h, $body]; break; }
    }
    if (empty($group)) {
        $raw = (string)@file_get_contents("$dir/chain.rec");
        @file_put_contents("$dir/chain.rec", preg_replace('/^status: .*$/m', 'status: done', $raw, 1));
        echo json_encode(['ok' => true, 'done' => true]); exit;
    }

    $setStatus = function ($file, $s) { $r = (string)@file_get_contents($file); @file_put_contents($file, preg_replace('/^status: .*$/m', "status: $s", $r, 1)); };
    $ckpt = function ($idx, $note) use ($dir) { @file_put_contents("$dir/steps/$idx.ckpt", time() . '|' . $note . "\n", FILE_APPEND); };
    $fillP = function ($body) use ($prevOut) { $p = function_exists('combos_fill') ? combos_fill($body, '', '', $prevOut) : $body; if ($prevOut !== '' && strpos($body, '%PREV%') === false) $p = "Context from the previous step:\n$prevOut\n\n" . $p; return $p; };

    $mh = curl_multi_init(); $handles = []; $routed = []; $ran = [];
    foreach ($group as $g) {
        [$f, $h, $body] = $g; $idx = $h['idx']; $agent = $h['agent'] ?? 'ollama'; $model = $h['model'] ?? '';
        if ($agent === 'auto' || $agent === '') {   // C4: capability routing
            $agent = hive_route($HIVE, $h['need'] ?? '', 'local');
            $rr = (string)@file_get_contents($f); @file_put_contents($f, preg_replace('/^agent: .*$/m', "agent: $agent", $rr, 1));
            @file_put_contents("$dir/steps/$idx.ckpt", time() . "|routed → $agent (cap: " . ($h['need'] ?? 'any') . ")\n", FILE_APPEND);
        }
        if (!in_array($agent, ['ollama', 'localai'], true)) {
            // route to the agent via the bus (consent path); leave pending
            $mid = dechex((int)(microtime(true) * 1000)) . bin2hex(random_bytes(3));
            @mkdir("$HIVE/inbox/$agent", 0777, true);
            @file_put_contents("$HIVE/inbox/$agent/$mid.rec",
                "id: $mid\nts: " . time() . "\nfrom: cockpit/web\nto: $agent\ntype: ask\nsubject: chain step $id/$idx\ncorr: $id\n\n" . $fillP($body));
            $ckpt($idx, "routed → $agent (via bus, needs that agent)");
            $routed[] = ['step' => $idx, 'agent' => $agent];
            continue;
        }
        $prompt = $fillP($body);
        $base = combos_backend_base($agent);
        if ($agent === 'localai') { $url = "$base/v1/chat/completions"; $payload = ['model' => $model, 'messages' => [['role' => 'user', 'content' => $prompt]], 'stream' => false]; }
        else { $url = "$base/api/generate"; $payload = ['model' => $model, 'prompt' => $prompt, 'stream' => false, 'options' => ['num_ctx' => 4096]]; }
        $ch = curl_init($url);
        curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_POST => true, CURLOPT_POSTFIELDS => json_encode($payload), CURLOPT_HTTPHEADER => ['Content-Type: application/json'], CURLOPT_TIMEOUT => 180]);
        curl_multi_add_handle($mh, $ch);
        $handles[$idx] = ['ch' => $ch, 'file' => $f, 'agent' => $agent];
        $setStatus($f, 'running'); $ckpt($idx, "dispatched (parallel) → $agent/$model");
    }
    // drive the concurrent requests
    if ($handles) { do { $mrc = curl_multi_exec($mh, $active); if ($active) curl_multi_select($mh, 1.0); } while ($active && $mrc == CURLM_OK); }
    foreach ($handles as $idx => $hd) {
        $raw = curl_multi_getcontent($hd['ch']); curl_multi_remove_handle($mh, $hd['ch']);
        $j = json_decode((string)$raw, true);
        $text = $hd['agent'] === 'localai' ? (string)($j['choices'][0]['message']['content'] ?? '') : (string)($j['response'] ?? '');
        if (is_array($j) && $text !== '' && !isset($j['error'])) {
            @file_put_contents("$dir/steps/$idx.out", $text); $setStatus($hd['file'], 'done'); $ckpt($idx, 'done (parallel)');
            $ran[] = ['step' => $idx, 'preview' => mb_substr($text, 0, 160)];
        } else { $setStatus($hd['file'], 'failed'); $ckpt($idx, 'failed'); }
    }
    curl_multi_close($mh);
    // advance chain status
    $remaining = 0; $anyFail = false;
    foreach (glob("$dir/steps/*.rec") ?: [] as $sf) { [$sh] = hive_read_record($sf); $s = $sh['status'] ?? ''; if ($s === 'pending' || $s === 'running') $remaining++; if ($s === 'failed') $anyFail = true; }
    $craw = (string)@file_get_contents("$dir/chain.rec");
    $newStatus = $anyFail ? 'failed' : ($remaining === 0 ? 'done' : 'running');
    @file_put_contents("$dir/chain.rec", preg_replace('/^status: .*$/m', "status: $newStatus", $craw, 1));
    @file_put_contents("$HIVE/log.txt", date('H:i:s') . ' ts=' . time() . " chain_group id=$id ran=" . count($ran) . " routed=" . count($routed) . " remaining=$remaining\n", FILE_APPEND);
    echo json_encode(['ok' => !$anyFail, 'ran' => $ran, 'routed' => $routed, 'remaining' => $remaining, 'done' => $remaining === 0 && !$anyFail]);
    exit;
}

if ($action === 'chain_run_step' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    require_cap('cruise');   // sequential step execution — Cruise's engine (Basic); the quorum branch below adds require_cap('cognition')
    // C1b: durable executor — run the NEXT pending step through Cockpit's dispatch,
    // checkpoint it, save output, advance. Client calls repeatedly (run-next loop).
    // Local runners (ollama/localai) auto-run; other agents pause for consent.
    require_once __DIR__ . '/combos_core.php';
    require_once __DIR__ . '/combos_lib.php';
    $in = json_decode(file_get_contents('php://input'), true) ?: [];
    $id = preg_replace('/[^a-f0-9]/i', '', (string)($in['id'] ?? ''));
    $dir = "$HIVE/board/$id";
    if ($id === '' || !is_dir($dir)) { echo json_encode(['ok' => false, 'error' => 'no such chain']); exit; }

    $files = glob("$dir/steps/*.rec") ?: []; sort($files);
    $target = null; $prevOut = '';
    foreach ($files as $f) {
        [$h, $body] = hive_read_record($f);
        $st = $h['status'] ?? '';
        if ($st === 'done') { $o = @file_get_contents("$dir/steps/{$h['idx']}.out"); if ($o !== false) $prevOut = $o; continue; }
        if ($st === 'pending') { $target = [$f, $h, $body]; break; }
        if ($st === 'running') { $target = [$f, $h, $body]; break; }   // resume an in-flight one
    }
    if (!$target) {
        $raw = (string)@file_get_contents("$dir/chain.rec");
        @file_put_contents("$dir/chain.rec", preg_replace('/^status: .*$/m', 'status: done', $raw, 1));
        echo json_encode(['ok' => true, 'done' => true]); exit;
    }
    [$f, $h, $body] = $target; $idx = $h['idx']; $agent = $h['agent'] ?? 'ollama'; $model = $h['model'] ?? '';
    // Parallel group → let the client call chain_run_group (concurrent). Quorum/single continue here.
    if (($h['parallel'] ?? 'no') === 'yes' && empty($h['quorum'])) { echo json_encode(['ok' => true, 'parallel' => true]); exit; }
    if ($agent === 'auto' || $agent === '') {   // C4: capability routing
        $agent = hive_route($HIVE, $h['need'] ?? '', 'local');
        $rr = (string)@file_get_contents($f); @file_put_contents($f, preg_replace('/^agent: .*$/m', "agent: $agent", $rr, 1));
        @file_put_contents("$dir/steps/$idx.ckpt", time() . "|routed → $agent (cap: " . ($h['need'] ?? 'any') . ")\n", FILE_APPEND);
    }
    // build the prompt with previous output as context
    $prompt = function_exists('combos_fill') ? combos_fill($body, '', '', $prevOut) : $body;
    if ($prevOut !== '' && strpos($body, '%PREV%') === false) $prompt = "Context from the previous step:\n$prevOut\n\n" . $prompt;

    $setStatus = function ($file, $s) { $r = (string)@file_get_contents($file); @file_put_contents($file, preg_replace('/^status: .*$/m', "status: $s", $r, 1)); };
    $ckpt = function ($note) use ($dir, $idx) { @file_put_contents("$dir/steps/$idx.ckpt", time() . '|' . $note . "\n", FILE_APPEND); };

    // C5: quorum step — ask N models the same task, a judge picks/synthesizes the best.
    if (!empty($h['quorum']) && function_exists('ollama_generate')) {
        require_cap('cognition');   // quorum voting is AutoCognition (Pro) — blocks a crafted Cruise chain from buying it at Basic
        $voters = array_values(array_filter(array_map('trim', explode(',', $h['quorum']))));
        $judgeM = trim((string)($h['judge'] ?? '')) ?: ($voters[0] ?? $model);
        $setStatus($f, 'running'); $answers = [];
        foreach ($voters as $vi => $vm) {
            $ckpt('voter ' . ($vi + 1) . '/' . count($voters) . ': ' . $vm);
            $vr = ollama_generate($vm, $prompt, ['runner' => 'ollama', 'timeout' => 120]);
            $answers[] = !empty($vr['ok']) ? (string)$vr['text'] : '[voter error]';
        }
        $jp = "You are a judge. TASK:\n$prompt\n\nCandidate answers from different models:\n";
        foreach ($answers as $ai => $a) $jp .= '[' . ($ai + 1) . "] $a\n\n";
        $jp .= "Pick the single best answer, or synthesize a superior one from them. Output ONLY the final answer, no commentary.";
        $ckpt("judging with $judgeM (" . count($voters) . ' voters)');
        $jr = ollama_generate($judgeM, $jp, ['runner' => 'ollama', 'timeout' => 120]);
        $out = !empty($jr['ok']) ? (string)$jr['text'] : ($answers[0] ?? '');
        @file_put_contents("$dir/steps/$idx.out", $out); $setStatus($f, 'done'); $ckpt('quorum done (' . count($voters) . ' voters + judge)');
        $craw = (string)@file_get_contents("$dir/chain.rec");
        if (preg_match('/^cursor:\s*(\d+)/m', $craw, $mm)) $craw = preg_replace('/^cursor:.*$/m', 'cursor: ' . ((int)$mm[1] + 1), $craw, 1);
        @file_put_contents("$dir/chain.rec", $craw);
        $remaining = 0; foreach (glob("$dir/steps/*.rec") ?: [] as $sf) { [$sh] = hive_read_record($sf); if (($sh['status'] ?? '') === 'pending') $remaining++; }
        if ($remaining === 0) { $craw = (string)@file_get_contents("$dir/chain.rec"); @file_put_contents("$dir/chain.rec", preg_replace('/^status: .*$/m', 'status: done', $craw, 1)); }
        @file_put_contents("$HIVE/log.txt", date('H:i:s') . ' ts=' . time() . " chain_quorum id=$id step=$idx voters=" . count($voters) . "\n", FILE_APPEND);
        echo json_encode(['ok' => true, 'step' => $idx, 'quorum' => count($voters), 'preview' => mb_substr($out, 0, 240), 'remaining' => $remaining, 'done' => $remaining === 0]);
        exit;
    }

    if (in_array($agent, ['ollama', 'localai'], true) && function_exists('ollama_generate')) {
        $setStatus($f, 'running'); $ckpt("dispatched → $agent/$model");
        $r = ollama_generate($model, $prompt, ['runner' => $agent, 'timeout' => 180]);
        if (!empty($r['ok'])) {
            @file_put_contents("$dir/steps/$idx.out", (string)$r['text']);
            $setStatus($f, 'done'); $ckpt("done ({$r['ms']}ms)");
            $craw = (string)@file_get_contents("$dir/chain.rec");
            if (preg_match('/^cursor:\s*(\d+)/m', $craw, $mm)) $craw = preg_replace('/^cursor:.*$/m', 'cursor: ' . ((int)$mm[1] + 1), $craw, 1);
            @file_put_contents("$dir/chain.rec", $craw);
            $remaining = 0; foreach (glob("$dir/steps/*.rec") ?: [] as $sf) { [$sh] = hive_read_record($sf); if (($sh['status'] ?? '') === 'pending') $remaining++; }
            if ($remaining === 0) { $craw = (string)@file_get_contents("$dir/chain.rec"); @file_put_contents("$dir/chain.rec", preg_replace('/^status: .*$/m', 'status: done', $craw, 1)); }
            @file_put_contents("$HIVE/log.txt", date('H:i:s') . ' ts=' . time() . " chain_step_done id=$id step=$idx agent=$agent ms={$r['ms']}\n", FILE_APPEND);
            echo json_encode(['ok' => true, 'step' => $idx, 'agent' => $agent, 'ms' => $r['ms'], 'preview' => mb_substr((string)$r['text'], 0, 240), 'remaining' => $remaining, 'done' => $remaining === 0]);
        } else {
            $setStatus($f, 'failed'); $ckpt('failed: ' . ($r['error'] ?? '?'));
            $craw = (string)@file_get_contents("$dir/chain.rec"); @file_put_contents("$dir/chain.rec", preg_replace('/^status: .*$/m', 'status: failed', $craw, 1));
            @file_put_contents("$HIVE/log.txt", date('H:i:s') . ' ts=' . time() . " chain_step_failed id=$id step=$idx err=" . ($r['error'] ?? '?') . "\n", FILE_APPEND);
            echo json_encode(['ok' => false, 'step' => $idx, 'error' => $r['error'] ?? 'step failed']);
        }
        exit;
    }
    // Non-local agent (claude/aider/gemini/opencode/worker): pause for consent — the
    // step stays pending; the user runs that agent (via the broker/CLI) themselves.
    echo json_encode(['ok' => true, 'step' => $idx, 'blocked' => true, 'agent' => $agent,
        'reason' => "step needs agent '$agent' — run it via that agent (broker/CLI), then continue"]);
    exit;
}

if ($action === 'combo_to_chain' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    // C1: serialize a Power Combo into a durable HIVE chain (chain template).
    // Each combo step {model,runner,prompt} → a chain step (agent=runner, model kept,
    // prompt=action). judge/seed become their own steps. Pattern carried on the chain.
    $in = json_decode(file_get_contents('php://input'), true) ?: [];
    $combo = $in['combo'] ?? null;   // inline combo (testing) …
    if (!$combo && !empty($in['combo_id'])) {   // … or load by id
        require_once __DIR__ . '/combos_core.php';
        if (function_exists('combos_find')) $combo = combos_find(preg_replace('/[^a-z0-9_.-]/i', '', (string)$in['combo_id']), $in['backend'] ?? null);
    }
    if (!$combo || empty($combo['steps'])) { echo json_encode(['ok' => false, 'error' => 'combo not found or has no steps']); exit; }

    // Cruise's fast-path builds a single sequential text step (Basic). A combo that
    // is parallel or carries a judge/quorum step is AutoCognition (Pro) authoring —
    // gate it there so a crafted payload can't buy Pro at the Basic bar.
    require_cap('cruise');
    $_pat = $combo['pattern'] ?? 'parallel';   // matches the resolver below
    $_needsCog = ($_pat === 'parallel') || !empty($combo['judge']['model']);
    if (!$_needsCog) foreach ($combo['steps'] as $_s) { if (!empty($_s['quorum']) || !empty($_s['parallel'])) { $_needsCog = true; break; } }
    if ($_needsCog) require_cap('cognition');

    // auto-resume default from global config
    $arDef = 'on'; $cfgf = "$HIVE/config.txt";
    if (is_file($cfgf) && preg_match('/^auto_resume_default:\s*(\S+)/m', (string)@file_get_contents($cfgf), $m)) $arDef = $m[1];

    $cid = dechex((int)(microtime(true) * 1000)) . bin2hex(random_bytes(3));
    $dir = "$HIVE/board/$cid"; @mkdir("$dir/steps", 0777, true);
    $pattern = $combo['pattern'] ?? 'parallel';
    $gran = $pattern === 'sequential' ? 'normal' : 'normal';   // author can raise to fine later
    @file_put_contents("$dir/chain.rec",
        "id: $cid\ngoal: ⚡ " . str_replace(["\r", "\n"], ' ', (string)($combo['name'] ?? $combo['id'] ?? 'combo')) .
        "\ncreated_by: cockpit/web\nstatus: building\ncursor: 0\ngranularity: $gran\nauto_resume: $arDef" .
        "\npattern: $pattern\nfrom_combo: " . ($combo['id'] ?? '') . "\ncreated: " . time() . "\n");

    $i = 0;
    $writeStep = function ($agent, $model, $prompt, $parallel, $need = '', $quorum = '', $judge = '') use ($dir, &$i) {
        $idx = sprintf('%03d', $i++);
        @file_put_contents("$dir/steps/$idx.rec",
            "idx: $idx\nagent: " . preg_replace('/[^a-z0-9_.:-]/i', '', (string)$agent) .
            "\nstatus: pending\nmodel: " . str_replace(["\r", "\n"], ' ', (string)$model) .
            "\nparallel: " . ($parallel ? 'yes' : 'no') . "\nneed: " . preg_replace('/[^a-z0-9_.-]/i', '', (string)$need) .
            "\nquorum: " . str_replace(["\r", "\n"], ' ', (string)$quorum) . "\njudge: " . str_replace(["\r", "\n"], ' ', (string)$judge) .
            "\nts: " . time() . "\n\n" . (string)$prompt);
    };
    if (!empty($combo['seed']['model'])) $writeStep($combo['seed']['runner'] ?? 'ollama', $combo['seed']['model'], '[seed] ' . ($combo['seed']['prompt'] ?? ''), false);
    foreach ($combo['steps'] as $s) {
        $writeStep($s['runner'] ?? 'ollama', $s['model'] ?? '', $s['prompt'] ?? '', $pattern === 'parallel', $s['need'] ?? '', $s['quorum'] ?? '', $s['judge'] ?? '');
    }
    if (!empty($combo['judge']['model'])) $writeStep($combo['judge']['runner'] ?? 'ollama', $combo['judge']['model'], '[judge] aggregate the parallel outputs and pick/synthesize the best', false);

    @file_put_contents("$HIVE/log.txt", date('H:i:s') . ' ts=' . time() . " chain_from_combo id=$cid combo=" . ($combo['id'] ?? '?') . " steps=$i by=cockpit/web\n", FILE_APPEND);
    echo json_encode(['ok' => true, 'chain_id' => $cid, 'steps' => $i, 'pattern' => $pattern]);
    exit;
}

echo json_encode(['ok' => false, 'error' => 'unknown action']);
