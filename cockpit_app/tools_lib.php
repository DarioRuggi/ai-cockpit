<?php
// tools_lib.php — what the tool code and the project-kind code share: where a tool's program is, how to install it, and where its definition is.
// (Moved out of tools.php, which runs an endpoint when it is included, so that files.php can ask "is this kind's tool installed?".)
if (defined('CK_TOOLS_LIB')) return;
define('CK_TOOLS_LIB', 1);

// Look up the resolved binary path for a tool — checks state override first,
// then $PATH (via `command -v`), then known absolute paths.
function resolve_binary($tool, $state) {
    $tid = $tool['id'];
    // 1. User override in state
    if (!empty($state['tools'][$tid]['binary_override'])) {
        $bin = $state['tools'][$tid]['binary_override'];
        if (is_executable($bin)) return $bin;
    }
    // 2. command -v on the canonical name
    $name = $tool['binary'] ?? $tid;
    $resolved = trim((string)shell_exec('command -v ' . escapeshellarg($name) . ' 2>/dev/null'));
    if ($resolved && is_executable($resolved)) return $resolved;
    // 3. Try common absolute paths (OS-aware via paths.php)
    switch (COCKPIT_OS) {
        case 'macos':   $search = ['/opt/homebrew/bin/', '/usr/local/bin/', '/usr/bin/']; break;
        case 'android': $search = [getenv('PREFIX') . '/bin/']; break;
        default:        $search = ['/usr/bin/', '/usr/local/bin/', '/opt/bin/']; break;
    }
    foreach ($search as $p) {
        if (is_executable($p . $name)) return $p . $name;
    }
    // 4. Fetched without root into the owner's home (docs/user_space_tools.md): ~/.local/share/cockpit/tools/<id>/<name>, or ~/.local/bin
    global $PATHS;
    $home = rtrim((string)($PATHS['home'] ?? getenv('HOME') ?: ''), '/');
    if ($home !== '' && preg_match('/^[A-Za-z0-9._-]+$/', $name)) {
        $cands = ["$home/.local/share/cockpit/tools/$tid/$name", "$home/.local/bin/$name"];
        // an unpacked release keeps its binary in <tool>/<release folder>/bin/ (the Castle Game Engine)
        if (preg_match('/^[A-Za-z0-9_-]+$/', $tid)) foreach ((array)glob("$home/.local/share/cockpit/tools/$tid/*/bin/$name") as $g) $cands[] = $g;
        foreach ($cands as $p) {
            if (is_executable($p)) return $p;
        }
    }
    return null;
}

// Install hint for a missing binary: the tool definition's `packages` map keyed
// by package manager, resolved against whichever manager this rig has; else the
// definition's `install_note`; else its website. Cockpit never runs the
// install itself (Apache has no sudo) — it shows the exact line to run.
function tools_install_hint(array $tool): string {
    $pk = is_array($tool['packages'] ?? null) ? $tool['packages'] : [];
    $mgrs = [
        'apt'    => ['apt-get', 'sudo apt install %s'],
        'dnf'    => ['dnf',     'sudo dnf install %s'],
        'pacman' => ['pacman',  'sudo pacman -S %s'],
        'zypper' => ['zypper',  'sudo zypper install %s'],
        'apk'    => ['apk',     'sudo apk add %s'],
        'brew'   => ['brew',    'brew install %s'],
    ];
    foreach ($mgrs as $key => [$bin, $fmt]) {
        if (empty($pk[$key])) continue;
        if (trim((string)shell_exec('command -v ' . escapeshellarg($bin) . ' 2>/dev/null')) === '') continue;
        return sprintf($fmt, $pk[$key]);
    }
    if (!empty($tool['install_note'])) return (string)$tool['install_note'];
    if (!empty($tool['website']))      return 'See ' . $tool['website'];
    return 'Install "' . ($tool['binary'] ?? $tool['id']) . '" and make sure it is on the PATH, or set the binary override in Tools settings.';
}

/** The definition of tool $id: shipped (tools_builtins/ID.json) or the user's own (<data>/tools/ID.json); null when there is none. */
function tools_def_find(string $id, string $dataDir, string $shipDir): ?array {
    if (!preg_match('/^[a-z][a-z0-9_-]{0,63}$/', $id)) return null;
    foreach ([rtrim($shipDir, '/') . '/' . $id . '.json', rtrim($dataDir, '/') . '/tools/' . $id . '.json'] as $f) {
        if (!is_file($f)) continue;
        $j = json_decode((string)@file_get_contents($f), true);
        if (is_array($j)) { $j['id'] = $j['id'] ?? $id; return $j; }
    }
    return null;
}
