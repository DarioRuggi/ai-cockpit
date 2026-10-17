<?php
// slides_fixture.php DECK.pptx OUTDIR — variants of a pandoc-made deck for tests/slides_tools_test.sh: tiny.pptx (a 10 pt run and four fonts on slide 2), macro.pptm (a vbaProject.bin added)
[$deck, $d] = [$argv[1] ?? '', $argv[2] ?? '']; if (!is_file($deck) || $d === '') { fwrite(STDERR, "usage: slides_fixture.php DECK.pptx OUTDIR\n"); exit(2); }
@mkdir($d, 0775, true);
copy($deck, "$d/tiny.pptx"); $z = new ZipArchive(); $z->open("$d/tiny.pptx");
$x = $z->getFromName('ppt/slides/slide2.xml');
$x = preg_replace('~<a:rPr\s*/>~', '<a:rPr sz="1000"><a:latin typeface="FontA"/></a:rPr>', $x, 1);
$x = preg_replace('~<a:rPr\s*/>~', '<a:rPr><a:latin typeface="FontB"/></a:rPr>', $x, 1);
$x = preg_replace('~<a:rPr\s*/>~', '<a:rPr><a:latin typeface="FontC"/></a:rPr>', $x, 1);
$z->addFromString('ppt/slides/slide2.xml', $x);
$y = $z->getFromName('ppt/slides/slide3.xml'); $y = preg_replace('~<a:rPr\s*/>~', '<a:rPr><a:latin typeface="FontD"/></a:rPr>', $y, 1); $z->addFromString('ppt/slides/slide3.xml', $y); $z->close();
copy($deck, "$d/macro.pptm"); $z = new ZipArchive(); $z->open("$d/macro.pptm"); $z->addFromString('ppt/vbaProject.bin', "\xD0\xCF\x11\xE0stub"); $z->close();
echo "wrote $d\n";
