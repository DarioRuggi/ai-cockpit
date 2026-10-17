<?php
// photo_fixture.php OUTDIR — photos for tests/photo_tools_test.sh, with real EXIF written by hand (no exiftool on the rig):
//   a.jpg  800x600, Canon / EOS 5D, taken 2026:01:05 14:30:02, Orientation 6, GPS 32.0853 N 34.7818 E
//   a_copy.jpg  an exact copy of a.jpg;  b.jpg  the same picture as a.jpg AS DISPLAYED (rotation applied), smaller, re-saved, no EXIF (a near-duplicate);  c.png  a different picture;
//   tiny.jpg 100x80;  cmyk.jpg a CMYK JPEG;  fake.jpg  an SVG with a .jpg name (must be refused);  noexif.jpg  a plain JPEG
$d = $argv[1] ?? ''; if ($d === '') { fwrite(STDERR, "usage: photo_fixture.php OUTDIR\n"); exit(2); } @mkdir($d, 0775, true);
function rat(int $n, int $dn = 1): string { return pack('NN', $n, $dn); }
function entry(int $tag, int $type, int $count, string $val): string { return pack('nnN', $tag, $type, $count) . str_pad($val, 4, "\0"); }
/** an IFD at $start: entries are [tag, type, count, bytes]; values over 4 bytes go in a data area after the table. Returns the bytes (table + data) */
function ifd(int $start, array $es): string {
    $n = count($es); $table = pack('n', $n); $dataOff = $start + 2 + $n * 12 + 4; $data = '';
    foreach ($es as [$tag, $type, $count, $val]) { if (strlen($val) <= 4) $table .= entry($tag, $type, $count, $val); else { $table .= pack('nnNN', $tag, $type, $count, $dataOff + strlen($data)); $data .= $val . (strlen($val) % 2 ? "\0" : ''); } }
    return $table . pack('N', 0) . $data;
}
function exif_bytes(): string {
    $make = "Canon\0"; $model = "EOS 5D\0"; $dt = "2026:01:05 14:30:02\0";
    $ifd0len = strlen(ifd(0, [[0x010F, 2, 6, $make], [0x0110, 2, 7, $model], [0x0112, 3, 1, pack('n', 6)], [0x8769, 4, 1, pack('N', 0)], [0x8825, 4, 1, pack('N', 0)]]));
    $exStart = 8 + $ifd0len; $ex = ifd($exStart, [[0x9003, 2, 20, $dt]]); $gpsStart = $exStart + strlen($ex);
    $gps = ifd($gpsStart, [[0x0001, 2, 2, "N\0"], [0x0002, 5, 3, rat(32) . rat(5) . rat(7, 1)], [0x0003, 2, 2, "E\0"], [0x0004, 5, 3, rat(34) . rat(46) . rat(54)]]);
    $ifd0 = ifd(8, [[0x010F, 2, 6, $make], [0x0110, 2, 7, $model], [0x0112, 3, 1, pack('n', 6)], [0x8769, 4, 1, pack('N', $exStart)], [0x8825, 4, 1, pack('N', $gpsStart)]]);
    return "MM\0*" . pack('N', 8) . $ifd0 . $ex . $gps;
}
function inject_exif(string $jpeg, string $tiff): string { $app1 = "Exif\0\0" . $tiff; return substr($jpeg, 0, 2) . "\xFF\xE1" . pack('n', strlen($app1) + 2) . $app1 . substr($jpeg, 2); }
function im(string $cmd): void { exec($cmd . ' 2>&1', $o, $rc); if ($rc !== 0) { fwrite(STDERR, "convert failed: " . implode("\n", $o) . "\n"); exit(1); } }
im("convert -size 800x600 gradient:blue-yellow -fill white -draw 'circle 400,300 400,100' -quality 90 " . escapeshellarg("$d/base.jpg"));
file_put_contents("$d/a.jpg", inject_exif((string)file_get_contents("$d/base.jpg"), exif_bytes())); copy("$d/a.jpg", "$d/a_copy.jpg");
im("convert " . escapeshellarg("$d/a.jpg") . " -auto-orient -strip -resize 300x400 -quality 75 " . escapeshellarg("$d/b.jpg"));
im("convert -size 640x480 gradient:red-black -fill white -draw 'rectangle 100,100 300,200' " . escapeshellarg("$d/c.png"));
im("convert -size 100x80 xc:green " . escapeshellarg("$d/tiny.jpg"));
im("convert -size 700x500 gradient:cyan-magenta -colorspace CMYK -quality 85 " . escapeshellarg("jpeg:$d/cmyk.jpg"));
im("convert -size 700x500 xc:white -fill black -draw 'polygon 50,450 350,50 650,450' -fill red -draw 'circle 600,100 640,100' -quality 85 " . escapeshellarg("$d/noexif.jpg"));
file_put_contents("$d/fake.jpg", '<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>');
unlink("$d/base.jpg"); echo "wrote $d\n";
