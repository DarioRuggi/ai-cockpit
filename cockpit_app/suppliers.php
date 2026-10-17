<?php
// =============================================================================
// suppliers.php — Configurable supplier slot management
//
// Manages which CLI AI tools occupy the primary (card 1) and fallback (card 2)
// slots, and which local LLM server occupies the ollama slot.
//
// Actions:
//   ?action=config       — GET current slot config + available suppliers
//   ?action=set_slots    — POST {primary, fallback} — assign CLI tools to slots
//   ?action=set_local    — POST {provider, base_url, name} — configure local LLM server
// =============================================================================

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

$CD = $PATHS['cockpit_data'];
$SLOTS_F   = $CD . '/supplier_slots.json';
$CLI_CAT_F = $CD . '/cli_suppliers.json';

// ── CLI supplier catalog (shipped defaults) ─────────────────────────────────
require __DIR__ .'/cli_catalog_default.php';   // $CLI_CATALOG_DEFAULT (shared with launch_cli.php)

// Local LLM server options
$LOCAL_SERVERS = [
    'ollama' => [
        'name'     => 'Ollama',
        'base_url' => 'http://127.0.0.1:11434',
        'api_style' => 'ollama',
    ],
    'localai' => [
        'name'     => 'LocalAI',
        'base_url' => 'http://127.0.0.1:8080',
        'api_style' => 'openai',
    ],
    // LM Studio and llama.cpp Server were listed here but never actually
    // wired up (Power Combos and the classic Card 3 picker only ever
    // supported ollama/localai) — removed 2026-07-31 to keep Card 3 to the
    // three backends that actually work: Ollama, LocalAI, Dual. Either
    // server is still usable in the app — add it as a Worker instead (Card 3
    // Workers accept any OpenAI-compatible endpoint via action=add_custom),
    // just not as a Supplier Slot / Power Combos backend.
    // Not a real server of its own — a mode flag meaning "run Ollama and
    // LocalAI together" (both have fixed addresses already, see
    // combos_lib.php's combos_ollama_base()/combos_localai_base()). base_url
    // stays empty; nothing reads it for this entry.
    'dual' => [
        'name'     => 'Dual — Ollama + LocalAI',
        'base_url' => '',
        'api_style' => 'dual',
    ],
];

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
// action=models / vram_budget are harmless read-only lookups (catalog + models.dev
// cache; VRAM estimate) — let them through in demo too, so the demo's model dropdowns
// show real model names and the VRAM guard behaves normally.
if (ed_is('demo') && ed_is_direct(__FILE__) && !in_array($_GET['action'] ?? '', ['models','vram_budget'], true)) {
    header('Content-Type: application/json');
    $__demoAction = $_GET['action'] ?? $_POST['action'] ?? '';
    if ($__demoAction === 'config') {
        $demoSuppliers = [];
        foreach ($CLI_CATALOG_DEFAULT as $id => $c) { $demoSuppliers[$id] = array_merge($c, ['id'=>$id,'installed'=>true]); }
        echo json_encode(['ok'=>true,'slots'=>['primary'=>'claude','fallback'=>'codex','local'=>['provider'=>'dual','base_url'=>'','name'=>'Dual - Ollama + LocalAI']],'cli_suppliers'=>$demoSuppliers,'local_servers'=>$LOCAL_SERVERS]); exit;
    }
    if ($__demoAction === 'set_slots' || $__demoAction === 'set_local') {
        $in = json_decode(file_get_contents('php://input'), true) ?: [];
        echo json_encode(['ok'=>true] + $in); exit;
    }
    ed_demo_stub();
}

function load_json_file(string $f, $default = []) {
    if (!is_readable($f)) return $default;
    $d = json_decode(file_get_contents($f), true);
    return is_array($d) ? $d : $default;
}

function save_json_file_sup(string $f, $data): void {
    $dir = dirname($f);
    if (!is_dir($dir)) @mkdir($dir, 0775, true);
    file_put_contents($f, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE), LOCK_EX);
    @chmod($f, 0664);
}

function sup_json(array $d): void {
    header('Content-Type: application/json');
    echo json_encode($d, JSON_UNESCAPED_UNICODE);
    exit;
}

// ── Load config ─────────────────────────────────────────────────────────────

function load_slots(string $f): array {
    $defaults = [
        'primary'  => 'claude',
        'fallback' => 'codex',   // Card 2 default = Codex (second paid agent, runs alongside Claude)
        'local'    => [
            'provider' => 'dual',
            'base_url' => '',
            'name'     => 'Dual — Ollama + LocalAI',
        ],
    ];
    $saved = load_json_file($f, []);
    return array_merge($defaults, $saved);
}

function load_cli_catalog(string $f, array $defaults): array {
    $saved = load_json_file($f, []);
    return empty($saved) ? $defaults : array_merge($defaults, $saved);
}
// Materialise the merged catalog for agent_loop.sh (bash + jq, cannot read the PHP
// defaults). cli_suppliers.json stays the optional hand override; cli_catalog.json is
// regenerated whenever the defaults file or the override is newer. Without it the loop
// ran a free_cli alias with Claude's flags (opencode -p …) — rig, 2026-09-21.
function sup_materialize_catalog(string $cd, string $overrideF, array $catalog): void {
    $matF = $cd . '/cli_catalog.json';
    $srcT = max(@filemtime(__DIR__ . '/cli_catalog_default.php') ?: 0, @filemtime($overrideF) ?: 0);
    if (is_file($matF) && (@filemtime($matF) ?: 0) >= $srcT) return;
    @file_put_contents($matF, json_encode($catalog, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), LOCK_EX);
    @chmod($matF, 0664);
}

// ── Action dispatch ─────────────────────────────────────────────────────────

$action = $_GET['action'] ?? '';
$in = json_decode(file_get_contents('php://input'), true) ?: [];

// Relay-based suppliers (e.g. groq_build) have no local binary to detect —
// they dispatch through worker_relay.php + the Workers engine's encrypted
// key store instead. The only real "is this usable" signal for those is
// whether a key is actually saved, not a binary check. Duplicated (not
// require_once'd) from workers.php's own decrypt_blob()/load_keys() —
// requiring workers.php directly from a real web request would trigger ITS
// own auth/dispatch block (only skipped under PHP_SAPI==='cli'), hijacking
// this response.
function sup_worker_keys(): array {
    global $CD;
    $f = $CD . '/workers_keys.enc';
    if (!is_file($f)) return [];
    $b64 = trim((string)file_get_contents($f));
    if ($b64 === '') return [];
    $raw = base64_decode($b64, true);
    if ($raw === false || strlen($raw) < 28) return [];
    $machineIdPath = '/etc/machine-id';
    $machineId = is_readable($machineIdPath) ? trim((string)file_get_contents($machineIdPath)) : 'cockpit-default-machine';
    $key = hash('sha256', $machineId . 'AICockpit-WorkerKeys-v1-DarioRuggi', true);
    $pt = openssl_decrypt(substr($raw, 28), 'aes-256-gcm', $key, OPENSSL_RAW_DATA, substr($raw, 0, 12), substr($raw, 12, 16));
    if ($pt === false) return [];
    $j = json_decode($pt, true);
    return is_array($j) ? $j : [];
}

// action=models&id=<supplier> — live model list for a CLI card. Curated aliases
// (CLI-accepted, stable; e.g. claude's opus/sonnet/haiku auto-resolve to latest)
// come first, then the current models.dev list for that vendor is appended (deduped,
// ctx-labeled). models.dev is refreshed by models_dev.php (cron + ?action=refresh);
// if its cache is missing we still return the curated list, so this never empties.
if ($action === 'models') {
    $id = $_GET['id'] ?? '';
    $catalog = load_cli_catalog($CLI_CAT_F, $CLI_CATALOG_DEFAULT);
    $entry = $catalog[$id] ?? null;
    if (!is_array($entry)) { echo json_encode(['ok'=>false,'error'=>'unknown supplier']); exit; }

    $out = []; $seen = [];
    foreach (($entry['models'] ?? []) as $m) {           // curated first
        if (empty($m['id'])) continue;
        $out[] = ['id'=>$m['id'], 'label'=>$m['label'] ?? $m['id'], 'source'=>'curated'];
        $seen[$m['id']] = true;
    }
    $pid = $entry['models_provider'] ?? '';
    $mdUpdated = null;
    if ($pid !== '') {
        // Read the SHARED models.dev cache (machine-wide; written by models_dev.php).
        $mdFile = ($PATHS['cockpit_data_root'] ?? $CD) . '/models_dev.json';
        $md   = @json_decode((string)@file_get_contents($mdFile), true);
        $prov = $md['providers'][$pid] ?? null;
        $mdUpdated = $md['updated'] ?? null;
        if (is_array($prov)) {
            uasort($prov, fn($a, $b) => ($b['ctx'] ?? 0) <=> ($a['ctx'] ?? 0));  // biggest ctx first
            foreach ($prov as $mid => $meta) {
                if (isset($seen[$mid])) continue;
                // Keep only text-generation models — drop embeddings/TTS/image/video/clip.
                // (out_modal null = older cache without the field → keep, don't over-filter.)
                $om = $meta['out_modal'] ?? null;
                if (is_array($om) && !in_array('text', $om, true)) continue;
                // Belt-and-braces for models.dev entries with wrong/missing modality
                // (e.g. Lyria music, Veo/Imagen media, embeddings, whisper/TTS).
                if (preg_match('/embedding|whisper|tts|lyria|veo|imagen|\bclip\b|audio|music|moderation|guard|rerank/i', $mid . ' ' . ($meta['name'] ?? ''))) continue;
                $label = $meta['name'] ?? $mid;
                if (!empty($meta['ctx'])) $label .= ' · ' . number_format($meta['ctx'] / 1000) . 'K ctx';
                $out[] = ['id'=>$mid, 'label'=>$label, 'source'=>'modelsdev', 'ctx'=>$meta['ctx'] ?? null];
            }
        }
    }
    // Local-backed agents (e.g. Aider → Ollama) list the installed LOCAL models via
    // Ollama's /api/tags — the same source Card 3 uses. Empty if Ollama isn't up
    // (client keeps whatever it has). The dispatch prepends model_prefix (ollama_chat/).
    if (($entry['models_source'] ?? '') === 'ollama' || ($entry['backend'] ?? '') === 'ollama') {
        $base = 'http://127.0.0.1:11434';
        $tags = @json_decode((string)@file_get_contents($base . '/api/tags'), true);
        foreach (($tags['models'] ?? []) as $t) {
            $name = $t['name'] ?? '';
            if ($name === '' || isset($seen[$name])) continue;
            $out[] = ['id' => $name, 'label' => $name, 'source' => 'ollama'];
            $seen[$name] = true;
        }
    }
    echo json_encode(['ok'=>true, 'id'=>$id, 'models'=>$out, 'count'=>count($out),
        'models_dev_updated'=>$mdUpdated], JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);
    exit;
}

// action=vram_budget — do the selected LOCAL models co-fit in GPU VRAM? Feeds the
// Broadcast guard: local subset runs sequentially when it won't fit, cloud stays
// parallel. Input: POST {locals:[{runner,model}]} OR ?models=ollama:qwen…:7b,ollama:llama3.2:3b
if ($action === 'vram_budget') {
    require_once __DIR__ . '/vram_lib.php';
    $locals = [];
    if (!empty($in['locals']) && is_array($in['locals'])) {
        $locals = $in['locals'];
    } elseif (!empty($_GET['models'])) {
        foreach (explode(',', $_GET['models']) as $spec) {
            $spec = trim($spec);
            if ($spec === '') continue;
            $runner = 'ollama'; $model = $spec;
            if (preg_match('/^(ollama|localai):(.+)$/', $spec, $mm)) { $runner = $mm[1]; $model = $mm[2]; }
            $locals[] = ['runner' => $runner, 'model' => $model];
        }
    }
    echo json_encode(vram_budget($locals), JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'config') {
    $slots = load_slots($SLOTS_F);
    $catalog = load_cli_catalog($CLI_CAT_F, $CLI_CATALOG_DEFAULT);
    sup_materialize_catalog($CD, $CLI_CAT_F, $catalog);
    $workerKeys = sup_worker_keys();

    // Detect which CLIs are installed. www-data's PATH lacks the user's
    // npm-global/local bins, so prepend them or claude/gemini look "not installed".
    $home = $PATHS['home'] ?? cockpit_home();
    $detEnv = 'PATH="' . $home . '/.npm-global/bin:' . $home . '/.opencode/bin:' . $home . '/.local/bin:/usr/local/bin:/usr/bin:/bin" ';
    $available = [];
    foreach ($catalog as $id => $c) {
        if (!is_array($c) || $id === '' || $id[0] === '_') continue;  // skip notes/meta keys
        $installed = false;
        if (!empty($c['relay'])) {
            // Relay-based (Workers-dispatched) — "installed" means "has a key
            // saved", not "binary present". No detect_cmd for these at all.
            $installed = !empty($workerKeys[$c['relay']]);
        } elseif (!empty($c['detect_cmd'])) {
            $out = []; $ret = 1;
            exec($detEnv . $c['detect_cmd'], $out, $ret);
            $installed = ($ret === 0);
            // A version probe can fail for reasons that are not "absent": opencode
            // (Bun) tries to mkdir $HOME/.local and www-data's home is read-only →
            // exit 1 → "(not installed)" on a machine where it runs fine (rig, 2026-09-21).
            // A present binary on the detect PATH counts as installed regardless.
            if (!$installed && !empty($c['binary'])) {
                foreach ([$home . '/.npm-global/bin', $home . '/.opencode/bin', $home . '/.local/bin', '/usr/local/bin', '/usr/bin', '/bin'] as $d) {
                    if (is_executable($d . '/' . basename((string)$c['binary']))) { $installed = true; break; }
                }
            }
        }
        $available[$id] = array_merge($c, ['id' => $id, 'installed' => $installed]);
    }

    sup_json([
        'ok'             => true,
        'slots'          => $slots,
        'cli_suppliers'  => $available,
        'local_servers'  => $LOCAL_SERVERS,
    ]);
}

if ($action === 'set_slots') {
    auth_require_admin();
    $primary  = trim((string)($in['primary'] ?? ''));
    $fallback = trim((string)($in['fallback'] ?? ''));
    $catalog  = load_cli_catalog($CLI_CAT_F, $CLI_CATALOG_DEFAULT);

    if (!isset($catalog[$primary]))  sup_json(['ok' => false, 'error' => 'Unknown primary supplier: ' . $primary]);
    if (!isset($catalog[$fallback])) sup_json(['ok' => false, 'error' => 'Unknown fallback supplier: ' . $fallback]);
    if ($primary === $fallback)      sup_json(['ok' => false, 'error' => 'Primary and fallback must be different suppliers']);

    $slots = load_slots($SLOTS_F);
    $slots['primary']  = $primary;
    $slots['fallback'] = $fallback;
    save_json_file_sup($SLOTS_F, $slots);
    sup_json(['ok' => true, 'primary' => $primary, 'fallback' => $fallback]);
}

if ($action === 'set_local') {
    auth_require_admin();
    $provider = trim((string)($in['provider'] ?? ''));
    $baseUrl  = trim((string)($in['base_url'] ?? ''));
    $name     = trim((string)($in['name'] ?? ''));

    if (!$provider) sup_json(['ok' => false, 'error' => 'Missing provider']);
    if (!$baseUrl)  $baseUrl = $LOCAL_SERVERS[$provider]['base_url'] ?? 'http://127.0.0.1:11434';
    if (!$name)     $name = $LOCAL_SERVERS[$provider]['name'] ?? $provider;

    $slots = load_slots($SLOTS_F);
    $slots['local'] = [
        'provider' => $provider,
        'base_url' => $baseUrl,
        'name'     => $name,
    ];
    save_json_file_sup($SLOTS_F, $slots);
    sup_json(['ok' => true, 'local' => $slots['local']]);
}

// =============================================================================
// Catalog editing — add or change an agent without a rebuild (2026-09-23)
//
// The defaults live in PHP, but cli_suppliers.json is merged OVER them and the
// materialised cli_catalog.json is regenerated whenever it changes. So a new CLI
// only ever needed a JSON edit — there was simply no way to make that edit from
// inside the app, which meant "a new agent came out" was a code change.
//
// Entries are validated tightly: everything here ends up on a command line.
// =============================================================================
function sup_clean_entry(array $e): array {
    $word = fn($v, $pat) => (is_string($v) && $v !== '' && preg_match($pat, $v)) ? $v : null;
    $out = [];
    // A binary is a NAME, not a path or a command: no slashes, no spaces, no
    // shell metacharacters. It is resolved through PATH at dispatch.
    if ($b = $word($e['binary'] ?? '', '/^[A-Za-z0-9._-]{1,64}$/'))      $out['binary'] = $b;
    if ($n = $word($e['name'] ?? '', '/^[\p{L}\p{N} ._()+-]{1,48}$/u')) $out['name'] = $n;
    if ($v = $word($e['vendor'] ?? '', '/^[\p{L}\p{N} ._()+-]{1,48}$/u')) $out['vendor'] = $v;
    $kind = (string)($e['kind'] ?? 'paid_cli');
    $out['kind'] = in_array($kind, ['paid_cli', 'free_cli', 'free_rest'], true) ? $kind : 'paid_cli';
    foreach (['cli_flag' => '/^[-A-Za-z0-9_]{1,24}$/', 'model_flag' => '/^[-A-Za-z0-9_]{1,24}$/',
              'effort_flag' => '/^[-A-Za-z0-9_]{1,24}$/', 'image_flag' => '/^[-A-Za-z0-9_]{1,24}$/',
              'subcmd' => '/^[A-Za-z0-9_-]{1,24}$/'] as $k => $pat) {
        if ($f = $word($e[$k] ?? '', $pat)) $out[$k] = $f;
    }
    // extra_args is a flag list, never a place for ; | & $ ` or redirections.
    if (!empty($e['extra_args']) && is_string($e['extra_args'])
        && preg_match('/^[-A-Za-z0-9_= .]{1,120}$/', $e['extra_args'])) $out['extra_args'] = $e['extra_args'];
    $mode = (string)($e['image_mode'] ?? '');
    if (in_array($mode, ['path', 'flag', 'at', 'describe'], true)) $out['image_mode'] = $mode;
    if (!empty($e['image_needs_sep'])) $out['image_needs_sep'] = true;
    if (!empty($e['free']))            $out['free'] = true;
    if (!empty($e['notes']) && is_string($e['notes'])) $out['notes'] = mb_substr($e['notes'], 0, 200);
    if (!empty($out['binary'])) $out['detect_cmd'] = $out['binary'] . ' --version 2>/dev/null';
    return $out;
}

if ($action === 'catalog_set') {
    auth_require_admin();
    $id = strtolower(preg_replace('/[^a-z0-9_]/i', '', (string)($in['id'] ?? '')));
    if ($id === '' || $id[0] === '_') sup_json(['ok' => false, 'error' => 'Bad agent id']);
    $entry = sup_clean_entry((array)($in['entry'] ?? []));
    if (empty($entry['binary'])) sup_json(['ok' => false, 'error' => 'A binary name is required (letters, digits, . _ - only)']);
    if (empty($entry['name']))   $entry['name'] = ucfirst($id);
    $saved = load_json_file($CLI_CAT_F, []);
    // Merge over the shipped default when overriding one, so a partial edit does
    // not silently drop fields the dispatch relies on.
    $base = $CLI_CATALOG_DEFAULT[$id] ?? [];
    $saved[$id] = array_merge($base, $saved[$id] ?? [], $entry);
    save_json_file_sup($CLI_CAT_F, $saved);
    @unlink($CD . '/cli_catalog.json');          // force the materialiser to rewrite
    sup_json(['ok' => true, 'id' => $id, 'entry' => $saved[$id]]);
}

if ($action === 'catalog_delete') {
    auth_require_admin();
    $id = strtolower(preg_replace('/[^a-z0-9_]/i', '', (string)($in['id'] ?? '')));
    $saved = load_json_file($CLI_CAT_F, []);
    if (!array_key_exists($id, $saved)) sup_json(['ok' => false, 'error' => 'Nothing to remove: that agent comes from the shipped defaults']);
    unset($saved[$id]);
    save_json_file_sup($CLI_CAT_F, $saved);
    @unlink($CD . '/cli_catalog.json');
    // A custom agent that was sitting on a card would leave that card pointing at an id that no
    // longer exists (the dispatcher then fails with "CLI failed or not installed"). Put such a
    // slot back on its shipped default, never the same agent on both cards.
    $reset = [];
    if (!isset($CLI_CATALOG_DEFAULT[$id])) {
        $slots = load_slots($SLOTS_F);
        foreach (['primary' => 'claude', 'fallback' => 'codex'] as $k => $def) {
            if (($slots[$k] ?? '') !== $id) continue;
            $other = $k === 'primary' ? 'fallback' : 'primary';
            $slots[$k] = (($slots[$other] ?? '') === $def) ? ($k === 'primary' ? 'codex' : 'claude') : $def;
            $reset[] = $k;
        }
        if ($reset) save_json_file_sup($SLOTS_F, $slots);
    }
    // A shipped default reappears here; a custom agent is gone.
    sup_json(['ok' => true, 'id' => $id, 'restored_default' => isset($CLI_CATALOG_DEFAULT[$id]), 'slots_reset' => $reset]);
}

// ── "Can it see?" probe ──────────────────────────────────────────────────────
// Runs the agent against a shipped 2 KB image of a red triangle and a blue
// circle and asks what is in it. Needed because the failure mode is not an
// error: opencode, shown a photo, answered "a screenshot of image with text and
// images within that text". So the answer is scored AND shown — the catalog is
// only changed when the person confirms what they read.
//
// Every argument is built here from validated catalog fields and fixed strings.
// Nothing the browser sends reaches the command line as text.
if ($action === 'vision_probe') {
    auth_require_admin();
    $id    = strtolower(preg_replace('/[^a-z0-9_]/i', '', (string)($in['id'] ?? '')));
    $savedAll = load_json_file($CLI_CAT_F, []);
    $entry = sup_clean_entry(array_merge($CLI_CATALOG_DEFAULT[$id] ?? [],
                                         (array)($savedAll[$id] ?? []),
                                         (array)($in['entry'] ?? [])));
    $bin = $entry['binary'] ?? '';
    if ($bin === '') sup_json(['ok' => false, 'error' => 'No binary for ' . $id]);
    $which = trim((string)@shell_exec('command -v ' . escapeshellarg($bin) . ' 2>/dev/null'));
    if ($which === '') sup_json(['ok' => false, 'error' => $bin . ' is not installed on this machine']);

    $img = __DIR__ . '/assets/vision_probe.png';
    if (!is_file($img)) sup_json(['ok' => false, 'error' => 'probe image missing']);
    $question = 'Name the shapes in this image and their colours, in one short sentence.';
    $mode = $entry['image_mode'] ?? 'describe';

    $cmd = escapeshellarg($which);
    if (!empty($entry['subcmd']))     $cmd .= ' ' . escapeshellarg($entry['subcmd']);
    if (!empty($entry['extra_args'])) $cmd .= ' ' . $entry['extra_args'];   // validated flag list
    $prompt = $question;
    if ($mode === 'flag' && !empty($entry['image_flag'])) {
        $cmd .= ' ' . escapeshellarg($entry['image_flag']) . ' ' . escapeshellarg($img);
        if (!empty($entry['image_needs_sep'])) $cmd .= ' --';
    } elseif ($mode === 'path') {
        $prompt = 'Open ' . $img . ' with your Read tool. ' . $question;
    } elseif ($mode === 'at') {
        $prompt = '@' . $img . ' ' . $question;
    } else {
        sup_json(['ok' => false, 'error' => 'Nothing to probe: this agent is set to "describe", which uses the local vision model.']);
    }
    if (!empty($entry['cli_flag'])) $cmd .= ' ' . escapeshellarg($entry['cli_flag']);
    $cmd .= ' ' . escapeshellarg($prompt) . ' < /dev/null 2>&1';

    $t0 = microtime(true);
    $out = (string)@shell_exec('timeout 180 ' . $cmd);
    $secs = round(microtime(true) - $t0, 1);
    $low  = mb_strtolower($out);
    $hitTriangle = str_contains($low, 'triangle') && str_contains($low, 'red');
    $hitCircle   = str_contains($low, 'circle')   && str_contains($low, 'blue');
    $verdict = ($hitTriangle && $hitCircle) ? 'looks right'
             : (($hitTriangle || $hitCircle) ? 'partly right' : 'wrong or did not see it');
    // An agent that is not signed in, or has no key, did not fail to SEE anything: it never ran.
    // Cockpit launches agents with their own saved login and key, which this probe does not load,
    // so claude answered "Not logged in" and gemini asked for GEMINI_API_KEY (2026-10-02) and both
    // were scored "wrong or did not see it" — a verdict that blames the agent for the harness.
    $inconclusive = false;
    if ($verdict === 'wrong or did not see it'
        && preg_match('/not logged in|please run \/login|log ?in required|sign ?in|authenticat|unauthori[sz]ed|api[ _-]?key|GEMINI_API_KEY|invalid[ _]credentials|no credentials|openrouter\.ai\/auth/i', $out)) {
        $verdict = 'could not run here — the agent is not signed in, or has no key, in this test';
        $inconclusive = true;
    }
    // Show the TAIL: CLIs print notices first (trust prompts, deprecation lines)
    // and the answer last, so truncating from the front hides the thing we asked for.
    sup_json(['ok' => true, 'id' => $id, 'mode' => $mode, 'seconds' => $secs, 'inconclusive' => $inconclusive,
              'verdict' => $verdict, 'expected' => 'a red triangle and a blue circle',
              'answer' => mb_substr(trim($out), -1200)]);
}

sup_json(['ok' => false, 'error' => 'Unknown action']);
