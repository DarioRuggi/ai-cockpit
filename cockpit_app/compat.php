<?php
// =============================================================================
// compat.php — Phase 5: cross-platform object compatibility resolution.
//
// Portable objects (Tool / Capability / Skill / Worker-card / Pipeline /
// Tool-preset) may carry optional metadata describing where they came from and
// what they need to run:
//
//   origin        : { source, author, os, created }            (informational)
//   requirements  : { binaries:[...], os:[...], arch:[...],
//                     min_cockpit:"x.y.z", env:[...] }
//   compatibility : { "<os>": "ok"|"needs_install"|"unsupported", ... }  (override)
//   alternatives  : [ { os:"windows", use:"<id-or-cmd>", note:"…" }, … ]
//
// ALL fields are optional. An object with NO metadata resolves to "ok" so every
// existing local object keeps loading and running unchanged (Phase 5 GATE).
//
// Resolution: detect host platform → explicit compatibility override wins →
// else derive from requirements (os → arch → binaries) → consider alternatives.
// Badges are Protanopia-safe (text + shape symbol, never colour alone).
// =============================================================================

require_once __DIR__ . '/paths.php';

// Default (empty) metadata block — merge over any object missing fields.
function cockpit_object_meta_defaults(): array {
    return [
        'origin'        => ['source' => 'local', 'author' => '', 'os' => '', 'created' => ''],
        'requirements'  => ['binaries' => [], 'os' => [], 'arch' => [], 'min_cockpit' => '', 'env' => []],
        'compatibility' => new \stdClass(),   // {} — explicit per-OS overrides
        'alternatives'  => [],
    ];
}

// Ensure an object array has the metadata keys (sane defaults). Non-destructive.
function cockpit_object_with_meta(array $obj): array {
    $d = cockpit_object_meta_defaults();
    foreach (['origin', 'requirements'] as $k) {
        $obj[$k] = array_merge($d[$k], is_array($obj[$k] ?? null) ? $obj[$k] : []);
    }
    if (!isset($obj['compatibility'])) $obj['compatibility'] = [];
    if (!isset($obj['alternatives']) || !is_array($obj['alternatives'])) $obj['alternatives'] = [];
    return $obj;
}

// Protanopia-safe badge for a status (text + symbol; colour is a hint only).
function cockpit_compat_badge(string $status): array {
    switch ($status) {
        case 'ok':            return ['label' => 'Ready',          'symbol' => '✓', 'cls' => 'ok'];
        case 'needs_install': return ['label' => 'Needs setup',    'symbol' => '⚠', 'cls' => 'warn'];
        case 'alternative':   return ['label' => 'Alt available',  'symbol' => '⇄', 'cls' => 'alt'];
        case 'unsupported':   return ['label' => 'Not supported',  'symbol' => '✗', 'cls' => 'bad'];
        default:              return ['label' => 'Unknown',        'symbol' => '—', 'cls' => 'unknown'];
    }
}

// Resolve an object's compatibility against THIS host.
// Returns: ['status','reason','missing'=>[binaries],'alternative'=>?,'badge'=>[…]]
function cockpit_object_compat(array $obj): array {
    $plat = cockpit_platform_profile();
    $os   = $plat['os'];
    $arch = $plat['arch'];
    $o    = cockpit_object_with_meta($obj);

    $mk = function (string $status, string $reason = '', array $extra = []) {
        return array_merge([
            'status'      => $status,
            'reason'      => $reason,
            'missing'     => [],
            'alternative' => null,
            'badge'       => cockpit_compat_badge($status),
        ], $extra);
    };

    // 1. Explicit per-OS override wins.
    $compat = $o['compatibility'];
    if (is_array($compat) && isset($compat[$os]) && is_string($compat[$os])) {
        $st = $compat[$os];
        if (!in_array($st, ['ok', 'needs_install', 'unsupported', 'alternative'], true)) $st = 'unknown';
        return $mk($st, 'declared compatibility for ' . $os);
    }

    $req = $o['requirements'];

    // Helper: find an alternative entry for this OS.
    $altFor = null;
    foreach ($o['alternatives'] as $alt) {
        if (is_array($alt) && (($alt['os'] ?? '') === $os || ($alt['os'] ?? '') === '*')) { $altFor = $alt; break; }
    }

    // 2. OS requirement.
    if (!empty($req['os']) && is_array($req['os']) && !in_array($os, $req['os'], true)) {
        if ($altFor) return $mk('alternative', 'runs on ' . implode('/', $req['os']) . '; alternative provided for ' . $os, ['alternative' => $altFor]);
        return $mk('unsupported', 'requires OS ' . implode('/', $req['os']) . ' (host is ' . $os . ')');
    }

    // 3. Arch requirement.
    if (!empty($req['arch']) && is_array($req['arch']) && !in_array($arch, $req['arch'], true)) {
        if ($altFor) return $mk('alternative', 'requires arch ' . implode('/', $req['arch']) . '; alternative provided', ['alternative' => $altFor]);
        return $mk('unsupported', 'requires arch ' . implode('/', $req['arch']) . ' (host is ' . $arch . ')');
    }

    // 4. Required binaries present?
    $missing = [];
    foreach (($req['binaries'] ?? []) as $bin) {
        if (!is_string($bin) || $bin === '') continue;
        if (!cockpit_find_binary($bin)) $missing[] = $bin;
    }
    if ($missing) {
        return $mk('needs_install', 'missing: ' . implode(', ', $missing), ['missing' => $missing, 'alternative' => $altFor]);
    }

    // 5. Default: compatible.
    return $mk('ok', 'all requirements satisfied on ' . $os);
}
