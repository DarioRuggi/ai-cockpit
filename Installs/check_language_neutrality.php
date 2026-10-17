#!/usr/bin/env php
<?php
// =============================================================================
// check_language_neutrality.php — keeps the rule of 2026-10-13: Cockpit is a world-wide product; no language and no fact about its maker (religion, nationality, place, heritage) is
// singled out in anything the public or a user reads. Hebrew, Spanish and every other language stay fully supported and are shown like any other language.
//
//   php Installs/check_language_neutrality.php        exit 0 = clean; exit 1 = lists every hit
//
// What it looks for in PUBLIC TEXT (the public site pages, the app's screens/texts/kinds/tool descriptions/help, the guides, the generated builds catalog):
//   * words that identify the maker: Israel, Israeli, Jewish, Jerusalem, Tel Aviv, Zionist
//   * Hebrew SCRIPT (U+0590-05FF) outside the Hebrew language pack itself and outside test/fixture files: sample text in a public place would single the language out
// Not checked, on purpose: code comments (so the Hebrew-script check skips cockpit_app/js), PHP/JS logic, installers (a Hebrew-specific code path is a capability, not a message), the language packs, tests.
// A technical mention of the word "Hebrew" in a neutral list (e.g. "Arabic, Hebrew, CJK") is allowed; the lists are written alphabetically by the humans who add them.
// =============================================================================
$ROOT = dirname(__DIR__);
$globs = [
    'site_next/*.php', 'server_mirror/public_html/ai-cockpit.html', 'server_mirror/public_html/index.html', 'plans/copy/*.md', 'server_mirror/cockpit.ruggi.site/*.php', 'server_mirror/cockpit.ruggi.site/*.html', 'server_mirror/cockpit.ruggi.site/*.md', 'server_mirror/cockpit.ruggi.site/api/builds.json',
    'cockpit_app/index.html', 'cockpit_app/help_default.json', 'cockpit_app/workers_providers.json', 'cockpit_app/js/*/*.js', 'cockpit_app/kinds/*.json', 'cockpit_app/tools_builtins/*.json',
    'cockpit_app/lang/en.json', 'cockpit_app/lang/es.json', 'cockpit_app/lang/_template.json', 'cockpit_app/lang/README.md', 'docs/guides/*.md', 'README.md', 'LICENSE.md', 'TERMS.md', 'NOTICE',
];
$hits = [];
foreach ($globs as $g) foreach (glob("$ROOT/$g") ?: [] as $f) {
    $s = (string)file_get_contents($f); $rel = substr($f, strlen($ROOT) + 1);
    if (preg_match_all('/\b(Israel(?:i|is)?|Jewish|Jerusalem|Tel[ -]Aviv|Zionis[mt])\b/u', $s, $m, PREG_OFFSET_CAPTURE))
        foreach ($m[0] as [$w, $o]) $hits[] = "$rel: \"$w\" at " . (substr_count(substr($s, 0, $o), "\n") + 1) . ': ' . trim(preg_replace('/\s+/', ' ', mb_substr($s, max(0, $o - 50), 110)));
    if (!preg_match('#/js/#', $rel) && preg_match_all('/[\x{0590}-\x{05FF}]+/u', $s, $m, PREG_OFFSET_CAPTURE))
        foreach (array_slice($m[0], 0, 3) as [$w, $o]) $hits[] = "$rel: Hebrew script at line " . (substr_count(substr($s, 0, $o), "\n") + 1) . ': ' . trim(preg_replace('/\s+/', ' ', mb_substr($s, max(0, $o - 40), 100)));
}
if ($hits) { echo "language neutrality: " . count($hits) . " hit(s) in public text (rule of 2026-10-13: no language or personal fact singled out):\n  " . implode("\n  ", $hits) . "\n"; exit(1); }
echo "language neutrality: clean (" . count($globs) . " patterns checked)\n"; exit(0);
