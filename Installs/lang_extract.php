<?php
// =============================================================================
// lang_extract.php — builds the translator files from the code, and checks them.
//
//   php Installs/lang_extract.php           write lang/en.json and lang/_template.json
//   php Installs/lang_extract.php --check   verify; exit 1 if anything is stale or broken
//
// The English text of Cockpit lives IN THE CODE (see js/core/i18n.js): markup carries
// data-i18n="key" / data-i18n-title="key" / data-i18n-placeholder="key", script calls
// T('key', 'English'), and each tour step has an id. This script READS those and writes
//
//   cockpit_app/lang/en.json         every key with its English — the reference, GENERATED
//   cockpit_app/lang/_template.json  the same keys with EMPTY values, for a new language
//
// so en.json cannot drift from what the app says: there is no second copy to forget.
//
// A template key is followed by "key#en": the English, on the next line, so the person
// translating sees it beside the empty value without opening another file. lang.php
// ignores every key containing '#'.
//
// --check (wired into rebuild_tarballs.sh) fails when:
//   - en.json / _template.json are out of date with the code   (you added a string: re-run)
//   - the same key is used with two different English texts
//   - a language pack is not valid JSON, or is missing {placeholders} its English has
//     (or invents ones it does not), which would print "{n}" to a person
// and REPORTS (without failing) coverage per language and keys a pack carries that no
// longer exist. A translation may be incomplete — untranslated keys fall back to English.
// =============================================================================
$ROOT = dirname(__DIR__);
$APP  = $ROOT . '/cockpit_app';
$LANG = $APP . '/lang';
$check = in_array('--check', $argv, true);

$en = [];            // key => English
$where = [];         // key => first place it was seen
$problems = [];

function add(string $key, string $text, string $at): void {
    global $en, $where, $problems;
    $text = trim(preg_replace('/\s+/u', ' ', $text));
    if (!preg_match('/^[a-z0-9][a-z0-9._-]*$/', $key)) { $problems[] = "bad key '$key' ($at)"; return; }
    if ($text === '') { $problems[] = "empty English for '$key' ($at)"; return; }
    if (isset($en[$key]) && $en[$key] !== $text) {
        $problems[] = "key '$key' has two different English texts:\n      {$where[$key]}: $en[$key]\n      $at: $text"; return;
    }
    $en[$key] = $text; $where[$key] ??= $at;
}
function unq(string $s): string {            // a JS string literal's body -> its text
    return preg_replace_callback('/\\\\(u[0-9a-fA-F]{4}|.)/su', function ($m) {
        $c = $m[1];
        if ($c[0] === 'u' && strlen($c) === 5) return json_decode('"\\' . $c . '"');
        return ['n' => "\n", 't' => "\t", "'" => "'", '"' => '"', '\\' => '\\'][$c] ?? $c;
    }, $s);
}

// ---- 1. markup: data-i18n* attributes --------------------------------------------
$html = file_get_contents($APP . '/index.html');
$dom = new DOMDocument(); libxml_use_internal_errors(true);
$dom->loadHTML('<?xml encoding="UTF-8">' . $html); libxml_clear_errors();
$xp = new DOMXPath($dom);
foreach ($xp->query('//*[@data-i18n]') as $el)             add($el->getAttribute('data-i18n'), $el->textContent, 'index.html');
foreach ($xp->query('//*[@data-i18n-title]') as $el)       add($el->getAttribute('data-i18n-title'), $el->getAttribute('title'), 'index.html (title)');
foreach ($xp->query('//*[@data-i18n-placeholder]') as $el) add($el->getAttribute('data-i18n-placeholder'), $el->getAttribute('placeholder'), 'index.html (placeholder)');

// ---- 2. script: T('key', 'English') -----------------------------------------------
$files = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($APP . '/js', FilesystemIterator::SKIP_DOTS));
foreach ($files as $f) {
    if ($f->getExtension() !== 'js' || $f->getFilename() === 'i18n.js') continue;   // i18n.js only documents T() in comments
    $src = file_get_contents($f->getPathname()); $rel = 'js/' . substr($f->getPathname(), strlen($APP . '/js/'));
    if (preg_match_all('/\bT\(\s*([\'"])([a-z0-9._-]+)\1\s*,\s*(\'((?:[^\'\\\\\n]|\\\\.)*)\'|"((?:[^"\\\\\n]|\\\\.)*)")/s', $src, $m, PREG_SET_ORDER))
        foreach ($m as $x) add($x[2], unq($x[4] !== '' ? $x[4] : ($x[5] ?? '')), $rel);
}

// ---- 3. the tour: steps carry an id; title and text are literals ------------------
$tour = file_get_contents($APP . '/js/panels/right-help-tour.js');
$i = strpos($tour, 'const TUTORIAL_STEPS'); $j = $i === false ? false : strpos($tour, "\n];", $i);
if ($i !== false && $j !== false) {
    $block = substr($tour, $i, $j - $i);
    $q = "'((?:[^'\\\\\n]|\\\\.)*)'";
    foreach (preg_split('/\n/', $block) as $line) {
        if (!preg_match('/^\s*\{\s*(id|sel):/', $line)) continue;
        if (!preg_match("/\bid:\s*'([a-z0-9._-]+)'/", $line, $id)) { $problems[] = 'a tour step has no id: ' . substr(trim($line), 0, 70); continue; }
        if (preg_match("/\btitle:\s*$q/", $line, $t)) add("tour.{$id[1]}.title", unq($t[1]), 'tour');
        if (preg_match("/\btext:\s*$q/", $line, $t))  add("tour.{$id[1]}.text",  unq($t[1]), 'tour');
    }
}

ksort($en);
if ($problems) { fwrite(STDERR, "lang_extract: PROBLEMS\n  " . implode("\n  ", $problems) . "\n"); if ($check) exit(1); }

// ---- the two generated files --------------------------------------------------------
function dump(array $d): string { return json_encode($d, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . "\n"; }
$enDoc = ['_meta' => [
    'code' => 'en', 'name' => 'English', 'native' => 'English', 'dir' => 'ltr',
    'note' => 'GENERATED by Installs/lang_extract.php from the code — do not edit by hand. To change a string, change it where it is used and re-run the script.',
], 'strings' => $en];
$tpl = [];
foreach ($en as $k => $v) { $tpl[$k] = ''; $tpl[$k . '#en'] = $v; }
$tplDoc = ['_meta' => [
    'code' => '', 'name' => '', 'native' => '', 'dir' => 'ltr', 'mirror' => false, 'translator' => '',
    'rules' => [
        'Translate the meaning, not word by word, and keep it short: most of these texts sit in buttons and small labels.',
        'Keep every {placeholder} (curly braces) exactly as written, for example {name} or {n}; you may move it inside the sentence. A line that loses one is refused.',
        'Leave a value empty to keep English there. A half-finished translation works and you can add to it later.',
        'Do not translate product and file names (Cockpit, Ollama, Claude, Gemini, tmux, .json), keyboard keys (Ctrl, Shift) or code.',
        'The "…#en" line under each key is the English for reference; keep it or delete it.',
        'Fill in _meta: code (fr, pt-BR), name (in English), native (the language in itself), dir (ltr or rtl), translator (your name). For a right-to-left language also set mirror to true if the layout should be mirrored (experimental).',
    ],
    'send' => 'Easiest: open Cockpit, Translate Cockpit… (the translate icon under the clock), choose Upload a file, finish the lines there, then Send it to us. Or send this file at https://cockpit.ruggi.site/translate.php. To use it yourself, save it as <code>.json in the lang folder of your Cockpit data folder and reload.',
    'note' => 'COPY this file to <code>.json (for example fr.json), fill in _meta (code, name in English, native name, dir = ltr or rtl, your name) and put your text in the empty values. The "…#en" line under each key is the English, for reference — keep or delete it. Leave a value empty to keep the English. Put your file in the cockpit_data/lang/ folder, which survives updates, then pick it under Settings → Language. See lang/README.md.',
], 'strings' => $tpl];

$wantEn = dump($enDoc); $wantTpl = dump($tplDoc);
$haveEn = (string)@file_get_contents("$LANG/en.json"); $haveTpl = (string)@file_get_contents("$LANG/_template.json");

if (!$check) {
    if (!is_dir($LANG)) mkdir($LANG, 0775, true);
    file_put_contents("$LANG/en.json", $wantEn); file_put_contents("$LANG/_template.json", $wantTpl);
    fwrite(STDERR, sprintf("lang_extract: %d strings -> lang/en.json, lang/_template.json\n", count($en)));
    exit(0);
}

// ---- --check ------------------------------------------------------------------------
$bad = 0;
if ($haveEn !== $wantEn)   { fwrite(STDERR, "  lang/en.json is out of date with the code — run: php Installs/lang_extract.php\n"); $bad++; }
if ($haveTpl !== $wantTpl) { fwrite(STDERR, "  lang/_template.json is out of date with the code — run: php Installs/lang_extract.php\n"); $bad++; }

function ph(string $s): array { preg_match_all('/\{(\w+)\}/', $s, $m); $p = $m[1]; sort($p); return $p; }
$rows = [];
foreach (glob("$LANG/*.json") as $f) {
    $code = basename($f, '.json'); if ($code[0] === '_' || $code === 'en') continue;
    $j = json_decode((string)file_get_contents($f), true);
    if (!is_array($j) || !isset($j['strings']) || !is_array($j['strings'])) { fwrite(STDERR, "  $code.json: not a valid language pack\n"); $bad++; continue; }
    $done = 0; $stale = 0;
    foreach ($j['strings'] as $k => $v) {
        if (strpos($k, '#') !== false) continue;
        if (!isset($en[$k])) { $stale++; continue; }
        if (!is_string($v) || trim($v) === '') continue;
        $done++;
        if (ph($v) !== ph($en[$k])) { fwrite(STDERR, "  $code.json: '$k' has different {placeholders} from the English (" . implode(',', ph($en[$k])) . " vs " . implode(',', ph($v)) . ")\n"); $bad++; }
    }
    $rows[] = sprintf("  %-8s %3d%%  (%d of %d)%s", $code, (int)round(100 * $done / max(1, count($en))), $done, count($en), $stale ? "  — $stale key(s) that no longer exist" : '');
}
fwrite(STDERR, "lang_extract: " . count($en) . " strings; languages:\n" . ($rows ? implode("\n", $rows) : '  (none besides English)') . "\n");
if ($bad) { fwrite(STDERR, "lang_extract: $bad problem(s)\n"); exit(1); }
