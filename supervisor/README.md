# aicsupervisor — keeps AI Cockpit's background pieces running (standalone)

Detached from Cockpit: nothing here reads or writes the Cockpit tree. One foreground process, one
single-threaded event loop (it sleeps in `poll()` on its control socket for at most 100 ms), no threads.

    bash build.sh                         # needs only fpc 3.2+
    bash tests/run_all.sh                 # build + every suite (about 2 minutes)
    bin/aicsupervisor check   --config examples/cockpit.supervisor.json
    bin/aicsupervisor run     --config my.json          # foreground; a service manager keeps THIS alive
    bin/aicsupervisor ctl     --config my.json status | start N | stop N | restart N | run-job N | logs N | reload | shutdown
    bin/aicsupervisor service-file systemd-user|systemd-system|launchd --config my.json

## What it replaces on the current rig
| Today | Supervisor |
|---|---|
| `crontab: */1 * * * * php scheduler.php` | job `"schedule": "every 60s"` (overlap=skip, timeout, logged) |
| `cockpit-archive.timer` (Sun 04:00, Persistent, RandomizedDelaySec) | job `weekly sun 04:00`, `persistent`, `random_delay_s` |
| `cockpit-model-watch.timer` (1st, 09:00, Persistent) | job `monthly 1 09:00`, `persistent` |
| `cockpit-guard.service` + `cockpit_guard.sh` (inotifywait loop) | `guards` (stat-cached sha256 check, flag file, verified restore) |
| `cockpit_start.sh` / `cockpit_stop.sh` (service parts) | `services` (order, health, restart, stop) |
| tmux agent sessions, `session.php` | the engine as a service (`aicengine serve`) |

`examples/cockpit.supervisor.json` is that whole setup as one validated file.

## Services
Dependency order (`start_after`); "running" means alive AND, with a health check, answering (`tcp`, `unix`,
`http`, `command`). A crash restarts after an exponential backoff (1 s, 2 s, 4 s … capped); the backoff resets
after `stable_after_s`; more than `max_restarts` crashes in `restart_window_s` = state **failed**, it stays
down until someone says `start`. Stop = SIGTERM to the whole process group, SIGKILL after `stop_timeout_s`.
A health check that fails `failures` times in a row restarts the service. `adopt_if_healthy` leaves a service
that is already up (the system's Ollama) alone and never stops it. Per-service stdout/stderr go to a size-capped,
rotated log. After a **supervisor crash** (`kill -9`, OOM) the services keep running; the next supervisor
re-attaches to them through per-service pid files (identity checked via `/proc`), instead of starting duplicates.

## Jobs
`every 60s|5m|2h`, `daily 04:00`, `weekly sun 04:00`, `monthly 1 09:00` (local time; a short month uses its last
day). `overlap` skip|kill, `timeout_s` kills the whole tree, `run_at_start`, `persistent` (a slot missed while the
supervisor was down runs once at start; others are skipped), `random_delay_s`. Last run / status / exit code
survive restarts (`state.json`).

## Guard
Manifest `{"files": {"rel/path": "sha256"}}`. Each interval every file is compared; unchanged `size:mtime:inode`
= not re-hashed (3000 files: first pass 0.1 s, later passes 5 ms). A violation is logged once per distinct state,
written to a flag file, and — with `restore: copy` — restored from `restore_from` **only if that copy hashes to
the manifest value** (a tampered backup is refused), atomically, then re-verified. Manifest paths with `..` or a
leading `/` are ignored; a new manifest (a deploy) is picked up. Polling, not inotify: same on every OS.

## Control
Unix socket, JSON lines, per-install token (mode 0600 / 0640 with a group), same shape as aicengine's.
SIGTERM/SIGINT = stop everything in reverse start order and exit 0; SIGHUP = reload (an invalid new file is
refused, the old one stays in force).

## Proven (tests/run_all.sh): 37 schedule checks, SHA-256 vs `sha256sum` on 20 inputs, 86 supervisor scenarios
Bugs the tests found and fixed: the control socket (and any other descriptor) leaked into every service, so after a
supervisor crash a service kept the socket "alive" and `ctl` hung (also fixed in aicengine, with its own test);
a double free on invalid configs; O(n²) guard lookups (195 ms → 5 ms for 3000 files); local time stored as UTC;
test races (stale socket after `kill -9`, sampling a job mid-run).

## Not done
- **Windows** (CreateProcess + job objects, named pipe, service wrapper): same contract, separate unit.
- **macOS** is untested (the code is POSIX; `/proc` identity check falls back to "alive").
- Managing the system's own Apache/PHP during the transition (the supervisor only runs what it is configured to run).
- Notifications beyond the log and flag file.
