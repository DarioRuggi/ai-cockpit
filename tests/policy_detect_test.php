<?php
// Unit test for the sensitivity detectors (policy_lib.php): positives MUST be found, negatives MUST NOT.
// Run: php tests/policy_detect_test.php      exit 0 = all pass
require_once __DIR__ . '/../cockpit_app/policy_lib.php';
$pos = [   // [text, expected type]
  ['my key AKIAIOSFODNN7EXAMPLE ok',                                    'aws_key'],
  ['token ghp_' . str_repeat('a1B2', 9),                                    'github_token'],
  ['use xoxb-123456789012-abcdefghij',                                      'slack_token'],
  ['AIzaSyA-' . str_repeat('x7Q', 9) . 'abcd',                                'google_key'],
  ['sk_live_' . 'abcdEFGH1234abcdEFGH1234',                                 'stripe_key'],
  ['ANTHROPIC sk-ant-api03-' . str_repeat('Ab3_', 12),                      'api_key'],
  ['eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk', 'jwt'],
  ["-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----", 'private_key'],
  ['DB=postgres://admin:S3cr3tPass!@db.internal:5432/app',                  'url_password'],
  ['password: Tr0ub4dor&3xyz',                                              'password'],
  ['api_key = "k9Xp2LmQ8vRt"',                                              'password'],
  ['card 4111 1111 1111 1111 expires 12/30',                                'card'],
  ['5500-0000-0000-0004',                                                   'card'],
  ['IBAN GB82 WEST 1234 5698 7654 32 please',                               'iban'],
  ['ssn 078-05-1120',                                                       'ssn'],
];
$neg = [   // things that look similar but are NOT secrets
  'order number 4111111111111112 was shipped',            // fails Luhn
  'timestamp 1790967471123 and id 20261002183827',        // digit runs that are not cards
  'phone 054-123-4567 or +972 3 555 1234',                // phones: deliberately not a rule
  'mail me at dario@example.com',                         // e-mail: deliberately not a rule
  'password: your_password_here',                         // placeholder
  'api_key=<YOUR_KEY>',                                   // placeholder
  'token: ${GITHUB_TOKEN}',                               // env reference
  'secret = process.env.SECRET',                          // env lookup
  'password: password',                                   // a plain word
  'The password policy requires 12 characters.',          // prose
  'sha256 3b7e1f0a9c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7', // a hash
  'uuid 123e4567-e89b-12d3-a456-426614174000',
  'version 2.0.0 build 177, 2026-10-02 17:57:51',
  'GB82 1234 is not an IBAN',
  'SSN 000-12-3456 and 666-12-3456 and 987-65-4321',      // invalid SSN ranges
  'use sk-learn for ML',                                  // "sk-" prefix too short
  'xxxx xxxx xxxx xxxx 4444',
];
$fail = 0; $i = 0;
foreach ($pos as [$t, $type]) { $i++; $f = array_column(policy_detect($t), 'type'); if (!in_array($type, $f, true)) { $fail++; echo "MISSED   [$type]  " . substr($t, 0, 60) . "   (found: " . implode(',', $f) . ")\n"; } }
foreach ($neg as $t) { $i++; $f = policy_detect($t); if ($f) { $fail++; echo "FALSE+   " . substr($t, 0, 60) . "   (found: " . implode(',', array_column($f, 'type')) . ")\n"; } }
// redaction removes every secret and keeps the rest
$t = "key AKIAIOSFODNN7EXAMPLE and card 4111 1111 1111 1111 done"; $r = policy_redact($t, policy_detect($t));
if (strpos($r, 'AKIA') !== false || strpos($r, '4111') !== false || strpos($r, 'done') === false || substr_count($r, '[REDACTED:') !== 2) { $fail++; echo "REDACT   wrong: $r\n"; }
// previews never contain more than 4 characters of the value
foreach (policy_detect('AKIAIOSFODNN7EXAMPLE') as $f) if (mb_strlen($f['preview']) > 5) { $fail++; echo "PREVIEW  too long: {$f['preview']}\n"; }
echo ($fail ? "FAILED $fail of " : "OK: all ") . ($i + 2) . " checks\n"; exit($fail ? 1 : 0);
