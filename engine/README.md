# aicengine — Phase 1 (standalone)

Runs agent CLIs, local-model APIs and tools through one interface and one JSON event stream.
Detached from Cockpit: nothing here reads or writes the Cockpit tree.

    bash build.sh                       # needs only fpc 3.2+ (fcl-web, fcl-process, fcl-json)
    bash tests/run_all.sh               # build + every suite
    bin/aicengine detect                # which adapters are ready on this machine
    bin/aicengine run ollama --model qwen2.5-coder:1.5b --prompt "hello"
    bin/aicengine run claude --prompt "..." --tier read_only --cwd ~/project --env CLAUDE_CONFIG_DIR=~/.cockpit/claude
    bin/aicengine record claude --prompt "..." --record tests/fixtures/x.jsonl   # save real output
    bin/aicengine run claude --replay tests/fixtures/x.jsonl                     # re-parse it, no network

## Layout
- `src/` — `aic_events` (the event format), `aic_adapter` (catalog + argument templates + permission tiers),
  `aic_parse` (plain, claude stream-json, ollama ndjson, generic jsonl), `aic_proc` (process transport),
  `aic_http` (local HTTP streaming), `aic_run` (a run: limits, error codes, record/replay), `aic_test`, `aicengine.lpr`.
- `adapters/` — the real catalog: claude, codex, gemini, opencode, aider, goose, qwen, ollama, ollama_chat, localai.
- `tests/` — mock agent + mock HTTP server (test doubles), mock adapters with declared expectations,
  `scenarios.sh` (system-level), `fixtures/` (recorded REAL vendor output).

## What is proven (tests/run_all.sh, all green)
No shell (hostile prompts are one argument); 300 KB prompts through stdin without deadlock; one 1 MB line;
invalid UTF-8 and non-ASCII under `LC_ALL=C`; timeout / output cap / SIGINT cancel each kill the WHOLE process
tree; SIGPIPE survived; 8 parallel runs with distinct ids; secrets masked; refused permission tier never runs;
replay == live; HTTP streaming arrives as it is produced; cancel and timeout over HTTP; real Ollama streaming.
Bugs the tests found and fixed: raw wait() status as exit code, relative program path + cwd, duplicate run ids,
system-code-page `?` for non-ASCII, SIGPIPE, HTTP cancel returning 0, read-timeout misclassified.

## Not done yet
- (service mode: DONE, see below)
- Windows process transport (job objects) — same contract, separate unit.
- Parsers for `codex exec --json` and `gemini --output-format json`: need a REAL recorded run first (no guessing).
- Live vendor runs need a logged-in CLI (the sandboxed shell used for development was not).
- HTTPS: FPC 3.2.2 cannot load OpenSSL 3, so cloud APIs go through a `curl` process adapter (not written yet).

## Service mode (Phase 1b) — `aicengine serve`
PHP (Cockpit's backend) talks to a Unix socket; no tmux, no queue/ + responses/ files, no sudo.

    bin/aicengine serve --socket /run/aicockpit/engine.sock --state /var/lib/aicockpit/engine \
        [--socket-mode 660 --socket-group www-data]       # while PHP still runs as www-data
        [--allowed-roots /path/to/projects:/tmp/x] [--max-runs 16] [--max-request-mb 32] [--adapters DIR]

    require 'clients/php/aicengine_client.php';
    $c = new AicEngineClient($socket, $tokenFile);
    $r = $c->run('claude', ['prompt' => '...', 'chat' => 'chat-7', 'cwd' => $dir, 'tier' => 'edit'],
                 fn($ev) => print(json_encode($ev) . "\n"));      // events as they arrive; return false to stop the run

Protocol: one JSON line in, then either one `{"type":"response",...}` line or the run's event stream.
Ops: `ping adapters detect status sessions session_clear cancel run`.
One forked child per connection (crash isolation, no threads). A client that disconnects CANCELS its run and
the agent's whole process tree, even when the agent is idle. A `chat` name resumes that chat's agent session.
Security: socket mode/group options, per-install 256-bit token (constant-time compare), `cwd` limited to
`--allowed-roots` (symlinks resolved), `LD_*`/`DYLD_*`/`BASH_ENV`/`ENV`/`IFS` refused in request env.

Proven by `php tests/service_test.php` (54 checks, stable over repeated runs). Bugs it found: duplicate
environment keys (first one wins in getenv), idle runs never noticing their client left, and a race in the
run registry (a half-written file was deleted as "stale").

## Legacy mode (Phase 2, slice 1) — `aicengine legacy`

The first piece of `agent_loop.sh` that the engine takes over: the step that **spawns the agent**
(`run_generic_cli` and the native Claude call). Same catalog (`cli_catalog.json`), same command line, same plain-text
`OUT_FILE` that `bridge.php` polls — so nothing else in Cockpit changes. Everything around it (queue, history, RAG,
chat saving, the done-file) stays in Bash for now.

    aicengine legacy --prompt-file F --out FILE (--supplier ID --catalog FILE | --claude-model M)
                     [--model RAW] [--images a|b] [--extra-args "..."] [--local-base URL] [--cwd DIR] [--timeout S]

**Switch (off by default).** `agent_loop.sh` hands the spawn to the engine when `COCKPIT_ENGINE=1` is set or the file
`use_engine` exists in the user's (or the shared) `cockpit_data`, and the binary is found (`COCKPIT_ENGINE_BIN`,
`~/scripts/aicengine`, or `PATH`). If the engine is missing, or refuses a request (exit 2, nothing ran), the original Bash
path runs — turning it on can never leave an agent without an answer.

**Proof:** `tests/legacy_parity.sh` extracts the real `resolve_supplier`, `run_generic_cli` and `run_claude_json` from
`agent_loop.sh` and runs 59 checks with the engine off and on, against a mock CLI that records its arguments, environment
and working directory: argument order for every catalog entry, the `$(cat file)` prompt semantics (dash-leading, quotes,
glob characters, 100 KB, Hebrew, empty), merged stdout+stderr ordering, no trailing newline, CRLF, invalid UTF-8, 5 MB,
failure exit, the opencode banner `sed`, and every `jq '.result // .error.message // .error'` case (including how jq
treats a value it cannot index, and its pretty-printing of objects). A second block proves that moving the Claude branch
into a function changed nothing (original inline code from git vs the function). One real run: aider → Ollama through the
engine answered correctly.

**Deliberate differences (improvements):**
- the agent's stdin is closed (EOF) instead of the terminal — an agent that waits for stdin can no longer look hung. Side
  effect: agents that test `isatty(0)` say so (aider prints "Warning: Input is not a terminal");
- the agent runs in its own process group, so Stop (SIGINT to the engine) kills the whole tree (130, error line written);
- the Claude answer is extracted without `jq` installed;
- a program that does not exist writes the `[SUPPLIER ERROR] …` line only (Bash also printed "command not found");
- not carried over: a prompt over the kernel's 128 KB-per-argument limit fails in both paths (the same `[… ERROR]` line).

**Also changed in the engine:** `aic_proc` no longer uses FPC's `TProcess`. Its argv builder (`StrNew`) turns an empty string
into nil, so one empty argument (`--message ""`) silently ended the argument list and dropped everything after it. Direct
fork/exec now: empty arguments are kept, descriptors above 2 are closed in the child, stderr can be merged into stdout like
a shell's `2>&1`. The whole existing engine suite (replay, scenarios, service mode, real Ollama) passes on it.

**Not yet:** `opencode_ensure_provider` (jq-edits `~/.config/opencode`) stays in Bash; history/chat-index (`sqlite3`, `jq`,
`python3`), `crud_executor.sh`, start/stop, the Gemini REST branch and the relay branch are the next slices.

### Slice 1b — opencode's provider block
`aicengine legacy` now also does what `opencode_ensure_provider` did with `jq`: it merges the Ollama provider and the model
into `~/.config/opencode/opencode.json` before an opencode run, byte for byte as jq wrote it (pretty-printed, key order kept,
mode 0600), and leaves the file alone when the model is already listed or the file is not usable JSON. 17 more parity checks
(76 in `tests/legacy_parity.sh`). The engine path of `agent_loop.sh` no longer calls Bash for it.


## `aicengine gemini` and the HTTPS client (2026-10-06, engine 0.5.0)

The Gemini REST branch of agent_loop.sh (one generateContent call) as a command: `aicengine gemini --model M --prompt-file F --out FILE [--base URL] [--ca-file F] [--resolve IP] [--timeout S]`, key in the environment (`GEMINI_API_KEY`), the answer (or an `[GEMINI ERROR] ...` line) appended to OUT_FILE.

It rests on a new small HTTPS client: `aic_tls.pas` binds libssl.so.3 at run time (the same approach as aicserver's server side; FPC 3.2.2's own openssl unit cannot load OpenSSL 3) and `aic_https.pas` speaks HTTP/1.1 over it (chunked, Content-Length or close-delimited bodies, one deadline for the whole call, no redirects). **TLS is always verified**: the chain against the system trust store (or the given PEM), and the host name against the certificate; a failure is reported and nothing is sent. IP-address hosts are refused.

Proven by `Cockpit/tests/gemini_parity.sh` (38 checks) against a local TLS stand-in for the API (`tests/gemini_mock.php`): 18 response shapes give byte-identical output from the Bash path and the engine; an untrusted certificate and a certificate for another host name are refused with no request reaching the server (a mutation that turns the host-name check off makes that test fail); the API key is never in the URL or on the engine's command line; a 400 KB prompt arrives whole; a timeout and a refused connection end with a reason; a missing key exits 2.
Also checked once against the real API with a dummy key: the real certificate chain and host name verify against the system store (0.19 s).

Deliberate differences (improvements): the key travels in the `x-goog-api-key` header, not in the URL (the Bash path does the same now); a failed connection says why (`[GEMINI ERROR] connection failed (...)`; the old Bash wrote `[GEMINI ERROR] ` with nothing after it); and **a bug found and fixed in the Bash path**: `.parts[]?.text // ""` printed one empty line when no part had text, so the file was never empty and the code written to explain a safety block or an empty candidate (`finishReason`) never ran; the person saw a blank answer. It is `// empty` now, in both paths.


## `aicengine prompt` (2026-10-06, engine 0.6.0)

`assemble_prompt` of agent_loop.sh as a command: it writes the prompt file (and, for Gemini/Ollama, the system-block file) from the project's and the person's files. Inputs it reads itself: the chat's and the project's goal / kind / description files (`.chat_meta/<slug>.json`, `.cockpit_project.json`; cut at 600 / 900 / 300 / 60 bytes exactly as `jq … | head -c N` did, multibyte cut points included), `COCKPIT.md` (8 KB cut with its notice), `profile.md` (4 KB, and the `profile_enabled` marker the Bash reads as "off"), the directives (full / compact / per-agent override, `directives_config.json` including what an invalid or odd config does), and the identity line for every supplier. The blocks the loop computes with other tools (history, retrieved context, workers, tools, capability text) and the two fixed system texts come in as files.

Proven by `Cockpit/tests/prompt_parity.sh`: **156 cases byte-identical** between the Bash path and the engine (both output files each): every supplier and dialect, every optional block, goal/kind/description edge cases (non-string values, invalid JSON, arrays where objects belong), COCKPIT.md at 8191/8192/8193 bytes and cut through a character, NUL bytes, profile and directives in all their states. A mutation of the engine's text makes the profile cases fail, so the engine path is really the one being compared. 17 ms → 7 ms per assembly (spawn included).

Deliberate differences: it needs no `jq` (the Bash silently left the goal, kind and descriptions out when jq was missing); and a user prompt that is exactly `-n`, `-e`, `-E` or similar no longer vanishes: `echo "$USER_PROMPT"` took it for an option, so the Bash path printed nothing. The Bash path now uses `printf '%s\n'` there too, so both agree.


## `aicengine clean` and `aicengine signin-hint` (2026-10-06, engine 0.7.0)

What agent_loop.sh does with an agent's raw answer before saving it, as two commands.

- `clean --agent A --out-file F --start-ns N [--usage-log F --model M --project P --chat C --prompt-chars N]`: strips the terminal artifacts from an Ollama or Gemini answer (carriage returns, ANSI escape sequences, Ollama's spinner line when it is the LAST line, the Gemini CLI's colour warnings and tool-fallback notices), measures the turn (printed on stdout in the exact form `bc` gave: `.3`, `0`, `2.3`, `5.0`), and appends the Ollama usage line. A missing final newline stays missing, as with `sed -i`.
- `signin-hint --agent A --agent-uc UC --out-file F`: a short answer (under 800 bytes) that says the CLI is not signed in gets the line saying where to sign in.

Proven by `Cockpit/tests/post_parity.sh`: **304 cases byte-identical** (the answer file, the duration and the usage line) between the Bash path (real sed, bc, date arithmetic, printf, grep, run under `LC_ALL=C` with a fixed clock) and the engine: 34 answer shapes × 4 agents (CRLF, every kind of escape sequence including malformed ones, spinner lines in every position, Gemini noise in every capitalisation, no final newline, empty, unicode, invalid UTF-8, a 20 KB line), 36 durations around the 0.1-second truncation points, usage-line sizes, names with quotes and unicode, and the hint's regular expression on 24 phrases × 4 agents plus the 800-byte boundary. Three mutations of the engine (rounding instead of truncating, a changed noise phrase, a changed colour rule) each made the test fail.

Deliberate differences (improvements): none of sed, bc or GNU `date` is needed (macOS has no `date +%s%N`: the Bash path's duration is garbage there); and the usage line is valid JSON for any name (the Bash escaped only the double quote, so a backslash in a chat name made the line unparseable for the usage page). Not replicated: GNU sed in a UTF-8 locale treats a line with invalid UTF-8 as not matching `.`, so the Bash could keep a Gemini warning line that contains such a byte; the engine reads bytes.

## `aicengine intake` (2026-10-06, engine 0.8.0)

The first half of one turn of agent_loop.sh, as one command: `intake --agent A --queue-dir D --response-dir D --prompt-file F --root D --prompt-out F`.

It takes the token from the prompt file's name, reads the request's meta file the way the loop's `json_get` does (the first `"key": "string"` on any line; `\/` becomes `/`; the same defaults for an empty project, chat or model), reads the Ollama model file, works out the project folder and chat file, applies the supplier control (the effort text is put in front of the prompt, the extra CLI arguments are kept only if they pass the whitelist), removes the prompt, meta and model files, writes the prompt to `--prompt-out`, and prints shell assignments (every value single-quoted) for the loop to `eval`.

Exit 2 = refused before anything was touched, and the loop's Bash then does it: a control that is not clean base64 (GNU `base64 -d` would print a partial result), a NUL byte in a decoded control, or a prompt file that cannot be read.

Proven by `Cockpit/tests/intake_parity.sh` (56 cases: every variable, the prompt, the files left in the queue, the working directory; the Bash is cut out of the real loop) and by `Cockpit/tests/loop_intake_e2e_test.sh` (the real loop with a fake CLI, once on each path: same answer file, same saved exchange).

## `aicengine route` and `aicengine loop` (2026-10-06, engine 1.0.0)

**route** (`--agent A --project P --project-dir D --data-dir D --base-url U --home D`): the capabilities step (Claude's MCP file and skill links, Ollama's system-prompt text) and the Workers / Tools auto-route prompts of a turn, printed as shell assignments. The two lists are fetched from `workers.php` / `tools.php` with the loop's internal key (`COCKPIT_INTERNAL_KEY` / `COCKPIT_INTERNAL_USER` in the environment). Exit 2 = refused before writing anything (Gemini's MCP settings merge, odd skill files, non-string provider names). Proven by `Cockpit/tests/route_parity.sh` (69 cases against real jq, curl, `ln`, `cp`).

**loop** (`aicengine loop <claude|gemini|ollama>`; environment `COCKPIT_QUEUE_DIR`, `COCKPIT_RESPONSE_DIR`, `COCKPIT_DATA_DIR`, `HOME`): the whole agent queue loop of `agent_loop.sh`: watch the queue, read the request (intake), resolve the supplier slots and the CLI catalog, isolate the Claude CLI's config, apply capabilities and auto-route (route), assemble the prompt, run the agent (Claude and generic CLIs, the free-REST relay, Gemini REST, the local Ollama / OpenAI-style server), clean the answer, carry out the `%%markers%%`, save the exchange, write the `.done` file. One loop per agent (pid file shared with the Bash loop), Stop (SIGINT) ends the running agent and the loop keeps serving.

It calls the same helpers the Bash calls when the engine is on: `history_cli.php` (history gate and renderer, saving the turn), `crud_cli.php` (the markers) and `worker_relay.php` (free-REST suppliers). Deliberate differences: no jq / sed / bc / python3 / curl / coreutils needed; without PHP there is no history and the turn is saved by the loop itself (same fields, JSON re-formatted by this program); a control that is not clean base64, Gemini MCP settings and unusable skill entries are handled (merged / skipped) instead of being left to the Bash; Gemini's settings file is rewritten with this program's JSON formatting.

Switch: the file `use_native_loop` in the data folder (or `COCKPIT_NATIVE_LOOP=1`); `agent_loop.sh` then `exec`s the engine, so tmux and the supervisor keep working unchanged. Proven by `Cockpit/tests/loop_native_test.sh`: the real `agent_loop.sh` (engine on) and `aicengine loop` serve the same 13 requests (stand-in Claude CLI, a catalog CLI on card 1 and card 2, a mock Ollama server, markers, effort and arguments, sign-in hint, no meta file, earlier turns in the chat); answer file (including a hash of the whole prompt), saved chat, created files, log lines and the requests to the mock are identical.

## `aicengine fs`, `aicengine exec` and the service ops `fs` / `exec` / `sandbox` (2026-10-07, engine 1.1.0)

The engine side of Cockpit's file window and command window (the PHP pages `fm.php` and `cmd.php` only authenticate and relay).

**fs** (`--request-file F`, or the `fs` op of `aicengine serve` with a `fsop` field): `list stat read mkdir newfile rename move copy write delete empty_trash open`. A request names its **zones** (`[{"name":"public","path":...,"rw":true},{"name":"projects","path":...,"rw":false}]`); paths are `zone:relative/path`. The read-write zone is created on first use; a read-only area must be owned by the account running the engine, or it is not offered. Confinement: the zone folder is opened once and every component is opened relative to the previous one with `O_NOFOLLOW`; every action is an `*at()` call on that descriptor, so a symbolic link can never be followed and there is no check-then-use gap. `..` and empty names are refused. Copy never overwrites (`name (2).ext`) and skips links; move works inside one zone; delete in the read-write zone moves to `.trash`, delete inside `.trash` is permanent. Every change and refusal is appended to the audit log (`audit` path in the request). Proven by `Cockpit/tests/fs_test.sh` (70 checks, including a mutation run without `O_NOFOLLOW` that fails 7 of them, and a swap race).

**exec** (`--request-file F`, or the `exec` op): one command line through `/bin/sh -c`, as the engine's own account, with a small fixed environment, in a zone folder (default `public:`, resolved link-free), 20 s and 256 KB by default. The kernel's **Landlock** confines it: write only in the read-write zone(s) and `Public/.tmp`, read the read-only areas and `/usr /bin /lib /etc /opt /proc /sys`, nothing else visible; `no_new_privs` is set, so it cannot gain privileges. If Landlock is not available (not Linux, kernel < 5.13, or disabled) the command is **refused, never run unconfined**. Network access is not restricted (Landlock's network rules need a newer kernel). Timeout kills the whole process group. Proven by `Cockpit/tests/exec_test.sh` (30 checks; a build without `landlock_restrict_self` fails 10 of them).

**sandbox** (service op): `{"abi": N}`, the Landlock ABI version (0 = unavailable).

The service refuses a read-write zone whose path is outside `--allowed-roots`. Hosted by the supervisor as `cockpit_engine` (generated by `scripts/cockpit_sup_config.php`). Not built: a dedicated low-privilege account, and the Windows restricted-token / job-object variant of the confinement.

Also fixed on the way: `aic_fs` read FPC's own errno after C-library calls, which does not see their errors (an "already exists" read as "not found"); it now reads libc's.

## `aicengine history` (2026-10-07, engine 1.2.0)

The chat-history half of the agent loop, native, with the same interface and the same results as `scripts/history_cli.php` (itself the byte-exact reference of the Bash it replaced): `needs` (does this prompt need earlier turns?), `build` (which turns, rendered inline, as a pointer block or as a JSON messages array; the whole-tail fallbacks), `sync`/`add` (the derived index) and `append` (saving a turn into the chat JSON, under the chat's lock, with the Bash's quirks).

The relevance index is the same SQLite FTS5 file the PHP side uses (porter unicode61, bm25). SQLite is reached through the system's library **loaded at run time**: with no library, no FTS5, or `HISTORY_CLI_NO_INDEX`, the whole-tail fallbacks answer exactly as the Bash does, so the engine has no hard dependency on it. The long text constants, the stop words and the back-reference phrases are generated from `history_cli.php` (`Installs/gen_history_texts.php`, checked by a build guard), so there is one source.

**Exit 9 = refused before touching anything**, for the inputs the engine does not copy exactly: text that is not valid UTF-8; a character FPC's Unicode tables mark unassigned (the PHP side would count it by a newer table); an agent name that does not start with an ASCII letter; a chat file that is not strict JSON (only old loops wrote those); unusual field types. `aicengine loop` then asks the PHP helper if there is one.

Proven by `Cockpit/tests/history_native_parity.sh`: **1,743 cases identical** to the PHP helper on identical copies of 16 chat shapes and 59 prompts (output, log lines, exit codes, every chat file, every index row), plus 198 refused cases that left their files untouched; a build with two deliberate changes fails 26 of them. `aicengine loop` runs it in-process (no PHP process per turn); `loop_native_test.sh` also covers a loop with no PHP helper at all.

## `aicengine crud` (2026-10-07, engine 1.3.0)

Carrying out the `%%COMMAND%%` markers of an agent's answer, native, with the same results as `scripts/crud_cli.php` (the byte-exact reference of `crud_executor.sh`): `CREATE / UPDATE / APPEND` blocks, `PROPOSE`, `READ`, `DELETE` (with `%%CONFIRM:DELETE%%`), `MKDIR`, `LIST`, `FETCH`, `SEARCH`, `WORKER`, `TOOL`, `LOAD_SKILL`, `LIB / SNIP / SRC`. One result line (or block) per marker, every quirk of the reference kept (the markers' matching rules, a marker inside a block's content running too, `UPDATE` reported as `CREATE`, the `-n` path quirk, the `../` strip, symlink-aware containment). The web markers call Cockpit's own pages with the loop's key in a header (never to a catalog entry's URL) through the engine's HTTP client (plain http, or https with the certificate and host name checked; redirects are followed for catalog URLs).

**Exit 9 = refused before touching anything**, for what the engine does not copy exactly: a number that is not an integer, or an array/object, in a worker or tool answer (the reference would format it with PHP's JSON printer); a worker answer that is not valid UTF-8; a provider name that is a regular expression in the reference; text that looks like JSON but is not strictly valid. `aicengine loop` and the shell loop's `run_crud` then use the PHP helper, then the Bash executor.

Proven by `Cockpit/tests/crud_parity.sh`: the Bash, the PHP helper and the engine on the same scenarios against a recording mock web server (output, stderr, the whole file tree, and every request including the key headers): 148 checks, 59 of them native-versus-PHP plus the native-only cases (error bodies, integer and refused values, redirects); 5 refusals, files untouched; a build with two deliberate changes fails 5 of them.

## `aicengine relay` (2026-10-07, engine 1.4.0)

The Workers relay of the free-REST suppliers (Card 2), native: `aicengine relay PROVIDER MODEL PROMPT_FILE` prints what `php worker_relay.php PROVIDER MODEL PROMPT_FILE` prints, for `groq`, `huggingface` and `cloudflare`. The per-user data folder comes from `COCKPIT_DATA_OVERRIDE` (as for the PHP), `COCKPIT_WORKER_BASE` replaces the provider's address (tests). It opens `workers_keys.enc` exactly as `workers.php` does (AES-256-GCM through the system's libcrypto 3, key = sha256 of `/etc/machine-id` + the Cockpit salt; strict base64; a tag mismatch reads as "no key", as in the PHP), makes the one POST of the `invoke_*` function (same JSON body bytes, `\/` escaping and all) and shapes the answer with the same texts (`[GROQ ERROR] HTTP 401: …`, `Bad JSON from Groq`, `Cloudflare key must be "ACCOUNT_ID:API_TOKEN"`, image/audio answers as data URIs, PHP's falsy rules for `success`, the 300-byte body fallback).

**Exit 9 = refused, nothing printed**, for what it does not reproduce byte for byte: another provider, no per-user data folder (the PHP would read the shared one), an empty or non-UTF-8 prompt, a key or message that is not text, an error that is a list, a redirect, HuggingFace's "pretty-printed JSON" answer, libcrypto 3 missing. `aicengine loop` then runs the PHP relay. Known difference: a transport failure reads `curl: <this engine's reason>`.

Proven by `Cockpit/tests/workers_relay_parity.sh` (46 checks: the PHP relay and the engine on the same encrypted store against a mock provider, output and received request compared; refusals; transport failure) and by a loop scenario in `tests/loop_native_test.sh`.
