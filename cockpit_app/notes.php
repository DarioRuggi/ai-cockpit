<?php
// =============================================================================
// notes.php — Cockpit Notes backend (two forms, one engine).
//
//   scope = "internal"  → notes stored in cockpit_data/notes/ (Markdown + index)
//   scope = "folder"    → notes in a USER-CHOSEN local folder (Markdown files)
//
// Both operate on their own storage. Cross-link: an action may pass
// include_foreign=1 to ALSO read the other store (READ-ONLY) for search / RAG.
//
// AI (auto summarize/tag/embed) uses a ≤4B local model only (auto policy);
// GLM-4 etc. never auto-loaded here. Auto-AI is a global toggle (default off) +
// an explicit "Process now". Embeddings reuse nomic-embed-text (like library).
//
// Actions:
//   get_config|set_config           — { auto_ai: bool, ai_model: "gemma3:4b" }
//   get_folder|set_folder           — Form B folder path
//   list   ?scope                   — list notes (id,title,tags,updated,preview)
//   read   ?scope&id                — note content
//   save    {scope,id?,title,content,tags?}  — create/update
//   delete  {scope,id}
//   search  {scope,q,include_foreign?}       — keyword search (+ optional foreign)
//   ai_process {scope,id}            — summarize + tags (≤4B), store in index
//   rag_context {q,scopes[],limit?}  — gather top-k context across chosen stores
// =============================================================================

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

ed_gate_or_exit('notes');   // demo: described-modal; v1/v2: real

header('Content-Type: application/json');
header('Cache-Control: no-store');

$CD          = $PATHS['cockpit_data'];
$NOTES_DIR   = $CD . '/notes';
$NOTES_IDX   = $CD . '/notes_index.json';
$FOLDER_F    = $CD . '/notes_folder.json';
$CFG_F       = $CD . '/notes_config.json';
$OLLAMA_URL  = 'http://localhost:11434';

$action = $_GET['action'] ?? '';
$in     = json_decode((string)file_get_contents('php://input'), true) ?: [];

function njson($a){ echo json_encode($a, JSON_UNESCAPED_UNICODE); exit; }
function nload($f,$d=[]){ if(!is_file($f)) return $d; $j=json_decode((string)file_get_contents($f),true); return is_array($j)?$j:$d; }
function nsave($f,$a){ $d=dirname($f); if(!is_dir($d)) @mkdir($d,0775,true); file_put_contents($f,json_encode($a,JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE),LOCK_EX); @chmod($f,0664); }
function nslug($s){ $s=preg_replace('/[^a-z0-9]+/','-',strtolower(trim($s))); return trim($s,'-') ?: 'note'; }
function npreview($s,$n=160){ $s=trim(preg_replace('/\s+/',' ',strip_tags($s))); return mb_substr($s,0,$n); }

// ── config ───────────────────────────────────────────────────────────────────
function notes_cfg($f){ return array_merge(['auto_ai'=>false,'ai_model'=>'gemma3:4b'], nload($f,[])); }

if ($action === 'get_config') njson(['ok'=>true,'config'=>notes_cfg($CFG_F)]);
if ($action === 'set_config') {
    $c = notes_cfg($CFG_F);
    if (isset($in['auto_ai']))  $c['auto_ai']  = (bool)$in['auto_ai'];
    if (!empty($in['ai_model'])) $c['ai_model'] = preg_replace('/[^a-zA-Z0-9._:\-\/]/','',(string)$in['ai_model']);
    nsave($CFG_F,$c); njson(['ok'=>true,'config'=>$c]);
}

// ── Form B folder path ────────────────────────────────────────────────────────
if ($action === 'get_folder') { $p=nload($FOLDER_F,[]); njson(['ok'=>true,'path'=>$p['path']??'']); }
if ($action === 'set_folder') {
    $p = trim((string)($in['path'] ?? ''));
    if ($p === '') njson(['ok'=>false,'error'=>'empty path']);
    $real = realpath($p);
    if ($real === false) { if(!@mkdir($p,0775,true)) njson(['ok'=>false,'error'=>'folder not found / not creatable']); $real=realpath($p); }
    if (!is_dir($real) || !is_writable($real)) njson(['ok'=>false,'error'=>'not a writable directory']);
    nsave($FOLDER_F,['path'=>$real]); njson(['ok'=>true,'path'=>$real]);
}

function folder_path($f){ $p=nload($f,[]); return $p['path']??''; }

// ── folder browser (server-side) for the Notepad picker ───────────────────────
if ($action === 'list_dirs') {
    $path = trim((string)($in['path'] ?? $_GET['path'] ?? ''));
    if ($path === '') $path = getenv('HOME') ?: '/home';
    $real = realpath($path);
    if ($real === false || !is_dir($real)) njson(['ok'=>false,'error'=>'not a directory','path'=>$path]);
    if (!is_readable($real)) njson(['ok'=>false,'error'=>'not readable','path'=>$real]);
    $showHidden = !empty($in['hidden']) || !empty($_GET['hidden']);
    $dirs = [];
    foreach (scandir($real) ?: [] as $e) {
        if ($e === '.' || $e === '..') continue;
        if (!$showHidden && $e[0] === '.') continue;
        $full = $real . '/' . $e;
        if (is_dir($full)) $dirs[] = ['name'=>$e, 'path'=>$full, 'readable'=>is_readable($full)];
    }
    usort($dirs, fn($a,$b)=>strcasecmp($a['name'],$b['name']));
    $parent = dirname($real);
    njson(['ok'=>true,'path'=>$real,'parent'=>($parent!==$real?$parent:null),'dirs'=>$dirs,
           'writable'=>is_writable($real)]);
}

// ── storage helpers per scope ─────────────────────────────────────────────────
// internal: md files in $NOTES_DIR, metadata in $NOTES_IDX keyed by id.
// folder:   md files in user folder; id == filename; metadata in a sidecar
//           .cockpit_notes.json inside the folder.
function store_list($scope, $NOTES_DIR, $NOTES_IDX, $folder) {
    $out = [];
    if ($scope === 'internal') {
        $idx = nload($NOTES_IDX, []);
        foreach ($idx as $id=>$m) {
            $out[] = ['id'=>$id,'title'=>$m['title']??$id,'tags'=>$m['tags']??[],
                      'updated'=>$m['updated']??'','summary'=>$m['summary']??'','preview'=>$m['preview']??''];
        }
    } else {
        if ($folder==='' || !is_dir($folder)) return $out;
        $meta = nload($folder.'/.cockpit_notes.json', []);
        foreach (glob($folder.'/*.md') ?: [] as $fp) {
            $fn = basename($fp); $m = $meta[$fn] ?? [];
            $out[] = ['id'=>$fn,'title'=>$m['title']??pathinfo($fn,PATHINFO_FILENAME),
                      'tags'=>$m['tags']??[],'updated'=>date('c',@filemtime($fp)),
                      'summary'=>$m['summary']??'','preview'=>npreview((string)@file_get_contents($fp))];
        }
    }
    usort($out, fn($a,$b)=>strcmp($b['updated'],$a['updated']));
    return $out;
}
function store_read($scope,$id,$NOTES_DIR,$folder){
    if ($scope==='internal'){ $fp=$NOTES_DIR.'/'.basename($id); }
    else { if($folder==='') return null; $fp=$folder.'/'.basename($id); }
    return is_file($fp) ? (string)file_get_contents($fp) : null;
}

if ($action === 'list') {
    $scope = ($in['scope'] ?? $_GET['scope'] ?? 'internal') === 'folder' ? 'folder':'internal';
    njson(['ok'=>true,'scope'=>$scope,'notes'=>store_list($scope,$NOTES_DIR,$NOTES_IDX,folder_path($FOLDER_F)),
           'folder'=>folder_path($FOLDER_F)]);
}

if ($action === 'read') {
    $scope = ($in['scope'] ?? $_GET['scope'] ?? 'internal')==='folder'?'folder':'internal';
    $id = (string)($in['id'] ?? $_GET['id'] ?? '');
    $c = store_read($scope,$id,$NOTES_DIR,folder_path($FOLDER_F));
    if ($c === null) njson(['ok'=>false,'error'=>'not found']);
    njson(['ok'=>true,'id'=>$id,'content'=>$c]);
}

if ($action === 'save') {
    $scope = ($in['scope'] ?? 'internal')==='folder'?'folder':'internal';
    $title = trim((string)($in['title'] ?? 'Untitled'));
    $content = (string)($in['content'] ?? '');
    $tags = is_array($in['tags'] ?? null) ? array_values($in['tags']) : [];
    $id = trim((string)($in['id'] ?? ''));

    if ($scope==='internal') {
        if(!is_dir($NOTES_DIR)) @mkdir($NOTES_DIR,0775,true);
        if ($id==='') $id = date('Ymd_His').'_'.nslug($title).'.md';
        $id = basename($id); if(substr($id,-3)!=='.md') $id.='.md';
        file_put_contents($NOTES_DIR.'/'.$id,$content); @chmod($NOTES_DIR.'/'.$id,0664);
        $idx = nload($NOTES_IDX,[]);
        $idx[$id] = array_merge($idx[$id]??[], ['title'=>$title,'tags'=>$tags,
            'updated'=>date('c'),'preview'=>npreview($content)]);
        nsave($NOTES_IDX,$idx);
    } else {
        $folder = folder_path($FOLDER_F);
        if ($folder==='') njson(['ok'=>false,'error'=>'no folder set']);
        if ($id==='') $id = nslug($title).'.md';
        $id = basename($id); if(substr($id,-3)!=='.md') $id.='.md';
        file_put_contents($folder.'/'.$id,$content);
        $meta = nload($folder.'/.cockpit_notes.json',[]);
        $meta[$id] = array_merge($meta[$id]??[], ['title'=>$title,'tags'=>$tags,'updated'=>date('c')]);
        nsave($folder.'/.cockpit_notes.json',$meta);
    }
    njson(['ok'=>true,'id'=>$id]);
}

if ($action === 'delete') {
    $scope = ($in['scope'] ?? 'internal')==='folder'?'folder':'internal';
    $id = basename((string)($in['id'] ?? ''));
    if ($scope==='internal') {
        @unlink($NOTES_DIR.'/'.$id);
        $idx=nload($NOTES_IDX,[]); unset($idx[$id]); nsave($NOTES_IDX,$idx);
    } else {
        $folder=folder_path($FOLDER_F); if($folder==='') njson(['ok'=>false,'error'=>'no folder']);
        @unlink($folder.'/'.$id);
        $meta=nload($folder.'/.cockpit_notes.json',[]); unset($meta[$id]); nsave($folder.'/.cockpit_notes.json',$meta);
    }
    njson(['ok'=>true]);
}

if ($action === 'search') {
    $scope = ($in['scope'] ?? $_GET['scope'] ?? 'internal')==='folder'?'folder':'internal';
    $q = strtolower(trim((string)($in['q'] ?? $_GET['q'] ?? '')));
    $foreign = !empty($in['include_foreign']) || !empty($_GET['include_foreign']);
    $hit = function($scope) use ($q,$NOTES_DIR,$NOTES_IDX,$FOLDER_F){
        $res=[]; foreach (store_list($scope,$NOTES_DIR,$NOTES_IDX,folder_path($FOLDER_F)) as $n){
            $body=strtolower(($n['title']??'').' '.implode(' ',$n['tags']??[]).' '.($n['preview']??''));
            $c = store_read($scope,$n['id'],$NOTES_DIR,folder_path($FOLDER_F));
            if ($q==='' || strpos($body,$q)!==false || ($c && strpos(strtolower($c),$q)!==false)) {
                $n['scope']=$scope; $res[]=$n;
            }
        } return $res;
    };
    $results = $hit($scope);
    if ($foreign) $results = array_merge($results, $hit($scope==='internal'?'folder':'internal'));
    njson(['ok'=>true,'results'=>$results]);
}

// ── AI: summarize + tag a note (≤4B model only) ──────────────────────────────
function ollama_gen($url,$model,$prompt){
    $ch=curl_init($url.'/api/generate');
    curl_setopt_array($ch,[CURLOPT_RETURNTRANSFER=>true,CURLOPT_POST=>true,
        CURLOPT_POSTFIELDS=>json_encode(['model'=>$model,'prompt'=>$prompt,'stream'=>false]),
        CURLOPT_HTTPHEADER=>['Content-Type: application/json'],CURLOPT_TIMEOUT=>120]);
    $r=curl_exec($ch); curl_close($ch); $j=json_decode((string)$r,true);
    return $j['response'] ?? '';
}

if ($action === 'ai_process') {
    $scope = ($in['scope'] ?? 'internal')==='folder'?'folder':'internal';
    $id = basename((string)($in['id'] ?? ''));
    $cfg = notes_cfg($CFG_F);
    $model = $cfg['ai_model'] ?: 'gemma3:4b';
    $content = store_read($scope,$id,$NOTES_DIR,folder_path($FOLDER_F));
    if ($content === null) njson(['ok'=>false,'error'=>'not found']);
    $text = mb_substr($content,0,6000);
    $summary = trim(ollama_gen($OLLAMA_URL,$model,"Summarize this note in 2 short sentences. Output only the summary:\n\n".$text));
    $tagsRaw = trim(ollama_gen($OLLAMA_URL,$model,"Extract up to 5 short topic tags (comma-separated, lowercase, no #). Output only the tags:\n\n".$text));
    $tags = array_values(array_filter(array_map(fn($t)=>trim($t),explode(',',$tagsRaw)), fn($t)=>$t!=='' && mb_strlen($t)<30));
    $tags = array_slice($tags,0,5);
    // store back
    if ($scope==='internal'){ $idx=nload($NOTES_IDX,[]); if(isset($idx[$id])){ $idx[$id]['summary']=$summary; if($tags)$idx[$id]['tags']=$tags; nsave($NOTES_IDX,$idx);} }
    else { $folder=folder_path($FOLDER_F); $meta=nload($folder.'/.cockpit_notes.json',[]); $meta[$id]['summary']=$summary; if($tags)$meta[$id]['tags']=$tags; nsave($folder.'/.cockpit_notes.json',$meta); }
    njson(['ok'=>true,'summary'=>$summary,'tags'=>$tags,'model'=>$model]);
}

// ── RAG context: gather top notes (keyword) across chosen scopes for chat ─────
if ($action === 'rag_context') {
    $q = strtolower(trim((string)($in['q'] ?? '')));
    $scopes = is_array($in['scopes'] ?? null) ? $in['scopes'] : ['internal'];
    $limit = max(1, min(10, (int)($in['limit'] ?? 5)));
    $ctx = [];
    foreach ($scopes as $sc) {
        if (!in_array($sc,['internal','folder'],true)) continue;
        foreach (store_list($sc,$NOTES_DIR,$NOTES_IDX,folder_path($FOLDER_F)) as $n) {
            $c = store_read($sc,$n['id'],$NOTES_DIR,folder_path($FOLDER_F));
            if ($c===null) continue;
            $score = ($q===''?1:substr_count(strtolower($c),$q)) + (strpos(strtolower($n['title']??''),$q)!==false?5:0);
            if ($score>0) $ctx[] = ['scope'=>$sc,'id'=>$n['id'],'title'=>$n['title'],'score'=>$score,'content'=>mb_substr($c,0,1500)];
        }
    }
    usort($ctx, fn($a,$b)=>$b['score']<=>$a['score']);
    njson(['ok'=>true,'context'=>array_slice($ctx,0,$limit)]);
}

njson(['ok'=>false,'error'=>'unknown action: '.$action]);
