<?php
// macro_fixture.php OUTDIR — writes small macro-enabled Office files made with cockpit_app/vba_lib.php: macro.xlsm and macro.docm (each with a
// procedural module and an auto-run procedure; Spanish text in Windows-1252), plus the module source as macro_module1.bas for comparison.
// There is no Office on the rig, so these are made by our own writer and validated by LibreOffice, an independent reader.
require __DIR__ . '/../cockpit_app/vba_lib.php';
$d = $argv[1] ?? ''; if ($d === '') { fwrite(STDERR, "usage: macro_fixture.php OUTDIR\n"); exit(2); }
@mkdir($d, 0775, true);
$src1 = "Attribute VB_Name = \"Module1\"\r\nOption Explicit\r\n\r\n' C\xE1lculo del IVA: \xBFcu\xE1nto es?\r\nPublic Function Iva(ByVal importe As Double) As Double\r\n    Iva = importe * 0.21\r\nEnd Function\r\n\r\nSub Auto_Open()\r\n    MsgBox \"Hola desde la macro\"\r\n    Dim fso As Object\r\n    Set fso = CreateObject(\"Scripting.FileSystemObject\")\r\nEnd Sub\r\n";
file_put_contents("$d/macro_module1.bas", $src1);
$bin = vba_build(['Module1' => $src1]);
file_put_contents("$d/vbaProject.bin", $bin);
function zipit(string $path, array $files): void { @unlink($path); $z = new ZipArchive(); $z->open($path, ZipArchive::CREATE); foreach ($files as $n => $c) $z->addFromString($n, $c); $z->close(); }
$rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">';
zipit("$d/macro.xlsm", [
 '[Content_Types].xml' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="bin" ContentType="application/vnd.ms-office.vbaProject"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.ms-excel.sheet.macroEnabled.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
 '_rels/.rels' => $rels . '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
 'xl/workbook.xml' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Hoja1" sheetId="1" r:id="rId1"/></sheets></workbook>',
 'xl/_rels/workbook.xml.rels' => $rels . '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.microsoft.com/office/2006/relationships/vbaProject" Target="vbaProject.bin"/></Relationships>',
 'xl/worksheets/sheet1.xml' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1"><v>100</v></c><c r="B1"><f>A1*0.21</f><v>21</v></c></row></sheetData></worksheet>',
 'xl/vbaProject.bin' => $bin]);
zipit("$d/macro.docm", [
 '[Content_Types].xml' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="bin" ContentType="application/vnd.ms-office.vbaProject"/><Override PartName="/word/document.xml" ContentType="application/vnd.ms-word.document.macroEnabled.main+xml"/></Types>',
 '_rels/.rels' => $rels . '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
 'word/_rels/document.xml.rels' => $rels . '<Relationship Id="rId1" Type="http://schemas.microsoft.com/office/2006/relationships/vbaProject" Target="vbaProject.bin"/></Relationships>',
 'word/document.xml' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Documento con macro</w:t></w:r></w:p></w:body></w:document>',
 'word/vbaProject.bin' => $bin]);
echo "wrote $d\n";
