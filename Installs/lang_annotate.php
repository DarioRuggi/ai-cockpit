<?php
// =============================================================================
// lang_annotate.php — marks the visible text of cockpit_app/index.html as translatable.
//
//   php Installs/lang_annotate.php            annotate in place (idempotent — re-run after adding HTML)
//   php Installs/lang_annotate.php --dry      report only
//
// What it does, and ONLY this:
//   * a text that is the whole content of its element  -> data-i18n="ui.<slug>" on that element
//   * a text beside other elements (icon + label)       -> wrapped in <span data-i18n="ui.<slug>">
//   * title="…"       -> data-i18n-title="ui.tip.<slug>"
//   * placeholder="…" -> data-i18n-placeholder="ui.ph.<slug>"
// Same English -> same key. It never touches: script/style/pre/code/textarea/svg/title, icon
// ligatures (class material-symbols…/ico), text with {{ }} or <?php, anything already annotated.
// It then PROVES it changed nothing else: before/after DOM, with the added attributes and spans
// folded away, must be identical (tags, attributes, text) or the file is not written.
// =============================================================================
$f = dirname(__DIR__) . '/cockpit_app/index.html';
$dry = in_array('--dry', $argv, true);
$src = file_get_contents($f);

function slug(string $s, int $max = 40): string {
    $s = strtolower(html_entity_decode($s, ENT_QUOTES | ENT_HTML5, 'UTF-8'));
    $s = trim(preg_replace('/[^a-z0-9]+/', '.', $s), '.');
    $s = substr($s, 0, $max); $s = rtrim($s, '.');
    return $s === '' ? 'x' : $s;
}
$byKey = [];   // key => english (collision detection)
function key_for(string $prefix, string $english): string {
    global $byKey;
    $en = trim(preg_replace('/\s+/u', ' ', html_entity_decode($english, ENT_QUOTES | ENT_HTML5, 'UTF-8')));
    $k = $prefix . slug($en);
    if (isset($byKey[$k]) && $byKey[$k] !== $en) $k .= '.' . substr(md5($en), 0, 4);
    $byKey[$k] = $en; return $k;
}
function worth(string $t): bool {
    $d = html_entity_decode($t, ENT_QUOTES | ENT_HTML5, 'UTF-8');
    return (bool)preg_match('/[A-Za-z]{2,}/', $d) && !preg_match('/\{\{|\}\}|<\?|\$\{/', $d);
}
$VOID = array_flip(['area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr']);
$SKIP = array_flip(['script','style','pre','code','textarea','svg','title','head','noscript']);

$tok = preg_split('/(<!--.*?-->|<(?:[^>"\']|"[^"]*"|\'[^\']*\')*>)/s', $src, -1, PREG_SPLIT_DELIM_CAPTURE);
$stack = []; $n = ['text' => 0, 'wrap' => 0, 'title' => 0, 'ph' => 0]; $out = $tok;

function add_attr(string $tag, string $attr): string { return preg_replace('/\s*(\/?)>$/', ' ' . $attr . '$1>', $tag, 1); }

for ($i = 0; $i < count($tok); $i++) {
    $t = $tok[$i];
    if ($t === '') continue;
    if ($t[0] === '<' && substr($t, 0, 4) === '<!--') continue;
    if ($t[0] === '<' && $t[1] !== '!' && $t[1] !== '?') {
        if ($t[1] === '/') {                                   // closing tag
            $name = strtolower(trim(substr($t, 2, -1)));
            while ($stack && end($stack)['name'] !== $name) array_pop($stack);   // tolerate sloppy markup
            array_pop($stack); continue;
        }
        preg_match('/^<([a-zA-Z][a-zA-Z0-9-]*)/', $t, $m); $name = strtolower($m[1] ?? '');
        $tag = $t;
        // attributes: title / placeholder
        if (!isset($SKIP[$name]) && !count(array_filter($stack, fn($s) => isset($SKIP[$s['name']])))) {
            if (strpos($tag, 'data-i18n-title') === false && preg_match('/\stitle="([^"]*)"/', $tag, $a) && worth($a[1])) {
                $tag = add_attr($tag, 'data-i18n-title="' . key_for('ui.tip.', $a[1]) . '"'); $n['title']++;
            }
            if (strpos($tag, 'data-i18n-placeholder') === false && preg_match('/\splaceholder="([^"]*)"/', $tag, $a) && worth($a[1])) {
                $tag = add_attr($tag, 'data-i18n-placeholder="' . key_for('ui.ph.', $a[1]) . '"'); $n['ph']++;
            }
        }
        $out[$i] = $tag;
        if (!isset($VOID[$name]) && substr(rtrim($t), -2) !== '/>') $stack[] = ['name' => $name, 'tag' => $t, 'idx' => $i];
        continue;
    }
    if ($t[0] === '<') continue;                               // doctype etc.
    // ---- a text node ----
    if (!worth($t) || !$stack) continue;
    foreach ($stack as $s) if (isset($SKIP[$s['name']])) continue 2;
    $p = end($stack); $ptag = $out[$p['idx']];
    if (preg_match('/class="[^"]*(material-symbols|\bico\b|icon)[^"]*"/', $ptag)) continue;
    if (strpos($ptag, 'data-i18n="') !== false) continue;
    $lead = preg_match('/^\s*/', $t, $mm) ? $mm[0] : ''; $trail = preg_match('/\s*$/', $t, $mm) ? $mm[0] : '';
    $core = trim($t);
    $next = $tok[$i + 1] ?? '';
    $leaf = ($p['idx'] === $i - 1) && preg_match('#^</' . preg_quote($p['name'], '#') . '\s*>$#i', $next);
    $key = key_for('ui.', $core);
    if ($leaf) { $out[$p['idx']] = add_attr($ptag, 'data-i18n="' . $key . '"'); $n['text']++; }
    else       { $out[$i] = $lead . '<span data-i18n="' . $key . '" data-w>' . $core . '</span>' . $trail; $n['wrap']++; }
}
$new = implode('', $out);

// ---- proof: nothing but the additions changed -------------------------------------------
function canon(string $html): string {
    $d = new DOMDocument(); libxml_use_internal_errors(true);
    $d->loadHTML('<?xml encoding="UTF-8">' . $html); libxml_clear_errors();
    $walk = function (DOMNode $n) use (&$walk): string {
        if ($n->nodeType === XML_TEXT_NODE) return preg_replace('/\s+/u', ' ', $n->nodeValue);
        if ($n->nodeType !== XML_ELEMENT_NODE) return '';
        $attrs = []; foreach ($n->attributes as $a) { if (strpos($a->name, 'data-i18n') !== 0 && $a->name !== 'data-w') $attrs[] = $a->name . '=' . $a->value; }
        sort($attrs); $inner = '';
        foreach ($n->childNodes as $c) $inner .= $walk($c);
        $isWrap = $n->nodeName === 'span' && $n->hasAttribute('data-w');
        return $isWrap ? $inner : '<' . $n->nodeName . ' ' . implode(' ', $attrs) . '>' . $inner . '</' . $n->nodeName . '>';
    };
    $s = $walk($d->documentElement);
    return preg_replace('/\s+/u', ' ', $s);
}
$a = canon($src); $b = canon($new);
if ($a !== $b) { fwrite(STDERR, "lang_annotate: ABORT — the annotated page differs from the original beyond the added attributes.\n"); 
    for ($k = 0; $k < min(strlen($a), strlen($b)); $k++) if ($a[$k] !== $b[$k]) { fwrite(STDERR, "  first difference near: ..." . substr($a, max(0, $k - 60), 140) . "\n  vs: ..." . substr($b, max(0, $k - 60), 140) . "\n"); break; }
    exit(1); }
fwrite(STDERR, sprintf("lang_annotate: %d element texts, %d wrapped texts, %d titles, %d placeholders%s\n", $n['text'], $n['wrap'], $n['title'], $n['ph'], $dry ? ' (dry run)' : ''));
if (!$dry && $new !== $src) file_put_contents($f, str_replace(' data-w>', '>', $new));
