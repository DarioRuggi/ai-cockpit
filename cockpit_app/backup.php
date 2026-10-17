<?php
// =============================================================================
// backup.php — Backup, restore-test and restore of everything Cockpit keeps for one user.
//
//   GET  ?action=status                list of backups + what a new one would contain (sizes)
//   GET  ?action=download&file=NAME    stream one backup (a plain .tar.gz anyone can open)
//   POST {action:'create',  groups:{chats,library,settings,generated,keys}}
//   POST {action:'verify',  file}      restore into a scratch folder, compare every file's sha256
//                                      with the manifest, delete the scratch folder, report
//   POST {action:'restore', file, confirm:true}   put it back; a "pre-restore" backup of the
//                                      current state is made first, so a restore can be undone
//   POST {action:'delete',  file}
//
// An archive holds   manifest.json   (format version, what is inside, a sha256 per file)
//                    data/           the user's cockpit_data  (settings, library, chats' index, ...)
//                    projects/       the user's projects folder (chats, project files)
// It is an ordinary tar.gz: nothing here is needed to read it.
//
// Left out on purpose (rebuildable or huge): venv*, install_src, the Shelf index (tens of GB
// worth of derived data), cached language packs, earlier backups. API keys / the account file
// are left out unless the person ticks "keys" — they are encrypted at rest but are the one thing
// people forget they copied.
//
// DATA FORMAT VERSION: archives carry data_version. When a future build changes how data is
// stored it adds a step to backup_migrations(); a restore of an older archive runs the steps
// in order. Today there are none (data_version 1 is the first), and the manifest says so.
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

ed_gate_or_exit('export');

const BACKUP_FORMAT = 1;
const BACKUP_DATA_VERSION = 1;

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
if (session_status() === PHP_SESSION_ACTIVE) session_write_close();
@set_time_limit(0);

$DATA = rtrim($PATHS['cockpit_data'], '/');
$PROJ = rtrim($PATHS['projects_root'], '/');
$DIR  = $DATA . '/backups';

function bk_out(array $a, int $code = 200): void { http_response_code($code); echo json_encode($a, JSON_UNESCAPED_UNICODE); exit; }
function bk_name_ok(string $f): bool { return (bool)preg_match('/^cockpit-backup-[0-9]{8}-[0-9]{6}(-pre-restore)?\.tar\.gz$/', $f); }

/** The migration steps, oldest first: from_version => function(string $dataRoot): void. None yet. */
function backup_migrations(): array { return []; }

/** Directories/patterns that never go in. Relative to the data root. */
function bk_excludes(array $groups): array {
    $x = ['venv', 'venv-aider', 'install_src', 'backups', 'libretranslate_cached', 'libretranslate_langs',
          'users/*/shelf', 'shelf', 'models_dev.json', 'session_env', '*.lock', 'relay_poller.log', 'guard.log'];
    if (empty($groups['generated'])) { $x[] = 'generated'; $x[] = 'users/*/generated'; }
    if (empty($groups['keys']))      { $x = array_merge($x, ['workers_keys.enc', '*_api_key.txt', 'saas_account.json', 'combos_store.enc', 'users/*/combos_store.enc']); }
    if (empty($groups['library']))   { $x = array_merge($x, ['library', 'library_text', 'library_index.json', 'snippets', 'sources', 'books', 'users/*/library*', 'users/*/books']); }
    return $x;
}

function bk_walk(string $root, array $ex, string $prefix = ''): Generator {
    if (!is_dir($root)) return;
    $it = new RecursiveIteratorIterator(new RecursiveCallbackFilterIterator(
        new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS),
        function ($f) use ($root, $ex) {
            $rel = ltrim(substr($f->getPathname(), strlen($root)), '/');
            foreach ($ex as $pat) if (fnmatch($pat, $rel) || fnmatch($pat, $f->getFilename()) && strpos($pat, '/') === false) return false;
            return !$f->isLink();
        }));
    foreach ($it as $f) if ($f->isFile()) yield $prefix . ltrim(substr($f->getPathname(), strlen($root)), '/') => $f->getPathname();
}

function bk_size_label(int $b): string { return $b > 1048576 ? round($b / 1048576, 1) . ' MB' : round($b / 1024) . ' KB'; }

function bk_list(string $dir): array {
    $r = [];
    foreach ((array)glob($dir . '/cockpit-backup-*.tar.gz') as $f) {
        $m = @json_decode((string)@file_get_contents($f . '.json'), true) ?: [];
        $r[] = ['file' => basename($f), 'bytes' => filesize($f), 'size' => bk_size_label(filesize($f)), 'made' => gmdate('c', filemtime($f)),
                'files' => $m['files'] ?? null, 'groups' => $m['groups'] ?? null, 'verified' => $m['verified'] ?? null,
                'pre_restore' => (bool)preg_match('/-pre-restore\.tar\.gz$/', $f)];
    }
    usort($r, fn($a, $b) => strcmp($b['made'], $a['made']));
    return $r;
}

function bk_rmtree(string $d): void {
    if (!is_dir($d) || is_link($d)) return;
    foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator($d, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST) as $f)
        $f->isDir() && !$f->isLink() ? @rmdir($f->getPathname()) : @unlink($f->getPathname());
    @rmdir($d);
}

function bk_create(array $groups, string $suffix = ''): array {
    global $DATA, $PROJ, $DIR;
    if (!is_dir($DIR) && !@mkdir($DIR, 0775, true)) return ['ok' => false, 'error' => 'cannot create ' . $DIR];
    $ex = bk_excludes($groups);
    $stage = $DIR . '/.stage-' . bin2hex(random_bytes(4));
    if (!@mkdir($stage, 0775, true)) return ['ok' => false, 'error' => 'cannot create a staging folder'];
    @mkdir("$stage/tree", 0775, true);
    $files = []; $bytes = 0;
    foreach ([bk_walk($DATA, $ex, 'data/'), bk_walk($PROJ, ['*.lock', 'node_modules', '.git'], 'projects/')] as $gen)
        foreach ($gen as $rel => $abs) {
            if ($rel === 'projects/' || strpos($abs, $DIR . '/') === 0) continue;
            $h = @hash_file('sha256', $abs); if ($h === false) continue;
            $files[$rel] = ['sha256' => $h, 'bytes' => filesize($abs)]; $bytes += filesize($abs);
            @mkdir(dirname("$stage/tree/$rel"), 0775, true); @symlink($abs, "$stage/tree/$rel");
        }
    $manifest = ['format' => BACKUP_FORMAT, 'data_version' => BACKUP_DATA_VERSION, 'made' => gmdate('c'),
                 'build' => (string)(@json_decode((string)@file_get_contents(__DIR__ . '/manifest.json'), true)['build'] ?? ''),
                 'groups' => $groups, 'files' => count($files), 'bytes' => $bytes,
                 'note' => 'Plain tar.gz. data/ = cockpit_data, projects/ = the projects folder. sha256 per file below.',
                 'entries' => $files];
    file_put_contents("$stage/tree/manifest.json", json_encode($manifest, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
    $name = 'cockpit-backup-' . gmdate('Ymd-His') . $suffix . '.tar.gz';
    $out = [];
    exec('tar -chzf ' . escapeshellarg("$DIR/$name") . ' -C ' . escapeshellarg("$stage/tree") . ' . 2>&1', $out, $rc);
    bk_rmtree($stage);
    if ($rc !== 0 || !is_file("$DIR/$name")) { @unlink("$DIR/$name"); return ['ok' => false, 'error' => 'tar failed: ' . implode(' ', array_slice($out, 0, 3))]; }
    @chmod("$DIR/$name", 0640);
    $meta = ['files' => count($files), 'bytes' => $bytes, 'groups' => $groups, 'verified' => null];
    file_put_contents("$DIR/$name.json", json_encode($meta));
    return ['ok' => true, 'file' => $name, 'files' => count($files), 'size' => bk_size_label(filesize("$DIR/$name"))];
}

/** Extract $file into a fresh scratch folder; returns [scratchPath|null, manifest|null, error|null]. Checks member names first. */
function bk_extract(string $file): array {
    global $DIR;
    $path = "$DIR/$file";
    if (!bk_name_ok($file) || !is_file($path)) return [null, null, 'no such backup'];
    $list = []; exec('tar -tvzf ' . escapeshellarg($path) . ' 2>&1', $list, $rc);
    if ($rc !== 0) return [null, null, 'the archive is damaged (gzip/tar could not read it)'];
    foreach ($list as $l) {
        if ($l !== '' && ($l[0] === 'l' || $l[0] === 'h' || strpos($l, '../') !== false))
            return [null, null, 'refusing an archive with links or paths that escape it'];
    }
    $scratch = $DIR . '/.verify-' . bin2hex(random_bytes(4));
    @mkdir($scratch, 0775, true);
    $o = []; exec('tar -xzf ' . escapeshellarg($path) . ' --no-same-owner -C ' . escapeshellarg($scratch) . ' 2>&1', $o, $rc);
    if ($rc !== 0) { bk_rmtree($scratch); return [null, null, 'extract failed: ' . implode(' ', array_slice($o, 0, 2))]; }
    $m = @json_decode((string)@file_get_contents("$scratch/manifest.json"), true);
    if (!is_array($m)) { bk_rmtree($scratch); return [null, null, 'no manifest.json inside — not a Cockpit backup']; }
    return [$scratch, $m, null];
}

function bk_check(string $scratch, array $m): array {
    $bad = []; $n = 0;
    foreach (($m['entries'] ?? []) as $rel => $e) {
        $n++; $p = "$scratch/$rel";
        if (!is_file($p)) { $bad[] = "missing: $rel"; continue; }
        if (hash_file('sha256', $p) !== $e['sha256']) $bad[] = "different: $rel";
    }
    return [$n, $bad];
}

$in = json_decode((string)file_get_contents('php://input'), true);
if (!is_array($in)) $in = [];
$action = (string)($_GET['action'] ?? ($in['action'] ?? 'status'));
$file = basename((string)($_GET['file'] ?? ($in['file'] ?? '')));

if ($action === 'status') {
    $g = ['chats' => true, 'library' => true, 'settings' => true, 'generated' => false, 'keys' => false];
    $ex = bk_excludes($g); $n = 0; $b = 0;
    foreach ([bk_walk($DATA, $ex, 'data/'), bk_walk($PROJ, ['*.lock', 'node_modules', '.git'], 'projects/')] as $gen)
        foreach ($gen as $rel => $abs) { $n++; $b += (int)@filesize($abs); }
    bk_out(['ok' => true, 'backups' => bk_list($DIR), 'would_contain' => ['files' => $n, 'size' => bk_size_label($b)],
            'dir' => $DIR, 'format' => BACKUP_FORMAT, 'data_version' => BACKUP_DATA_VERSION]);
}
if ($action === 'download') {
    if (!bk_name_ok($file) || !is_file("$DIR/$file")) bk_out(['ok' => false, 'error' => 'no such backup'], 404);
    header('Content-Type: application/gzip'); header('Content-Disposition: attachment; filename="' . $file . '"');
    header('Content-Length: ' . filesize("$DIR/$file")); readfile("$DIR/$file"); exit;
}

auth_require_writer();

if ($action === 'create') {
    $g = $in['groups'] ?? [];
    $groups = ['chats' => true, 'library' => !isset($g['library']) || !empty($g['library']), 'settings' => true,
               'generated' => !empty($g['generated']), 'keys' => !empty($g['keys'])];
    bk_out(bk_create($groups));
}
if ($action === 'verify') {
    [$scratch, $m, $err] = bk_extract($file);
    if ($err) bk_out(['ok' => false, 'error' => $err]);
    [$n, $bad] = bk_check($scratch, $m); bk_rmtree($scratch);
    $meta = @json_decode((string)@file_get_contents("$DIR/$file.json"), true) ?: [];
    $meta['verified'] = ['at' => gmdate('c'), 'files' => $n, 'ok' => !$bad];
    file_put_contents("$DIR/$file.json", json_encode($meta));
    bk_out(['ok' => !$bad, 'files' => $n, 'problems' => array_slice($bad, 0, 10), 'data_version' => $m['data_version'] ?? null,
            'message' => $bad ? count($bad) . ' file(s) did not come back identical' : "restored $n files into a scratch folder and every one matched its checksum; scratch folder deleted"]);
}
if ($action === 'restore') {
    if (empty($in['confirm'])) bk_out(['ok' => false, 'error' => 'confirm required'], 400);
    [$scratch, $m, $err] = bk_extract($file);
    if ($err) bk_out(['ok' => false, 'error' => $err]);
    if ((int)($m['data_version'] ?? 0) > BACKUP_DATA_VERSION) { bk_rmtree($scratch); bk_out(['ok' => false, 'error' => 'this backup comes from a newer Cockpit (data version ' . $m['data_version'] . '); update Cockpit first']); }
    [$n, $bad] = bk_check($scratch, $m);
    if ($bad) { bk_rmtree($scratch); bk_out(['ok' => false, 'error' => 'the backup failed its own checksums; nothing was changed', 'problems' => array_slice($bad, 0, 10)]); }
    $pre = bk_create(is_array($m['groups'] ?? null) ? $m['groups'] : [], '-pre-restore');
    if (empty($pre['ok'])) { bk_rmtree($scratch); bk_out(['ok' => false, 'error' => 'could not make the safety backup first, so nothing was changed: ' . ($pre['error'] ?? '')]); }
    $steps = [];
    foreach (backup_migrations() as $from => $fn) if ($from >= (int)($m['data_version'] ?? 1)) { $fn("$scratch/data"); $steps[] = $from; }
    $o = []; $fails = 0;
    foreach (['data' => $DATA, 'projects' => $PROJ] as $sub => $dest) {
        if (!is_dir("$scratch/$sub")) continue;
        exec('cp -a ' . escapeshellarg("$scratch/$sub") . '/. ' . escapeshellarg($dest) . '/ 2>&1', $o, $rc); if ($rc !== 0) $fails++;
    }
    bk_rmtree($scratch);
    bk_out(['ok' => !$fails, 'restored' => $n, 'safety_backup' => $pre['file'], 'migrations_run' => $steps,
            'message' => $fails ? 'some files could not be written (permissions?): ' . implode(' ', array_slice($o, 0, 2)) : "restored $n files. The state before is saved as {$pre['file']} — restore that to undo."]);
}
if ($action === 'delete') {
    if (!bk_name_ok($file) || !is_file("$DIR/$file")) bk_out(['ok' => false, 'error' => 'no such backup']);
    @unlink("$DIR/$file"); @unlink("$DIR/$file.json"); bk_out(['ok' => true]);
}
bk_out(['ok' => false, 'error' => 'unknown action'], 400);
