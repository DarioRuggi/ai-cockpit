# cockpit_shell — native window for AI Cockpit

A 400-line Free Pascal program: one GTK 3 window holding a WebKitGTK view of the
local AI Cockpit app. It exists for a single reason — **the window's close
button, Alt+F4 and the dock's "Quit" must run the app's own exit procedure**
(the "Leaving Cockpit" modal: kill jobs, stop sessions, wait, or leave), which a
browser `--app` window cannot guarantee.

Licence: Apache License 2.0 — same as AI Cockpit (see `LICENSE.md`, `NOTICE`).
Source: `scripts/cockpit_shell_src/` inside every bundle, and on
https://cockpit.ruggi.site/download.php.

## How it works

| Direction | Mechanism |
|---|---|
| shell → page, on a close request | runs `window.cockpitShellClose()` in the page and **vetoes** the close |
| page → shell, to really quit | sets `document.title = '__COCKPIT_QUIT__'` (the shell watches `notify::title`) |
| page detects the shell | user agent ends with `AICockpitShell/<version>` |

If the page is not loaded (server down, splash still showing) a close request
simply quits. Links outside the app (`ruggi.site`, docs, `window.open`) go to
the desktop browser via `xdg-open`; the shell never opens a second window.

Keys: **F11** fullscreen, **F5** / **Ctrl+R** reload, **Ctrl+Shift+R** / **Ctrl+F5** reload bypassing the cache.

## Page ↔ shell messages

The page posts JSON to `window.webkit.messageHandlers.cockpit`; the shell answers
by calling `window.cockpitShellReply(json)` with the same `id`.

| cmd | reply |
|---|---|
| `quit` | (window closes) |
| `bw_status` | `installed`, `unlocked` |
| `bw_search` `{q}` | `items: [{id,name,username}]` (login items only) |
| `bw_get` `{item}` | `name`, `username`, `password` |
| `pick_files` `{multiple,title,dir}` | native GTK file chooser → `paths` (absolute) |
| `notify` `{title,body,urgency}` | libnotify desktop notification with an "Open Cockpit" action |
| `present` | bring the window up |
| `open_window` `{url,title,w,h}` | a second window on the app's own origin (relative URL, or one that matches it); up to 6, Escape / Ctrl+W closes one |
| `open_path` / `reveal_path` `{path}` | the desktop's handler / the file manager with the file selected |
| `open_terminal` `{path}` | a terminal already in that directory |
| `open_tmux` `{session,socket}` | a terminal attached to that tmux session |
| `clipboard_files` | absolute paths of the files on the clipboard (`text/uri-list`) |
| `sysinfo` | `cpu_pct`, `mem_used_mb`/`mem_total_mb`, `gpu_pct`, `vram_used_mb`/`vram_total_mb` from /proc and sysfs |
| `kr_set` `{key,value}` / `kr_get` `{key}` / `kr_del` `{key}` | OS keyring (libsecret, schema `site.ruggi.cockpit`); `available:false` without libsecret |

**Tray.** libayatana-appindicator3 (or libappindicator3) when present: Show /
Minimise / Exit Cockpit… (the exit item takes the close-button path). GNOME needs
the AppIndicator extension to display it.

**Drops.** GTK's `drag-data-received` on the web view fires before WebKit's DOM drop;
the shell reads the URI list and calls `window.cockpitShellDrop({paths})`, so the
page attaches by real path instead of uploading File objects.

**Keyring.** The page keeps its "keep me signed in" token there (GNOME Keyring /
KWallet, unlocked with the desktop session) — never in Cockpit's own files.

**Bitwarden.** The shell is the only side that runs the official CLI (`bw`, looked
for in `~/.local/bin`, `/usr/local/bin`, then `PATH`). When the vault is locked it
opens a terminal running `bw unlock --raw`: the master password is typed into bw,
never into Cockpit; the session token is handed over through a 0600 file that is
deleted the moment it is read, then kept in the process only. Nothing is logged.

## Page ↔ shell messages

The page posts JSON to `window.webkit.messageHandlers.cockpit`; the shell answers
by calling `window.cockpitShellReply(json)` with the same `id`.

| cmd | reply |
|---|---|
| `quit` | (window closes) |
| `bw_status` | `installed`, `unlocked` |
| `bw_search` `{q}` | `items: [{id,name,username}]` (login items only) |
| `bw_get` `{item}` | `name`, `username`, `password` |

**Bitwarden.** The shell is the only side that runs the official CLI (`bw`, looked
for in `~/.local/bin`, `/usr/local/bin`, then `PATH`). When the vault is locked it
opens a terminal running `bw unlock --raw`: the master password is typed into bw,
never into Cockpit; the session token is handed over through a 0600 file that is
deleted the moment it is read, then kept in the process only. Nothing is logged.

Cookies (the app's local login) persist in `$XDG_DATA_HOME/ai-cockpit/`
(`~/.local/share/ai-cockpit/`), where WebKit also keeps the app's localStorage.

## Build

    bash build.sh            # → ./cockpit_shell

Only `fpc` is required. GTK 3 and WebKitGTK 4.1 are loaded at run time
(`libgtk-3.so.0`, `libwebkit2gtk-4.1.so.0`), so no `-dev` packages are needed
to build and only the runtime libraries to run:

- Debian/Ubuntu/Mint: `libwebkit2gtk-4.1-0` · Arch: `webkit2gtk-4.1` ·
  Fedora: `webkit2gtk4.1` · openSUSE: `libwebkit2gtk-4_1-0`

The installer ships a prebuilt x86-64 binary in `scripts/cockpit_shell` and
rebuilds from this source when `fpc` is present and the prebuilt one cannot run
(other architectures).

## Usage

    cockpit_shell --url URL [--title T] [--icon PNG]
                  [--splash FILE --ready FILE] [--width W --height H] [--devtools] [--check]

`--splash FILE --ready FILE`: show FILE first and switch to URL once the ready
file exists — `cockpit_start.sh` touches it when the agent sessions are up.

`--verify DIR`: hash the files `DIR/integrity.json` lists **before** loading the
page (index.html, auth.php, paths.php, integrity_lib.php and every css/ and js/ file — the ones that decide
what runs in this window). Any difference and the app is not loaded at all; the
window explains instead. A tampered page cannot vouch for itself, which is why
this check lives out here. `--no-verify` skips it.

`--start CMD`: when the app URL does not answer, the window shows its own boot
screen (built in — no web server needed to draw it), runs CMD once, and polls
until the server answers, then loads the app. On timeout it says so and offers
Retry. This is what lets the window be launched on a machine where nothing is
running yet. `--start-timeout SECONDS` (default 90).

`--kiosk`: fullscreen, undecorated, F11 disabled.

`--hotkey ctrl+alt+c` (or `none`): one combination grabbed on the X11 root
window — pressed anywhere it brings the window to the front, pressed again while
it is in front it minimises it. Every lock-key variant is grabbed, a clash with
another app fails silently, and under Wayland the grab is skipped (the
compositor owns shortcuts there; bind `cockpit-start` in its settings instead).
"In front" is decided by walking the X input focus, not by GTK's own idea of it,
which differs between window managers.

The window's size and maximised state are remembered per user in
`$XDG_CONFIG_HOME/ai-cockpit/window.json` (never the position — the WM places
the window, and a stored position lands wrong when the monitors change).

## Worker mode (`--worker DIR`)

`cockpit_shell --worker DIR --url URL` loads a page in a window nobody sees (a GtkOffscreenWindow: nothing is drawn on any screen, yet the page is laid out and its timers run
normally) and is driven through files in `DIR`: Cockpit writes `cmd.<n>.json` (`eval` / `show` / `hide` / `load` / `reload` / `status` / `quit`), the window appends one JSON line per
event to `events.ndjson` (what the page posts through `window.webkit.messageHandlers.cockpit`, plus `ready` / `loaded` / `status`), and rewrites `alive` every 150 ms. `show` moves the
page into a normal window (to log in); `hide` puts it back. Cookies live in `DIR/profile/`. The user agent is the plain WebKit one. See `cockpit_app/webworker_lib.php`.
