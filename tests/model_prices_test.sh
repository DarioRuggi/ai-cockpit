#!/usr/bin/env bash
# model_prices_test.sh — the Anthropic model list and its prices (cockpit_app/workers_providers.json) and how workers.php reads them (model_rates: flat price, long-context tier).
# The prices are Anthropic's published ones (platform.claude.com/docs/en/about-claude/pricing, read 2026-10-12): if they change, update the catalog AND this test.   bash tests/model_prices_test.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v php >/dev/null 2>&1 || { echo "model_prices_test: needs php - SKIPPED"; exit 0; }
php -r '
$src = file_get_contents("'"$ROOT"'/cockpit_app/workers.php");
if (!preg_match("/^function model_rates\(.*?^}\n/ms", $src, $m)) { echo "FAIL could not find model_rates in workers.php\n"; exit(1); }
eval($m[0]);
$cat = json_decode(file_get_contents("'"$ROOT"'/cockpit_app/workers_providers.json"), true); $prov = null;
foreach (($cat["providers"] ?? $cat) as $p) if (($p["id"] ?? "") === "anthropic") $prov = $p;
$f = 0; $n = 0; $chk = function ($ok, $msg) use (&$f, &$n) { $n++; if (!$ok) { $f++; echo "  FAIL $msg\n"; } };
$chk($prov !== null, "anthropic provider missing"); if (!$prov) { echo "model_prices_test: 0 passed, 1 failed\n"; exit(1); }
$want = ["claude-haiku-5-5" => [0.1, 0.5], "claude-sonnet-5-5" => [2, 10], "claude-opus-5-5" => [4, 20], "claude-fable-5-1" => [10, 50], "claude-sonnet-4-6" => [3, 15], "claude-opus-4-8" => [5, 25], "claude-haiku-4-5-20251001" => [1, 5]];
foreach ($want as $id => $w) { $r = model_rates($prov, $id, 1000); $chk($r == [(float)$w[0], (float)$w[1]], "$id: rates " . json_encode($r) . " expected " . json_encode($w)); }
$chk(model_rates($prov, "claude-haiku-5-5", 100000) == [0.1, 0.5], "Haiku 5.5 at exactly 100,000 prompt tokens is still the short-prompt price");
$chk(model_rates($prov, "claude-haiku-5-5", 100001) == [0.5, 2.5], "Haiku 5.5 above 100,000 prompt tokens is the long-context price");
$chk(model_rates($prov, "claude-sonnet-5-5", 900000) == [2.0, 10.0], "a model without a long-context tier keeps its price at any size");
$chk(model_rates($prov, "claude-nonexistent", 10) == [0.0, 0.0], "an unknown model has no price (the cap gate refuses it)");
foreach ($prov["models"] as $m) $chk(isset($m["pricing"]["input_per_mtok"], $m["pricing"]["output_per_mtok"]), ($m["id"] ?? "?") . " has no pricing");
$chk(($prov["models"][0]["id"] ?? "") === "claude-haiku-5-5", "the cheapest model must be first (it is the default pick)");
echo "model_prices_test: " . ($n - $f) . " passed, $f failed\n"; exit($f ? 1 : 0);'
