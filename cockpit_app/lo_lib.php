<?php
// =============================================================================
// lo_lib.php — LibreOffice headless conversions for the command-line tools (slides_tool, later office_tool). Never reachable over the web.
//
//   lo_convert(string $in, string $target, string $out, int $timeout = 300): ?string      null = done, else the reason it failed
//       $target is an extension ("pdf", "docx") or "ext:Filter Name" ("xlsm:Calc MS Excel 2007 VBA XML"). The result is moved to $out.
//
// Every conversion runs in a THROW-AWAY profile (-env:UserInstallation) with macro security at its maximum and VBA execution off: opening an untrusted
// document to convert it cannot run its macros, and the user's own LibreOffice profile (settings, recent files, a LibreOffice window that is open) is
// never touched or locked.
// =============================================================================
if (PHP_SAPI !== 'cli') { http_response_code(403); exit; }

function lo_find(): ?string {
    foreach (['soffice', 'libreoffice'] as $b) { $p = trim((string)shell_exec('command -v ' . $b . ' 2>/dev/null')); if ($p !== '') return $p; }
    foreach (['/usr/bin/soffice', '/usr/lib/libreoffice/program/soffice', '/opt/libreoffice/program/soffice', '/Applications/LibreOffice.app/Contents/MacOS/soffice'] as $p) if (is_executable($p)) return $p;
    return null;
}

/** a fresh profile folder with macros locked down; returns its path */
function lo_profile(string $tmp): string {
    $p = "$tmp/profile"; @mkdir("$p/user", 0700, true);
    $item = fn($path, $name, $val) => '<item oor:path="' . $path . '"><prop oor:name="' . $name . '" oor:op="fuse"><value>' . $val . '</value></prop></item>';
    $x = '<?xml version="1.0" encoding="UTF-8"?><oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
       . $item('/org.openoffice.Office.Common/Security/Scripting', 'MacroSecurityLevel', '3')              // very high: only signed macros from trusted places
       . $item('/org.openoffice.Office.Common/Security/Scripting', 'DisableMacrosExecution', 'true')
       . $item('/org.openoffice.Office.Common/Security/Scripting', 'BlockUntrustedRefererLinks', 'true')
       . $item('/org.openoffice.Office.Calc/Filter/Import/VBA', 'Executable', 'false')
       . $item('/org.openoffice.Office.Writer/Filter/Import/VBA', 'Executable', 'false')
       . $item('/org.openoffice.Office.Impress/Filter/Import/VBA', 'Executable', 'false')
       . $item('/org.openoffice.Office.Common/Misc', 'FirstRun', 'false')
       . '</oor:items>';
    file_put_contents("$p/user/registrymodifications.xcu", $x);
    return $p;
}

function lo_rmtree(string $d): void {
    if (!is_dir($d) || strpos(basename($d), 'lo_') !== 0) return;       // only ever our own lo_<pid> folders
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($d, FilesystemIterator::SKIP_DOTS), RecursiveIteratorIterator::CHILD_FIRST);
    foreach ($it as $f) { $f->isDir() && !$f->isLink() ? @rmdir($f->getPathname()) : @unlink($f->getPathname()); }
    @rmdir($d);
}

function lo_convert(string $in, string $target, string $out, int $timeout = 300): ?string {
    $so = lo_find(); if (!$so) return 'LibreOffice is not installed (sudo apt install libreoffice-writer libreoffice-calc libreoffice-impress)';
    if (!is_file($in)) return "no such file: $in";
    $tmp = sys_get_temp_dir() . '/lo_' . getmypid() . '_' . mt_rand(1000, 9999); @mkdir($tmp, 0700, true);
    $ext = explode(':', $target, 2)[0];
    $src = "$tmp/in." . strtolower(pathinfo($in, PATHINFO_EXTENSION)); copy($in, $src);        // a plain name: no odd characters reach the command line
    $profile = lo_profile($tmp); $o = []; $rc = 0;
    $cmd = 'timeout ' . (int)$timeout . ' ' . escapeshellarg($so) . ' -env:UserInstallation=file://' . $profile . ' --headless --norestore --nologo --convert-to ' . escapeshellarg($target) . ' --outdir ' . escapeshellarg("$tmp/out") . ' ' . escapeshellarg($src) . ' 2>&1';
    exec($cmd, $o, $rc);
    $res = "$tmp/out/in.$ext"; $err = null;
    if (!is_file($res) || filesize($res) === 0) $err = ($rc === 124 ? 'LibreOffice took longer than ' . $timeout . ' s and was stopped' : 'LibreOffice could not convert it' . ($o ? ': ' . trim(implode(' ', array_slice($o, -2))) : ''));
    else { if (!@rename($res, $out)) { copy($res, $out); } }
    lo_rmtree($tmp);
    return $err;
}
