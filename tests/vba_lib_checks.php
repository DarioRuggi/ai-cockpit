<?php
// vba_lib_checks.php ROOT — the pure-PHP checks of cockpit_app/vba_lib.php, one "ok ..." or "FAIL ..." line each (run by tests/vba_lib_test.sh)
require ($argv[1] ?? '.') . '/cockpit_app/vba_lib.php'; mt_srand(7);
$r = function (int $l): string { $s = ''; for ($i = 0; $i < $l; $i++) $s .= chr(mt_rand(0, 255)); return $s; };
$say = function (bool $ok, string $m): void { echo ($ok ? 'ok ' : 'FAIL ') . $m . "\n"; };
// compression
foreach ([0, 1, 5, 4095, 4096, 4097, 9000] as $len) { $d = $len ? substr(str_repeat("Dim x As Long: x = x + 1\r\n", 500), 0, $len) : ''; $say(ovba_decompress(ovba_compress($d)) === $d, "text round trip $len"); }
$d = $r(5000); $say(ovba_decompress(ovba_compress($d)) === $d, 'incompressible 5000 bytes round trip');
$big = str_repeat("Sub Foo()\r\n  Dim x As Integer\r\n  x = x + 1\r\nEnd Sub\r\n", 400); $say(strlen(ovba_compress($big)) < strlen($big) / 5, 'repetitive text really compresses');
$say(ovba_decompress('') === '' && ovba_decompress("\x02abc") === '', 'garbage in, empty out');
// compound file: streams around every size boundary, a nested storage
$tree = []; $want = [];
foreach ([0, 1, 63, 64, 65, 511, 512, 513, 4095, 4096, 4097, 10000, 70000] as $len) { $nm = "S$len"; $data = $r($len); $tree[] = ['name' => $nm, 'data' => $data]; $want[$nm] = $data; }
$sub = []; foreach ([10, 5000] as $len) { $x = $r($len); $sub[] = ['name' => "in$len", 'data' => $x]; $want["Dir/in$len"] = $x; }
$tree[] = ['name' => 'Dir', 'children' => $sub];
$bin = cfb_build($tree); $got = cfb_parse($bin);
$say($got !== null, 'built file parses');
$bad = []; foreach ($want as $p => $v) if (!isset($got[$p]) || $got[$p] !== $v) $bad[] = $p;
$say(!$bad, 'every stream comes back identical' . ($bad ? ' (bad: ' . implode(',', $bad) . ')' : ''));
$say(cfb_parse('not a compound file') === null, 'a non-compound file is refused');
// the project
$src = "Attribute VB_Name = \"Module1\"\r\nOption Explicit\r\nSub A()\r\n  MsgBox \"hi\"\r\nEnd Sub\r\n";
$p = vba_build(['Module1' => $src, 'class:Clase1' => "Option Explicit\r\nPublic X As Long\r\n"]); $m = vba_extract($p);
$say(is_array($m) && count($m) === 2, 'two modules found');
$say(isset($m[0]) && $m[0]['name'] === 'Module1' && $m[0]['source'] === $src && $m[0]['type'] === 'std', 'procedural module: name, type and source identical');
$say(isset($m[1]) && $m[1]['name'] === 'Clase1' && $m[1]['type'] === 'class', 'class module type kept');
$huge = ''; for ($k = 0; $k < 900; $k++) $huge .= "Dim v$k As String: v$k = \"" . substr(md5((string)$k), 0, 12) . "\" ' " . ($k * 7919 % 10007) . "\r\n";
$p2 = vba_build(['Big' => $huge]); $m2 = vba_extract($p2);
$say(strlen(ovba_compress($huge)) > 4096 && $m2 && $m2[0]['source'] === $huge, 'a module whose compressed form fills ordinary sectors (' . strlen($huge) . ' bytes)');
$say(vba_extract(cfb_build([['name' => 'WordDocument', 'data' => 'x']])) === [], 'a compound file with no macros gives []');
$say(vba_extract('plain') === null, 'not a compound file gives null');
