<?php
// =============================================================================
// vba_lib.php — read and write the container of Visual Basic for Applications macros, in plain PHP (no Office, no Python):
//   * MS-OVBA compression      ovba_compress / ovba_decompress
//   * OLE2 compound files      cfb_parse (every stream by path) / cfb_build (a tree of storages and streams)
//   * the VBA project          vba_extract (modules and their source out of a vbaProject.bin or a .doc/.xls) / vba_build (modules in)
// A library for the command-line tools (vba_tool); never reachable over the web.
// Formats: [MS-CFB] and [MS-OVBA]. Source text is kept as the bytes of the project's code page (default Windows-1252): a caller converts to and from UTF-8.
// =============================================================================
if (PHP_SAPI !== 'cli') { http_response_code(403); exit; }

// ---- MS-OVBA compression ---------------------------------------------------------------------------------------------------------------------
function ovba_bitcount(int $pos): int { $b = 4; while ((1 << $b) < $pos) $b++; return min($b, 12); }

function ovba_decompress(string $c): string {
    if ($c === '' || $c[0] !== "\x01") return '';
    $out = ''; $i = 1; $n = strlen($c);
    while ($i + 2 <= $n) {
        $h = ord($c[$i]) | (ord($c[$i + 1]) << 8); $size = ($h & 0x0FFF) + 3; $comp = ($h & 0x8000) !== 0; $end = min($i + $size, $n); $i += 2;
        $chunkStart = strlen($out);
        if (!$comp) { $out .= substr($c, $i, 4096); $i = $end; continue; }
        while ($i < $end) {
            $flags = ord($c[$i++]);
            for ($bit = 0; $bit < 8 && $i < $end; $bit++) {
                if (!($flags & (1 << $bit))) { $out .= $c[$i++]; continue; }
                if ($i + 2 > $end) { $i = $end; break; }
                $tok = ord($c[$i]) | (ord($c[$i + 1]) << 8); $i += 2;
                $bc = ovba_bitcount(strlen($out) - $chunkStart); $lenMask = 0xFFFF >> $bc; $len = ($tok & $lenMask) + 3; $off = (($tok & ~$lenMask & 0xFFFF) >> (16 - $bc)) + 1;
                $from = strlen($out) - $off; if ($from < $chunkStart) return $out;       // corrupt: stop with what we have
                for ($k = 0; $k < $len; $k++) $out .= $out[$from + $k];
            }
        }
        $i = $end;
    }
    return $out;
}

function ovba_compress(string $d): string {
    $out = "\x01"; $n = strlen($d); if ($n === 0) return $out;
    for ($p = 0; $p < $n || $p === 0; $p += 4096) {
        $chunk = substr($d, $p, 4096); $cl = strlen($chunk); $data = ''; $i = 0;
        while ($i < $cl) {
            $flag = 0; $tokens = '';
            for ($bit = 0; $bit < 8 && $i < $cl; $bit++) {
                $bc = ovba_bitcount($i); $maxLen = (0xFFFF >> $bc) + 3; $maxOff = 1 << $bc; $best = 0; $bestOff = 0;
                for ($j = max(0, $i - $maxOff); $j < $i; $j++) {
                    $l = 0; while ($l < $maxLen && $i + $l < $cl && $chunk[$j + $l] === $chunk[$i + $l]) $l++;       // may run on into the bytes being matched
                    if ($l > $best) { $best = $l; $bestOff = $i - $j; }
                }
                if ($best >= 3) { $flag |= 1 << $bit; $tok = (($bestOff - 1) << (16 - $bc)) | ($best - 3); $tokens .= chr($tok & 0xFF) . chr($tok >> 8); $i += $best; }
                else { $tokens .= $chunk[$i]; $i++; }
            }
            $data .= chr($flag) . $tokens;
        }
        if (strlen($data) <= 4095 && $cl > 0) { $h = (strlen($data) + 2 - 3) | 0x3000 | 0x8000; $out .= chr($h & 0xFF) . chr($h >> 8) . $data; }
        else { $h = (4096 + 2 - 3) | 0x3000; $out .= chr($h & 0xFF) . chr($h >> 8) . str_pad($chunk, 4096, "\0"); }       // an uncompressed chunk is always 4096 bytes
        if ($n === 0) break;
    }
    return $out;
}

// ---- OLE2 compound file: reading -------------------------------------------------------------------------------------------------------------
/** every stream of a compound file, by path ("VBA/dir", "PROJECT", ...). Returns null if it is not one. */
function cfb_parse(string $b): ?array {
    if (strlen($b) < 512 || substr($b, 0, 8) !== "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1") return null;
    $u16 = fn($o) => ord($b[$o]) | (ord($b[$o + 1]) << 8); $u32 = fn($o) => $u16($o) | ($u16($o + 2) << 16);
    $ss = 1 << $u16(30); $mss = 1 << $u16(32); $cutoff = $u32(56);
    $sec = fn($id) => substr($b, 512 * 0 + ($id + 1) * $ss, $ss);          // sector n starts at (n+1)*sectorSize (version 3: header is one sector; v4 pads it to 4096)
    if ($ss === 4096) $sec = fn($id) => substr($b, ($id + 1) * $ss, $ss);
    $difat = []; for ($k = 0; $k < 109; $k++) { $v = $u32(76 + 4 * $k); if ($v < 0xFFFFFFFA) $difat[] = $v; }
    $nextDif = $u32(68); $nDif = $u32(72);
    while ($nextDif < 0xFFFFFFFA && $nDif-- > 0) { $s = $sec($nextDif); for ($k = 0; $k < $ss / 4 - 1; $k++) { $v = unpack('V', substr($s, 4 * $k, 4))[1]; if ($v < 0xFFFFFFFA) $difat[] = $v; } $nextDif = unpack('V', substr($s, $ss - 4, 4))[1]; }
    $fat = []; foreach ($difat as $f) { foreach (unpack('V*', $sec($f)) as $v) $fat[] = $v; }
    $chain = function (int $start) use ($fat, $sec) { $o = ''; $seen = 0; while ($start < 0xFFFFFFFA && isset($fat[$start]) && $seen++ < 1000000) { $o .= $sec($start); $start = $fat[$start]; } return $o; };
    $dir = $chain($u32(48)); $ents = [];
    for ($o = 0; $o + 128 <= strlen($dir); $o += 128) {
        $e = substr($dir, $o, 128); $nl = unpack('v', substr($e, 64, 2))[1]; $type = ord($e[66]);
        if ($type === 0) { $ents[] = null; continue; }
        $ents[] = ['name' => mb_convert_encoding(substr($e, 0, max(0, $nl - 2)), 'UTF-8', 'UTF-16LE'), 'type' => $type, 'left' => unpack('V', substr($e, 68, 4))[1], 'right' => unpack('V', substr($e, 72, 4))[1], 'child' => unpack('V', substr($e, 76, 4))[1], 'start' => unpack('V', substr($e, 116, 4))[1], 'size' => unpack('V', substr($e, 120, 4))[1]];
    }
    if (!$ents || !$ents[0]) return null;
    $miniFat = []; foreach (unpack('V*', $chain($u32(60)) ?: '') ?: [] as $v) $miniFat[] = $v;
    $mini = $chain($ents[0]['start']); $mini = substr($mini, 0, $ents[0]['size']);
    $read = function (array $e) use ($chain, $miniFat, $mini, $cutoff, $mss) {
        if ($e['size'] < $cutoff) { $o = ''; $s = $e['start']; $g = 0; while ($s < 0xFFFFFFFA && $g++ < 1000000) { $o .= substr($mini, $s * $mss, $mss); $s = $miniFat[$s] ?? 0xFFFFFFFE; } return substr($o, 0, $e['size']); }
        return substr($chain($e['start']), 0, $e['size']);
    };
    $res = [];
    $walk = function (int $id, string $prefix) use (&$walk, &$res, $ents, $read) {
        if ($id >= count($ents) || $ents[$id] === null) return;
        $e = $ents[$id]; $walk($e['left'], $prefix); $walk($e['right'], $prefix);
        $path = $prefix . $e['name'];
        if ($e['type'] === 2) $res[$path] = $read($e); elseif ($e['type'] === 1) $walk($e['child'], $path . '/');
    };
    $walk($ents[0]['child'], '');
    return $res;
}

// ---- OLE2 compound file: writing -------------------------------------------------------------------------------------------------------------
/** $tree: list of nodes ['name'=>..., 'data'=>string] (a stream) or ['name'=>..., 'children'=>[...]] (a storage). Builds a version-3 file with 512-byte sectors. */
function cfb_build(array $tree): string {
    // assign indexes depth-first, children lists kept for the tree links
    $assign = function (array $nodes) use (&$assign, &$ents): array {
        $ids = [];
        foreach ($nodes as $nd) {
            $idx = count($ents); $isStore = isset($nd['children']);
            $ents[] = ['name' => $nd['name'], 'type' => $isStore ? 1 : 2, 'data' => $nd['data'] ?? '', 'kids' => [], 'idx' => $idx, 'child' => -1, 'left' => -1, 'right' => -1];
            if ($isStore) $ents[$idx]['kidids'] = $assign($nd['children']);
            $ids[] = $idx;
        }
        return $ids;
    };
    $ents = [['name' => 'Root Entry', 'type' => 5, 'data' => '', 'idx' => 0, 'child' => -1, 'left' => -1, 'right' => -1]];
    $ents[0]['kidids'] = $assign($tree);
    // a balanced search tree of each storage's children, ordered by name length then upper-cased name (the compound-file rule)
    $cmpKey = fn($i) => [strlen(mb_convert_encoding($ents[$i]['name'], 'UTF-16LE', 'UTF-8')), mb_strtoupper($ents[$i]['name'])];
    $buildTree = function (array $ids) use (&$buildTree, &$ents, $cmpKey) {
        if (!$ids) return -1;
        usort($ids, function ($a, $b) use ($cmpKey) { [$la, $na] = $cmpKey($a); [$lb, $nb] = $cmpKey($b); return $la <=> $lb ?: strcmp(mb_convert_encoding($na, 'UTF-16BE', 'UTF-8'), mb_convert_encoding($nb, 'UTF-16BE', 'UTF-8')); });
        $mid = intdiv(count($ids), 2); $root = $ids[$mid];
        $ents[$root]['left'] = $buildTree(array_slice($ids, 0, $mid)); $ents[$root]['right'] = $buildTree(array_slice($ids, $mid + 1));
        return $root;
    };
    foreach ($ents as $k => $e) if (isset($e['kidids'])) $ents[$k]['child'] = $buildTree($e['kidids']);
    // streams: small ones (< 4096) in the mini stream, the rest in ordinary sectors
    $mini = ''; $miniFat = []; $regular = [];       // $regular: idx => data
    foreach ($ents as $k => $e) {
        if ($e['type'] !== 2) continue;
        $len = strlen($e['data']);
        if ($len === 0) { $ents[$k]['start'] = 0xFFFFFFFE; continue; }
        if ($len < 4096) {
            $ents[$k]['start'] = intdiv(strlen($mini), 64); $cnt = intdiv($len + 63, 64);
            for ($m = 0; $m < $cnt; $m++) $miniFat[] = ($m === $cnt - 1) ? 0xFFFFFFFE : intdiv(strlen($mini), 64) + $m + 1;
            $mini .= str_pad($e['data'], $cnt * 64, "\0");
        } else $regular[$k] = $e['data'];
    }
    $sectors = [];                                  // list of 512-byte strings; ids assigned in order
    $addChain = function (string $data) use (&$sectors): int {
        $cnt = max(1, intdiv(strlen($data) + 511, 512)); $first = count($sectors);
        for ($m = 0; $m < $cnt; $m++) $sectors[] = str_pad(substr($data, $m * 512, 512), 512, "\0");
        return $first;                                // consecutive: the FAT below chains first..first+cnt-1
    };
    $chains = [];                                   // [first, count] for the FAT
    foreach ($regular as $k => $data) { $f = $addChain($data); $ents[$k]['start'] = $f; $chains[] = [$f, intdiv(strlen($data) + 511, 512)]; }
    $miniStart = 0xFFFFFFFE; $miniSecCount = 0;
    if ($mini !== '') { $f = $addChain($mini); $ents[0]['start'] = $f; $ents[0]['size'] = strlen($mini); $chains[] = [$f, intdiv(strlen($mini) + 511, 512)]; }
    else { $ents[0]['start'] = 0xFFFFFFFE; $ents[0]['size'] = 0; }
    if ($miniFat) { $mf = ''; foreach ($miniFat as $v) $mf .= pack('V', $v); $miniStart = $addChain($mf); $miniSecCount = intdiv(strlen($mf) + 511, 512); $chains[] = [$miniStart, $miniSecCount]; }
    $dirData = ''; foreach ($ents as $e) {
        $nm = mb_convert_encoding($e['name'], 'UTF-16LE', 'UTF-8'); $rec = str_pad($nm . "\0\0", 64, "\0") . pack('v', strlen($nm) + 2) . chr($e['type']) . "\x01" . pack('VVV', $e['left'] & 0xFFFFFFFF, $e['right'] & 0xFFFFFFFF, $e['child'] & 0xFFFFFFFF) . str_repeat("\0", 16) . pack('V', 0) . str_repeat("\0", 16) . pack('VVV', $e['start'] ?? 0, $e['size'] ?? ($e['type'] === 2 ? strlen($e['data']) : 0), 0);
        if ($e['type'] === 2) $rec = substr($rec, 0, 120) . pack('VV', strlen($e['data']), 0);
        $dirData .= str_pad(substr($rec, 0, 128), 128, "\0");
    }
    $dirFirst = $addChain($dirData); $chains[] = [$dirFirst, intdiv(strlen($dirData) + 511, 512)];
    // the FAT: one entry per sector, FAT sectors themselves marked 0xFFFFFFFD; grow the count until it fits
    $nonFat = count($sectors); $nFat = 1; while ($nFat * 128 < $nonFat + $nFat) $nFat++;
    if ($nFat > 109) fail_cfb('the project is too large for this writer');
    $fat = array_fill(0, $nFat * 128, 0xFFFFFFFF);
    foreach ($chains as [$f, $c]) for ($m = 0; $m < $c; $m++) $fat[$f + $m] = ($m === $c - 1) ? 0xFFFFFFFE : $f + $m + 1;
    for ($m = 0; $m < $nFat; $m++) $fat[$nonFat + $m] = 0xFFFFFFFD;
    $fatData = ''; foreach ($fat as $v) $fatData .= pack('V', $v);
    $hdr = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1" . str_repeat("\0", 16) . pack('vvvvv', 0x003E, 3, 0xFFFE, 9, 6) . str_repeat("\0", 6) . pack('V', 0) . pack('V', $nFat) . pack('V', $dirFirst) . pack('V', 0) . pack('V', 4096) . pack('V', $miniStart) . pack('V', $miniSecCount) . pack('V', 0xFFFFFFFE) . pack('V', 0);
    for ($m = 0; $m < 109; $m++) $hdr .= pack('V', $m < $nFat ? $nonFat + $m : 0xFFFFFFFF);
    return $hdr . implode('', $sectors) . $fatData;
}
function fail_cfb(string $m): void { fwrite(STDERR, "vba_lib: $m\n"); exit(1); }

// ---- the VBA project -------------------------------------------------------------------------------------------------------------------------
/** modules out of a vbaProject.bin (or a .doc/.xls compound file: the VBA storage is found wherever it is). Each: [name, type (std|class|document), source (code-page bytes), stream]. */
function vba_extract(string $bin): ?array {
    $st = cfb_parse($bin); if ($st === null) return null;
    $dirPath = null; foreach ($st as $p => $_) if (preg_match('~(^|/)VBA/dir$~', $p)) { $dirPath = $p; break; }
    if ($dirPath === null) return [];
    $base = substr($dirPath, 0, -strlen('VBA/dir')); $dir = ovba_decompress($st[$dirPath]); $n = strlen($dir); $i = 0; $mods = []; $codepage = 1252;
    while ($i + 6 <= $n) {
        $id = unpack('v', substr($dir, $i, 2))[1]; $sz = unpack('V', substr($dir, $i + 2, 4))[1]; $i += 6;
        if ($id === 0x0009) { $sz = 4; $d = substr($dir, $i, 4); $i += 4 + 2; continue; }       // PROJECTVERSION: size field is a reserved value, the record is 4 + 2 bytes after it
        $d = substr($dir, $i, $sz); $i += $sz;
        switch ($id) {
            case 0x0003: $codepage = unpack('v', $d)[1]; break;
            case 0x0019: $mods[] = ['name' => $d, 'type' => 'std', 'stream' => $d, 'offset' => 0]; break;
            case 0x001A: if ($mods) $mods[count($mods) - 1]['stream'] = $d; break;
            case 0x0031: if ($mods) $mods[count($mods) - 1]['offset'] = unpack('V', $d)[1]; break;
            case 0x0021: if ($mods) $mods[count($mods) - 1]['type'] = 'std'; break;
            case 0x0022: if ($mods) $mods[count($mods) - 1]['type'] = 'class'; break;
        }
    }
    $res = [];
    foreach ($mods as $m) {
        $path = $base . 'VBA/' . $m['stream']; $raw = null;
        foreach ($st as $p => $data) if (strcasecmp($p, $path) === 0) { $raw = $data; break; }
        if ($raw === null) continue;
        $res[] = ['name' => $m['name'], 'type' => $m['type'], 'source' => ovba_decompress(substr($raw, $m['offset'])), 'stream' => $m['stream'], 'codepage' => $codepage];
    }
    return $res;
}

/** a minimal vbaProject.bin holding the given modules ([name => source bytes], procedural modules; a name starting "class:" makes a class module). Source in the code page 1252. */
function vba_build(array $modules, string $projectName = 'VBAProject'): string {
    $rec = function (int $id, string $data) { return pack('vV', $id, strlen($data)) . $data; };
    $dir = $rec(0x0001, pack('V', 1)) . $rec(0x0002, pack('V', 0x409)) . $rec(0x0014, pack('V', 0x409)) . $rec(0x0003, pack('v', 1252)) . $rec(0x0004, $projectName)
         . $rec(0x0005, '') . $rec(0x0040, '') . $rec(0x0006, '') . $rec(0x003D, '') . $rec(0x0007, pack('V', 0)) . $rec(0x0008, pack('V', 0))
         . pack('vV', 0x0009, 4) . pack('V', 0x4E10D7C3 & 0x7FFFFFFF) . pack('v', 1) . $rec(0x000C, '') . $rec(0x003C, '')
         . $rec(0x000F, pack('v', count($modules))) . $rec(0x0013, pack('v', 0xFFFF));
    $streams = []; $projectLines = ''; $ws = '';
    foreach ($modules as $name => $src) {
        $class = strncmp($name, 'class:', 6) === 0; $nm = $class ? substr($name, 6) : $name;
        $u = mb_convert_encoding($nm, 'UTF-16LE', 'UTF-8');
        $dir .= $rec(0x0019, $nm) . $rec(0x0047, $u) . $rec(0x001A, $nm) . $rec(0x0032, $u) . $rec(0x001C, '') . $rec(0x0048, '')
              . $rec(0x0031, pack('V', 0)) . $rec(0x001E, pack('V', 0)) . $rec(0x002C, pack('v', 0xFFFF)) . ($class ? $rec(0x0022, '') : $rec(0x0021, '')) . $rec(0x002B, '');
        $streams[] = ['name' => $nm, 'data' => ovba_compress($src)];
        $projectLines .= ($class ? 'Class=' . $nm . "\r\n" : 'Module=' . $nm . "\r\n"); $ws .= $nm . "=0, 0, 0, 0, C\r\n";
    }
    $dir .= $rec(0x0010, '');
    $project = "ID=\"{" . strtoupper(sprintf('%04X%04X-%04X-%04X-%04X-%04X%04X%04X', mt_rand(0, 0xFFFF), mt_rand(0, 0xFFFF), mt_rand(0, 0xFFFF), mt_rand(0, 0xFFFF), mt_rand(0, 0xFFFF), mt_rand(0, 0xFFFF), mt_rand(0, 0xFFFF), mt_rand(0, 0xFFFF))) . "}\"\r\n"
             . $projectLines . "Name=\"$projectName\"\r\nHelpContextID=\"0\"\r\nVersionCompatible32=\"393222000\"\r\n\r\n[Host Extender Info]\r\n&H00000001={3832D640-CF90-11CF-8E43-00A0C911005A};VBE;&H00000000\r\n\r\n[Workspace]\r\n" . $ws;
    $wm = ''; foreach ($modules as $name => $_) { $nm = strncmp($name, 'class:', 6) === 0 ? substr($name, 6) : $name; $wm .= $nm . "\0" . mb_convert_encoding($nm, 'UTF-16LE', 'UTF-8') . "\0\0"; } $wm .= "\0\0";
    $vba = [['name' => '_VBA_PROJECT', 'data' => "\xCC\x61\xFF\xFF\x00\x00\x00"], ['name' => 'dir', 'data' => ovba_compress($dir)]];
    foreach ($streams as $s) $vba[] = $s;
    return cfb_build([['name' => 'VBA', 'children' => $vba], ['name' => 'PROJECT', 'data' => $project], ['name' => 'PROJECTwm', 'data' => $wm]]);
}
