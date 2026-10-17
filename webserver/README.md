# aicserver — a small web server for AI Cockpit (standalone)

Static files + FastCGI (PHP), streaming, ranges, uploads, strict request parsing. Detached from Cockpit.
Process model: the parent only accepts; **one forked child per connection** serves its HTTP/1.1 keep-alive
requests with blocking, deadline-guarded I/O (same model as aicengine): a crash costs one connection, no threads.

    bash build.sh                          # needs only fpc 3.2+
    bash tests/run_all.sh                  # build + 72 unit checks + 123 server scenarios (about 2 minutes)
    bin/aicserver check --config examples/cockpit.server.json
    bin/aicserver run   --config my.json   # foreground; the supervisor keeps it alive

## What Cockpit needs from a web server (measured on the real code, not guessed)
Standard CGI variables (`REQUEST_METHOD SCRIPT_FILENAME SCRIPT_NAME HTTP_COOKIE HTTP_HOST HTTPS SERVER_PORT REMOTE_ADDR
PATH_INFO HTTP_AUTHORIZATION`); one SSE client + four `flush()` users; no WebSockets; no range handling in PHP;
post_max_size 8 MB. The mounts, cache rules and PHP handler of today's Apache setup are in
`examples/cockpit.server.json`.

## Routing (srv_main)
method check -> Host allow-list (421) -> path normalisation (400) -> root redirect -> mount (longest prefix on a
segment boundary) -> deny globs (404) -> resolve under the mount's root (directory = 301 to the slash form + index
files; `x.php/extra` = PATH_INFO) -> real-path containment (a symlink out of the root = 404) -> PHP files go to
FastCGI **and are never sent as source**; below a `static_only_dirs` folder they are refused (403), not executed ->
everything else is static.

## Security (each has tests)
Path normaliser decodes ONCE and refuses `..` above the root, encoded `/` and `\`, NUL, control characters (17
traversal encodings tested); dotfiles/backups/source files 404; per-mount deny globs; Host allow-list (DNS
rebinding); strict parser: CRLF only, no obsolete folding, token header names, Content-Length digits only, CL+TE and
conflicting CL refused (smuggling), unknown TE 501, 414/431/413 limits, 408 timeouts at every stage; no `Proxy`
header into the environment (httpoxy); header values cannot split a response; binds to 127.0.0.1 by default;
`max_connections` -> 503; no directory listing.

## Static
Last-Modified + weak ETag, `If-None-Match` / `If-Modified-Since` -> 304, single `Range` (first-last, first-, -suffix)
-> 206 / 416, several ranges -> whole file, `If-Range`, HEAD, 64 KB streaming reads (a 30 MB file in 0.05 s),
Cache-Control from rules (Cockpit's own: html/js/css/json = `no-cache, must-revalidate`).

## FastCGI (srv_fcgi)
Streams every STDOUT record to the client as it arrives (SSE: first event after 0.3 s of a 1.5 s stream); parses
the CGI header block (Status, Location -> 302, multiple Set-Cookie, bare-LF blocks, empty block, headers split
across records); chunked request bodies are assembled so PHP gets a Content-Length; large uploads are streamed;
the pump reads backend output while writing the body (no deadlock); client disconnect sends ABORT_REQUEST;
backend slow -> 504, closed -> 502, dies mid-response -> the connection is cut (never left hanging), idle after
headers -> cut at the idle timeout; unix-socket and TCP backends; `.php` endpoints get JSON error bodies.

## Proven against the real Cockpit tree
`aicserver` pointed at `/var/www/html/cockpit` and `/cockpit-v1`, compared with the live Apache for every static
file: 402 files, 81 MB — **status and bytes identical for all of them**, cache headers identical. The only
differences were `Content-Type`: Apache sends none for unknown extensions (114 files), we send
`application/octet-stream`; plus the `.ico` type name (we use the IANA name).

## Bugs the tests found and fixed
`Delete(IndexOfName(...))` on a `Name: value` list (twice: it looks for `Name=`, so a 416 raised and killed the
connection, and a bare `Location` never became a 302); a missing HTTP version answered 505 instead of 400; an empty
CGI header block was not recognised; plus test-side races (a connection process still finishing when the cap was
tested). Found while testing: **the live Apache serves `cockpit/responses/*.payload` (prompt payloads) to the LAN.**

## Not done
- **Real PHP** has not been run through it: no `php-cgi` / `php-fpm` is installed here (the mock FastCGI backend
  implements the protocol; the first run against real PHP should be a short test with Cockpit's own scripts).
- gzip/deflate for text (Apache's `deflate` module is on today), HTTPS, WebSockets, HTTP/2, access-log rotation.
- Windows (see the notes in ../README.md).

## Wired into Cockpit (2026-10-07, aicserver 1.0.0 `version`)
Opt-in, beside Apache: a file called `use_aicserver` in the Cockpit data folder (its content, when it is a port number, is the port; default 8081 for V2, 8082 for V1) makes `cockpit_sup_config.php` add two supervised services: `cockpit_phpcgi` (php-cgi, 6 workers, a private Unix socket in the data folder's `supervisor/`) and `cockpit_web` (this server, config written to `supervisor/web.json`). Both run as the owner; Apache is not touched. The generated config refuses what Apache's `cockpit-security.conf` refuses: `paths.json`, `project_state.json`, `workers_quotas.json`, `*.jsonl`, `*.lock`, `*.sock`, dotfiles (so `.user.ini`), and the whole `queue/` and `responses/` folders. Found by the first side-by-side run: without those rules `paths.json`, the usage log and the quota file were served (200). Proven by `Cockpit/tests/web_front_test.sh` (23 checks on a sandbox copy: pages, PHP, JSON errors, every denied path, traversal, a 20 MB upload through php-cgi).

## Native answers (2026-10-08, `native` in the config, srv_native.pas)
Requests the server answers itself instead of handing them to PHP. The first: `bridge.php` `mode=poll`, the chat's "new bytes of the answer" call. The rule: answer only when provably what PHP would answer, and hand everything else to PHP **untouched** (the body already read is passed on to php-cgi byte for byte) before anything has changed on disk. It answers when: the `cockpit_sid` cookie names a PHP session file in `native.session_dir` (the folder php-cgi writes its sessions to) that holds `cockpit_user` and `cockpit_role` and is younger than `session_days`; the body is a small JSON object with `mode:"poll"`, a text token and an integer offset; while the answer is still being written, the supervisor (control socket in `native.supervisor_dir`, only when `use_supervisor` is on) reports `cockpit_<agent>` running; the new bytes are valid UTF-8 and hold no diff marker. It then reads the bytes, strips terminal sequences and control characters exactly as `cleanChunk()` does, writes the JSON as `json_encode(JSON_UNESCAPED_UNICODE)` does and, on the final poll, removes the `.out` and `.done` files. A native answer carries `X-Aic-Native: bridge-poll`. No session, a stopped agent, a half character at the end, a diff, another mode: PHP answers as before. Proven by `Cockpit/tests/bridge_poll_parity.sh` (36 cases: the same request to a native-on and a native-off server in front of one php-cgi, same bodies, same files left behind, and the header only where it should be; a build with a changed escape fails it).
