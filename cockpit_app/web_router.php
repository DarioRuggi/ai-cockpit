<?php
// web_router.php — the router of the Web Site tools' preview server (web_serve). PHP's built-in server serves the folder as it is, with three
// differences that make the preview behave like a real web server:
//   * anything hidden (a dot-file or dot-folder such as .git or .env) and editor backups answer 404, so previewing a site never shows its secrets;
//   * a URL that matches no file answers 404 (the built-in server would otherwise fall back to the index page and hide every broken link);
//   * a folder answers only when it has an index page; there is no folder listing.
$p = rawurldecode((string)parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH));
$notFound = function () { http_response_code(404); header('Content-Type: text/plain; charset=utf-8'); echo "Not found\n"; return true; };
if (preg_match('~(^|/)\.~', $p) || preg_match('#(~|\.bak|\.orig|\.swp)$#i', $p)) return $notFound();
$root = rtrim((string)$_SERVER['DOCUMENT_ROOT'], '/');
$f = $root . $p;
if (is_file($f)) return false;                                          // a file: served as usual (.php files run)
if (is_dir($f)) { foreach (['index.html', 'index.htm', 'index.php'] as $ix) if (is_file(rtrim($f, '/') . '/' . $ix)) return false; }
return $notFound();
