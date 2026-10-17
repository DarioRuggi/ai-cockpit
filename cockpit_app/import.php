<?php
require_once __DIR__ . "/auth.php";
// =============================================================================
// import.php — Cockpit chat import
//
// Accepts either:
//   - A .zip file produced by export.php (preferred)
//   - A bare .json file (raw Cockpit chat format)
//
// POST: multipart/form-data with:
//   file        — uploaded file
//   project     — target project slug (defaults to "_standalone")
//   chat_name   — target chat slug (optional; falls back to source name)
//   overwrite   — "1" if existing chats with same slug should be replaced
// =============================================================================

header('Content-Type: application/json');
header('Cache-Control: no-store');

define('COCKPIT_ROOT', $PATHS['projects_root']);

function safeName($s) {
    return preg_replace('/[^a-zA-Z0-9_\-]/', '', (string)$s);
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
    echo json_encode(['ok'=>false,'error'=>'POST only'], JSON_UNESCAPED_UNICODE); exit;
}

if (empty($_FILES['file']) || $_FILES['file']['error'] !== UPLOAD_ERR_OK) {
    echo json_encode(['ok'=>false,'error'=>(cockpit_upload_limit_message() ?: 'No file uploaded')], JSON_UNESCAPED_UNICODE); exit;
}

$tmp     = $_FILES['file']['tmp_name'];
$origin  = $_FILES['file']['name'];
$project = safeName($_POST['project']   ?? '_standalone');
$chatIn  = safeName($_POST['chat_name'] ?? '');
$over    = ($_POST['overwrite'] ?? '0') === '1';

$jsonText = null;

// Detect format: if it starts with PK\x03\x04 it's a zip
$head = file_get_contents($tmp, false, null, 0, 4);
if ($head === "PK\x03\x04") {
    $zip = new ZipArchive();
    if ($zip->open($tmp) !== true) {
        echo json_encode(['ok'=>false,'error'=>'Could not open zip'], JSON_UNESCAPED_UNICODE); exit;
    }
    // Look for any *.json that isn't manifest.json
    for ($i = 0; $i < $zip->numFiles; $i++) {
        $name = $zip->getNameIndex($i);
        if ($name !== 'manifest.json' && substr($name, -5) === '.json') {
            $jsonText = $zip->getFromIndex($i);
            // If chat_name not provided, use the filename stem
            if (!$chatIn) {
                $chatIn = safeName(pathinfo($name, PATHINFO_FILENAME));
            }
            break;
        }
    }
    $zip->close();
    if ($jsonText === null) {
        echo json_encode(['ok'=>false,'error'=>'No chat JSON found in zip'], JSON_UNESCAPED_UNICODE); exit;
    }
} else {
    $jsonText = file_get_contents($tmp);
    if (!$chatIn) {
        $chatIn = safeName(pathinfo($origin, PATHINFO_FILENAME));
        // Strip any chat_ prefix from the original filename
        if (strpos($chatIn, 'chat_') === 0) $chatIn = substr($chatIn, 5);
    }
}

$data = json_decode($jsonText, true);
if (!is_array($data) || !isset($data['exchanges'])) {
    echo json_encode(['ok'=>false,'error'=>'Invalid chat JSON (missing exchanges)'], JSON_UNESCAPED_UNICODE); exit;
}

if (!$chatIn) {
    echo json_encode(['ok'=>false,'error'=>'Could not determine target chat name'], JSON_UNESCAPED_UNICODE); exit;
}

// Determine target dir
if ($project === '_standalone') {
    $projDir = COCKPIT_ROOT . '/_standalone';
} else {
    $projDir = COCKPIT_ROOT . '/' . $project;
}
if (!is_dir($projDir)) {
    @mkdir($projDir, 0775, true);
}

$dest = $projDir . '/chat_' . $chatIn . '.json';

if (file_exists($dest) && !$over) {
    // Suggest a unique alternative name
    $i = 2;
    do {
        $alt = $chatIn . '_' . $i;
        $altPath = $projDir . '/chat_' . $alt . '.json';
        $i++;
    } while (file_exists($altPath) && $i < 50);
    echo json_encode([
        'ok'        => false,
        'error'     => 'Chat already exists: ' . $chatIn,
        'suggested' => $alt,
        'conflict'  => true
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// Update the project/chat fields in the JSON to match destination
$data['project'] = $project;
$data['chat']    = $chatIn;
$data['updated'] = date('c');
if (empty($data['created'])) $data['created'] = $data['updated'];

file_put_contents($dest, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
@chmod($dest, 0664);

echo json_encode([
    'ok'              => true,
    'project'         => $project,
    'chat'            => $chatIn,
    'exchanges_count' => count($data['exchanges']),
    'overwritten'     => file_exists($dest) && $over,
], JSON_UNESCAPED_UNICODE);
