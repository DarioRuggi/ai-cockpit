<?php
// =============================================================================
// edition.php — SPIKE (not yet wired; nothing requires this file).
//
// Single source of truth for which AI Cockpit edition this deploy is:
//   v2   — Full. Everything on.
//   v1   — Stand-alone. SaaS muted (UI hidden + backend 404). All else REAL.
//   demo — Public. SaaS muted + non-working features canned or "described"
//          (UI shown; a modal explains it and points to the edition that runs
//          it for real).
//
// One codebase (V2) drives all three. Behavior differs ONLY by the edition
// value. To wire it: `require_once __DIR__ . '/edition.php';` at the very top
// of paths.php (the universal choke-point every backend already loads).
//
// Detection order (first hit wins):
//   1. env  COCKPIT_EDITION = v2 | v1 | demo
//   2. file <web-root>/.edition   (single token: v2 | v1 | demo)
//   3. default: v2
//
// NOTE on fail-safe: default is v2 (canonical installs ship no marker). The
// v1 and demo tarballs MUST ship a `.edition` marker so a stamped deploy never
// silently falls back to v2. An unknown/garbage value is treated as the most-
// locked edition (demo) and logged, so a corrupt marker never leaks SaaS or
// real dispatch/filesystem.
// =============================================================================

if (!defined('COCKPIT_EDITION')) {

    $__ed = getenv('COCKPIT_EDITION');
    if ($__ed === false || $__ed === '') {
        $__f = __DIR__ . '/.edition';
        if (is_readable($__f)) {
            $__ed = trim((string)@file_get_contents($__f));
        }
    }
    $__ed = strtolower(trim((string)$__ed));

    if ($__ed === '') {
        $__ed = 'v2';                       // no marker → canonical Full
    } elseif (!in_array($__ed, ['v2', 'v1', 'demo'], true)) {
        error_log("edition.php: unknown edition '$__ed' → locking to demo");
        $__ed = 'demo';                     // corrupt marker → most-locked
    }

    define('COCKPIT_EDITION', $__ed);
    unset($__ed, $__f);
}

// ── Capability matrix ────────────────────────────────────────────────────────
// The ONLY thing that differs between editions. Add a row, not an if-ladder.
//   saas          — account layer: register/login, marketplace, relay, recovery
//   real_dispatch — actually run agents/models (tmux, live API calls)
//   filesystem    — real local file read/write (files.php, notes.php, export…)
const COCKPIT_CAPS = [
    //          saas   real_dispatch  filesystem
    'v2'   => ['saas'=>true,  'real_dispatch'=>true,  'filesystem'=>true ],
    'v1'   => ['saas'=>false, 'real_dispatch'=>true,  'filesystem'=>true ],
    'demo' => ['saas'=>false, 'real_dispatch'=>false, 'filesystem'=>false],
];

// Rank for "which edition is higher" comparisons (demo < v1 < v2).
const COCKPIT_RANK = ['demo' => 0, 'v1' => 1, 'v2' => 2];

// Human labels for modals / titles / splashes.
const COCKPIT_LABEL = [
    'v2'   => 'AI Cockpit (Full)',
    'v1'   => 'AI Cockpit V1',
    'demo' => 'AI Cockpit Web Demo',
];

// ── Helpers ──────────────────────────────────────────────────────────────────
function edition(): string { return COCKPIT_EDITION; }
function ed_is(string $e): bool { return COCKPIT_EDITION === $e; }
function ed_label(?string $e = null): string { return COCKPIT_LABEL[$e ?? COCKPIT_EDITION] ?? '?'; }

/**
 * The version to SHOW, for this edition.
 *
 * One version exists in the code: the even, Full one in cockpit_app/VERSION. It
 * is what integrity.json, official_builds.json, telemetry and the update check
 * all use, so nothing has to reason about two numbers or stay in step with a
 * second file.
 *
 * The published scheme is majors stepping by two -- Stand-alone odd (1, 3, 5),
 * Full even (2, 4, 6) -- so Stand-alone displays one major lower. It is a label,
 * applied at the last moment, not a second source of truth. Tried the other way
 * first (a VERSION_V1 file stamped into the v1 tree at build time) and it needed
 * a build stamp, a docker stamp and an exemption in the drift guard; this needs
 * none of them.
 *
 * 2.0.0 -> 1.0.0 in v1. Anything unparseable is returned untouched.
 */
function ed_display_version(string $v): string {
    if (COCKPIT_EDITION !== 'v1') return $v;
    if (!preg_match('/^\s*v?(\d+)(\.\d+.*)?$/', $v, $m)) return $v;
    $major = (int)$m[1];
    if ($major < 1) return $v;                 // never show 0.x or a negative
    return ($major - 1) . ($m[2] ?? '');
}

/** True if this edition really performs $cap (see COCKPIT_CAPS). */
function ed_allows(string $cap): bool {
    return (bool)(COCKPIT_CAPS[COCKPIT_EDITION][$cap] ?? false);
}

/** Lowest edition (by rank) that really performs $cap, or null if none. */
function ed_min_for(string $cap): ?string {
    $best = null;
    foreach (COCKPIT_CAPS as $ed => $caps) {
        if (!empty($caps[$cap])) {
            if ($best === null || COCKPIT_RANK[$ed] < COCKPIT_RANK[$best]) $best = $ed;
        }
    }
    return $best;
}

// ── Feature registry (drives the demo "described" modal) ─────────────────────
// Each entry: the feature the client shows but this edition can't run for real.
//   name        — shown as the modal title
//   description — one line: what it does
//   cap         — capability it needs (looked up in the matrix)
// The recommended edition is COMPUTED (ed_min_for(cap)) so it's always "the
// lowest edition that contains this feature", never hand-maintained.
const COCKPIT_FEATURES = [
    'fileman'     => ['name'=>'File Manager',    'description'=>'A file window for your Public folder, with read-only access to your project folders.', 'cap'=>'filesystem'],
    'cmdpanel'    => ['name'=>'Command Window',  'description'=>'Run simple commands in your Public folder, confined by the system.', 'cap'=>'filesystem'],
    'files'       => ['name'=>'File Browser',    'description'=>'Browse and edit files on this machine.',            'cap'=>'filesystem'],
    'notes'       => ['name'=>'Notes',           'description'=>'Persist notes to local storage.',                   'cap'=>'filesystem'],
    'export'      => ['name'=>'Export',          'description'=>'Write chats/artifacts to disk.',                    'cap'=>'filesystem'],
    'workers'     => ['name'=>'Workers',         'description'=>'Run real provider models with your own keys.',      'cap'=>'real_dispatch'],
    'agents'      => ['name'=>'Local Agents',    'description'=>'Drive Claude/Gemini/Ollama CLIs on this machine.',  'cap'=>'real_dispatch'],
    'combos'      => ['name'=>'Power Combos',     'description'=>'Chain multiple models into one orchestrated run.', 'cap'=>'real_dispatch'],
    'dual'        => ['name'=>'Dual Mode',        'description'=>'Run two local backends in parallel.',              'cap'=>'real_dispatch'],
    'generate'    => ['name'=>'Image / Video',    'description'=>'Generate media locally (Stable Diffusion).',       'cap'=>'real_dispatch'],
    'transcribe'  => ['name'=>'Transcribe',       'description'=>'Whisper speech-to-text on local files.',           'cap'=>'real_dispatch'],
];

/**
 * Gate a feature for the current edition.
 * Returns null when the feature runs for real here (caller proceeds normally).
 * Otherwise returns the payload the client renders as the "described" modal:
 *   [ 'ok'=>false, 'edition_gate'=>true,
 *     'feature'=>'File Browser',
 *     'description'=>'Browse and edit files on this machine.',
 *     'need_edition'=>'v1', 'need_label'=>'AI Cockpit V1',
 *     'message'=>'Download and install AI Cockpit V1 to use this for real.' ]
 * v1 does NOT use this for SaaS — SaaS is hidden outright, never described.
 */
function ed_feature_gate(string $key): ?array {
    $f = COCKPIT_FEATURES[$key] ?? null;
    if ($f === null) return null;                 // unknown key → don't block
    if (ed_allows($f['cap'])) return null;        // this edition runs it → ok

    $need = ed_min_for($f['cap']);                 // cheapest edition that has it
    return [
        'ok'           => false,
        'edition_gate' => true,
        'feature'      => $f['name'],
        'description'  => $f['description'],
        'need_edition' => $need,
        'need_label'   => $need ? ed_label($need) : ed_label('v2'),
        'message'      => 'Download and install ' . ($need ? ed_label($need) : ed_label('v2'))
                          . ' to use this for real.',
    ];
}

// Convenience: emit the gate JSON and exit, if gated. Backends call:
//   ed_gate_or_exit('files');   // returns if allowed; exits with modal JSON if not
function ed_gate_or_exit(string $key): void {
    $g = ed_feature_gate($key);
    if ($g === null) return;
    if (!headers_sent()) header('Content-Type: application/json');
    echo json_encode($g);
    exit;
}

// True only when $file is the directly-requested HTTP endpoint (not merely
// required as a library by another backend). Demo canned/stub blocks guard on
// this so a top-of-file demo short-circuit never fires mid-`require` and break
// a consumer. Call as: ed_is_direct(__FILE__).
function ed_is_direct(string $file): bool {
    return PHP_SAPI !== 'cli'
        && isset($_SERVER['SCRIPT_FILENAME'])
        && @realpath($_SERVER['SCRIPT_FILENAME']) === @realpath($file);
}

// Generic demo stub for internal/support endpoints that have no user-facing
// "feature" modal (status, capabilities, latency, session, …). In the demo
// edition they return a harmless empty-but-ok shape so the client degrades
// cleanly instead of executing real dispatch/filesystem/shell. Feature
// endpoints use ed_gate_or_exit() (described-modal) instead of this.
function ed_demo_stub(): void {
    if (!headers_sent()) header('Content-Type: application/json');
    echo json_encode(['ok'=>true, 'items'=>[], 'list'=>[], 'data'=>[],
        'message'=>'Not available in the web demo -- download AI Cockpit to use this for real.']);
    exit;
}

// SaaS choke-point for the SaaS-only files (saas.php, mkt_install.php,
// browse.php): they call this first. (worker_relay.php + models_dev.php are
// NOT saas — local dispatch / public metadata — so they do not call this.)
function ed_require_saas(): void {
    if (ed_allows('saas')) return;
    http_response_code(404);
    if (!headers_sent()) header('Content-Type: application/json');
    echo json_encode(['ok'=>false, 'error'=>'not_found']);   // no leak: plain 404
    exit;
}
