<?php
// tests/standards_test.php — the Pascal standards checker against a small fixture project.
define('PASCAL_STANDARDS_LIB', 1);
require __DIR__ . '/../cockpit_app/pascal_standards.php';
$d = sys_get_temp_dir() . '/ps_test_' . getmypid(); @mkdir($d);
file_put_contents("$d/main.pas", <<<'PAS'
unit main;
{$mode objfpc}{$H+}
interface
uses
  Classes, SysUtils, Forms,
  {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  ShellAPI;
resourcestring
  rsOk = 'Fine text here';
implementation
procedure T.A;
begin
  Caption := 'Save the file';
  Label1.Caption := rsOk;
  // Caption := 'in a comment';
  { ShowMessage('in a brace comment') }
  ShowMessage('Something happened');
  Edit1.Text := 'it''s here';
  Edit2.Text := '';
  Path := 'C:\Users\x\file.txt';
  Path2 := Dir + '\' + Name;
  raise Exception.Create('Disk is full');
  x := GetWindowsDirectory(nil, 0);
  {$IFDEF WINDOWS}
  y := GetWindowsDirectory(nil, 0);
  {$ENDIF}
  Hint := 'x';
end;
end.
PAS);
file_put_contents("$d/main.lfm", "object F: TF\n  Caption = 'Main window'\n  Hint = 'ab'\n  Name = 'Button1'\nend\n");
$r = ps_scan($d); $by = []; foreach ($r['findings'] as $x) $by[$x['rule']][] = $x['line'] . ':' . substr($x['message'], 0, 24);
$fail = 0; function ok($c, $m) { global $fail; echo ($c ? 'ok   ' : 'FAIL ') . $m . "\n"; if (!$c) $fail++; }
$lines = fn($rule) => array_map(fn($x) => (int)$x, $by[$rule] ?? []);
$msgs = implode("\n", array_map(fn($x) => $x['message'], $r['findings']));
ok(strpos($msgs, "Caption := 'Save the file'") !== false, 'flags a typed Caption');
ok(strpos($msgs, 'in a comment') === false && strpos($msgs, 'brace comment') === false, 'ignores strings inside comments');
ok(strpos($msgs, 'rsOk') === false && strpos($msgs, 'Fine text here') === false, 'ignores resourcestring contents and uses');
ok(strpos($msgs, 'Something happened') !== false, 'flags ShowMessage text');
ok(strpos($msgs, "it''s here") !== false, 'handles doubled quotes');
ok(strpos($msgs, "Text := ''") === false && strpos($msgs, "Hint := 'x'") === false, 'skips empty and one-letter strings');
ok(strpos($msgs, 'Disk is full') !== false, 'flags exception text');
ok(strpos($msgs, 'Main window') !== false && strpos($msgs, "form Hint = 'ab'") !== false, 'flags .lfm captions');
ok(strpos($msgs, 'unit shellapi') !== false, 'flags unguarded ShellAPI');
ok(strpos($msgs, 'unit windows') === false, 'accepts guarded Windows unit');
ok(substr_count($msgs, 'GetWindowsDirectory') === 1, 'flags the unguarded API call once, not the guarded one');
ok(strpos($msgs, 'drive-letter') !== false, 'flags a drive-letter path');
ok(strpos($msgs, 'PathDelim') !== false, "flags '\\' where PathDelim belongs");
ok(isset($r['counts']['theme']), 'reports the missing dark/light switch');
$rs = ps_resources($r['strings']);
ok(strpos($rs, "rsSaveTheFile = 'Save the file'") !== false && strpos($rs, 'resourcestring') !== false, 'generates a resourcestring unit');
exec('rm -rf ' . escapeshellarg($d));
echo $fail ? "$fail FAILED\n" : "all passed\n"; exit($fail ? 1 : 0);
