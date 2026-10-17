#!/usr/bin/env bash
# scad_tools_test.sh — the 3D tools (cockpit_app/scad_tool, tools_builtins/scad.json, kinds/3d-printing.json): the STL analyser on hand-made meshes (no OpenSCAD needed), and, with the real
# OpenSCAD INSIDE bubblewrap, compile / export / print check — and a model that tries to read files outside its folder is contained.   bash tests/scad_tools_test.sh
# SKIPPED without php; the OpenSCAD parts without openscad or a working bwrap.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; DT="$ROOT/cockpit_app/scad_tool"
command -v php >/dev/null 2>&1 || { echo "scad_tools_test: php is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
# a 10x10x10 cube as an ASCII STL (12 triangles), watertight; the same with one triangle missing (a hole); and a flat 40x5x1 plate
php -r '
function tri($a,$b,$c){ return "facet normal 0 0 0\n outer loop\n  vertex ".implode(" ",$a)."\n  vertex ".implode(" ",$b)."\n  vertex ".implode(" ",$c)."\n endloop\nendfacet\n"; }
function cube($x,$y,$z){ $v=[[0,0,0],[$x,0,0],[$x,$y,0],[0,$y,0],[0,0,$z],[$x,0,$z],[$x,$y,$z],[0,$y,$z]]; $f=[[0,2,1],[0,3,2],[4,5,6],[4,6,7],[0,1,5],[0,5,4],[1,2,6],[1,6,5],[2,3,7],[2,7,6],[3,0,4],[3,4,7]]; return array_map(fn($t)=>[$v[$t[0]],$v[$t[1]],$v[$t[2]]],$f); }
$w=function($n,$tris){ $s="solid t\n"; foreach($tris as $t) $s.=tri(...$t); file_put_contents($n,$s."endsolid t\n"); };
$c=cube(10,10,10); $w("cube.stl",$c); $w("hole.stl",array_slice($c,1)); $w("plate.stl",cube(40,5,1)); $w("big.stl",cube(300,10,10));
$bin=str_pad("binary header",80,"\0").pack("V",count($c)); foreach($c as $t){ $bin.=pack("f3",0,0,0); foreach($t as $p) $bin.=pack("f3",...$p); $bin.="\0\0"; } file_put_contents("bin.stl",$bin);
// the same cube but every triangle reversed: inside out
$w("inside.stl", array_map(fn($t)=>[$t[0],$t[2],$t[1]],$c));'
php "$DT" info cube.stl i.md >/dev/null; has "Triangles: 12" i.md && has "Bounding box: 10 x 10 x 10 mm" i.md && has "Volume: 1 cm³ (1000 mm³)" i.md && has "Watertight: yes" i.md && ok || bad "cube info: $(sed -n 3,9p i.md)"
php "$DT" info bin.stl ib.md >/dev/null; has "Triangles: 12" ib.md && has "Volume: 1 cm³" ib.md && ok || bad "a BINARY stl: $(sed -n 3,7p ib.md)"
php "$DT" info hole.stl ih.md >/dev/null; has "Watertight: NO (3 open edge(s)" ih.md && ok || bad "a mesh with a missing triangle must not be watertight: $(grep Watertight ih.md)"
php "$DT" print cube.stl p1.md >/dev/null; has "[exit code 0]" p1.md && has "it fits, it is watertight" p1.md && ok || bad "a good cube prints: $(sed -n 8,16p p1.md)"
php "$DT" print hole.stl p2.md >/dev/null; has "the mesh is not watertight" p2.md && ok || bad "an open mesh warns"
php "$DT" print big.stl p3.md bed=220x220x250 >/dev/null; has "[exit code 1]" p3.md && grep -q "300x10x10 mm does not fit a 220x220x250 mm bed in any direction" p3.md || grep -q "300x10x10 mm does not fit a 220x220x250 mm bed" p3.md; ok
has "does not fit" p3.md && ok || bad "a part longer than the bed: $(grep -i fit p3.md)"
php "$DT" print big.stl p4.md bed=350x350x350 >/dev/null; has "[exit code 0]" p4.md && ok || bad "the same part on a bigger bed fits"
php "$DT" print plate.stl p5.md >/dev/null; grep -q "thinner than" p5.md && bad "1 mm flagged as too thin" || ok
php "$DT" print plate.stl p6.md bed=40x5x0.5 >/dev/null 2>&1; php "$DT" print plate.stl p7.md 'bed=big' >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a bad bed was not refused"
php "$DT" print inside.stl p8.md >/dev/null; has "the triangles face inwards" p8.md && ok || bad "an inside-out mesh: $(sed -n 8,14p p8.md)"
printf 'not an stl' > junk.stl; php "$DT" info junk.stl x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a junk .stl was not refused"
php "$DT" info nope.stl x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing file was not refused"
# params (no OpenSCAD needed)
cat > part.scad <<'SC'
/* [Size in mm] */
width = 60;      // outside width
depth = 40; height = 25;   // two on one line
/* [Shape] */
radius = 4;      // corner radius
module m() { inner = 5; cube(inner); }
$fn = 48;
SC
php "$DT" params part.scad pm.md >/dev/null; has "| Size in mm | width | 60 | outside width |" pm.md && has "| Size in mm | depth | 40 |" pm.md && has "| Size in mm | height | 25 | two on one line |" pm.md && has "| Shape | radius | 4 | corner radius |" pm.md && ok || bad "params: $(sed -n 5,12p pm.md)"
grep -q "inner" pm.md && bad "a variable inside a module was listed as a parameter" || ok
php "$DT" new . n.txt part1 >/dev/null; [ -f part1.scad ] && grep -q "width = 60" part1.scad && ok || bad "new part"
php "$DT" new . n2.txt part1 >/dev/null 2>&1; [ $? = 1 ] && ok || bad "new over an existing part was not refused"
# OpenSCAD in the sandbox
if command -v openscad >/dev/null 2>&1 && command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / --unshare-all --die-with-parent true >/dev/null 2>&1; then
  printf 'w = 30; d = 20; h = 10;\ndifference() { cube([w, d, h]); translate([w/2, d/2, -1]) cylinder(h = h + 2, r = 4, $fn = 48); }\n' > good.scad
  printf 'w = 30;\ncube([w, 20, 10]);\ntranslate([1,2,3] cube(5);\n' > bad.scad
  printf 'cube([10, 10, 10]);\ncube(5, centr = true);\nx = undefined_thing;\n' > warn.scad
  printf 'import("/etc/passwd");\ninclude </etc/hostname>\ncube(1);\n' > evil.scad
  php "$DT" check good.scad c.md >/dev/null; has "No problems found." c.md && has "valid solid (2-manifold): yes" c.md && has "Run in a sandbox" c.md && ok || bad "good model: $(sed -n 3,9p c.md)"
  php "$DT" check bad.scad cb.md >/dev/null; grep -qE '^bad\.scad\(3\) Error: Parser error' cb.md && has "[exit code 1]" cb.md && ok || bad "syntax error with its line: $(sed -n 5,10p cb.md)"
  php "$DT" check warn.scad cw.md >/dev/null; has "warn.scad(3) Warning: Ignoring unknown variable 'undefined_thing'" cw.md && has "warn.scad(2) Warning: variable centr not specified" cw.md && ok || bad "warnings: $(grep Warning cw.md)"
  [ "$(grep -cE '^(.+?)\([0-9]+\) (Error|Warning): ' cw.md)" = 2 ] && ok || bad "summary-box regex"
  php "$DT" stl good.scad o.stl >/dev/null; head -c 5 o.stl | grep -q solid && ok || bad "stl export"
  php "$DT" stl good.scad o.3mf >/dev/null; unzip -l o.3mf 2>/dev/null | grep -q "3dmodel" && ok || bad "3mf export"
  php "$DT" stl good.scad o.xyz >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an unknown export format was not refused"
  php "$DT" png good.scad o.png >/dev/null; head -c 8 o.png | grep -q PNG && ok || bad "png"
  php "$DT" info good.scad ig.md >/dev/null; has "Bounding box: 30 x 20 x 10 mm" ig.md && has "Watertight: yes" ig.md && ok || bad "info of a model: $(sed -n 3,9p ig.md)"
  php "$DT" print good.scad pg.md bed=25x25x25 >/dev/null; has "does not fit a 25x25x25 mm bed" pg.md && has "[exit code 1]" pg.md && ok || bad "print of a model on a small bed"
  php "$DT" check bad.scad x.md >/dev/null; php "$DT" stl bad.scad x.stl >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an stl export of a broken model must fail"
  # containment: the model must not read /etc/hostname (the sandbox has no /etc/hostname) nor leak it
  php "$DT" check evil.scad e.md >/dev/null 2>&1; has "Can't open include file '/etc/hostname'" e.md && ok || bad "include of a file outside the folder must fail inside the sandbox: $(sed -n 5,10p e.md)"
  php "$DT" stl evil.scad e.stl >/dev/null 2>&1; [ ! -s e.stl ] || ! grep -q "root:" e.stl && ok || bad "/etc/passwd content reached the output"
  printf 'cube(1);\n' > ok.scad; ln -s /etc/passwd link.scad 2>/dev/null; php "$DT" check ok.scad lk.md >/dev/null; has "No problems found." lk.md && ok || bad "a symlink next to the model broke the run"
  ls -d /tmp/scad_* 2>/dev/null | grep -q . && bad "scratch folders left in /tmp" || ok
  mkdir nobw; for b in php openscad; do ln -s "$(command -v $b)" nobw/$b; done; PATH="$T/nobw" "$(command -v php)" "$DT" check good.scad nb.md >/dev/null 2>nb.err; [ $? = 1 ] && grep -q "bwrap" nb.err && grep -q "not run without it" nb.err && ok || bad "without bwrap the tool must REFUSE: $(cat nb.err)"
else echo "  (openscad or a working bwrap is missing: the compile, export and sandbox checks were skipped)"; fi
php "$DT" frob cube.stl x >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown subcommand was not refused"
head -20 "$ROOT/cockpit_app/scad_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/scad_tool (check|stl|png|info|print|params|new) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/scad.json" > pc 2>&1; [ "$(cat pc)" = 8 ] && ok || bad "scad.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/3d-printing.json")" = scad ] && ok || bad "the kind does not name the tool"
echo "scad_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
