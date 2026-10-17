<?php
require_once __DIR__ . "/auth.php";
// =============================================================================
// migrate_v2.php — Tools Staleness Fix migration (one-time, idempotent)
//
// Called by tools.php on every request via require_once + migrate_v2_run().
// The function is a no-op after first successful run (guarded by a lock file).
//
// What it does:
//   1. Scans cockpit_data/tools/ for non-custom JSONs (old built-in copies
//      that were seeded on first run under the old behaviour).
//   2. For each stale built-in copy:
//      a. Extracts any user-added presets (presets not present in the shipped
//         version) and writes them to tools_state.json under
//         tools.<id>.user_presets[] (tagged user_added:true).
//      b. Backs up the stale file to cockpit_data/tools/_backup/<id>.json
//      c. Deletes the stale file from cockpit_data/tools/
//   3. Similarly migrates cockpit_data/workers_providers.json (old full copy)
//      to the overlay format (format_version:2) if needed.
//   4. Writes .migration_v2_completed (permanent done flag).
//   5. Writes .migration_v2_notify (ephemeral — consumed by migration_status
//      endpoint to show a one-time UI banner, then deleted).
//
// Idempotency: if .migration_v2_completed exists, returns immediately.
// Lock file: .migration_v2_lock prevents concurrent runs (e.g. parallel tabs).
//
// ZERO risk: stale files are backed up, never permanently deleted without
// backup. The function catches all exceptions and returns a result array
// rather than crashing tools.php.
// =============================================================================

function migrate_v2_run(
    string $CD,
    string $TOOLS_DIR,
    string $BUILTINS_SHIP,
    string $WORKERS_SHIP_PATH   // path to shipped workers_providers.json
): array {

    $result = [
        'ran'            => false,
        'notify'         => false,
        'tools_migrated' => [],
        'workers_migrated' => false,
        'error'          => null,
    ];

    $done_f  = $CD . '/.migration_v2_completed';
    $lock_f  = $CD . '/.migration_v2_lock';
    $notify_f = $CD . '/.migration_v2_notify';

    // Already done — fast path (every request after first run takes this path)
    if (is_file($done_f)) return $result;

    // Acquire lock (non-blocking) — skip if another PHP process is migrating
    $lock = @fopen($lock_f, 'x');
    if (!$lock) return $result;   // another process has the lock

    try {
        $result['ran'] = true;

        // ── Load tools_state.json ────────────────────────────────────────────
        $state_f = $CD . '/tools_state.json';
        $state   = [];
        if (is_file($state_f)) {
            $s = json_decode((string)file_get_contents($state_f), true);
            if (is_array($s)) $state = $s;
        }
        if (!isset($state['tools'])               || !is_array($state['tools']))               $state['tools']               = [];
        if (!isset($state['auto_route_projects']) || !is_array($state['auto_route_projects'])) $state['auto_route_projects'] = [];

        // Backup dir
        $backup_dir = $TOOLS_DIR . '/_backup';
        if (!is_dir($backup_dir)) @mkdir($backup_dir, 0775, true);

        // ── Scan cockpit_data/tools/ for stale built-in copies ───────────────
        foreach (glob($TOOLS_DIR . '/*.json') ?: [] as $f) {
            $def = @json_decode((string)file_get_contents($f), true);
            if (!is_array($def) || empty($def['id'])) continue;

            // Custom tools (custom:true) stay — they're the user's own tools
            if (!empty($def['custom'])) continue;

            $tid       = $def['id'];
            $ship_path = $BUILTINS_SHIP . '/' . $tid . '.json';

            // If there's no shipped version, treat as custom and leave alone
            if (!is_file($ship_path)) continue;

            // Load the shipped version to find which presets are user-added
            $shipped = @json_decode((string)file_get_contents($ship_path), true);
            $shipped_preset_ids = [];
            if (is_array($shipped)) {
                foreach (($shipped['presets'] ?? []) as $p) {
                    if (!empty($p['id'])) $shipped_preset_ids[] = $p['id'];
                }
            }

            // Extract user-added presets (present in stale copy but not in shipped)
            $user_presets = [];
            foreach (($def['presets'] ?? []) as $p) {
                if (empty($p['id'])) continue;
                if (in_array($p['id'], $shipped_preset_ids, true)) continue;
                // This is a user-added preset — preserve it
                $p['user_added'] = true;
                $user_presets[] = $p;
            }

            // Write user-added presets to state (merge with any that already exist)
            if ($user_presets) {
                if (!isset($state['tools'][$tid])) $state['tools'][$tid] = [];
                if (!isset($state['tools'][$tid]['user_presets'])) $state['tools'][$tid]['user_presets'] = [];
                // Append without duplicating (by preset id)
                $existing_ids = array_column($state['tools'][$tid]['user_presets'], 'id');
                foreach ($user_presets as $up) {
                    if (!in_array($up['id'], $existing_ids, true)) {
                        $state['tools'][$tid]['user_presets'][] = $up;
                    }
                }
            }

            // Back up and remove the stale file
            $backup_dest = $backup_dir . '/' . $tid . '_' . date('Ymd_His') . '.json';
            @copy($f, $backup_dest);
            @unlink($f);

            $result['tools_migrated'][] = $tid;
        }

        // Save updated state if anything changed
        if ($result['tools_migrated']) {
            $tmp = $state_f . '.tmp';
            file_put_contents($tmp, json_encode($state, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
            rename($tmp, $state_f);
        }

        // ── Workers providers migration (format_version: 2) ──────────────────
        // Old: cockpit_data/workers_providers.json was a full copy of the shipped catalog.
        // New: it's an overlay with only custom additions.
        $workers_user_f  = $CD . '/workers_providers.json';
        if (is_file($workers_user_f) && is_file($WORKERS_SHIP_PATH)) {
            $user_w   = @json_decode((string)file_get_contents($workers_user_f),   true);
            $ship_w   = @json_decode((string)file_get_contents($WORKERS_SHIP_PATH), true);

            // Only migrate if it's the old format (no format_version key)
            if (is_array($user_w) && !isset($user_w['format_version']) && is_array($ship_w)) {
                // Find custom providers (present in user copy, absent in shipped)
                $ship_ids   = is_array($ship_w)
                    ? array_column(array_filter($ship_w, 'is_array'), 'id')
                    : [];

                $custom_providers   = [];
                $user_added_models  = [];

                foreach ($user_w as $key => $entry) {
                    if (!is_array($entry)) continue;
                    $eid = $entry['id'] ?? $key;
                    if (!in_array($eid, $ship_ids, true)) {
                        // Entirely new provider — preserve wholesale
                        $custom_providers[] = $entry;
                    } else {
                        // Shipped provider — check for user-added models
                        // Find the shipped entry for comparison
                        $ship_entry = null;
                        foreach ($ship_w as $se) {
                            if (is_array($se) && ($se['id'] ?? null) === $eid) {
                                $ship_entry = $se; break;
                            }
                        }
                        if ($ship_entry) {
                            $ship_model_ids = array_column($ship_entry['models'] ?? [], 'id');
                            foreach (($entry['models'] ?? []) as $m) {
                                if (!in_array($m['id'] ?? '', $ship_model_ids, true)) {
                                    $user_added_models[] = array_merge($m, ['provider_id' => $eid]);
                                }
                            }
                        }
                    }
                }

                // Back up old file
                $w_backup = $backup_dir . '/workers_providers_' . date('Ymd_His') . '.json';
                @copy($workers_user_f, $w_backup);

                // Write new overlay format
                $overlay = [
                    'format_version'    => 2,
                    'custom_providers'  => $custom_providers,
                    'user_added_models' => $user_added_models,
                ];
                $tmp = $workers_user_f . '.tmp';
                file_put_contents($tmp, json_encode($overlay, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
                rename($tmp, $workers_user_f);
                $result['workers_migrated'] = true;
            }
        }

        // ── Write flag files ─────────────────────────────────────────────────
        // Only set the notify flag if something actually changed (no point
        // nagging the user if everything was already clean)
        if ($result['tools_migrated'] || $result['workers_migrated']) {
            file_put_contents($notify_f, date('c'));
            $result['notify'] = true;
        }

        // Always write the done flag — even if nothing was migrated, we don't
        // want to rescan on every request.
        file_put_contents($done_f, date('c'));

    } catch (\Throwable $e) {
        $result['error'] = $e->getMessage();
    } finally {
        @fclose($lock);
        @unlink($lock_f);
    }

    return $result;
}
