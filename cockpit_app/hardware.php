<?php
// =============================================================================
// hardware.php — this machine's hardware for the top bar (CPU, RAM, GPU, VRAM).
// GET → the cached hardware_scan.sh result (see vram_lib.php hw_scan()).
// Read-only. The rig line used to be a literal in index.html — every install
// showed the author's i5/RX 6500 XT — so this is what fills it now.
// =============================================================================
header('Content-Type: application/json');
header('Cache-Control: no-store');
// Local app authentication, like every other backend (saas.php lesson).
require_once __DIR__ . '/auth.php';
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/vram_lib.php';
// ── The machine's software, ahead of the hardware: OS name + version, desktop
// (window manager), terminal app and file manager — the same candidates the
// toolbar launchers use (launch_apps.json choice first, else the first installed).
function hw_os_info(): array {
    global $PATHS;
    $o = ['name' => '', 'version' => '', 'desktop' => '', 'terminal' => '', 'files' => ''];
    $rel = @parse_ini_file('/etc/os-release');
    if (is_array($rel)) {
        $o['name']    = (string)($rel['NAME'] ?? $rel['PRETTY_NAME'] ?? '');
        $o['version'] = (string)($rel['VERSION_ID'] ?? $rel['VERSION'] ?? '');
        if ($o['name'] === '' && PHP_OS_FAMILY === 'Darwin') $o['name'] = 'macOS';
    } elseif (PHP_OS_FAMILY === 'Darwin') { $o['name'] = 'macOS'; $o['version'] = trim((string)@shell_exec('sw_vers -productVersion 2>/dev/null')); }
    // desktop: what cockpit_start.sh saw inside the session (Apache has no session env)
    $home = rtrim((string)($PATHS['home'] ?? ''), '/');
    $senv = $home . '/scripts/cockpit_data/session_env';
    foreach ((is_readable($senv) ? file($senv, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) : []) as $l) {
        if (preg_match('/^XDG_CURRENT_DESKTOP=([\x21-\x7e]{1,60})$/', $l, $m)) { $o['desktop'] = preg_replace('/^X-/', '', $m[1]); break; }
    }
    if ($o['desktop'] === '') foreach (['XDG_CURRENT_DESKTOP', 'DESKTOP_SESSION'] as $k) { $v = (string)getenv($k); if ($v !== '') { $o['desktop'] = preg_replace('/^X-/', '', $v); break; } }
    $which = function (array $names): string { foreach ($names as $n) { $p = trim((string)@shell_exec('command -v ' . escapeshellarg($n) . ' 2>/dev/null')); if ($p !== '') return basename($p); } return ''; };
    $cfg = @json_decode((string)@file_get_contents(($PATHS['cockpit_data'] ?? '') . '/launch_apps.json'), true) ?: [];
    $o['terminal'] = ($cfg['terminal'] ?? '') !== '' ? basename((string)$cfg['terminal']) : $which(['gnome-terminal','ptyxis','kgx','konsole','xfce4-terminal','mate-terminal','tilix','kitty','alacritty','xterm']);
    $o['files']    = ($cfg['files'] ?? '') !== '' ? basename((string)$cfg['files']) : $which(['nemo','nautilus','dolphin','thunar','pcmanfm','caja']);
    return $o;
}
// The hosted demo runs on a web host with no hardware_scan.sh: show a plain
// "demo machine" line instead of "hardware: unknown".
$hw = ed_is('demo')
    ? ['ok' => true, 'os' => 'linux', 'cpu_cores' => 8, 'cpu_model' => 'Demo machine', 'ram_mb' => 16384, 'gpu_name' => 'Demo GPU', 'gpu_vram_mb' => 8192]
    : hw_scan();
echo json_encode(['ok' => !empty($hw), 'hw' => $hw, 'os' => ed_is('demo') ? ['name' => 'Demo OS', 'version' => '', 'desktop' => 'Web', 'terminal' => '', 'files' => ''] : hw_os_info()], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
