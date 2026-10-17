<?php
// =============================================================================
// archive.php — Personal archive: your own papers (warranties, invoices, insurance, contracts,
// manuals, IDs) as searchable, dated Library items.
//
//   GET  ?action=status                     items, what is due soon, which readers are available
//   GET  ?action=original&id=ID             the file as you gave it
//   POST {action:'ingest', filename, data_b64, title?, type?, due?}
//   POST {action:'set',    id, title?, type?, due?}       correct what the reader guessed
//   POST {action:'delete', id}
//
// Reading a document (nothing leaves this computer — the scan is never sent to an online service):
//   1. text PDF            pdftotext -layout
//   2. scan / photo / PDF with no text layer
//          tesseract (if installed)   else   a local vision model through Ollama (gemma3:4b by default)
//   3. nothing available   the file is still kept, flagged "not read", and you can type the text in
// Then: a type guess (warranty, invoice, insurance, contract, id, tax, medical, manual, other), the
// dates found, and a "due" date — the one beside words like expires / valid until / renew / warranty.
// The text goes into the Library as an item tagged "archive", so Library search and push-RAG find it.
//
// Every guess is shown and editable; none is trusted silently. "Due soon" is computed when you look,
// no background job is involved.
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
ed_gate_or_exit('export');   // demo: described-modal; v1/v2: real

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
if (session_status() === PHP_SESSION_ACTIVE) session_write_close();
@set_time_limit(300);

$CD  = rtrim($PATHS['cockpit_data'], '/');
$AR  = $CD . '/archive';
$LIBTEXT = $CD . '/library_text';
$GIDX = $CD . '/library_index.json';
const AR_EXT = ['pdf', 'png', 'jpg', 'jpeg', 'webp', 'tif', 'tiff', 'bmp', 'txt', 'md'];
const AR_MAX = 25 * 1048576;

function ar_out(array $a, int $code = 200): void { http_response_code($code); echo json_encode($a, JSON_UNESCAPED_UNICODE); exit; }
function ar_have(string $b): bool { return trim((string)shell_exec('command -v ' . escapeshellarg($b) . ' 2>/dev/null')) !== ''; }
function ar_load(string $f): array { $j = json_decode((string)@file_get_contents($f), true); return is_array($j) ? $j : []; }
function ar_save(string $f, array $d): void { @mkdir(dirname($f), 0775, true); $t = $f . '.tmp'; file_put_contents($t, json_encode($d, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES)); @chmod($t, 0664); rename($t, $f); }
function ar_vision_model(): string {
    $ch = curl_init('http://127.0.0.1:11434/api/tags'); curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => 1, CURLOPT_TIMEOUT => 3]);
    $r = json_decode((string)curl_exec($ch), true); curl_close($ch);
    $have = array_map(fn($m) => $m['name'] ?? '', $r['models'] ?? []);
    foreach (['gemma3:4b', 'llava', 'minicpm-v', 'qwen2.5vl', 'moondream'] as $p) foreach ($have as $h) if ($h === $p || strpos($h, $p) === 0) return $h;
    return '';
}

/** Text of one image: tesseract if present, else the local vision model. Returns [text, method]. */
function ar_ocr(string $img): array {
    if (ar_have('tesseract')) { $t = (string)shell_exec('tesseract ' . escapeshellarg($img) . ' stdout 2>/dev/null'); if (strlen(trim($t)) > 10) return [$t, 'tesseract']; }
    $m = ar_vision_model();
    if ($m === '') return ['', ''];
    $ch = curl_init('http://127.0.0.1:11434/api/generate');
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => 1, CURLOPT_POST => 1, CURLOPT_TIMEOUT => 240, CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
        CURLOPT_POSTFIELDS => json_encode(['model' => $m, 'stream' => false, 'options' => ['temperature' => 0],
            'prompt' => 'Transcribe all the text in this image exactly as written, line by line, including dates and numbers. Output only the text, nothing else.',
            'images' => [base64_encode((string)file_get_contents($img))]])]);
    $r = json_decode((string)curl_exec($ch), true); curl_close($ch);
    return [trim((string)($r['response'] ?? '')), $m ? "vision model ($m)" : ''];
}

function ar_read(string $path, string $ext): array {
    if (in_array($ext, ['txt', 'md'], true)) return [(string)file_get_contents($path), 'plain text'];
    $tmp = sys_get_temp_dir() . '/ar_' . bin2hex(random_bytes(4));
    if ($ext === 'pdf') {
        if (ar_have('pdftotext')) { $t = (string)shell_exec('pdftotext -layout ' . escapeshellarg($path) . ' - 2>/dev/null'); if (strlen(trim($t)) >= 40) return [$t, 'pdftotext']; }
        if (!ar_have('pdftoppm')) return ['', ''];
        @mkdir($tmp); shell_exec('pdftoppm -r 150 -l 3 -png ' . escapeshellarg($path) . ' ' . escapeshellarg("$tmp/p") . ' 2>/dev/null');
        $txt = ''; $meth = '';
        foreach ((array)glob("$tmp/p*.png") as $png) { [$t, $m] = ar_ocr($png); $txt .= $t . "\n"; $meth = $m ?: $meth; }
        shell_exec('rm -rf ' . escapeshellarg($tmp)); return [trim($txt), $meth];
    }
    return ar_ocr($path);
}

const AR_TYPES = [
    'warranty'  => '/warrant|guarantee|אחריות|garant[ií]a/iu',
    'invoice'   => '/invoice|receipt|tax invoice|חשבונית|קבלה|factura|recibo/iu',
    'insurance' => '/insurance|policy no|premium|ביטוח|seguro|póliza/iu',
    'contract'  => '/contract|agreement|lease|חוזה|הסכם|contrato/iu',
    'id'        => '/passport|identity card|driver.?s licen|דרכון|רישיון נהיגה|תעודת זהות|pasaporte/iu',
    'tax'       => '/tax return|income tax|vat|מס הכנסה|declaraci[oó]n de la renta/iu',
    'medical'   => '/prescription|diagnos|patient|medical|רפואי|מרשם|receta/iu',
    'manual'    => '/user manual|instruction manual|operating instructions|מדריך|manual de usuario/iu',
];
const AR_DUE_WORDS = '/(expir\w*|valid\s+(?:until|through|to)|renew\w*|due|warranty\s+(?:ends|until)|end\s+date|תוקף|בתוקף עד|תאריך פקיעה|vence|vencimiento|válido hasta)/iu';

function ar_guess_type(string $t): string { foreach (AR_TYPES as $k => $re) if (preg_match($re, $t)) return $k; return 'other'; }

/** All dates in the text as Y-m-d, with the character offset each was found at. */
function ar_dates(string $t): array {
    $o = []; $mon = ['jan' => 1, 'feb' => 2, 'mar' => 3, 'apr' => 4, 'may' => 5, 'jun' => 6, 'jul' => 7, 'aug' => 8, 'sep' => 9, 'oct' => 10, 'nov' => 11, 'dec' => 12];
    $add = function ($y, $m, $d, $pos) use (&$o) { $y = (int)$y; if ($y < 100) $y += 2000; if (checkdate((int)$m, (int)$d, $y) && $y >= 1990 && $y <= 2100) $o[] = [sprintf('%04d-%02d-%02d', $y, $m, $d), $pos]; };
    if (preg_match_all('/\b(20\d\d|19\d\d)-(\d\d?)-(\d\d?)\b/', $t, $m, PREG_SET_ORDER | PREG_OFFSET_CAPTURE)) foreach ($m as $x) $add($x[1][0], $x[2][0], $x[3][0], $x[0][1]);
    if (preg_match_all('/\b(\d{1,2})[\/.](\d{1,2})[\/.](\d{4}|\d{2})\b/', $t, $m, PREG_SET_ORDER | PREG_OFFSET_CAPTURE)) foreach ($m as $x) $add($x[3][0], $x[2][0], $x[1][0], $x[0][1]);   // day first
    if (preg_match_all('/\b(\d{1,2})\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?\s+(\d{4})\b/i', $t, $m, PREG_SET_ORDER | PREG_OFFSET_CAPTURE)) foreach ($m as $x) $add($x[3][0], $mon[strtolower(substr($x[2][0], 0, 3))], $x[1][0], $x[0][1]);
    if (preg_match_all('/\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2}),?\s+(\d{4})\b/i', $t, $m, PREG_SET_ORDER | PREG_OFFSET_CAPTURE)) foreach ($m as $x) $add($x[3][0], $mon[strtolower(substr($x[1][0], 0, 3))], $x[2][0], $x[0][1]);
    usort($o, fn($a, $b) => $a[1] <=> $b[1]); return $o;
}
/** The date beside an expiry word if there is one; else null (we do not guess a "due" from a random date). */
function ar_due(string $t): ?string {
    $dates = ar_dates($t); $best = null;
    if (preg_match_all(AR_DUE_WORDS, $t, $w, PREG_OFFSET_CAPTURE)) foreach ($w[0] as [$word, $wp]) foreach ($dates as [$d, $dp]) {
        $gap = $dp - ($wp + strlen($word)); if ($gap >= -2 && $gap <= 45 && ($best === null || $d > $best)) $best = $d;
    }
    return $best;
}
function ar_amounts(string $t): array { preg_match_all('/(?:[$€£₪]|ILS|USD|EUR|NIS)\s?\d[\d,]*(?:\.\d\d)?|\d[\d,]*(?:\.\d\d)?\s?(?:[$€£₪]|ILS|USD|EUR|NIS|ש"ח)/u', $t, $m); return array_slice(array_values(array_unique($m[0])), 0, 6); }

function ar_lib_put(array $it, string $text): void {
    global $LIBTEXT, $GIDX;
    @mkdir($LIBTEXT, 0775, true); $f = "$LIBTEXT/{$it['id']}.txt"; file_put_contents($f, $text); @chmod($f, 0664);
    $idx = ar_load($GIDX); $idx['library'] = array_values(array_filter($idx['library'] ?? [], fn($x) => ($x['id'] ?? '') !== $it['id']));
    $idx['library'][] = ['id' => $it['id'], 'file_path' => $f, 'title' => $it['title'], 'tags' => ['archive', $it['type']], 'source' => 'archive', 'size' => strlen($text), 'scope' => 'global', 'updated' => date('c')];
    ar_save($GIDX, $idx);
}
function ar_lib_drop(string $id): void {
    global $LIBTEXT, $GIDX; @unlink("$LIBTEXT/$id.txt");
    $idx = ar_load($GIDX); if (isset($idx['library'])) { $idx['library'] = array_values(array_filter($idx['library'], fn($x) => ($x['id'] ?? '') !== $id)); ar_save($GIDX, $idx); }
}

// Files arrive as base64 inside a JSON body, so memory_limit (not upload_max_filesize) is the ceiling: the base64
// text, its decoded copy and the decoded JSON array are alive together, about 3.7x the file. The distribution's 128M
// died with an empty 500 at ~35 MB although the documented cap is 25 MB. Raise it for THIS request only.
@ini_set('memory_limit', '768M');
$in = json_decode((string)file_get_contents('php://input'), true); if (!is_array($in)) $in = [];
$action = (string)($_GET['action'] ?? ($in['action'] ?? 'status'));
$ITEMS = $AR . '/items.json';

if ($action === 'status') {
    $items = ar_load($ITEMS); $today = date('Y-m-d'); $soon = date('Y-m-d', strtotime('+60 days')); $due = [];
    foreach ($items as $i) if (!empty($i['due']) && $i['due'] <= $soon) $due[] = ['id' => $i['id'], 'title' => $i['title'], 'due' => $i['due'], 'overdue' => $i['due'] < $today];
    usort($due, fn($a, $b) => strcmp($a['due'], $b['due']));
    usort($items, fn($a, $b) => strcmp($b['added'], $a['added']));
    ar_out(['ok' => true, 'items' => $items, 'due_soon' => $due, 'types' => array_merge(array_keys(AR_TYPES), ['other']),
            'readers' => ['pdftotext' => ar_have('pdftotext'), 'tesseract' => ar_have('tesseract'), 'vision_model' => ar_vision_model()]]);
}
if ($action === 'original') {
    $id = preg_replace('/[^A-Za-z0-9_]/', '', (string)($_GET['id'] ?? '')); foreach (ar_load($ITEMS) as $i) if ($i['id'] === $id) {
        $p = "$AR/files/{$i['file']}"; if (is_file($p)) { header('Content-Type: application/octet-stream'); header('Content-Disposition: attachment; filename="' . addslashes($i['original_name']) . '"'); readfile($p); exit; } }
    ar_out(['ok' => false, 'error' => 'no such item'], 404);
}
auth_require_writer();
if ($action === 'ingest') {
    $name = basename((string)($in['filename'] ?? '')); $ext = strtolower(pathinfo($name, PATHINFO_EXTENSION));
    $bin = base64_decode((string)($in['data_b64'] ?? ''), true);
    if ($name === '' || !in_array($ext, AR_EXT, true)) ar_out(['ok' => false, 'error' => 'file type not supported (' . implode(', ', AR_EXT) . ')']);
    if ($bin === false || $bin === '') ar_out(['ok' => false, 'error' => 'empty or damaged upload']);
    if (strlen($bin) > AR_MAX) ar_out(['ok' => false, 'error' => 'larger than 25 MB']);
    $id = 'ar' . date('Ymd_His') . '_' . substr(bin2hex(random_bytes(3)), 0, 6);
    @mkdir("$AR/files", 0775, true); $stored = "$id.$ext"; file_put_contents("$AR/files/$stored", $bin); @chmod("$AR/files/$stored", 0640);
    [$text, $method] = ar_read("$AR/files/$stored", $ext);
    $text = trim($text); $read = strlen($text) >= 10;
    $type = in_array($in['type'] ?? '', array_merge(array_keys(AR_TYPES), ['other']), true) ? $in['type'] : ar_guess_type($text);
    $due = preg_match('/^\d{4}-\d\d-\d\d$/', (string)($in['due'] ?? '')) ? $in['due'] : ar_due($text);
    $item = ['id' => $id, 'file' => $stored, 'original_name' => $name, 'title' => trim((string)($in['title'] ?? '')) ?: pathinfo($name, PATHINFO_FILENAME),
             'type' => $type, 'due' => $due, 'amounts' => ar_amounts($text), 'dates_found' => array_slice(array_values(array_unique(array_map(fn($d) => $d[0], ar_dates($text)))), 0, 8),
             'read' => $read, 'method' => $method, 'added' => date('c'), 'chars' => strlen($text)];
    $items = ar_load($ITEMS); $items[] = $item; ar_save($ITEMS, $items);
    if ($read) ar_lib_put($item, $text);
    ar_out(['ok' => true, 'item' => $item, 'note' => $read ? null : 'The file is kept but could not be read (no OCR or vision model available, or the image is unclear). Install tesseract-ocr or pull a vision model, then re-add it.']);
}
if ($action === 'set') {
    $id = (string)($in['id'] ?? ''); $items = ar_load($ITEMS); $hit = null;
    foreach ($items as &$i) if ($i['id'] === $id) {
        if (isset($in['title']) && trim($in['title']) !== '') $i['title'] = mb_substr(trim($in['title']), 0, 120);
        if (isset($in['type']) && in_array($in['type'], array_merge(array_keys(AR_TYPES), ['other']), true)) $i['type'] = $in['type'];
        if (array_key_exists('due', $in)) $i['due'] = preg_match('/^\d{4}-\d\d-\d\d$/', (string)$in['due']) ? $in['due'] : null;
        $hit = $i;
    } unset($i);
    if (!$hit) ar_out(['ok' => false, 'error' => 'no such item']);
    ar_save($ITEMS, $items);
    $tf = "$LIBTEXT/$id.txt"; if (is_file($tf)) ar_lib_put($hit, (string)file_get_contents($tf));
    ar_out(['ok' => true, 'item' => $hit]);
}
if ($action === 'delete') {
    $id = (string)($in['id'] ?? ''); $items = ar_load($ITEMS); $keep = [];
    foreach ($items as $i) { if ($i['id'] === $id) { @unlink("$AR/files/{$i['file']}"); ar_lib_drop($id); } else $keep[] = $i; }
    ar_save($ITEMS, $keep); ar_out(['ok' => true]);
}
ar_out(['ok' => false, 'error' => 'unknown action'], 400);
