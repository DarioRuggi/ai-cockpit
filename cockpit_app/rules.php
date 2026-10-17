<?php
// =============================================================================
// rules.php — Task delegation Rules (2026-07-02).
//
// A Rule says "tasks that look like X should be handled by supplier/model/
// combo Y" — checked automatically before EVERY prompt dispatch (single call
// site: sendPrompt() in index.html, covers Single/Pipeline/Broadcast/Plan/
// Combos uniformly), independent of whichever module/agent is currently
// selected. When a rule fires, its target runs first, the outcome is spliced
// into the prompt as context, and the ORIGINAL dispatch continues normally
// with that context included — the rule augments, it doesn't replace.
//
// Match strategy (user-specified, 2026-07-02): keyword/phrase first (fast,
// free, deterministic) → small local Ollama model as a fallback classifier
// for fuzzier phrasing → if still not decisive, the CLIENT asks the user to
// pick (this file just reports "ambiguous" + candidates; it never guesses).
//
// Storage: <cockpit_data>/rules.json (per-user, via $PATHS — same scoping as
// everything else since 2026-07-02's per-user data pass).
//
// ACTIONS:
//   GET  ?action=list                          — all rules
//   POST {action=save,  rule:{...}}             — create/update (id auto-assigned if new)
//   POST {action=delete, id}
//   POST {action=classify, prompt}              — → {matched, method, rule_id?, candidates?}
//   POST {action=delegate, rule_id, prompt}      — runs the rule's target, returns its outcome text
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) {
    header('Content-Type: application/json');
    $__demoAction = $_GET['action'] ?? $_POST['action'] ?? '';
    if ($__demoAction === 'list') {
        echo json_encode(['ok'=>true,'rules'=>[
            ['id'=>'rule_demo1','name'=>'Translation tasks -> Ollama','enabled'=>true,'keywords'=>['translate','translation'],'target'=>['kind'=>'ollama_model','id'=>'qwen2.5-coder:7b','model'=>''],'created_at'=>'2026-06-01T00:00:00Z'],
            ['id'=>'rule_demo2','name'=>'Doc conversion -> pandoc tool','enabled'=>true,'keywords'=>['convert to pdf','convert to docx'],'target'=>['kind'=>'tool','id'=>'pandoc','model'=>''],'created_at'=>'2026-05-28T00:00:00Z'],
        ]]); exit;
    }
    ed_demo_stub();
}
require_once __DIR__ . '/combos_core.php';   // combos_run() — pure function, no HTTP dispatch

header('Content-Type: application/json');
header('Cache-Control: no-store');

$RULES_F = $PATHS['cockpit_data'] . '/rules.json';
// Small model for fallback classification — same "keep it tiny" convention as
// ollama_guard.php's ≤4B auto-pick. Not pinned: the preferred name is only a
// preference. Pinning 'qwen2.5:1.5b' put the ambiguous-match modal on EVERY prompt
// the day that model was removed from Ollama (2026-09-12) — the classifier
// failed, the failure read as "unsure", and the client asked the user.
require_once __DIR__ . '/ollama_guard.php';
const RULES_CLASSIFIER_PREFER = ['qwen2.5:1.5b', 'llama3.2:3b', 'llama3.2:1b', 'qwen2.5:3b', 'phi4-mini:3.8b', 'gemma3:1b'];

// First preferred model that is actually installed; else the largest installed
// general model still ≤4B (coder/embedding models skipped — they answer the
// JSON-only instruction badly); else '' (skip the model pass entirely).
function rules_classifier_model(): string {
    $avail = ollama_available_models();
    if (!$avail) return '';
    foreach (RULES_CLASSIFIER_PREFER as $p) if (in_array($p, $avail, true)) return $p;
    $general = array_values(array_filter($avail, fn($m) => !preg_match('/coder|embed|vision|-r1/i', $m)));
    return ollama_auto_model('', $general, 'qwen2.5');
}

function rules_load(string $f): array {
    if (!is_readable($f)) return ['version' => 1, 'rules' => []];
    $d = json_decode((string)file_get_contents($f), true);
    return is_array($d) && isset($d['rules']) ? $d : ['version' => 1, 'rules' => []];
}
function rules_save(string $f, array $data): void {
    @mkdir(dirname($f), 0775, true);
    file_put_contents($f, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE), LOCK_EX);
    @chmod($f, 0664);
}

$action = $_GET['action'] ?? '';
$in     = json_decode((string)file_get_contents('php://input'), true) ?: [];

// ── list ──────────────────────────────────────────────────────────────────
if ($action === 'list') {
    $data = rules_load($RULES_F);
    echo json_encode(['ok' => true, 'rules' => $data['rules']], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── save (create or update) ──────────────────────────────────────────────
if ($action === 'save') {
    $rule = is_array($in['rule'] ?? null) ? $in['rule'] : [];
    $name = trim((string)($rule['name'] ?? ''));
    $kind = (string)($rule['target']['kind'] ?? '');
    $tid  = trim((string)($rule['target']['id'] ?? ''));
    $keywords = array_values(array_filter(array_map('trim', (array)($rule['keywords'] ?? []))));
    if ($name === '')                                        { echo json_encode(['ok'=>false,'error'=>'name required']); exit; }
    if (!in_array($kind, ['worker','combo','ollama_model','tool'], true)) { echo json_encode(['ok'=>false,'error'=>'bad target kind']); exit; }
    if ($tid === '')                                          { echo json_encode(['ok'=>false,'error'=>'target id required']); exit; }
    if (!$keywords)                                           { echo json_encode(['ok'=>false,'error'=>'at least one keyword/phrase required']); exit; }

    $data = rules_load($RULES_F);
    $id = trim((string)($rule['id'] ?? ''));
    $entry = [
        'id'       => $id !== '' ? $id : ('rule_' . bin2hex(random_bytes(4))),
        'name'     => $name,
        'enabled'  => !isset($rule['enabled']) || !empty($rule['enabled']),
        'keywords' => $keywords,
        'target'   => ['kind' => $kind, 'id' => $tid, 'model' => trim((string)($rule['target']['model'] ?? ''))],
        'created_at' => $rule['created_at'] ?? date('c'),
    ];
    $found = false;
    foreach ($data['rules'] as &$r) { if ($r['id'] === $entry['id']) { $r = $entry; $found = true; break; } }
    unset($r);
    if (!$found) $data['rules'][] = $entry;
    rules_save($RULES_F, $data);
    echo json_encode(['ok' => true, 'rule' => $entry], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── delete ────────────────────────────────────────────────────────────────
if ($action === 'delete') {
    $id = (string)($in['id'] ?? '');
    $data = rules_load($RULES_F);
    $before = count($data['rules']);
    $data['rules'] = array_values(array_filter($data['rules'], fn($r) => $r['id'] !== $id));
    rules_save($RULES_F, $data);
    echo json_encode(['ok' => true, 'removed' => $before - count($data['rules'])], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── classify — keyword pass, then small-model fallback ──────────────────
if ($action === 'classify') {
    $prompt = (string)($in['prompt'] ?? '');
    if ($prompt === '') { echo json_encode(['ok'=>false,'error'=>'prompt required']); exit; }
    $data = rules_load($RULES_F);
    $active = array_values(array_filter($data['rules'], fn($r) => !empty($r['enabled'])));
    if (!$active) { echo json_encode(['ok'=>true,'matched'=>false,'method'=>'none']); exit; }

    // Pass 1: keyword/phrase substring match (case-insensitive).
    $hay = mb_strtolower($prompt);
    $hits = [];
    foreach ($active as $r) {
        foreach ($r['keywords'] as $kw) {
            if ($kw !== '' && mb_strpos($hay, mb_strtolower($kw)) !== false) { $hits[] = $r; break; }
        }
    }
    if (count($hits) === 1) {
        echo json_encode(['ok'=>true,'matched'=>true,'method'=>'keyword','rule_id'=>$hits[0]['id'],'rule_name'=>$hits[0]['name']], JSON_UNESCAPED_UNICODE);
        exit;
    }
    // 0 or 2+ keyword hits → not decisive by keyword alone. Narrow the model's
    // candidate set to the keyword hits if there were any (more likely
    // correct than the full rule list); otherwise offer every active rule.
    $candidates = $hits ?: $active;

    // Pass 2: small local model picks among the candidates (or says "none").
    $list = '';
    foreach ($candidates as $i => $r) {
        $list .= ($i+1) . ". id=\"{$r['id']}\" name=\"{$r['name']}\" keywords=\"" . implode(', ', $r['keywords']) . "\"\n";
    }
    // Wording matters with ≤4B models. The first version listed the categories
    // and asked "which one?" — with a single rule defined, llama3.2:3b and
    // phi4-mini answered THAT rule at 0.8–0.9 for "best way to make a cake".
    // Saying up front that most tasks match nothing, and spelling out the null
    // answer, took the same models to 5/5 on a neutral/positive test set.
    $sys = "You decide whether a user's task belongs to one of the listed special categories. "
         . "Most tasks belong to NONE of them; pick a category only when the task clearly asks for that specific thing. "
         . "Reply with ONLY a JSON object: {\"rule_id\": \"<id>\"|null, \"confidence\": 0.0-1.0}. "
         . "No other text.";
    $userMsg = "Categories:\n{$list}\nTask: \"{$prompt}\"\n\n"
              . "If none of the categories clearly applies, answer {\"rule_id\": null, \"confidence\": <how sure you are it is none>}.";
    $clsModel = rules_classifier_model();
    $r = $clsModel !== ''
        ? ollama_generate($clsModel, $userMsg, ['system' => $sys, 'timeout' => 20,
                          'runner' => 'ollama',                  // the model was picked from Ollama's list — never route it to LocalAI
                          'options' => ['temperature' => 0]])   // deterministic classification
        : ['ok' => false, 'text' => '', 'error' => 'no small local model installed'];
    // A classifier that could not RUN (model missing, Ollama down, timeout) is
    // not the same as a classifier that ran and was unsure. Only the latter
    // earns a question to the user; the former means "no rule fired" — the
    // keyword pass already said so, and nagging on every prompt because a
    // background model is absent is worse than an occasional missed delegation.
    if (empty($r['ok'])) {
        error_log('rules.php classify: model pass skipped (' . ($clsModel ?: 'none') . ': ' . ($r['error'] ?? '?') . ')');
        echo json_encode(['ok'=>true,'matched'=>false,'method'=>'none','note'=>'classifier unavailable'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $parsed = null;
    $txt = trim((string)$r['text']);
    if (preg_match('/\{.*\}/s', $txt, $m)) {
        $parsed = json_decode($m[0], true);
    } elseif (preg_match('/^(?:```(?:json)?\s*)?null\s*(?:```)?$/i', $txt)) {
        // phi4-mini answers a bare `null` (often fenced) for "none" — that is
        // an explicit negative, not an unparseable reply.
        $parsed = ['rule_id' => null, 'confidence' => 1.0];
    }
    $confidence = is_array($parsed) ? (float)($parsed['confidence'] ?? 0) : 0;
    $pickedId   = is_array($parsed) ? ($parsed['rule_id'] ?? null) : null;
    $picked = null;
    foreach ($candidates as $r2) if ($r2['id'] === $pickedId) { $picked = $r2; break; }

    // "Decisive" bar: model must be confident AND actually name a known id.
    if ($picked && $confidence >= 0.7) {
        echo json_encode(['ok'=>true,'matched'=>true,'method'=>'model','rule_id'=>$picked['id'],'rule_name'=>$picked['name'],'confidence'=>$confidence], JSON_UNESCAPED_UNICODE);
        exit;
    }
    // A well-formed, confidently NEGATIVE response (parsed cleanly, explicit
    // null id, decent confidence in that null) means the model actively
    // decided "none of these" — that's decisive too, just not a match. Don't
    // make the user confirm "no" on every single unrelated prompt; only ask
    // when the response was genuinely unparseable/uncertain (empty output,
    // bad JSON, or low confidence either way).
    if (is_array($parsed) && $pickedId === null && $confidence >= 0.5) {
        echo json_encode(['ok'=>true,'matched'=>false,'method'=>'none'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    // Genuinely uncertain. Asking the person is only fair when the prompt actually
    // looked like one of their rules: with NO keyword hit at all, an uncertain small
    // model is noise, and the "Which rule applies?" modal pops on prompts that have
    // nothing to do with any rule (seen in the 2026-09-22 audit: an attached file).
    // Floor: at least one keyword hit, at most 4 candidates — otherwise: no match.
    if (!$hits || count($candidates) > 4) {
        echo json_encode(['ok'=>true,'matched'=>false,'method'=>'none','note'=>'uncertain, no keyword hit'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    echo json_encode([
        'ok' => true, 'matched' => false, 'method' => 'ambiguous',
        'candidates' => array_map(fn($r) => ['id'=>$r['id'],'name'=>$r['name']], $candidates),
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── delegate — actually run the rule's target, return outcome text ──────
if ($action === 'delegate') {
    $ruleId = (string)($in['rule_id'] ?? '');
    $prompt = (string)($in['prompt'] ?? '');
    if ($ruleId === '' || $prompt === '') { echo json_encode(['ok'=>false,'error'=>'rule_id and prompt required']); exit; }
    $data = rules_load($RULES_F);
    $rule = null;
    foreach ($data['rules'] as $r) if ($r['id'] === $ruleId) { $rule = $r; break; }
    if (!$rule) { echo json_encode(['ok'=>false,'error'=>'rule not found']); exit; }
    $target = $rule['target'];
    $kind   = $target['kind'];
    $tid    = $target['id'];
    $model  = $target['model'] ?? '';

    if ($kind === 'ollama_model') {
        $r = ollama_generate($tid ?: $model, $prompt, ['timeout' => 120]);
        if (empty($r['ok'])) { echo json_encode(['ok'=>false,'error'=>$r['error'] ?? 'ollama call failed']); exit; }
        echo json_encode(['ok'=>true,'outcome'=>(string)($r['text'] ?? ''),'source'=>$tid], JSON_UNESCAPED_UNICODE);
        exit;
    }

    if ($kind === 'combo') {
        $r = combos_run($tid, $prompt, '');
        $outcome = $r['ok'] ?? false ? combos_flatten($r) : '';
        if (!$outcome) { echo json_encode(['ok'=>false,'error'=>'combo run failed']); exit; }
        echo json_encode(['ok'=>true,'outcome'=>$outcome,'source'=>$tid], JSON_UNESCAPED_UNICODE);
        exit;
    }

    if ($kind === 'worker') {
        // workers.php is an HTTP-dispatch file (echoes+exits its own action),
        // not includable as a function library under a web SAPI request — loop
        // back over HTTP instead, forwarding this request's session cookie so
        // its auth.php check passes.
        $payload = json_encode(['provider' => $tid, 'model' => $model, 'task' => 'text', 'prompt' => $prompt]);
        // Release the session lock first. workers.php runs auth.php and opens the
        // SAME session file, which PHP holds exclusively for the life of a
        // request — so this call would wait for itself until the timeout and
        // report a failure that never happened. (Found 2026-09-23 when Dossier
        // hit the identical trap and returned an empty result with no error.)
        // Nothing below writes to $_SESSION, so closing it here is safe.
        if (session_status() === PHP_SESSION_ACTIVE) session_write_close();
        $ch = curl_init('http://127.0.0.1' . dirname($_SERVER['SCRIPT_NAME']) . '/workers.php?action=invoke');
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => $payload,
            CURLOPT_HTTPHEADER => ['Content-Type: application/json', 'Cookie: ' . ($_SERVER['HTTP_COOKIE'] ?? '')],
            CURLOPT_TIMEOUT => 60,
        ]);
        $resp = curl_exec($ch);
        curl_close($ch);
        $d = json_decode((string)$resp, true);
        if (!is_array($d) || empty($d['ok'])) { echo json_encode(['ok'=>false,'error'=>$d['error'] ?? 'worker call failed']); exit; }
        echo json_encode(['ok'=>true,'outcome'=>(string)($d['output'] ?? ''),'source'=>$tid], JSON_UNESCAPED_UNICODE);
        exit;
    }

    if ($kind === 'tool') {
        // Tools are file-in/file-out (ffmpeg/whisper/pandoc), not text-in/
        // text-out — doesn't fit the "splice a text outcome into the prompt"
        // model this delegate flow is built for. Reported so the client can
        // explain instead of silently failing.
        echo json_encode(['ok'=>false,'error'=>'tool-kind rules need a file input — not supported for automatic prompt delegation yet']); exit;
    }

    echo json_encode(['ok'=>false,'error'=>'unknown target kind']); exit;
}

echo json_encode(['ok'=>false,'error'=>'unknown action: '.$action]);
