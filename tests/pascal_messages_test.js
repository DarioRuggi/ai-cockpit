// pascal_messages_test.js — js/features/dialogs-tools-run.js _pascalParseMessages(): the compiler messages of a Pascal / Lazarus build,
// counted and listed the way the Tools panel shows them.   node tests/pascal_messages_test.js
const fs = require('fs'), vm = require('vm'), cp = require('child_process'), os = require('os'), path = require('path');
const src = fs.readFileSync(__dirname + '/../cockpit_app/js/features/dialogs-tools-run.js', 'utf8');
const m = src.match(/function _pascalParseMessages\(text\) \{[\s\S]*?\n\}\n/);
if (!m) { console.log('FAIL could not find _pascalParseMessages'); process.exit(1); }
const ctx = {}; vm.createContext(ctx); vm.runInContext(m[0], ctx);
let fails = 0, n = 0; const eq = (name, got, want) => { n++; const g = JSON.stringify(got), w = JSON.stringify(want); if (g !== w) { fails++; console.log('FAIL ' + name + ': ' + g + ' want ' + w); } };
const real = `Free Pascal Compiler version 3.2.2 [2021/05/16] for x86_64
Compiling broken.pas
broken.pas(4,8) Error: Incompatible types: got "Constant String" expected "SmallInt"
broken.pas(5,3) Error: Identifier not found "UndefinedThing"
broken.pas(7) Fatal: There were 2 errors compiling module, stopping
Fatal: Compilation aborted
Error: /usr/bin/ppcx64 returned an error exitcode
[exit code 1]`;
let p = ctx._pascalParseMessages(real);
eq('two real errors, the fpc summary line is not a third', p.errors.length, 2);
eq('first error has file, line, column, message', p.errors[0], { file: 'broken.pas', line: 4, col: 8, kind: 'Error', msg: 'Incompatible types: got "Constant String" expected "SmallInt"' });
eq('exit code is read', p.exit, 1);
p = ctx._pascalParseMessages('Compiling x.pas\nx.pas(3,5) Warning: (5024) Parameter "a" not used\nx.pas(9,1) Hint: (5028) Local const "k" is not used\nx.pas(10,1) Note: (3123) "begin" not needed\nLinking x\n[exit code 0]');
eq('warnings and hints are counted, numbered ids are skipped', [p.errors.length, p.warnings, p.hints, p.exit], [0, 1, 2, 0]);
p = ctx._pascalParseMessages('/home/u/proj/unit1.pas(12) Error: (2003) Identifier not found "Foo"\n[exit code 2]');
eq('a path, and no column', p.errors[0], { file: '/home/u/proj/unit1.pas', line: 12, col: 0, kind: 'Error', msg: 'Identifier not found "Foo"' });
eq('an empty answer is harmless', ctx._pascalParseMessages(''), { errors: [], warnings: 0, hints: 0, exit: null });
// and against the real compiler when it is here
try {
    const d = fs.mkdtempSync(path.join(os.tmpdir(), 'pm_')); fs.writeFileSync(d + '/b.pas', "program b;\nvar n: Integer;\nbegin\n  n := 'x';\nend.\n");
    const r = cp.spawnSync('fpc', ['-Cn', '-vewnh', '-FU' + d, '-FE' + d, d + '/b.pas'], { encoding: 'utf8' });
    const q = ctx._pascalParseMessages(r.stdout + r.stderr + '[exit code ' + r.status + ']');
    eq('the real fpc: one error on line 4', [q.errors.length, q.errors[0] && q.errors[0].line, q.exit], [1, 4, 1]);
} catch (e) { /* no fpc: skipped */ }
console.log('pascal_messages_test: ' + n + ' checks, ' + fails + ' failure(s)'); process.exit(fails ? 1 : 0);
