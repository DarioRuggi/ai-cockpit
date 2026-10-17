<?php
if (!function_exists('mb_strlen'))  { function mb_strlen($s, $e=null)  { return strlen($s); } }
if (!function_exists('mb_substr'))  { function mb_substr($s,$st,$l=null,$e=null) { return $l===null ? substr($s,$st) : substr($s,$st,$l); } }
// =============================================================================
// scheduler.php — Cockpit cron-driven job scheduler
//
// Installed as a cron entry (every minute):
//   */1 * * * * /usr/bin/php /var/www/html/cockpit/scheduler.php >/dev/null 2>&1
//
// Tick logic (one job per tick, FIFO by scheduled_at):
//   1. Acquire flock on scheduled_jobs.lock (non-blocking). Exit if can't.
//   2. Touch scheduler_heartbeat.txt (proof that cron is firing).
//   3. Read scheduled_jobs.json.
//   4. Sort pending jobs by scheduled_at (oldest first).
//   5. For each pending job:
//      - scheduled_at > now        → stop (all later jobs are future)
//      - scheduled_at < now-4h     → mark "missed", continue
//      - otherwise                 → mark "running", execute, mark "done"/"failed", BREAK
//   6. Release lock.
//
// This script is also called directly by the UI for:
//   GET  ?action=status            — queue snapshot + heartbeat status
//   POST ?action=schedule          — add a job to the queue
//   POST ?action=cancel            — cancel a pending job
//   POST ?action=delete            — delete any job from history
//   POST ?action=reschedule        — change scheduled_at of a missed/pending job
//   POST ?action=run_now           — immediately execute a missed/pending job
//
// =============================================================================

ini_set('display_errors', '0');
error_reporting(0);

// =============================================================================
// Paths
// =============================================================================
require_once __DIR__ . '/paths.php';
// The minute tick runs from cron as the person who owns the install — no browser,
// no session. Gating that with the session guard made every tick answer
// "Authentication required", which is why jobs never fired even with the crontab
// line in place (found 2026-09-22). Shell access as the owner IS the credential
// here; HTTP callers still go through the normal gate.
if (PHP_SAPI !== 'cli') {
    require_once __DIR__ . '/auth.php';
}

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) ed_demo_stub();
$JOBS_F      = $CD . '/scheduled_jobs.json';
$LOCK_F      = $CD . '/scheduled_jobs.lock';
$HEARTBEAT_F = $CD . '/scheduler_heartbeat.txt';

// Ensure data dir exists
if (!is_dir($CD)) @mkdir($CD, 0775, true);

// =============================================================================
// Helpers
// =============================================================================
function load_json_file(string $path, array $default = []): array {
    if (!is_file($path)) return $default;
    $j = json_decode((string)file_get_contents($path), true);
    return is_array($j) ? $j : $default;
}

function save_json_file(string $path, array $data): bool {
    $tmp = $path . '.tmp';
    if (file_put_contents($tmp, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)) === false) {
        return false;
    }
    return rename($tmp, $path);
}

// Acquire a non-blocking flock on the lock file.
// Returns the open file handle on success, false if already locked.
function acquire_lock(string $lock_path) {
    $fh = fopen($lock_path, 'c');
    if ($fh === false) return false;
    if (!flock($fh, LOCK_EX | LOCK_NB)) {
        fclose($fh);
        return false;
    }
    return $fh;
}

function release_lock($fh): void {
    // A closed handle is not a resource any more: guard, or a second release
    // (one per swept data dir) throws and kills the whole tick (2026-09-22).
    if ($fh && is_resource($fh)) {
        flock($fh, LOCK_UN);
        fclose($fh);
    }
}

// Generate a unique job ID
function make_job_id(): string {
    return 'sched_' . date('Y-m-d_H-i') . '_' . substr(bin2hex(random_bytes(4)), 0, 6);
}

// MISSED_TOLERANCE — how far past scheduled_at before a job is declared missed
const MISSED_TOLERANCE_SECS = 4 * 3600;   // 4 hours

// ORPHAN_RUNNING — a job stuck "running" longer than this had its worker die
// mid-run (sanitize is timeout-capped at 600s), so it's reclassified as failed.
const ORPHAN_RUNNING_SECS = 900;          // 15 minutes

// =============================================================================
// Job executor — dispatch to the right command handler
// =============================================================================
function execute_job(array $job, string $CD): array {
    // Returns ['ok' => bool, 'message' => string, 'details' => array]
    $cmd    = $job['command'] ?? '';
    $params = $job['params']  ?? [];

    switch ($cmd) {
        case 'sanitize':
            return job_sanitize($params, $CD);

        case 'echo_test':
            // Trivial test job for scheduler verification — logs a line and exits
            $msg = $params['message'] ?? 'scheduler echo test at ' . date('c');
            $log_f = $CD . '/scheduler_test_log.txt';
            file_put_contents($log_f, date('c') . ' ' . $msg . "\n", FILE_APPEND | LOCK_EX);
            return ['ok' => true, 'message' => 'echo_test completed', 'details' => ['msg' => $msg]];

        case 'plan_sequence':
            return job_plan_sequence($params);

        case 'goal_loop':
            return job_goal_loop($params, $CD);

        default:
            return ['ok' => false, 'message' => 'Unknown command: ' . $cmd, 'details' => []];
    }
}

// Dispatch a sanitize job — calls sanitizer.php via PHP CLI
function job_sanitize(array $params, string $CD): array {
    $sanitizer = __DIR__ . '/sanitizer.php';
    if (!is_file($sanitizer)) {
        return ['ok' => false, 'message' => 'sanitizer.php not found', 'details' => []];
    }
    $input_file = $params['input_file'] ?? '';
    $book_slug  = $params['book_slug']  ?? 'auto';
    $job_id     = $params['job_id']     ?? '';
    if (!$input_file || !is_file($input_file)) {
        return ['ok' => false, 'message' => 'Input file not found: ' . $input_file, 'details' => []];
    }
    // MED-94 fix: wrap with timeout(1) to prevent a hung sanitizer from
    // blocking the scheduler lock indefinitely. 10 minutes is generous for
    // a typical book; longer jobs should be split.
    $cmd = sprintf(
        '%s%s %s --input=%s --slug=%s --job_id=%s 2>&1',
        cockpit_timeout_cmd(600),
        escapeshellarg($PATHS['php_binary']),
        escapeshellarg($sanitizer),
        escapeshellarg($input_file),
        escapeshellarg($book_slug),
        escapeshellarg($job_id)
    );
    $output = [];
    $rc     = 0;
    exec($cmd, $output, $rc);
    $out_str = implode("\n", $output);
    return [
        'ok'      => $rc === 0,
        'message' => $rc === 0 ? 'Sanitize completed' : 'Sanitize failed (rc=' . $rc . ')',
        'details' => ['output' => mb_substr($out_str, 0, 2000)],
    ];
}

// =============================================================================
// Run a Plan-and-Sequence job: tick through all steps until complete/halted.
function job_plan_sequence(array $params): array {
    $project = $params['project'] ?? '';
    $plan_id = $params['plan_id'] ?? '';
    if (!$project || !$plan_id) {
        return ['ok'=>false, 'message'=>'Missing project or plan_id', 'details'=>[]];
    }

    $url_base = 'http://localhost/cockpit/orchestrator.php';
    $max_ticks = (int)($params['max_ticks'] ?? 30);
    $tick = 0;
    $last_status = '';

    // Start sequence
    $start = json_decode((string)@file_get_contents($url_base . '?action=run_sequence', false,
        stream_context_create(['http'=>[
            'method'=>'POST',
            'header'=>'Content-Type: application/json',
            'content'=>json_encode(['project'=>$project,'plan_id'=>$plan_id,
                'executor_model'=>$params['executor_model']??'',
                'guardrails'=>$params['guardrails']??[]], JSON_UNESCAPED_UNICODE),
            'timeout'=>30,
        ]])), true);

    if (empty($start['ok'])) {
        return ['ok'=>false, 'message'=>'Failed to start sequence: '.($start['error']??''), 'details'=>$start??[]];
    }

    while ($tick < $max_ticks) {
        $tick++;
        // Tick: advance one step
        $tick_resp = json_decode((string)@file_get_contents($url_base . '?action=run_sequence_tick', false,
            stream_context_create(['http'=>[
                'method'=>'POST',
                'header'=>'Content-Type: application/json',
                'content'=>json_encode(['project'=>$project,'plan_id'=>$plan_id], JSON_UNESCAPED_UNICODE),
                'timeout'=>120,
            ]])), true);

        if (empty($tick_resp['ok'])) {
            $last_status = $tick_resp['status'] ?? 'error';
            if (in_array($last_status, ['complete','halted'], true)) break;
            return ['ok'=>false, 'message'=>'Tick failed: '.($tick_resp['error']??''), 'details'=>$tick_resp??[]];
        }

        if (in_array($tick_resp['status'] ?? '', ['complete','halted'], true)) {
            $last_status = $tick_resp['status'];
            break;
        }

        // Poll for step output (bridge streaming). Wait up to 5 minutes.
        $token = $tick_resp['token'] ?? '';
        $step_n = $tick_resp['step'] ?? 0;
        if (!$token) continue;

        $step_output = '';
        $poll_start = time();
        while ((time() - $poll_start) < 300) {
            sleep(3);
            $poll = json_decode((string)@file_get_contents(
                'http://localhost/cockpit/bridge.php?mode=poll&token=' . urlencode($token)), true);
            if (!empty($poll['done'])) {
                $step_output = $poll['text'] ?? '';
                break;
            }
        }

        // Verify step
        $verify = json_decode((string)@file_get_contents($url_base . '?action=verify_step', false,
            stream_context_create(['http'=>[
                'method'=>'POST',
                'header'=>'Content-Type: application/json',
                'content'=>json_encode(['project'=>$project,'plan_id'=>$plan_id,
                    'step'=>$step_n,'output'=>$step_output], JSON_UNESCAPED_UNICODE),
                'timeout'=>60,
            ]])), true);

        $last_status = $verify['plan_status'] ?? 'sequencing';
        if (in_array($last_status, ['complete','halted'], true)) break;
    }

    return [
        'ok'      => true,
        'message' => 'Plan-and-Sequence finished: ' . $last_status,
        'details' => ['ticks'=>$tick, 'final_status'=>$last_status, 'plan_id'=>$plan_id],
    ];
}

// =============================================================================
// Autonomous goal loop: iteratively prompt an agent until goal is met or budget exhausted.
function job_goal_loop(array $params, string $CD): array {
    $goal       = $params['goal'] ?? '';
    $agent      = $params['agent'] ?? 'claude';
    $project    = $params['project'] ?? 'default';
    $max_steps  = min((int)($params['max_steps'] ?? 10), 50);
    $job_id     = $params['job_id'] ?? '';
    $kill_file  = $CD . '/goal_kill_' . $job_id;

    if (!$goal) return ['ok'=>false, 'message'=>'Missing goal', 'details'=>[]];

    // Budget the person can see and trust: steps, wall-clock minutes, and a stall
    // stop (no progress for 3 steps). Without these a goal loop was a black box
    // that either finished or silently burned its step budget (2026-09-22).
    $deadline_min = max(0, (int)($params['deadline_minutes'] ?? 0));
    $deadline_ts  = $deadline_min > 0 ? time() + $deadline_min * 60 : 0;
    $log_f = $CD . '/goal_loop_' . $job_id . '.json';
    $log   = ['goal'=>$goal, 'agent'=>$agent, 'project'=>$project, 'steps'=>[], 'status'=>'running',
              'started_at'=>date('c'), 'updated_at'=>date('c'), 'progress'=>0,
              'budget'=>['max_steps'=>$max_steps, 'steps_used'=>0,
                         'deadline_minutes'=>$deadline_min, 'deadline_at'=>$deadline_ts ? date('c', $deadline_ts) : null]];
    @file_put_contents($log_f, json_encode($log, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));

    $system_prompt = "You are an autonomous agent. Your goal: $goal\n\n" .
        "After each action, assess progress. Respond with JSON:\n" .
        "{\"action\": \"what you did\", \"observation\": \"what happened\", " .
        "\"progress\": 0-100, \"done\": true/false, \"next\": \"what to do next\"}\n\n" .
        "When done is true, the loop ends. Be concise.";

    $context = "Goal: $goal\nBegin working toward this goal. Report your first action.";

    for ($step = 0; $step < $max_steps; $step++) {
        // Check kill switch
        if (is_file($kill_file)) {
            @unlink($kill_file);
            $log['status'] = 'killed';
            $log['steps'][] = ['step'=>$step+1, 'action'=>'KILLED by user'];
            @file_put_contents($log_f, json_encode($log, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
            return ['ok'=>true, 'message'=>'Goal loop killed by user at step '.($step+1), 'details'=>$log];
        }

        // Submit prompt to bridge.php sync mode
        $bridge_url = 'http://localhost/cockpit/bridge.php';
        $submit = json_decode((string)@file_get_contents($bridge_url, false,
            stream_context_create(['http'=>[
                'method'=>'POST',
                'header'=>'Content-Type: application/json',
                'content'=>json_encode([
                    'mode'    => 'sync',
                    'agent'   => $agent,
                    'prompt'  => ($step === 0 ? $system_prompt . "\n\n" : '') . $context,
                    'project' => $project,
                ], JSON_UNESCAPED_UNICODE),
                'timeout'=>180,
            ]])), true);

        $response = $submit['text'] ?? ($submit['output'] ?? '');
        if (!$response) {
            $log['steps'][] = ['step'=>$step+1, 'error'=>'No response from agent'];
            $log['status'] = 'error';
            @file_put_contents($log_f, json_encode($log, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
            return ['ok'=>false, 'message'=>'Agent returned empty at step '.($step+1), 'details'=>$log];
        }

        // Try to parse JSON from response
        $parsed = null;
        if (preg_match('/\{[^{}]*"done"\s*:\s*(true|false)[^{}]*\}/s', $response, $m)) {
            $parsed = json_decode($m[0], true);
        }

        $step_log = [
            'step'     => $step + 1,
            'at'       => date('c'),
            'action'   => (string)($parsed['action'] ?? ''),
            'observation' => (string)($parsed['observation'] ?? ''),
            'progress' => isset($parsed['progress']) ? (int)$parsed['progress'] : null,
            'response' => mb_substr($response, 0, 2000),
            'parsed'   => $parsed,
        ];
        $log['steps'][] = $step_log;
        $log['updated_at'] = date('c');
        $log['budget']['steps_used'] = $step + 1;
        if ($step_log['progress'] !== null) $log['progress'] = max((int)$log['progress'], (int)$step_log['progress']);
        @file_put_contents($log_f, json_encode($log, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));

        // Check completion
        if ($parsed && !empty($parsed['done'])) {
            $log['status'] = 'complete';
            @file_put_contents($log_f, json_encode($log, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
            return ['ok'=>true, 'message'=>'Goal achieved in '.($step+1).' steps', 'details'=>$log];
        }

        // Wall-clock budget
        if ($deadline_ts && time() >= $deadline_ts) {
            $log['status'] = 'deadline_reached';
            @file_put_contents($log_f, json_encode($log, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
            return ['ok'=>true, 'message'=>'Goal loop stopped at its ' . $deadline_min . '-minute deadline (step ' . ($step+1) . ')', 'details'=>$log];
        }
        // Stall stop: three steps in a row without the agent's own progress moving.
        $recent = array_slice($log['steps'], -3);
        if (count($recent) === 3) {
            $vals = array_map(fn($x) => $x['progress'], $recent);
            if ($vals[0] !== null && $vals[0] === $vals[1] && $vals[1] === $vals[2]) {
                $log['status'] = 'stalled';
                @file_put_contents($log_f, json_encode($log, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
                return ['ok'=>true, 'message'=>'Goal loop stopped: no progress for 3 steps (stuck at ' . (int)$vals[0] . '%)', 'details'=>$log];
            }
        }

        // Build next context from agent's response
        $next = $parsed['next'] ?? '';
        $obs  = $parsed['observation'] ?? '';
        $context = "Previous result: $obs\nNext action requested: $next\nContinue working toward the goal. Report what you do.";

        sleep(2); // pace
    }

    $log['status'] = 'budget_exhausted';
    @file_put_contents($log_f, json_encode($log, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
    return ['ok'=>true, 'message'=>'Goal loop exhausted step budget ('.$max_steps.')', 'details'=>$log];
}

// Determine run mode: cron tick vs HTTP action
// =============================================================================
$is_http   = isset($_SERVER['REQUEST_METHOD']);
$action    = $is_http ? ($_GET['action'] ?? '') : 'tick';
$in        = [];

if ($is_http) {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $in = json_decode((string)file_get_contents('php://input'), true) ?: [];
}

// =============================================================================
// CRON TICK — runs every minute via cron
// =============================================================================
// A tick works on ONE data dir. Cron runs as the person, with no session, so
// paths.php hands it the SHARED root — while the app (signed in) keeps jobs under
// users/<login>/. Without sweeping every user dir the panel showed 'cron not
// firing' forever and no job ever ran (found 2026-09-22).
function scheduler_tick_dir(string $dir): void {
    $JOBS_F      = $dir . '/scheduled_jobs.json';
    $LOCK_F      = $dir . '/scheduled_jobs.lock';
    $HEARTBEAT_F = $dir . '/scheduler_heartbeat.txt';
    if (!is_dir($dir)) return;
        // Power Buttons that run by themselves (watched folders, daily and repeating buttons): same minute tick, no new daemon. A fault here must never stop the queue.
        if (is_file(__DIR__ . '/power_sched_lib.php')) { try { require_once __DIR__ . '/power_sched_lib.php'; power_sched_tick($dir); } catch (Throwable $e) {} }
        // Touch heartbeat first — even if lock is held, we want proof cron fires
        @file_put_contents($HEARTBEAT_F, date('c') . "\n");
        @chmod($HEARTBEAT_F, 0664);

        // Try to acquire lock — if another tick is still running, exit silently
        $lock = acquire_lock($LOCK_F);
        if (!$lock) return;

        $jobs  = load_json_file($JOBS_F, []);
        $now   = time();
        $dirty = false;

        // Sort pending jobs first (FIFO by scheduled_at). HIGH-91 fix: use a
        // consistent partition comparator so usort doesn't get undefined behaviour
        // when both A and B are non-pending.
        usort($jobs, function($a, $b) {
            $aP = ($a['status'] ?? '') === 'pending' ? 0 : 1;
            $bP = ($b['status'] ?? '') === 'pending' ? 0 : 1;
            if ($aP !== $bP) return $aP <=> $bP;
            return strcmp($a['scheduled_at'] ?? '', $b['scheduled_at'] ?? '');
        });

        foreach ($jobs as $i => $job) {
            if (($job['status'] ?? '') !== 'pending') continue;

            $sched_ts = strtotime($job['scheduled_at'] ?? '');
            if ($sched_ts === false) {
                $jobs[$i]['status']     = 'missed';
                $jobs[$i]['updated_at'] = date('c');
                $dirty = true;
                continue;
            }

            if ($sched_ts > $now) {
                break;
            }

            if ($sched_ts < ($now - MISSED_TOLERANCE_SECS)) {
                $jobs[$i]['status']     = 'missed';
                $jobs[$i]['updated_at'] = date('c');
                $dirty = true;
                continue;
            }

            // HIGH-90 fix: if marking running fails to save, do NOT execute.
            // Otherwise the next tick would see status=pending and run it again.
            $jobs[$i]['status']     = 'running';
            $jobs[$i]['started_at'] = date('c');
            $jobs[$i]['updated_at'] = date('c');
            if (!save_json_file($JOBS_F, $jobs)) {
                release_lock($lock);
            }
            $dirty = false;

            $result = execute_job($job, $dir);

            if ($result['ok']) {
                $jobs[$i]['status']       = 'done';
                $jobs[$i]['completed_at'] = date('c');
                $jobs[$i]['updated_at']   = date('c');
                $jobs[$i]['result']       = $result;
                // Recurring: spawn next occurrence
                $ri = (int)($job['repeat_interval'] ?? 0);
                if ($ri > 0) {
                    $next_job = $job;
                    $next_job['id']           = make_job_id();
                    $next_job['status']       = 'pending';
                    $next_job['scheduled_at'] = date('c', $now + $ri);
                    $next_job['created_at']   = date('c');
                    $next_job['updated_at']   = date('c');
                    $next_job['started_at']   = null;
                    $next_job['completed_at'] = null;
                    $next_job['result']       = null;
                    unset($next_job['attempt'], $next_job['last_error']);
                    $jobs[] = $next_job;
                }
            } else {
                // Auto-retry: if max_retries > 0 and attempts < max, reschedule
                $max_retries = (int)($job['max_retries'] ?? 0);
                $attempt     = (int)($job['attempt'] ?? 1);
                if ($max_retries > 0 && $attempt < $max_retries) {
                    $backoff = min(300, 60 * $attempt);
                    $jobs[$i]['status']       = 'pending';
                    $jobs[$i]['attempt']      = $attempt + 1;
                    $jobs[$i]['scheduled_at'] = date('c', $now + $backoff);
                    $jobs[$i]['updated_at']   = date('c');
                    $jobs[$i]['last_error']   = $result['message'] ?? 'unknown';
                } else {
                    $jobs[$i]['status']       = 'failed';
                    $jobs[$i]['completed_at'] = date('c');
                    $jobs[$i]['updated_at']   = date('c');
                    $jobs[$i]['result']       = $result;
                }
            }
            $dirty = true;

            break;   // one job per tick
        }

        if ($dirty) save_json_file($JOBS_F, $jobs);
        release_lock($lock);
}

// Install / remove the crontab line for the person who owns this install. PHP runs
// as the web user, so it goes through the same sudo -u allowlist the toolbar
// launchers use (scripts/cockpit_cron.sh). One click instead of a pasted line.
if ($action === 'cron_install' || $action === 'cron_remove' || $action === 'cron_status') {
    $owner  = cockpit_owner_user();
    $script = rtrim((string)($PATHS['home'] ?? ''), '/') . '/scripts/cockpit_cron.sh';
    if (!is_file($script)) { echo json_encode(['ok'=>false,'error'=>'cockpit_cron.sh not installed under ~/scripts'], JSON_UNESCAPED_UNICODE); exit; }
    $verb = ['cron_install'=>'install', 'cron_remove'=>'remove', 'cron_status'=>'status'][$action];
    $cmd  = cockpit_as_owner(true) . escapeshellarg($script) . ' ' . $verb . ' 2>&1';
    $out = []; $rc = 1; exec($cmd, $out, $rc);
    $txt = trim(implode("\n", $out));
    echo json_encode(['ok' => ($rc === 0), 'action' => $verb, 'output' => $txt,
        'installed' => (bool)preg_match('/^installed/m', $txt),
        'error' => $rc === 0 ? null : ($txt !== '' ? $txt : 'cockpit_cron.sh failed (rc=' . $rc . ')')], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'tick') {
    // Sweep the shared root and every per-user dir (users/<login>/).
    $dirs = [$CD];
    $root = rtrim((string)($PATHS['cockpit_data_root'] ?? $CD), '/');
    if ($root !== '' && $root !== rtrim($CD, '/')) $dirs[] = $root;
    foreach ((glob($root . '/users/*', GLOB_ONLYDIR) ?: []) as $ud) $dirs[] = $ud;
    foreach (array_unique($dirs) as $d) scheduler_tick_dir($d);
    exit(0);
}

// =============================================================================
// HTTP ACTIONS
// =============================================================================

// ---------------------------------------------------------------------------
// Action: status — queue snapshot + heartbeat info
// ---------------------------------------------------------------------------
if ($action === 'status') {
    $jobs = load_json_file($JOBS_F, []);

    // Orphan recovery — a job left "running" far longer than any real run could
    // take means the worker process died (crash / server restart) without ever
    // writing a result. Reclassify it as "failed" so it stops being counted as
    // running forever (this is what left month-old jobs showing as "running").
    $now = time();
    $orphanChanged = false;
    foreach ($jobs as $i => $j) {
        if (($j['status'] ?? '') !== 'running') continue;
        $started = !empty($j['started_at']) ? strtotime($j['started_at']) : 0;
        if ($started && ($now - $started) > ORPHAN_RUNNING_SECS) {
            $jobs[$i]['status']       = 'failed';
            $jobs[$i]['completed_at'] = date('c');
            $jobs[$i]['updated_at']   = date('c');
            $jobs[$i]['result']       = ['ok' => false,
                'message' => 'Orphaned — worker died before completion', 'details' => []];
            $orphanChanged = true;
        }
    }
    if ($orphanChanged) save_json_file($JOBS_F, $jobs);

    // Heartbeat check
    $hb_exists = is_file($HEARTBEAT_F);
    $hb_age    = $hb_exists ? (time() - filemtime($HEARTBEAT_F)) : null;
    // Green < 90s, amber < 300s, red otherwise
    if (!$hb_exists)        $hb_status = 'missing';
    elseif ($hb_age < 90)   $hb_status = 'ok';
    elseif ($hb_age < 300)  $hb_status = 'stale';
    else                    $hb_status = 'dead';

    // Cron line for copy-paste
    $cron_line = '*/1 * * * * ' . $PATHS['php_binary'] . ' ' . __FILE__ . ' >/dev/null 2>&1';

    // Summarise jobs by status
    $by_status = [];
    foreach ($jobs as $j) {
        $s = $j['status'] ?? 'unknown';
        $by_status[$s] = ($by_status[$s] ?? 0) + 1;
    }

    // Attach each goal loop's live progress so the Tasks panel can show step x/y,
    // percent and the last action instead of just "running".
    foreach ($jobs as &$_j) {
        if (($_j['command'] ?? '') !== 'goal_loop') continue;
        $gf = $CD . '/goal_loop_' . ($_j['id'] ?? '') . '.json';
        $gl = is_readable($gf) ? json_decode((string)file_get_contents($gf), true) : null;
        if (!is_array($gl)) continue;
        $last = is_array($gl['steps'] ?? null) && $gl['steps'] ? end($gl['steps']) : null;
        $_j['goal_progress'] = [
            'status'     => (string)($gl['status'] ?? ''),
            'progress'   => (int)($gl['progress'] ?? 0),
            'steps_used' => (int)($gl['budget']['steps_used'] ?? count((array)($gl['steps'] ?? []))),
            'max_steps'  => (int)($gl['budget']['max_steps'] ?? 0),
            'deadline_at'=> $gl['budget']['deadline_at'] ?? null,
            'last_action'=> $last ? mb_substr((string)($last['action'] ?: ($last['observation'] ?? '')), 0, 120) : '',
            'updated_at' => (string)($gl['updated_at'] ?? ''),
        ];
    }
    unset($_j);

    echo json_encode([
        'ok'        => true,
        'heartbeat' => [
            'status'    => $hb_status,
            'age_secs'  => $hb_age,
            'last_seen' => $hb_exists ? date('c', filemtime($HEARTBEAT_F)) : null,
        ],
        'cron_line' => $cron_line,
        'jobs'      => $jobs,
        'by_status' => $by_status,
        'server_time' => date('c'),
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// ---------------------------------------------------------------------------
// Action: schedule — add a new job to the queue
// ---------------------------------------------------------------------------
if ($action === 'schedule') {
    $command      = trim((string)($in['command']      ?? ''));
    $params       = is_array($in['params'] ?? null) ? $in['params'] : [];
    $scheduled_at = trim((string)($in['scheduled_at'] ?? ''));

    if (!$command) {
        echo json_encode(['ok' => false, 'error' => 'Missing command'], JSON_UNESCAPED_UNICODE); exit;
    }
    // Validate command whitelist
    $allowed_commands = ['sanitize', 'echo_test', 'plan_sequence', 'goal_loop'];
    if (!in_array($command, $allowed_commands, true)) {
        echo json_encode(['ok' => false, 'error' => 'Unknown command: ' . $command], JSON_UNESCAPED_UNICODE); exit;
    }
    // Validate / default scheduled_at
    if (!$scheduled_at) {
        $scheduled_at = date('c');   // now
    } else {
        $ts = strtotime($scheduled_at);
        if ($ts === false) {
            echo json_encode(['ok' => false, 'error' => 'Invalid scheduled_at: ' . $scheduled_at], JSON_UNESCAPED_UNICODE); exit;
        }
        $scheduled_at = date('c', $ts);
    }

    $job_id = make_job_id();
    // Embed job_id into params so sanitizer.php can use it for its state file
    $params['job_id'] = $job_id;

    $repeat_interval = (int)($in['repeat_interval'] ?? 0);
    $new_job = [
        'id'              => $job_id,
        'command'         => $command,
        'params'          => $params,
        'scheduled_at'    => $scheduled_at,
        'status'          => 'pending',
        'created_at'      => date('c'),
        'updated_at'      => date('c'),
        'started_at'      => null,
        'completed_at'    => null,
        'result'          => null,
        'repeat_interval' => $repeat_interval,
    ];

    $lock = acquire_lock($LOCK_F);
    if (!$lock) {
        echo json_encode(['ok' => false, 'error' => 'Scheduler busy — try again'], JSON_UNESCAPED_UNICODE); exit;
    }
    $jobs = load_json_file($JOBS_F, []);
    $jobs[] = $new_job;
    save_json_file($JOBS_F, $jobs);
    release_lock($lock);

    echo json_encode(['ok' => true, 'job_id' => $job_id, 'scheduled_at' => $scheduled_at], JSON_UNESCAPED_UNICODE);
    exit;
}

// ---------------------------------------------------------------------------
// Action: cancel — cancel a pending job
// ---------------------------------------------------------------------------
if ($action === 'cancel') {
    $job_id = trim((string)($in['job_id'] ?? ''));
    if (!$job_id) { echo json_encode(['ok' => false, 'error' => 'Missing job_id'], JSON_UNESCAPED_UNICODE); exit; }

    $lock = acquire_lock($LOCK_F);
    if (!$lock) { echo json_encode(['ok' => false, 'error' => 'Scheduler busy'], JSON_UNESCAPED_UNICODE); exit; }

    $jobs  = load_json_file($JOBS_F, []);
    $found = false;
    foreach ($jobs as $i => $j) {
        if ($j['id'] !== $job_id) continue;
        $found = true;
        if ($j['status'] !== 'pending') {
            release_lock($lock);
            echo json_encode(['ok' => false, 'error' => 'Job is not pending (status: ' . $j['status'] . ')'], JSON_UNESCAPED_UNICODE); exit;
        }
        $jobs[$i]['status']     = 'cancelled';
        $jobs[$i]['updated_at'] = date('c');
        break;
    }
    if (!$found) { release_lock($lock); echo json_encode(['ok' => false, 'error' => 'Job not found'], JSON_UNESCAPED_UNICODE); exit; }
    save_json_file($JOBS_F, $jobs);
    release_lock($lock);
    echo json_encode(['ok' => true, 'job_id' => $job_id], JSON_UNESCAPED_UNICODE);
    exit;
}

// ---------------------------------------------------------------------------
// Action: delete — remove a job from history entirely
// ---------------------------------------------------------------------------
if ($action === 'delete') {
    $job_id = trim((string)($in['job_id'] ?? ''));
    if (!$job_id) { echo json_encode(['ok' => false, 'error' => 'Missing job_id'], JSON_UNESCAPED_UNICODE); exit; }

    $lock = acquire_lock($LOCK_F);
    if (!$lock) { echo json_encode(['ok' => false, 'error' => 'Scheduler busy'], JSON_UNESCAPED_UNICODE); exit; }

    $jobs   = load_json_file($JOBS_F, []);
    $before = count($jobs);
    // Don't allow deleting a running job — could orphan its state file
    $jobs = array_values(array_filter($jobs, function($j) use ($job_id) {
        if ($j['id'] !== $job_id) return true;     // keep other jobs
        if ($j['status'] === 'running') return true; // keep running — refuse delete
        return false;                               // delete this one
    }));
    $after = count($jobs);
    if ($after === $before) {
        release_lock($lock);
        echo json_encode(['ok' => false, 'error' => 'Job not found or is currently running'], JSON_UNESCAPED_UNICODE); exit;
    }
    save_json_file($JOBS_F, $jobs);
    release_lock($lock);
    echo json_encode(['ok' => true, 'job_id' => $job_id], JSON_UNESCAPED_UNICODE);
    exit;
}

// ---------------------------------------------------------------------------
// Action: reschedule — change scheduled_at of a missed or pending job
// ---------------------------------------------------------------------------
if ($action === 'reschedule') {
    $job_id       = trim((string)($in['job_id']       ?? ''));
    $scheduled_at = trim((string)($in['scheduled_at'] ?? ''));
    if (!$job_id || !$scheduled_at) {
        echo json_encode(['ok' => false, 'error' => 'Missing job_id or scheduled_at'], JSON_UNESCAPED_UNICODE); exit;
    }
    $ts = strtotime($scheduled_at);
    if ($ts === false) {
        echo json_encode(['ok' => false, 'error' => 'Invalid scheduled_at'], JSON_UNESCAPED_UNICODE); exit;
    }
    $scheduled_at = date('c', $ts);

    $lock = acquire_lock($LOCK_F);
    if (!$lock) { echo json_encode(['ok' => false, 'error' => 'Scheduler busy'], JSON_UNESCAPED_UNICODE); exit; }

    $jobs  = load_json_file($JOBS_F, []);
    $found = false;
    foreach ($jobs as $i => $j) {
        if ($j['id'] !== $job_id) continue;
        $found = true;
        if (!in_array($j['status'], ['pending', 'missed'], true)) {
            release_lock($lock);
            echo json_encode(['ok' => false, 'error' => 'Can only reschedule pending or missed jobs'], JSON_UNESCAPED_UNICODE); exit;
        }
        $jobs[$i]['scheduled_at'] = $scheduled_at;
        $jobs[$i]['status']       = 'pending';   // reactivate missed jobs
        $jobs[$i]['updated_at']   = date('c');
        break;
    }
    if (!$found) { release_lock($lock); echo json_encode(['ok' => false, 'error' => 'Job not found'], JSON_UNESCAPED_UNICODE); exit; }
    save_json_file($JOBS_F, $jobs);
    release_lock($lock);
    echo json_encode(['ok' => true, 'job_id' => $job_id, 'scheduled_at' => $scheduled_at], JSON_UNESCAPED_UNICODE);
    exit;
}

// ---------------------------------------------------------------------------
// Action: run_now — immediately execute a missed or pending job (HTTP, blocks)
// ---------------------------------------------------------------------------
if ($action === 'run_now') {
    $job_id = trim((string)($in['job_id'] ?? ''));
    if (!$job_id) { echo json_encode(['ok' => false, 'error' => 'Missing job_id'], JSON_UNESCAPED_UNICODE); exit; }

    $lock = acquire_lock($LOCK_F);
    if (!$lock) { echo json_encode(['ok' => false, 'error' => 'Scheduler busy'], JSON_UNESCAPED_UNICODE); exit; }

    $jobs  = load_json_file($JOBS_F, []);
    $found = false;
    $idx   = -1;
    foreach ($jobs as $i => $j) {
        if ($j['id'] !== $job_id) continue;
        $found = true;
        $idx   = $i;
        if (!in_array($j['status'], ['pending', 'missed', 'failed'], true)) {
            release_lock($lock);
            echo json_encode(['ok' => false, 'error' => 'Job not in runnable state (status: ' . $j['status'] . ')'], JSON_UNESCAPED_UNICODE); exit;
        }
        break;
    }
    if (!$found) { release_lock($lock); echo json_encode(['ok' => false, 'error' => 'Job not found'], JSON_UNESCAPED_UNICODE); exit; }

    $jobs[$idx]['status']     = 'running';
    $jobs[$idx]['started_at'] = date('c');
    $jobs[$idx]['updated_at'] = date('c');
    save_json_file($JOBS_F, $jobs);
    release_lock($lock);

    // Execute (may take a while — client should use a long timeout or poll)
    $result = execute_job($jobs[$idx], $CD);

    // Re-acquire lock to update result
    $lock2 = acquire_lock($LOCK_F);
    if ($lock2) {
        $jobs2 = load_json_file($JOBS_F, []);
        foreach ($jobs2 as $i => $j) {
            if ($j['id'] !== $job_id) continue;
            $jobs2[$i]['status']       = $result['ok'] ? 'done' : 'failed';
            $jobs2[$i]['completed_at'] = date('c');
            $jobs2[$i]['updated_at']   = date('c');
            $jobs2[$i]['result']       = $result;
            break;
        }
        save_json_file($JOBS_F, $jobs2);
        release_lock($lock2);
    }

    echo json_encode(['ok' => $result['ok'], 'job_id' => $job_id, 'result' => $result], JSON_UNESCAPED_UNICODE);
    exit;
}

// ---------------------------------------------------------------------------
// Action: kill — stop a running job (sets kill flag for goal_loop, cancels others)
// ---------------------------------------------------------------------------
if ($action === 'kill') {
    $job_id = trim((string)($in['job_id'] ?? ''));
    if (!$job_id) { echo json_encode(['ok'=>false,'error'=>'Missing job_id'], JSON_UNESCAPED_UNICODE); exit; }

    $lock = acquire_lock($LOCK_F);
    if (!$lock) { echo json_encode(['ok'=>false,'error'=>'Scheduler busy'], JSON_UNESCAPED_UNICODE); exit; }

    $jobs = load_json_file($JOBS_F, []);
    $found = false;
    foreach ($jobs as $i => $j) {
        if ($j['id'] !== $job_id) continue;
        $found = true;
        if ($j['status'] === 'running' && ($j['command'] ?? '') === 'goal_loop') {
            @file_put_contents($CD . '/goal_kill_' . $job_id, '1');
        }
        if (in_array($j['status'], ['pending','running'], true)) {
            $jobs[$i]['status'] = 'cancelled';
            $jobs[$i]['updated_at'] = date('c');
        }
        break;
    }
    save_json_file($JOBS_F, $jobs);
    release_lock($lock);

    if (!$found) { echo json_encode(['ok'=>false,'error'=>'Job not found'], JSON_UNESCAPED_UNICODE); exit; }
    echo json_encode(['ok'=>true,'job_id'=>$job_id], JSON_UNESCAPED_UNICODE);
    exit;
}

// ---------------------------------------------------------------------------
// Action: goal_status — read goal loop log
// ---------------------------------------------------------------------------
if ($action === 'goal_status') {
    $job_id = trim((string)($_GET['job_id'] ?? ($in['job_id'] ?? '')));
    if (!$job_id) { echo json_encode(['ok'=>false,'error'=>'Missing job_id'], JSON_UNESCAPED_UNICODE); exit; }
    $log_f = $CD . '/goal_loop_' . $job_id . '.json';
    if (!is_file($log_f)) { echo json_encode(['ok'=>false,'error'=>'No log found'], JSON_UNESCAPED_UNICODE); exit; }
    $log = json_decode(file_get_contents($log_f), true);
    echo json_encode(['ok'=>true,'log'=>$log], JSON_UNESCAPED_UNICODE);
    exit;
}

// ---------------------------------------------------------------------------
// Catch-all
// ---------------------------------------------------------------------------
echo json_encode(['ok' => false, 'error' => 'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
