<?php
// =============================================================================
// policy_lib.php — what may leave this machine, and what paid agents may be used.
//
// Three rules, one place, run by bridge.php BEFORE a prompt is queued for an agent:
//
//   1. SENSITIVITY GATE   a prompt that is about to go to an online agent is scanned for secrets
//                         (private keys, API keys and tokens, passwords in assignments, connection
//                         strings with a password) and for payment/identity numbers that pass their
//                         own checksum (cards by Luhn, IBANs by mod 97, US SSNs). Local agents are
//                         never gated: nothing leaves the machine. The person chooses: redact and
//                         send, send anyway, switch to a local model, or cancel (or sets a standing
//                         action in Privacy & spending).
//   2. FREE-ONLY          when on, agents that need a paid plan are refused with a plain message.
//                         Default ON for a NEW install, OFF for an install that already has history,
//                         so an upgrade never starts refusing the agent someone has been using.
//   3. MONTHLY BUDGET     a limit on paid-agent PROMPTS per calendar month (UTC). Cockpit cannot see
//                         what a subscription CLI bills, so it counts what it can honestly measure.
//                         A warning at 80%, a stop at 100% that can be overridden once per prompt.
//
// Detection is deliberately HIGH PRECISION: a gate that cries wolf is switched off within a day. So
// there is no "looks like an e-mail" or "looks like a phone number" rule, card/IBAN/SSN need a valid
// checksum, and placeholders ("your_api_key", "xxxx", "<token>", "${KEY}") are ignored.
//
// Nothing found is ever written to disk or returned in full: findings carry a TYPE, a count and a
// masked preview (first 4 characters). The ledger stores agent names and timestamps only.
// =============================================================================
require_once __DIR__ . '/paths.php';

function policy_dir(): string { global $PATHS; return rtrim((string)($PATHS['cockpit_data'] ?? ''), '/'); }
function policy_file(): string { return policy_dir() . '/policy.json'; }
function policy_ledger_file(): string { return policy_dir() . '/policy_ledger.jsonl'; }

// ---- settings ---------------------------------------------------------------------------------
function policy_defaults(bool $existing): array {
    return [
        'version'    => 1,
        'gate'       => ['enabled' => true, 'action' => 'ask'],       // action: ask | redact | block
        'free_only'  => !$existing,
        'link_stay_free' => true,                                         // Stay Free (Suppliers) <-> Free agents only (here)
        'budget'     => ['paid_prompts_per_month' => 0, 'warn_at' => 0.8],   // 0 = no limit
        'created'    => gmdate('c'),
        'created_as' => $existing ? 'existing install' : 'new install',
    ];
}
/** An install with history already depends on its agents: free-only must not start refusing them. */
function policy_existing_install(): bool {
    $f = policy_dir() . '/cost_stats.json';
    if (!is_file($f)) return false;
    $d = json_decode((string)@file_get_contents($f), true);
    foreach ((array)($d['projects'] ?? []) as $p) if ((int)($p['turns'] ?? 0) > 0) return true;
    return false;
}
function policy_load(): array {
    $f = policy_file();
    $d = is_file($f) ? json_decode((string)@file_get_contents($f), true) : null;
    if (!is_array($d)) { $d = policy_defaults(policy_existing_install()); policy_save($d); }
    $def = policy_defaults(false);
    $d['gate']   = array_merge($def['gate'],   (array)($d['gate'] ?? []));
    $d['budget'] = array_merge($def['budget'], (array)($d['budget'] ?? []));
    $d['free_only'] = (bool)($d['free_only'] ?? false);
    $d['link_stay_free'] = (bool)($d['link_stay_free'] ?? true);
    if (!in_array($d['gate']['action'], ['ask', 'strict', 'redact', 'block'], true)) $d['gate']['action'] = 'ask';
    return $d;
}
function policy_save(array $d): bool {
    $dir = policy_dir(); if ($dir === '') return false;
    if (!is_dir($dir)) @mkdir($dir, 0775, true);
    $ok = @file_put_contents(policy_file(), json_encode($d, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE) . "\n", LOCK_EX) !== false;
    if ($ok) @chmod(policy_file(), 0664);
    return $ok;
}
/** Validate and store a settings change from the UI. Returns the saved settings. */
function policy_update(array $in): array {
    $d = policy_load();
    if (isset($in['gate']['enabled']))  $d['gate']['enabled'] = (bool)$in['gate']['enabled'];
    if (isset($in['gate']['action']) && in_array($in['gate']['action'], ['ask', 'strict', 'redact', 'block'], true)) $d['gate']['action'] = $in['gate']['action'];
    if (isset($in['free_only']))        $d['free_only'] = (bool)$in['free_only'];
    if (isset($in['link_stay_free']))   $d['link_stay_free'] = (bool)$in['link_stay_free'];
    if (isset($in['budget']['paid_prompts_per_month'])) $d['budget']['paid_prompts_per_month'] = max(0, min(100000, (int)$in['budget']['paid_prompts_per_month']));
    policy_save($d);
    return $d;
}

// ---- which agent is this, and does it leave the machine / need a paid plan? ----------------------
function policy_catalog(): array {
    $CLI_CATALOG_DEFAULT = [];
    $f = __DIR__ . '/cli_catalog_default.php';
    if (is_file($f)) { require $f; }
    $cat = (array)$CLI_CATALOG_DEFAULT;
    $ov = policy_dir() . '/cli_suppliers.json';
    $o = is_file($ov) ? json_decode((string)@file_get_contents($ov), true) : null;
    if (is_array($o)) foreach ($o as $id => $e) if (is_array($e)) $cat[$id] = array_merge((array)($cat[$id] ?? []), $e);
    return $cat;
}
function policy_agent_info(string $agent): array {
    $slots = ['primary' => 'claude', 'fallback' => 'codex'];
    $sf = policy_dir() . '/supplier_slots.json';
    $s = is_file($sf) ? json_decode((string)@file_get_contents($sf), true) : null;
    if (is_array($s)) { $slots['primary'] = (string)($s['primary'] ?? $slots['primary']); $slots['fallback'] = (string)($s['fallback'] ?? $slots['fallback']); }
    if ($agent === 'ollama' || $agent === 'tools') return ['supplier' => $agent, 'name' => $agent, 'kind' => 'local', 'paid' => false, 'cloud' => false];
    if ($agent === 'workers') return ['supplier' => 'workers', 'name' => 'Workers', 'kind' => 'free_rest', 'paid' => false, 'cloud' => true];
    $sid = $agent === 'claude' ? $slots['primary'] : ($agent === 'gemini' ? $slots['fallback'] : $agent);
    $c = (array)(policy_catalog()[$sid] ?? []);
    $kind = (string)($c['kind'] ?? 'unknown');
    $local = (($c['backend'] ?? '') === 'ollama');           // aider/goose/opencode wired to the local Ollama
    return ['supplier' => $sid, 'name' => (string)($c['name'] ?? $sid), 'kind' => $kind,
            'paid' => ($kind === 'paid_cli' && empty($c['free'])), 'cloud' => !$local];   // same test as Stay Free: an agent flagged free is never 'paid'
}

// ---- detectors ---------------------------------------------------------------------------------
function policy_luhn(string $digits): bool {
    $sum = 0; $alt = false;
    for ($i = strlen($digits) - 1; $i >= 0; $i--) {
        $n = (int)$digits[$i]; if ($alt) { $n *= 2; if ($n > 9) $n -= 9; } $sum += $n; $alt = !$alt;
    }
    return $sum % 10 === 0;
}
function policy_iban_ok(string $iban): bool {
    $s = strtoupper(preg_replace('/\s+/', '', $iban));
    if (!preg_match('/^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$/', $s)) return false;
    $r = substr($s, 4) . substr($s, 0, 4); $num = '';
    foreach (str_split($r) as $ch) $num .= ctype_alpha($ch) ? (string)(ord($ch) - 55) : $ch;
    $rem = 0; foreach (str_split($num, 7) as $chunk) $rem = (int)($rem . $chunk) % 97;
    return $rem === 1;
}
function policy_is_placeholder(string $v): bool {
    $l = strtolower($v);
    if (preg_match('/^[x*#.\-_•]+$/', $l)) return true;                                   // xxxx, ****, ----
    if (preg_match('/[<>{}$]|\bexample\b|placeholder|your[_ -]?(api|key|token|pass|secret)|changeme|redacted|\.\.\.|process\.env|getenv|os\.environ/i', $v)) return true;
    if (preg_match('/^(true|false|null|none|undefined|string|password|secret|token)$/i', $v)) return true;
    return false;
}
function policy_entropy(string $s): float {
    $n = strlen($s); if ($n === 0) return 0.0; $f = count_chars($s, 1); $e = 0.0;
    foreach ($f as $c) { $p = $c / $n; $e -= $p * log($p, 2); } return $e;
}
/** @return array<int,array{type:string,label:string,start:int,len:int,preview:string}> */
function policy_detect(string $text): array {
    $out = [];
    $add = function (string $type, string $label, int $start, int $len) use (&$out, $text) {
        foreach ($out as $o) if ($start < $o['start'] + $o['len'] && $start + $len > $o['start']) return;   // overlap: first rule wins
        $raw = substr($text, $start, $len);
        $out[] = ['type' => $type, 'label' => $label, 'start' => $start, 'len' => $len,
                  'preview' => mb_substr(preg_replace('/\s+/', ' ', $raw), 0, 4) . '…'];
    };
    $rules = [
        ['private_key', 'a private key',            '/-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY(?: BLOCK)?-----.*?(?:-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----|\z)/s'],
        ['aws_key',     'an AWS access key',        '/\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/'],
        ['github_token','a GitHub token',           '/\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})\b/'],
        ['slack_token', 'a Slack token',            '/\bxox[abprs]-[A-Za-z0-9-]{10,}\b/'],
        ['google_key',  'a Google API key',         '/\bAIza[0-9A-Za-z_\-]{35}\b/'],
        ['stripe_key',  'a Stripe live key',        '/\b[sr]k_live_[0-9A-Za-z]{20,}\b/'],
        ['api_key',     'an API key (sk-…)',        '/\bsk-(?:ant-|proj-)?[A-Za-z0-9_\-]{32,}\b/'],
        ['jwt',         'a JSON web token',         '/\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/'],
    ];
    foreach ($rules as [$type, $label, $re]) {
        if (preg_match_all($re, $text, $m, PREG_OFFSET_CAPTURE)) foreach ($m[0] as [$v, $o]) $add($type, $label, $o, strlen($v));
    }
    // user:password@host in a URL / connection string
    if (preg_match_all('~\b[a-z][a-z0-9+.\-]*://[^\s:@/]+:([^\s@/]{3,})@~i', $text, $m, PREG_OFFSET_CAPTURE)) {
        foreach ($m[1] as [$v, $o]) if (!policy_is_placeholder($v)) $add('url_password', 'a password inside a connection string', $o, strlen($v));
    }
    // password / secret / token = value  (only the VALUE is matched, and only when it looks like one)
    if (preg_match_all('/\b(?:pass(?:word|wd)?|passphrase|secret|client[_-]?secret|api[_-]?key|access[_-]?key|auth[_-]?token|token)\b["\']?\s*[:=]\s*["\']?([^\s"\'`,;]{8,})/i', $text, $m, PREG_OFFSET_CAPTURE)) {
        foreach ($m[1] as [$v, $o]) {
            if (policy_is_placeholder($v)) continue;
            if (!preg_match('/\d/', $v) && !preg_match('/[A-Z]/', $v) && policy_entropy($v) < 3.0) continue;   // a plain word is not a secret
            $add('password', 'a password or secret value', $o, strlen($v));
        }
    }
    // payment cards: 13-19 digits, Luhn, plausible leading digit, not a repeated digit
    if (preg_match_all('/(?<![\d.])(?:\d[ \-]?){12,18}\d(?![\d])/', $text, $m, PREG_OFFSET_CAPTURE)) {
        foreach ($m[0] as [$v, $o]) {
            $d = preg_replace('/\D/', '', $v);
            if (strlen($d) < 13 || strlen($d) > 19 || !in_array($d[0], ['2', '3', '4', '5', '6'], true)) continue;
            if (preg_match('/^(\d)\1+$/', $d) || !policy_luhn($d)) continue;
            $add('card', 'a payment card number', $o, strlen($v));
        }
    }
    if (preg_match_all('/\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,4})?\b/', $text, $m, PREG_OFFSET_CAPTURE)) {
        foreach ($m[0] as [$v, $o]) if (policy_iban_ok($v)) $add('iban', 'a bank account number (IBAN)', $o, strlen($v));
    }
    if (preg_match_all('/(?<![\d-])(\d{3})-(\d{2})-(\d{4})(?![\d-])/', $text, $m, PREG_OFFSET_CAPTURE, 0)) {
        foreach ($m[0] as $i => [$v, $o]) {
            $a = (int)$m[1][$i][0];
            if ($a === 0 || $a === 666 || $a >= 900 || (int)$m[2][$i][0] === 0 || (int)$m[3][$i][0] === 0) continue;
            $add('ssn', 'a US social security number', $o, strlen($v));
        }
    }
    usort($out, fn($a, $b) => $a['start'] <=> $b['start']);
    return $out;
}
function policy_redact(string $text, array $findings): string {
    usort($findings, fn($a, $b) => $b['start'] <=> $a['start']);               // from the end, offsets stay valid
    foreach ($findings as $f) $text = substr($text, 0, $f['start']) . '[REDACTED:' . $f['type'] . ']' . substr($text, $f['start'] + $f['len']);
    return $text;
}
/** Group findings for display: one row per type with a count and masked previews. */
function policy_summarise(array $findings): array {
    $g = [];
    foreach ($findings as $f) { $g[$f['type']] ??= ['type' => $f['type'], 'label' => $f['label'], 'count' => 0, 'previews' => []]; $g[$f['type']]['count']++; if (count($g[$f['type']]['previews']) < 2) $g[$f['type']]['previews'][] = $f['preview']; }
    return array_values($g);
}

// ---- the monthly budget ------------------------------------------------------------------------
function policy_month_used(?string $month = null): int {
    $f = policy_ledger_file(); if (!is_file($f)) return 0;
    $month = $month ?? gmdate('Y-m'); $n = 0;
    foreach ((array)@file($f, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $l) {
        $r = json_decode($l, true);
        if (is_array($r) && !empty($r['paid']) && substr((string)($r['t'] ?? ''), 0, 7) === $month) $n++;
    }
    return $n;
}
function policy_ledger_add(array $info): void {
    $dir = policy_dir(); if ($dir === '') return;
    @file_put_contents(policy_ledger_file(), json_encode(['t' => gmdate('c'), 'agent' => $info['supplier'], 'paid' => (bool)$info['paid']]) . "\n", FILE_APPEND | LOCK_EX);
    @chmod(policy_ledger_file(), 0664);
}

// ---- the decision ------------------------------------------------------------------------------
/**
 * Decide what happens to a prompt headed for $agent.
 * @return array allow: ['allow'=>true,'prompt'=>string,'notes'=>string[],'info'=>array]
 *         refuse: ['allow'=>false,'policy'=>['type'=>..., 'message'=>..., 'findings'=>[...], 'options'=>[...]]]
 * $ov = what the person already decided for THIS prompt: ['gate'=>'redact'|'anyway', 'spend_ok'=>true]
 */
function policy_check(string $prompt, string $agent, array $ov = [], bool $record = true): array {
    $pol  = policy_load();
    $info = policy_agent_info($agent);
    $notes = [];

    if ($pol['free_only'] && $info['paid']) {
        return ['allow' => false, 'policy' => [
            'type' => 'free_only', 'agent' => $info['name'],
            'message' => $info['name'] . ' needs a paid plan, and "free agents only" is on. Pick a free or local agent for this card, or turn the switch off in Privacy & spending.',
            'findings' => [], 'options' => ['settings', 'cancel']]];
    }
    if ($info['paid']) {
        $cap = (int)$pol['budget']['paid_prompts_per_month'];
        if ($cap > 0) {
            $used = policy_month_used();
            if ($used >= $cap && empty($ov['spend_ok'])) {
                return ['allow' => false, 'policy' => [
                    'type' => 'budget', 'agent' => $info['name'], 'used' => $used, 'cap' => $cap,
                    'message' => 'You have used ' . $used . ' of your ' . $cap . ' paid-agent prompts this month. Sending this one goes over your limit.',
                    'findings' => [], 'options' => ['spend_ok', 'settings', 'cancel']]];
            }
            if ($used + 1 >= (int)ceil($cap * (float)$pol['budget']['warn_at']) && $used < $cap) {
                $notes[] = 'Paid-agent prompts this month: ' . ($used + 1) . ' of ' . $cap . '.';
            }
        }
    }
    if ($pol['gate']['enabled'] && $info['cloud']) {
        $found = policy_detect($prompt);
        if ($found) {
            $act = $ov['gate'] ?? null;
            if ($act === null && $pol['gate']['action'] !== 'ask') $act = $pol['gate']['action'];     // redact | strict | block
            if ($act === 'redact') {
                $prompt = policy_redact($prompt, $found);
                $labels = array_map(fn($g) => $g['count'] . '× ' . $g['label'], policy_summarise($found));
                $notes[] = 'Redacted before sending to ' . $info['name'] . ': ' . implode(', ', $labels) . '.';
            } elseif ($act === 'anyway') {
                $notes[] = 'Sent to ' . $info['name'] . ' with ' . count($found) . ' sensitive item(s), as you chose.';
            } else {
                $kind = $act === 'block' ? 'sensitive_blocked' : ($act === 'strict' ? 'sensitive_strict' : 'sensitive');
                $tail = $act === 'block'  ? ' Your setting is to never send this.'
                      : ($act === 'strict' ? ' Your setting is to keep this off online agents unless you choose, each time, to send it.' : '');
                return ['allow' => false, 'policy' => [
                    'type' => $kind, 'agent' => $info['name'],
                    'message' => 'This looks like it contains ' . implode(', ', array_map(fn($g) => ($g['count'] > 1 ? $g['count'] . '× ' : '') . $g['label'], policy_summarise($found)))
                               . ', and ' . $info['name'] . ' is an online service.' . $tail,
                    'findings' => policy_summarise($found),
                    // strict: the safe choices come first and sending it as written needs a second, explicit confirmation
                    'options'  => $act === 'block'  ? ['redact', 'local', 'cancel']
                                : ($act === 'strict' ? ['local', 'redact', 'cancel', 'anyway'] : ['redact', 'local', 'anyway', 'cancel']),
                    'confirm'  => $act === 'strict' ? ['anyway'] : []]];
            }
        }
    }
    if ($info['paid'] && $record) policy_ledger_add($info);
    return ['allow' => true, 'prompt' => $prompt, 'notes' => $notes, 'info' => $info];
}
