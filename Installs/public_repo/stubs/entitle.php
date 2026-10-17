<?php
// entitle.php — in the full product this reads which plan an install has (from the account layer) and gates the paid surfaces.
// The open-source release has no account layer, so there is nothing to ask: every capability that works on this computer is allowed.
// (What needs a server of ours — the phone relay, publishing, early builds — has no server here.)
function cockpit_machine_fp(): string { return ''; }
function cockpit_app_major(): int { $v = trim((string)@file_get_contents(__DIR__ . '/VERSION')); return (int)($v !== '' ? explode('.', $v)[0] : 2); }
function cockpit_entitlement(): array { return ['tier' => 'open', 'beta' => true, 'can_cruise' => true, 'can_cognition' => true, 'can_everywhere' => false, 'can_content' => false]; }
function cap_allowed(string $cap): bool { return $cap !== 'everywhere'; }
function require_cap(string $cap): void { /* allowed */ }
