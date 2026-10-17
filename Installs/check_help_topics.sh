#!/usr/bin/env bash
# =============================================================================
# check_help_topics.sh — every help key the UI uses must have a help topic.
#
# Two places name a topic by key: the data-help="..." attributes in index.html
# (F1 and the expanded hover hint open that topic) and the `help:` field of each
# step in the guided tour. A key with no entry in help_default.json shows nothing —
# no error, just an F1 that does not help.
#
# Found 2026-10-01 while catching the docs up: the Apps button (launch-apps) and
# the PLAN button (plan-btn) had no topic, and the Toolbar panel carried two
# data-help attributes on one element (the browser keeps the first), so it was
# really answering for the left sidebar. Nothing flagged any of it.
#
# This is the "correct the help" half of the release-docs rule, made mechanical.
# =============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/cockpit_app"
php -r '
$app = $argv[1];
$idx = file_get_contents("$app/index.html");
$tour = file_get_contents("$app/js/panels/right-help-tour.js");
$t = json_decode(file_get_contents("$app/help_default.json"), true)["topics"] ?? [];
$bad = 0;
preg_match_all("/data-help=\"([a-z0-9_-]+)\"/i", $idx, $m);
foreach (array_unique($m[1]) as $k) if (!isset($t[$k])) { echo "  index.html: data-help=\"$k\" has no help topic\n"; $bad++; }
// the tour steps live between TUTORIAL_STEPS and its closing bracket
$i = strpos($tour, "const TUTORIAL_STEPS"); $j = strpos($tour, "\n];", $i);
preg_match_all("/help:\s*\x27([a-z0-9_-]+)\x27/i", substr($tour, $i, $j - $i), $s);
foreach (array_unique($s[1]) as $k) if (!isset($t[$k])) { echo "  tour step: help: \x27$k\x27 has no help topic\n"; $bad++; }
// one element, one data-help: a second attribute is silently ignored
if (preg_match_all("/<[a-z0-9]+\b[^>]*data-help=\"[^\"]*\"[^>]*data-help=\"[^\"]*\"[^>]*>/is", $idx, $d))
    foreach ($d[0] as $el) { echo "  index.html: an element carries TWO data-help attributes: " . substr(preg_replace("/\s+/", " ", $el), 0, 90) . "...\n"; $bad++; }
if ($bad) { echo "check_help_topics: $bad problem(s)\n"; exit(1); }
echo "check_help_topics: every data-help key and tour step has a topic (" . count($t) . " topics)\n";
' "$APP"
