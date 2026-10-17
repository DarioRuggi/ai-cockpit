<?php
// =============================================================================
// render.php — emits one splash screen. Called by Installs/build_splash.sh.
//   argv: <edition v1|v2> <version> <build> <rc> <srcdir>
//
// Self-contained on purpose: the shell loads this over file://, so no network,
// no second request, no font dependency. Icons are inline SVG rather than the
// vendored icon font, because the font lives in the web root and the splash does
// not. Images, when a card names one, are inlined as data: URIs.
// =============================================================================
[$self, $ed, $version, $build, $rc, $srcdir] = array_pad($argv, 6, '');
$ed = ($ed === 'v1') ? 'v1' : 'v2';
$cfg = json_decode((string)@file_get_contents($srcdir . '/features.json'), true) ?: [];
$me  = $cfg[$ed] ?? [];
$cards = $me['cards'] ?? [];
$tagline = (string)($me['tagline'] ?? '');

// One version in the code (the even, Full one); Stand-alone DISPLAYS one major
// lower, matching ed_display_version() in cockpit_app/edition.php. Duplicated
// rather than required, because this renders at build time from Installs/ and
// must not depend on the app tree being loadable. Keep the two in step.
if ($ed === 'v1' && preg_match('/^\s*v?(\d+)(\.\d+.*)?$/', $version, $vm) && (int)$vm[1] >= 1) {
    $version = ((int)$vm[1] - 1) . ($vm[2] ?? '');
}
$isV1   = ($ed === 'v1');
$title  = $isV1 ? 'AI Cockpit V1' : 'AI Cockpit';
$edBadge= $isV1 ? 'STAND-ALONE' : 'FULL';
// V1 carries no account, so it shows no tier chip — but it IS the same beta.
$badges = [$edBadge, 'BETA'];
if ($rc !== '') $badges[] = 'RC' . $rc;

function dataUri(string $path): string {
    if ($path === '' || !is_file($path)) return '';
    $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
    $mime = ['png'=>'image/png','jpg'=>'image/jpeg','jpeg'=>'image/jpeg','svg'=>'image/svg+xml','webp'=>'image/webp'][$ext] ?? '';
    if ($mime === '') return '';
    return 'data:' . $mime . ';base64,' . base64_encode((string)file_get_contents($path));
}
// Inline SVG, 24x24, currentColor — no font, no network.
function icon(string $name): string {
    $p = [
      'hive'   => '<path d="M7 3h10l3 5-3 5H7L4 8zM7 13h10l3 5-3 5H7l-3-5z"/>',
      'book'   => '<path d="M4 4h7a2 2 0 0 1 2 2v14a2 2 0 0 0-2-2H4zM20 4h-7a2 2 0 0 0-2 2v14a2 2 0 0 1 2-2h7z"/>',
      'globe'  => '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3.5 3 14.5 0 18-3-3.5-3-14.5 0-18z"/>',
      'lock'   => '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
      'chip'   => '<rect x="7" y="7" width="10" height="10" rx="1"/><path d="M4 10h3M4 14h3M17 10h3M17 14h3M10 4v3M14 4v3M10 17v3M14 17v3"/>',
      'folder' => '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
    ][$name] ?? '<circle cx="12" cy="12" r="8"/>';
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">' . $p . '</svg>';
}
$logo = dataUri(dirname($srcdir, 2) . '/cockpit_app/assets/logo.png');
$e = fn($s) => htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8');
?><!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title><?= $e($title) ?> — Loading…</title>
<style>
  /* The shell sets GTK prefer-dark from the desktop, so the light query is right
     even for a file:// page with no app CSS available. */
  :root{--bg:#0d1117;--card:#161b22;--line:#2b3440;--tx:#e6edf3;--dim:#8b949e;--acc:#58a6ff;--warm:#e0b84e}
  @media (prefers-color-scheme: light){:root{--bg:#f6f8fa;--card:#fff;--line:#d8dee4;--tx:#1f2328;--dim:#59636e}}
  *{box-sizing:border-box}
  html,body{margin:0;height:100%;overflow:hidden;background:var(--bg);color:var(--tx);
    font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
  /* Same structure in both editions — they used to be two unrelated pictures. */
  body{display:flex;align-items:center;justify-content:center;
    background-image:radial-gradient(ellipse 80% 60% at 50% -10%, rgba(88,166,255,.13), transparent 70%)}
  .wrap{width:min(680px,92vw);padding:26px 28px}
  .head{display:flex;align-items:center;gap:14px;margin-bottom:6px}
  .logo{width:46px;height:46px;border-radius:9px;flex:0 0 auto}
  h1{margin:0;font-size:23px;font-weight:700;letter-spacing:-.2px}
  .badges{display:flex;gap:5px;margin-top:5px;flex-wrap:wrap}
  .b{font-size:9px;font-weight:700;letter-spacing:.4px;padding:2px 6px;border-radius:4px;
     border:1px solid rgba(88,166,255,.5);color:var(--acc)}
  .b.warm{border-color:rgba(224,184,78,.5);color:var(--warm)}
  .ver{font-size:11px;color:var(--dim);margin-top:5px}
  .tag{font-size:13.5px;color:var(--tx);margin:14px 0 16px;line-height:1.45}
  .cards{display:flex;flex-direction:column;gap:9px}
  .c{display:flex;gap:11px;align-items:flex-start;background:var(--card);
     border:1px solid var(--line);border-radius:8px;padding:10px 12px}
  .c svg{width:19px;height:19px;flex:0 0 auto;color:var(--acc);margin-top:1px}
  .c img{width:56px;height:38px;object-fit:cover;border-radius:5px;flex:0 0 auto}
  .ct{font-size:12.5px;font-weight:650;margin:0 0 2px}
  .cx{font-size:11.5px;color:var(--dim);margin:0;line-height:1.42}
  .foot{display:flex;align-items:center;justify-content:space-between;margin-top:18px;
        font-size:10.5px;color:var(--dim)}
  .bar{height:2px;background:var(--line);border-radius:2px;overflow:hidden;margin-top:12px}
  .bar i{display:block;height:100%;width:38%;background:var(--acc);border-radius:2px;
         animation:s 1.25s ease-in-out infinite}
  @keyframes s{0%{transform:translateX(-100%)}100%{transform:translateX(320%)}}
  @media (prefers-reduced-motion: reduce){.bar i{animation:none;width:100%}}
</style></head><body>
<div class="wrap">
  <div class="head">
    <?php if ($logo): ?><img class="logo" src="<?= $logo ?>" alt=""><?php endif; ?>
    <div>
      <h1><?= $e($title) ?></h1>
      <div class="badges">
        <?php foreach ($badges as $i => $b): ?>
        <span class="b<?= $b === 'BETA' ? ' warm' : '' ?>"><?= $e($b) ?></span>
        <?php endforeach; ?>
      </div>
      <div class="ver">Version <?= $e($version) ?> · build <?= $e($build) ?></div>
    </div>
  </div>
  <p class="tag"><?= $e($tagline) ?></p>
  <div class="cards">
    <?php foreach ($cards as $c):
        $img = dataUri($srcdir . '/images/' . (string)($c['image'] ?? '')); ?>
    <div class="c">
      <?= $img ? '<img src="' . $img . '" alt="">' : icon((string)($c['icon'] ?? '')) ?>
      <div>
        <p class="ct"><?= $e($c['title'] ?? '') ?></p>
        <p class="cx"><?= $e($c['text'] ?? '') ?></p>
      </div>
    </div>
    <?php endforeach; ?>
  </div>
  <div class="bar"><i></i></div>
  <div class="foot"><span>Starting…</span><span>Ruggi Software — Where Intelligence Compiles.</span></div>
</div></body></html>
