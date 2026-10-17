---
title: AI Cockpit — Setup Guide
---

# AI Cockpit --- New-Machine Setup Guide

            . | .
             \|/
         .--- O ---.
        /    /|\    \
       '    / | \    '
            . | .

      Fresh Linux Mint → Working AI Cockpit

> Step-by-step setup for a Linux Mint 22 / Ubuntu 24.04 / Debian 13 / Fedora 44 / Manjaro machine (openSUSE takes the same installer; the package lists are per distro). Each step has a verification checkpoint. Do not skip steps. If a step fails, the Troubleshooting section at the end has fixes.

------------------------------------------------------------------------

## Table of contents

1.  [Before you start](#before-you-start) · [The installer --- the setup window](#the-installer)
2.  [Installing on macOS / Windows](#other-operating-systems)
3.  [Step 1 --- System packages](#step-1)
4.  [Step 2 --- Node.js (for Claude Code & Gemini CLI)](#step-2)
5.  [Step 3 --- AI CLI tools](#step-3)
6.  [Step 4 --- Ollama and local models](#step-4)
7.  [Step 5 --- Apache PHP setup](#step-5)
8.  [Step 6 --- Cockpit files](#step-6)
9.  [Step 7 --- Permissions and sudoers](#step-7)
10. [Step 8 --- Built-in capabilities](#step-8)
11. [Step 9 --- Tool binaries (optional but recommended)](#step-9)
12. [Step 10 --- First launch verification](#step-10)
13. [Step 10b --- Companion tools (installed for you)](#step-10b)
14. [Step 11 --- Worker provider keys (optional)](#step-11)
15. [Step 12 --- Personalization](#step-12)
16. [Troubleshooting](#troubleshooting)
17. [Uninstall](#uninstall)

------------------------------------------------------------------------

## Before you start

CI-verified --- an unattended end-to-end run of `install_cockpit.sh` passes on a real Linux Mint/Ubuntu runner (GitHub Actions). Hand-tested end to end on fresh Ubuntu 24.04, Fedora 44 Workstation, Debian 13 (XFCE), Manjaro (KDE), openSUSE Tumbleweed (GNOME) and Arch (MATE) VMs, and on Windows 11 (25H2) through WSL2, with every option on (LocalAI, LibreTranslate, Piper, whisper.cpp, Aider, companion tools).

### Required

-   Linux Mint 22.x / Ubuntu 24.04 / Debian 13 (or a derivative), Fedora 44 Workstation, or Manjaro/Arch. Arch: the installer does the full `pacman -Syu` first (keyrings, mirrors), wires `php-apache` (prefork + php_module + php.ini extensions) and lifts `ProtectHome` on `httpd.service` so the web server can reach `~/scripts`. On Fedora the installer also sets SELinux so the web server may run your agents (only the `httpd_t` domain is made permissive; everything else stays enforcing)
-   Sudo access on the machine
-   4 GB RAM and ~10 GB disk to run Cockpit itself
-   Working internet connection (only needed during setup; cockpit runs offline)

**Nothing below is required, and the installer never refuses a machine.** Hardware
decides only how fast *local models* run --- and local models are one of five supplier
classes. Paid CLIs (Claude, Codex, Qwen), free REST workers (Gemini, Groq) and every
tool need **no GPU at all**, so a modest laptop runs Cockpit perfectly well.

### Minimum recommendations {#minimum-recommendations}

Four tiers. **None of them is enforced** --- the installer accepts any machine and
tells you what it found.

**1. To run Cockpit --- 4 GB RAM, ~10 GB disk, no GPU.**
Everything works except local models: paid CLIs (Claude, Codex, Qwen), free REST
workers (Gemini, Groq), tools, projects, chats, the relay. This is a perfectly normal
way to use Cockpit.

**2. Minimum for local models at usable speed --- 8 GB RAM, no GPU needed.**
Measured: **3B at ~8 tok/s, 1.5B at ~16 tok/s**, both above the ~4 tok/s floor where
things begin timing out. Core count barely matters --- 2 threads measured the same as
12 --- because CPU inference is limited by memory bandwidth, not cores. Bookshelf sizes
its chapters to 12 KB here so one stays readable in under a minute.

**3. Comfortable local models --- 4 GB VRAM and 16 GB RAM.**
Measured: **3B at 58 tok/s, 1.5B at 104**. This is the sweet spot for a small card.
Do not expect more from it: 7B drops to 5.6 tok/s, and 14B **fails** rather than
crawls. Bookshelf uses 20 KB chapters here (~7s to read one).

**4. Larger models --- 8 GB VRAM for 7B-class, 12 GB+ for 14B-class.**
Inferred from how much VRAM a model needs to avoid spilling onto the CPU; not measured
here, since the test machine has 4 GB.

**The honest summary:** Cockpit needs very little. *Local models* are what want hardware,
and even they are usable with no GPU at all as long as you stay at 3B or below.

### How fast will local models be here? {#local-model-speed}

Measured on a 4 GB GPU (AMD RX 6400) and a 12-core CPU, generation tokens per second:

  Model        4 GB GPU     CPU only (no GPU)
  ------------ ------------ -------------------
  1.5B         104          16
  3B           58           8
  3.8B         12           6
  7B           5.6          3.7
  14B          2.3          1.8

Read it as: **above ~10 tok/s feels live** (faster than you read); **below ~4 tok/s
things start timing out rather than merely feeling slow**.

  What you have                   What to expect
  ------------------------------- -------------------------------------------------
  **No GPU**, modern multi-core   Everything works. Local models up to **3B** are
  CPU                             comfortable. 7B and larger will be painfully slow.
  **4 GB VRAM**                   **3B-class models are the sweet spot** (58 tok/s).
                                  7B runs but drags; **14B will time out** on long
                                  answers --- it is not slow, it fails.
  **8 GB VRAM**                   7B-class comfortably.
  **12 GB+ VRAM**                 14B-class comfortably.
  **RAM**                         16 GB is comfortable; 32 GB if you want several
                                  models resident or Dual mode.

Two measured details worth knowing. The cliff is **between 3B and 3.8B on a 4 GB card**
--- 58 to 12 tok/s --- because the model stops fitting in VRAM and spills onto the CPU.
And a 4 GB card only earns its keep up to 3B: at 7B it is just 1.5x faster than the CPU,
at 14B 1.3x, because by then most layers are running on the CPU anyway.

**If your machine is below these, install anyway.** Cockpit will tell you what it
detected, default the model downloads to *none* so you are not pulling multi-GB files
that will crawl, and let you pick. Everything except local model speed is unaffected.

Features that read long text size themselves to your hardware: Bookshelf splits a book
into chapters small enough for the machine that will read them (12 KB with no GPU, 20 KB
on a 4 GB card, 40 KB above that), so a chapter stays readable instead of taking minutes.

### Optional but useful

-   **A GPU, for local models only.** Nothing else uses it. A 4 GB card makes 3B-class models comfortable (58 tok/s measured); 8 GB suits 7B, 12 GB+ suits 14B. Dual mode needs enough for both models resident at once. The app detects your real GPU/VRAM at install time (AMD and NVIDIA) and sizes the local-model offers to it. With no GPU, local models still run on the CPU up to about 3B --- see [How fast will local models be here?](#local-model-speed)
-   A non-default home directory layout --- the cockpit derives your home directory from the environment, so a standard `/home/<you>` works with no edits. If your projects live somewhere unusual (a second disk, a network mount), point `projects_root` at it in `paths.json` or from the Library/Config tab

### What the installer sends, and how to stop it

`install_cockpit.sh` sends one anonymous line when it starts --- OS, distro, architecture, package manager, coarse hardware, and the installer's own version --- and uses the reply to tell you whether a newer release exists. No username, no file paths, no file contents, no IP. It happens before the edition prompt because one installer serves every edition, so at that moment there is no choice yet to respect.

Choosing **Stand-alone (V1)** ends it there: that line plus the record of your choice are the last things sent, and at the end you are asked once, knowing the install worked, whether to send a single anonymous "it succeeded" line. Decline and nothing is sent and nothing asks again. **V2/Both** additionally report install progress and errors, so broken installs can be found and fixed.

To send nothing at all, set the environment variable before running it:

::: {#cbtele .sourceCode}
``` {.sourceCode .bash}
COCKPIT_NO_TELEMETRY=1 sudo -E bash install_cockpit.sh
```
:::

(The manual steps in this guide send nothing regardless --- there is no installer involved.)

### What you should download before running these steps

Get this bundle ready in `~/Downloads/`:

    cockpit-bundle/
    ├─ index.html
    ├─ bridge.php
    ├─ files.php
    ├─ status.php
    ├─ models.php
    ├─ saver.php
    ├─ session.php
    ├─ config.php
    ├─ library.php
    ├─ paths.json
    ├─ search.php
    ├─ export.php
    ├─ import.php
    ├─ version.php
    ├─ VERSION
    ├─ capabilities.php
    ├─ orchestrator.php
    ├─ workers.php
    ├─ workers_providers.json
    ├─ tools.php
    ├─ tools_builtins.tar.gz
    ├─ cockpit_builtins.tar.gz
    ├─ install_capabilities.sh
    ├─ install_cockpit.sh
    ├─ build_cockpit_tarball.sh
    ├─ cockpit_start.sh
    ├─ cockpit_stop.sh
    ├─ agent_loop.sh
    └─ crud_executor.sh

### The installer --- the setup window {#the-installer}

The cockpit ships an automated `install_cockpit.sh` that does everything below end-to-end. This is the normal path; the numbered steps after it are the manual sequence, for understanding what happens or for finishing by hand if it stops.

- **A setup window, then it runs.** On a desktop the script opens a wizard (`ckdialog`, shipped in the bundle, Free Pascal + GTK 3): edition, install user, projects folder, optional CLIs, models sized to the hardware it detects, media tools, desktop shortcut, logins --- every choice first, a summary page, one **Install** button. The system password is asked once, in a dialog (sudo). A progress window then follows the install log phase by phase and says **Done**. It opens light or dark to match the desktop; the ☾/☀ button switches, and the choice is remembered. Over SSH, or with `COCKPIT_TUI=1`, the same questions are asked in the terminal up front; a question left alone for 10 minutes takes the default shown.
- **Full edition: the account comes first.** The first local login on a machine takes your Cockpit account name --- sign in with an existing account or register a free one (human check) inside the setup; the app's own login is created with that name. Stand-alone asks only for a local login.
- **Interrupted? Re-run it.** It remembers every answer (never passwords) in `~/.local/state/ai-cockpit/install.state` and asks **Continue** or **Start anew**. Components it finds already on the machine --- Node, Ollama, LocalAI, LibreTranslate, Piper, whisper.cpp, Aider, Goose/opencode, models, the companion tools --- are listed on a **Keep** page: ticked ones are left as they are, unticked ones are redone. Re-running over a finished install is the upgrade path: same answers remembered, same Keep page, files refreshed from the bundle.
- **Everything is logged** to `~/cockpit-install.log` --- send that file when reporting a problem. The final screen lists it with the web-server log.
- **Fedora:** the installer also sets SELinux so the web server may run your agents --- only the `httpd_t` domain is made permissive (denials are logged, not enforced); every other domain stays enforcing. Binaries under `~/.local/bin` get the `bin_t` label.
- **Tested as a stranger would**, on fresh Ubuntu 24.04, Fedora 44 Workstation, Debian 13, Manjaro, openSUSE Tumbleweed and Arch (MATE) VMs with every option on. Arch: the `http` account ships expired and `httpd.service` sets NoNewPrivileges — the installer lifts both, or nothing the app launches via sudo can start. openSUSE: Tumbleweed enforces SELinux and its web server runs as `wwwrun:www` — the installer handles both.

**This guide walks through the manual sequence** --- useful if you want to understand what's happening or if the auto-installer fails partway.

------------------------------------------------------------------------

## Installing on macOS / Windows {#other-operating-systems}

Steps 1--12 below are written for Linux Mint/Ubuntu. Cockpit itself is just Apache + PHP + Bash + tmux --- it runs the same way on any OS that can provide those, with the caveats below.

### macOS {#macos-setup}

[TESTED]{style="display:inline-block;font-size:0.7rem;font-weight:700;color:#3fb950;border:1px solid rgba(63,185,80,.5);border-radius:4px;padding:1px 6px;"} **macOS installs end to end on Apple Silicon**, verified 25 September 2026: the real installer runs unattended to *Installation complete*, httpd serves the app (HTTP 200), the VERSION file lands, and the runtime scripts pass a BSD-userland check.

This guide previously claimed macOS was CI-tested when it was not --- the weekly job was reporting a pass while the installer aborted part-way through, because it exited with a success status after dying. Making the job assert completion rather than trust the exit code exposed five real faults, all now fixed:

-   `stat -c` is GNU-only, and under `set -e` a failed command substitution aborts the script --- the install ended silently after the Edition phase.
-   The Homebrew `httpd.conf` was looked for at two paths that do not exist on a Mac, so the port move, the Cockpit alias and the PHP module were all skipped. httpd then came up healthy serving nothing.
-   `${var,,}` and `${var^^}` are **bash 4**; macOS still ships **bash 3.2** as `/bin/bash`. This killed the install at Phase 5b --- and `${1,,}` in one helper survived a build guard added to catch exactly that, because the guard's pattern could not match a positional parameter.
-   Three `sed -i` calls bypassed the script's own portable helper. On BSD that takes the next argument as a backup suffix, so the agent loop would have misbehaved on every Mac, quietly.

What the run does and does not prove: it installs, starts httpd and checks the app answers. It does not drive the interface.

There is no separate macOS installer --- the old `install_cockpit_macos.sh` was retired because it had genuine bugs on Apple Silicon and drifted from the Linux script.

Genuinely native-capable --- no virtualization needed. Apple removed PHP and disabled Apache by default since macOS 12, but both install cleanly via Homebrew:

    # 1. Install Homebrew if you don't have it: https://brew.sh
    brew install httpd php tmux ffmpeg pandoc

    # 2. whisper.cpp — build with the Metal backend (not Vulkan, that's Linux-only)
    git clone https://github.com/ggml-org/whisper.cpp
    cd whisper.cpp && make

    # 3. Ollama — official native app, Apple Silicon Metal-accelerated
    #    https://ollama.com/download/mac

    # 4. Start Apache (httpd), point its docroot at the cockpit-bundle folder,
    #    same as Step 5–6 below — paths differ slightly (/opt/homebrew/... on
    #    Apple Silicon, /usr/local/... on Intel) but the steps are the same.

Everything else --- Steps 6 through 12 --- is identical to the Linux instructions once Apache/PHP/tmux are running. Apple Silicon (M-series) is the architecture being worked on; Intel Macs are not tested at all.

### Windows --- via WSL2 (not native) {#windows-setup}

[TESTED]{style="display:inline-block;font-size:0.7rem;font-weight:700;color:#3fb950;border:1px solid rgba(63,185,80,.5);border-radius:4px;padding:1px 6px;"} Hand-tested end to end on a fresh Windows 11 25H2 machine: `install_windows.ps1`, then the normal Linux installer inside WSL, then the Cockpit window opened from the Windows Start menu. Findings from that run are folded into the script and the notes below.

**Native Windows can\'t run this stack as-is** --- `agent_loop.sh` is built around `tmux`, which has no real Windows equivalent. The supported path is **WSL2 (Windows Subsystem for Linux)**: a real Ubuntu environment running alongside Windows. Cockpit then runs in its own window (the same native WebKitGTK window as on Linux, shown by WSLg), opened from a Windows Start-menu / Desktop shortcut; its Terminal, Files and Browser buttons open gnome-terminal, Nautilus and the Cockpit Browser as ordinary windows next to your Windows apps.

#### Recommended --- one-click installer {#windows-one-click}

Download the bundle with Edge from the [download page](download.php), right-click `cockpit_install.tar.gz` → **Extract All** (Windows 11 unpacks .tar.gz natively), then run `install_windows.ps1` from the extracted `cockpit` folder in an elevated PowerShell:

    # Start → type powershell → "Run as administrator", then:
    cd $HOME\Downloads\cockpit_install\cockpit
    powershell -ep bypass .\install_windows.ps1

It does the whole Windows side: enables WSL2 and installs Ubuntu-24.04 (offers the one reboot Windows needs, and continues where it left off when you run it again), creates the Linux user `cockpit` **unattended** (shows its random password once --- that is the password `sudo` asks for inside WSL, not your Windows one), keeps `systemd` on inside the distro, writes `%USERPROFILE%\.wslconfig` (`vmIdleTimeout=-1` so Cockpit stays up when no terminal is open, `networkingMode=mirrored` so `localhost` reaches it from every Windows browser), installs VS Code + its **WSL** extension, and puts an **AI Cockpit** shortcut in the Start menu and on the Desktop.

It does **not** run `install_cockpit.sh` for you. When it finishes it prints the exact next line --- open the Ubuntu-24.04 app and paste it:

    cp -r /mnt/c/Users/<you>/Downloads/cockpit_install/cockpit ~/cockpit && cd ~/cockpit && bash install_cockpit.sh

From there it is the Linux installer, setup window included (WSLg shows it). Then click **AI Cockpit** on the Desktop.

#### Manual path (if you\'d rather not run the script) {#windows-manual}

    # 1. Install WSL2 + Ubuntu (PowerShell, as Administrator)
    wsl --install -d Ubuntu-24.04

    # 2. Reboot when prompted, then open the new "Ubuntu-24.04" Start Menu entry
    #    and finish the Ubuntu first-run (create a Linux username/password —
    #    unrelated to your Windows login).

    # 3. In PowerShell, write %USERPROFILE%\.wslconfig with these two lines,
    #    then run  wsl --shutdown  once:
    #      [wsl2]
    #      vmIdleTimeout=-1
    #      networkingMode=mirrored
    #    (without them WSL stops Cockpit a minute after the last terminal closes,
    #    and Edge/Chrome cannot reach http://localhost/cockpit/ — it is
    #    forwarded on IPv6 only in the default NAT mode.)

    # 4. Inside the Ubuntu shell, follow Steps 1–12 of this guide exactly
    #    as written — it's a real Ubuntu 24.04, nothing Windows-specific
    #    from here on. Open Cockpit with  cockpit-start  (its own window), or
    #    from your Windows browser at http://localhost/cockpit/  (type the
    #    http:// — Edge silently upgrades bare addresses to https).

Then install VS Code + its \"WSL\" (Remote-WSL) extension yourself, and use **Ctrl+Shift+P → \"WSL: Connect to WSL\"** to open project folders with full native-tool convenience at full WSL-native filesystem speed --- this is the setup we recommend project files live under (inside WSL\'s own filesystem), not on the Windows side reached via `/mnt/c/...`, which has real I/O overhead for the kind of many-small-file CRUD Cockpit\'s agents do.

**Ollama --- run it natively on Windows, not inside WSL.** Ollama has a real native Windows installer with full NVIDIA CUDA GPU support --- better performance than running it inside the WSL2 virtual machine. Install it normally from [ollama.com/download/windows](https://ollama.com/download/windows), then point Cockpit\'s Ollama connection (inside WSL) at the Windows host\'s IP instead of `localhost`:

    # Inside WSL, find the Windows host IP:
    cat /etc/resolv.conf | grep nameserver
    # → use that IP with Ollama's port, e.g. http://172.x.x.x:11434
    # Set OLLAMA_HOST=0.0.0.0 on the Windows side (System Environment
    # Variables) so it accepts connections from WSL, not just localhost.

#### Optional --- stable machine identity across WSL reinstalls {#wsl-license-stability}

WSL2\'s own machine identity is **not stable** --- reinstalling the Ubuntu distro (or certain Windows updates) resets it, which would make Cockpit\'s SaaS licensing think it\'s a brand-new machine each time. To avoid that, copy the Windows-native `cockpit_auth.exe` build to a fixed path Windows and WSL can both see, and Cockpit will automatically prefer it for machine identification (falls back to the normal Linux binary if this isn\'t set up --- nothing breaks either way):

    # From Windows (PowerShell or File Explorer):
    mkdir C:\CockpitAuth
    copy cockpit_auth.exe C:\CockpitAuth\cockpit_auth.exe
    # That's it — Cockpit (running in WSL) detects WSL automatically and
    # reaches this .exe at /mnt/c/CockpitAuth/cockpit_auth.exe.

### Alternative for Windows or macOS --- Docker {#docker-setup}

[NOT TESTED YET]{style="display:inline-block;font-size:0.7rem;font-weight:700;color:#8b949e;border:1px solid rgba(139,148,158,.5);border-radius:4px;padding:1px 6px;"} Written and reviewed carefully, but this bundle hasn\'t actually been built/run end-to-end yet --- please [let us know how it goes](https://cockpit.ruggi.site/qa.php) if you try it.

One `Dockerfile` + `docker-compose.yml`, same on both OSes --- Docker Desktop already runs on WSL2 (Windows) or Apple\'s virtualization framework (macOS), so this sidesteps writing separate native/WSL2/Homebrew instructions per OS. Ollama **and LocalAI both run inside the same container** as Cockpit, not as separate ones --- the app\'s PHP backends call both at hardcoded local addresses (`127.0.0.1:11434` / `127.0.0.1:8080`), not a configurable host, so split containers wouldn\'t be reachable. Both agents\' models persist in their own named Docker volumes across rebuilds.

Download the [Docker bundle](download.php) from the download page (separate small zip --- Dockerfile, compose file, entrypoint script, and a step-by-step README; it doesn\'t duplicate the app itself, you extract the main tarball\'s `web/` folder alongside it). Not yet published to Docker Hub, so you build locally:

    docker compose build      # first time, or after updating web/
    docker compose up -d
    # One-time: authenticate the agent CLIs
    docker compose exec cockpit su - cockpit -c claude
    docker compose exec cockpit su - cockpit -c gemini
    # Then open in your normal browser:
    # http://localhost:8080

GPU passthrough to Ollama only works via Docker on a Linux host with the NVIDIA Container Toolkit (uncomment the `deploy:` block in `docker-compose.yml`) --- Docker Desktop on Windows/macOS doesn\'t pass a GPU through to containers, so Ollama runs CPU-only there, fine for small (1--4B) models.

### Raspberry Pi / ARM Linux {#raspberry-pi-setup}

CI-verified --- an unattended end-to-end run of `install_cockpit.sh` passes on a real ARM64 runner (GitHub Actions).

A Pi running 64-bit Raspberry Pi OS (Debian-based) is **full, real Linux** --- Apache, PHP, bash, and tmux all work exactly as they do on any x86_64 Linux box. **Steps 1--12 of this guide apply unchanged** --- there\'s no separate \"Pi edition\" of the install process. A Pi is also a legitimate, popular way to host Ollama itself as a small always-on local model server, even for other machines on your network to reach.

The one Pi-specific piece is `cockpit_auth` --- the compiled SaaS-licensing binary needs its own ARM build (a Pi can\'t run the x86_64 binary). That build now exists --- see the download page for the ARM Linux binary alongside the x86_64/Windows/macOS ones.

Realistic expectations: a Pi 4/5 with 8GB RAM can run small Ollama models (1--4B parameters) at reasonable speed for CRUD-style combo work; it is not going to run anything comparable to a desktop GPU for larger models --- treat it as a small-model or remote-Ollama-target machine, not a general-purpose Cockpit workstation replacement.

### Everywhere --- remote access from your phone {#everywhere-relay-setup}

The Everywhere tier lets a phone or any other browser talk to a Cockpit already running on your home rig, without port-forwarding or a static IP. Your rig has no open port; both sides poll a small queue on `cockpit.ruggi.site` over plain HTTPS --- nothing to configure on your router.

**Status: built, not yet deployed.** The relay server, the home-rig poller, and the phone page all exist in the codebase as of this guide\'s last update, but the database schema hasn\'t been run against the live server yet and none of it has been tested end-to-end. Treat this section as \"how it will work\", not a guarantee it\'s live right now.

#### One-time setup on your home rig

1.  Make sure your account is signed in and has the Max plan (or the Everywhere add-on) --- check `Settings → Account`.

2.  Create `~/scripts/cockpit_data/relay_poller_credentials.json` with your local Cockpit login (the same username/password you use to open the web UI on this machine):

        {"username": "your-local-username", "password": "your-local-password"}

    This lets the relay poller submit prompts to your own local Cockpit the same way your browser does --- it\'s a local secret file, never uploaded anywhere, same as the Gemini API key file.

3.  Start the poller: `~/scripts/relay_start.sh` (stop it with `~/scripts/relay_stop.sh`). It no-ops safely if you\'re not signed in or not on an Everywhere-capable tier.

#### From your phone

Open `cockpit.ruggi.site/relay.html`, sign in with the same account, pick your rig from the list (skipped automatically if you only have one), and send a message --- it runs on your home rig\'s Claude/Gemini/ Ollama session exactly as if you\'d typed it there, and the reply streams back to your phone. A green dot means the rig\'s poller checked in within the last 30 seconds; grey means it\'s offline or not started.

### Mobile (Android / iOS) {#mobile-setup}

AI Cockpit runs on Linux, ARM Linux, macOS, and Windows (via WSL2). Every other system --- Android, iOS, ChromeOS, anything else --- connects through the **Everywhere relay** page on the site (above) instead: no install, just a browser and a free account with the Everywhere tier.

------------------------------------------------------------------------

## Step 1 --- System packages {#step-1}

Install Apache, PHP, and the supporting CLI tools that the cockpit depends on:

::: {#cb3 .sourceCode}
``` {.sourceCode .bash}
sudo apt update
sudo apt install -y nala
sudo nala install -y \
    apache2 \
    php8.3 \
    php8.3-cli \
    php8.3-curl \
    php8.3-mbstring \
    php8.3-xml \
    php8.3-zip \
    libapache2-mod-php8.3 \
    tmux \
    jq \
    curl \
    git \
    util-linux \
    xed \
    zsh \
    build-essential \
    ca-certificates \
    libwebkit2gtk-4.1-0 \
    libnotify4 \
    libayatana-appindicator3-1
```
:::

### Verification

::: {#cb4 .sourceCode}
``` {.sourceCode .bash}
apache2 -v          # Should show 2.4.x
php -v              # Should show 8.3.x
tmux -V             # Should show 3.x or higher
jq --version        # Should show jq-1.6 or 1.7
which curl          # Should show /usr/bin/curl
```
:::

If any command says "not found", re-run the install for that package.

### Why each package?

-   **apache2 + PHP 8.3** --- serves the cockpit web UI and handles all backend logic
-   **php8.3-curl** --- needed by `bridge.php`, `workers.php`, `orchestrator.php` for HTTP
-   **php8.3-mbstring** --- string handling for non-ASCII content (accents and every script)
-   **php8.3-xml** --- DOM parser for `search.php` (better than regex for HTML scraping)
-   **php8.3-zip** --- chat export/import via ZIP archives
-   **tmux** --- runs each AI agent in a persistent session
-   **jq** --- JSON parsing in shell scripts (capabilities, workers, tools auto-route)
-   **xed** --- your preferred text editor
-   **zsh** --- your preferred shell
-   **libwebkit2gtk-4.1-0 + libnotify4 + libayatana-appindicator3-1** --- the runtime for Cockpit's own window (`cockpit_shell`), its desktop notifications and its tray icon. Without them Cockpit still runs, in a browser window instead --- see [The Cockpit window](USER_GUIDE.html#cockpit-window) in the User Guide.

------------------------------------------------------------------------

## Step 2 --- Node.js (for Claude Code & Gemini CLI) {#step-2}

Node.js is needed for `npx` (which launches MCP servers) and for the official Claude Code and Gemini CLI tools.

::: {#cb5 .sourceCode}
``` {.sourceCode .bash}
# NodeSource repository for current LTS
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo nala install -y nodejs

# Set up a global npm prefix in user-space (avoids sudo for global installs)
mkdir -p "$HOME/.npm-global"
npm config set prefix "$HOME/.npm-global"

# Add to PATH (zsh)
echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.zshrc
echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc
```
:::

Reload your shell config or open a fresh terminal.

### Verification

::: {#cb6 .sourceCode}
``` {.sourceCode .bash}
node --version      # Should show v20.x
npm --version       # Should show 10.x
echo $PATH | tr ':' '\n' | grep npm-global
                    # Should show /home/<you>/.npm-global/bin
```
:::

------------------------------------------------------------------------

## Step 3 --- AI CLI tools {#step-3}

Install the three CLI tools the cockpit dispatches to:

::: {#cb7 .sourceCode}
``` {.sourceCode .bash}
# Anthropic Claude Code
npm install -g @anthropic-ai/claude-code

# Google Gemini CLI
npm install -g @google/gemini-cli

# (Ollama is installed in Step 4)
```
:::

You'll need to authenticate each one before the cockpit can use it:

::: {#cb8 .sourceCode}
``` {.sourceCode .bash}
# Claude — opens a browser for OAuth, you sign in to your Anthropic account
claude

# Gemini — likewise, OAuth flow with your Google account
gemini
```
:::

After both authenticate successfully, you can `Ctrl-D` out of each.

### Verification

::: {#cb9 .sourceCode}
``` {.sourceCode .bash}
claude --version     # Should show a version string
gemini --version     # Likewise

# Sanity smoke tests
echo "Say hello in one word" | claude --print
echo "Say hello in one word" | gemini --prompt
```
:::

Both should return a response within 5--15 seconds.

------------------------------------------------------------------------

## Step 4 --- Ollama and local models {#step-4}

::: {#cb10 .sourceCode}
``` {.sourceCode .bash}
# Ollama installer — official one-liner
curl -fsSL https://ollama.com/install.sh | sh

# Configure non-default model storage location
mkdir -p "$HOME/ollama/models"
sudo systemctl edit ollama.service
```
:::

In the editor that opens, paste:

::: {#cb11 .sourceCode}
``` {.sourceCode .ini}
[Service]
Environment="OLLAMA_MODELS=/home/<you>/ollama/models"
```
:::

Save and exit. Then:

::: {#cb12 .sourceCode}
``` {.sourceCode .bash}
sudo systemctl daemon-reload
sudo systemctl restart ollama
sudo systemctl enable ollama

# Also export for interactive shells
echo 'export OLLAMA_MODELS="$HOME/ollama/models"' >> ~/.zshrc
echo 'export OLLAMA_MODELS="$HOME/ollama/models"' >> ~/.bashrc
```
:::

### Pulling models

The cockpit's default tier-1 recommendations:

::: {#cb13 .sourceCode}
``` {.sourceCode .bash}
# Tier 1 — best for CRUD and context (3 GB VRAM)
ollama pull qwen2.5-coder:1.5b
ollama pull qwen2.5-coder:7b

# Optional — tool-calling fine-tune
ollama pull MFDoom/deepseek-r1-tool-calling:7b
```
:::

### Verification

::: {#cb14 .sourceCode}
``` {.sourceCode .bash}
ollama list                     # Should list pulled models
ollama show qwen2.5-coder:1.5b    # Should show model details

# Smoke test
echo "Say hello in one word" | ollama run qwen2.5-coder:1.5b
```
:::

If `ollama list` shows the storage path is `/usr/share/ollama/...`, the custom path didn't take effect. Re-check the systemd override file:

::: {#cb15 .sourceCode}
``` {.sourceCode .bash}
systemctl cat ollama.service | grep OLLAMA_MODELS
```
:::

### LocalAI (optional --- needed for Dual mode) {#localai-for-dual-mode}

Skip this if you only plan to use Ollama. Dual mode (Card 3 --- both backends genuinely in parallel, for chat and Power Combos) needs LocalAI actually running too. The automated installer does all of this for you; here\'s the manual equivalent.

    # Download the checksum-verified binary (Linux amd64 shown — see
    # install_cockpit.sh for the arm64 asset/checksum)
    mkdir -p ~/.local/bin
    curl -fL https://github.com/mudler/LocalAI/releases/download/v4.7.1/local-ai-v4.7.1-linux-amd64 \
      -o ~/.local/bin/local-ai
    chmod +x ~/.local/bin/local-ai

    # Verify the checksum before trusting it
    echo "2a4ccf4cd7ecc76fb6dde8d847a6d1448b67d7cf84fdcb4285cd002f42a9c801  $HOME/.local/bin/local-ai" | sha256sum -c -

    mkdir -p ~/localai/models ~/localai/data ~/localai/backends
    sudo systemctl edit --force --full localai.service

In the editor that opens, paste (LocalAI\'s own paths default to CWD-relative, which breaks under systemd --- every path below is explicit so it never depends on the caller\'s working directory):

    [Unit]
    Description=LocalAI Service
    After=network-online.target

    [Service]
    WorkingDirectory=/home/YOUR_USERNAME
    ExecStart=/home/YOUR_USERNAME/.local/bin/local-ai run --address 127.0.0.1:8080
    Environment="LOCALAI_MODELS_PATH=/home/YOUR_USERNAME/localai/models"
    Environment="LOCALAI_DATA_PATH=/home/YOUR_USERNAME/localai/data"
    Environment="LOCALAI_BACKENDS_PATH=/home/YOUR_USERNAME/localai/backends"
    User=YOUR_USERNAME
    Group=YOUR_USERNAME
    Restart=always
    RestartSec=3

    [Install]
    WantedBy=default.target

Save and exit, replacing `YOUR_USERNAME` above with your actual username first. Then:

    sudo systemctl daemon-reload
    sudo systemctl enable --now localai

    # Wait for it to come up, then confirm
    curl http://127.0.0.1:8080/

### Pulling LocalAI models

LocalAI has no `pull` command --- models are requested through its own HTTP API. The cockpit\'s default suggestions (LocalAI equivalents of the Ollama Tier-1 set above, same job/size class, run through LocalAI\'s llama.cpp backend instead):

    curl -X POST http://127.0.0.1:8080/models/apply \
      -H "Content-Type: application/json" \
      -d '{"id":"qwen3-1.7b"}'

    # Returns a job uuid — poll it until "processed":true
    curl http://127.0.0.1:8080/models/jobs/<uuid>

Other suggested ids: `llama-3.2-3b-instruct:q4_k_m`, `deepseek-r1-distill-qwen-1.5b`, `qwen3-8b`, `qwen3-4b`. Gallery ids change between LocalAI releases — `curl -s localhost:8080/models/available` lists what this version knows. If an id 404s, browse <http://127.0.0.1:8080/models/available> on the running instance for the exact current gallery id.

### Verification {#verification-localai}

    curl http://127.0.0.1:8080/v1/models   # Should list pulled models
    systemctl status localai               # Should be active (running)

    # Smoke test
    curl http://127.0.0.1:8080/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d '{"model":"qwen3-1.7b","messages":[{"role":"user","content":"Say hello in one word"}]}'

------------------------------------------------------------------------

## Step 5 --- Apache PHP setup {#step-5}

The cockpit runs as a normal Apache vhost at `/var/www/html/cockpit/`.

::: {#cb16 .sourceCode}
``` {.sourceCode .bash}
# Make sure mod_php is enabled
sudo a2enmod php8.3
sudo a2enmod rewrite       # Used by some PHP endpoints

# Set timezone in PHP so dates are correct
sudo bash -c 'cat > /etc/php/8.3/apache2/conf.d/99-cockpit.ini' << 'EOF'
date.timezone = UTC        # or your own, e.g. Europe/Berlin -- `timedatectl` shows it
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 300
EOF

# Same settings for CLI PHP
sudo cp /etc/php/8.3/apache2/conf.d/99-cockpit.ini /etc/php/8.3/cli/conf.d/

# Restart Apache
sudo systemctl restart apache2
sudo systemctl enable apache2
```
:::

### Verification {#verification-4}

::: {#cb17 .sourceCode}
``` {.sourceCode .bash}
# Apache should respond
curl -I http://localhost/   # Should return HTTP/1.1 200 OK

# PHP should be enabled
echo "<?php phpinfo(); ?>" | sudo tee /var/www/html/phpinfo.php > /dev/null
curl -s http://localhost/phpinfo.php | grep "PHP Version"
                            # Should show "PHP Version => 8.3.x"
sudo rm /var/www/html/phpinfo.php

# Verify timezone
php -r 'echo date("c"), "\n";'
                            # Should show current time in your zone
```
:::

### Keep the working folders private {#apache-private-folders}

Apache listens on every network interface and, left alone, **lists the contents of any folder** and serves any file in it. For Cockpit that would expose `responses/` and `queue/` (the agents' replies and the queued prompts) to everyone on your network without a login. The automated installer closes this for you; if you set Apache up by hand, install the same rule:

::: {#cb17b .sourceCode}
``` {.sourceCode .bash}
sudo bash Installs/apache/install_security_conf.sh
# Both of these should now say 403:
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/cockpit/responses/
curl -s -o /dev/null -w '%{http_code}\n' http://localhost/cockpit/paths.json
```
:::

It tests the configuration before reloading and puts everything back if the test fails. The rule never touches anything that is not under a `cockpit` or `cockpit-v1` folder.

### Raising the upload size limit {#upload-limits}

PHP ships with `upload_max_filesize = 2M` and `post_max_size = 8M`. Above that, PHP does not complain: the upload just arrives **empty**, and the feature answers "No audio uploaded" or "No file uploaded". On a stock install that meant a voice note longer than about a minute, a video for the transcriber, or a larger chat import was silently dropped. The automated installer raises both limits to 1 GB for Cockpit's folders only. By hand:

::: {#cb17c .sourceCode}
``` {.sourceCode .bash}
# Apache with mod_php (Debian, Ubuntu, Mint):
sudo bash Installs/apache/install_php_conf.sh

# PHP-FPM or php-cgi: nothing to install --- Cockpit ships a .user.ini beside
# index.html with the same two values (upload_max_filesize, post_max_size).
# Check what PHP actually uses for Cockpit's folder:
curl -s http://localhost/cockpit/auth.php?action=check >/dev/null   # (any PHP page)
php -i | grep -E 'upload_max_filesize|post_max_size'                 # the CLI's own values, for comparison
```
:::

Files that travel inside the page's own data (chat attachments up to 50 MB, books up to 80 MB, personal-archive scans up to 25 MB) are limited by PHP's *memory*, not by these two settings; Cockpit raises that limit itself for those requests.

------------------------------------------------------------------------

## Step 6 --- Cockpit files {#step-6}

Deploy the cockpit's web files to `/var/www/html/cockpit/`:

::: {#cb18 .sourceCode}
``` {.sourceCode .bash}
# Web root for cockpit
sudo mkdir -p /var/www/html/cockpit

# Copy all PHP files, the HTML, JSON catalogs, and VERSION
cd ~/Downloads/cockpit-bundle
sudo cp \
    index.html \
    bridge.php files.php status.php models.php saver.php \
    session.php config.php library.php paths.json \
    search.php export.php import.php version.php VERSION \
    capabilities.php orchestrator.php workers.php tools.php \
    workers_providers.json \
    /var/www/html/cockpit/

# Extract built-in capability and tool definitions
sudo tar -xzf cockpit_builtins.tar.gz -C /var/www/html/cockpit/
sudo tar -xzf tools_builtins.tar.gz   -C /var/www/html/cockpit/

# Scripts that run as the user via tmux
mkdir -p ~/scripts
cp \
    cockpit_start.sh cockpit_stop.sh \
    agent_loop.sh crud_executor.sh \
    install_capabilities.sh \
    ~/scripts/
chmod +x ~/scripts/*.sh

# Cockpit data directory
mkdir -p ~/scripts/cockpit_data/{library,snippets,sources,code,approvals,capabilities/_builtin,plans,workers_state,tools,tools_outputs,_standalone}

# Projects root
mkdir -p ~/Software/Programing/LocalAIProjs
```
:::

### Verification {#verification-5}

::: {#cb19 .sourceCode}
``` {.sourceCode .bash}
ls /var/www/html/cockpit/   # Should list all .php and .html files
ls ~/scripts/               # Should list shell scripts
ls ~/scripts/cockpit_data/  # Should show empty subdirs
```
:::

------------------------------------------------------------------------

## Step 7 --- Permissions and sudoers {#step-7}

Apache (running as `www-data`) needs read access to the cockpit data and tmux socket. Your user (running as `dario`) needs write access. The bridge between these is the `www-data` group.

::: {#cb20 .sourceCode}
``` {.sourceCode .bash}
# Add www-data group membership for shared file access
sudo chgrp -R www-data /var/www/html/cockpit/
sudo chmod -R g+rX /var/www/html/cockpit/

sudo chgrp -R www-data ~/scripts/cockpit_data/
sudo chmod -R g+rwX ~/scripts/cockpit_data/

# tmux socket lives in /tmp; needs group access from www-data
# (cockpit_start.sh creates this on each run with the right perms)

# Add www-data to your group so it can read your home dir prefix
sudo usermod -a -G $USER www-data

# Allow www-data to invoke the cockpit_*.sh scripts without password
sudo bash -c 'cat > /etc/sudoers.d/cockpit' << EOF
www-data ALL=(${USER}) NOPASSWD: ${HOME}/scripts/cockpit_start.sh
www-data ALL=(${USER}) NOPASSWD: ${HOME}/scripts/cockpit_stop.sh
EOF
sudo chmod 440 /etc/sudoers.d/cockpit
```
:::

### Verification {#verification-6}

::: {#cb21 .sourceCode}
``` {.sourceCode .bash}
# As www-data, can it read cockpit_data?
sudo -u www-data ls ~/scripts/cockpit_data/
                            # Should list directories without error

# Validate sudoers without breaking the system
sudo visudo -cf /etc/sudoers.d/cockpit
                            # Should say "/etc/sudoers.d/cockpit: parsed OK"
```
:::

------------------------------------------------------------------------

## Step 8 --- Built-in capabilities {#step-8}

Capability definitions ship as a tarball; deploy them to `cockpit_data`:

::: {#cb22 .sourceCode}
``` {.sourceCode .bash}
cd ~/Downloads/cockpit-bundle
BUILTINS_SOURCE="$PWD/cockpit_builtins" ~/scripts/install_capabilities.sh
```
:::

This copies five built-in capabilities (filesystem, git, web-search, web-fetch, ssh) into:

    ~/scripts/cockpit_data/capabilities/_builtin/

### Verification {#verification-7}

::: {#cb24 .sourceCode}
``` {.sourceCode .bash}
ls ~/scripts/cockpit_data/capabilities/_builtin/
# Should list 5 directories: filesystem, git, ssh, web-fetch, web-search

# Each should contain CAP.json + README.md
for d in ~/scripts/cockpit_data/capabilities/_builtin/*/; do
    echo "$(basename $d):"
    ls "$d"
done
```
:::

------------------------------------------------------------------------

## Step 9 --- Tool binaries (optional but recommended) {#step-9}

Without these binaries, the **TOOLS** card in the cockpit will show "no tools detected". Install whichever you'll use:

::: {#cb25 .sourceCode}
``` {.sourceCode .bash}
# Audio/video — almost always wanted
sudo nala install -y ffmpeg

# Speech-to-text — large download, ~1 GB for the base model
# whisper.cpp (what Cockpit uses) is built by the installer's optional
# Phase 5e into ~/ai-tools/whisper.cpp -- no Python involved. To do it by hand:
#   git clone https://github.com/ggerganov/whisper.cpp ~/ai-tools/whisper.cpp
#   cd ~/ai-tools/whisper.cpp && cmake -B build && cmake --build build -j --config Release
#   sh ./models/download-ggml-model.sh base

# Document conversion
sudo nala install -y pandoc texlive-xetex texlive-fonts-recommended
                                        # texlive needed for md→pdf
```
:::

### Verification {#verification-8}

::: {#cb26 .sourceCode}
``` {.sourceCode .bash}
ffmpeg -version | head -1   # Should show ffmpeg N.x.x
whisper --help | head -3    # Should show Whisper usage
pandoc --version | head -1  # Should show pandoc 3.x
```
:::

If any are missing, you can still launch the cockpit --- Tools will show them as "[close]{.material-symbols-rounded .ico} not found" and you can install later. The cockpit's **Detect** button in Tools settings re-scans whenever you click it.

### Optional add-ons for later

-   **imagemagick** for image conversion: `sudo nala install imagemagick`
-   **yt-dlp** for downloading audio/video: the installer fetches the self-contained build for your platform (no Python needed). By hand: `sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux -o /usr/local/bin/yt-dlp && sudo chmod a+rx /usr/local/bin/yt-dlp`
-   **calibre** for ebook conversion: `sudo nala install calibre`

These don't ship with built-in tool definitions but you can add them via the "+" button in Tools settings.

------------------------------------------------------------------------

## Step 10 --- First launch verification {#step-10}

> **Full edition asks for an account here.** The first time the app loads, the Full (V2) edition shows a Cockpit Account panel with no close button and waits until the install is registered. A free account is enough --- no card, no paid step --- but it is not skippable, because the *server* decides it: it checks whether this machine is registered, so editing local files does not get around it. If you want Cockpit with no registration at all, install the **Stand-alone (V1)** edition instead --- same download, you choose at the prompt --- which has no account layer and makes no network calls. See *Do you need one?* in the User Guide.



Time to start the cockpit:

::: {#cb27 .sourceCode}
``` {.sourceCode .bash}
~/scripts/cockpit_start.sh
```
:::

You should see output like:

    Starting cockpit sessions...
      Claude session: cockpit_claude
      Gemini session: cockpit_gemini
      Ollama session: cockpit_ollama
      tmux socket: /tmp/cockpit_tmux.sock
      Apache: ready
    Cockpit ready: http://localhost/cockpit/

The start script opens Cockpit's **own window** (`~/scripts/cockpit_shell`): a splash while the sessions come up, then the app. Nothing else to launch.

If the window does not appear (no WebKitGTK runtime on this machine, or a CPU the prebuilt binary does not cover), Cockpit falls back to a browser window --- open it by hand with:

::: {#cb29 .sourceCode}
``` {.sourceCode .bash}
xdg-open http://localhost/cockpit/
```
:::

To check the window itself:

::: {.sourceCode}
``` {.sourceCode .bash}
~/scripts/cockpit_shell --check     # "runtime libraries OK" when it can run here
tail -5 ~/.cache/cockpit_shell.log # what it did on the last launch
```
:::

### What to verify

1.  **The topbar** shows the brand mark (control-yoke logo + "AI Cockpit" wordmark + version + "by Dario Ruggi") on the left
2.  **Five supplier cards** appear: CLAUDE, GEMINI, OLLAMA, WORKERS, TOOLS
3.  **CLAUDE is the default active card** (expanded with model dropdown)
4.  **Stop / Restart** buttons appear on the right
5.  **Info bar** below the strip shows project/chat/path
6.  The **chat console** is the large central area
7.  **Right sidebar** has 9 vertical icon tabs
8.  The window has **no address bar and no tabs** --- it is Cockpit's own window; closing it opens the *Leaving Cockpit* dialog rather than closing at once
9.  **Ctrl+Alt+C** brings the window up from any other application (and starts Cockpit when it is not running, if you accepted the shortcut during install)

### First prompt smoke test

1.  Type "say hello in one word" in the prompt area
2.  Press Enter (Ctrl-Enter or Shift-Enter adds a line instead)
3.  Within a few seconds, "Hello" or similar appears as a streamed response

If this works, you're done. The next steps are optional personalization.

------------------------------------------------------------------------

## Step 10b --- Companion tools (installed for you) {#step-10b}

The scripted installer also sets up two small command-line suites that are not part of Cockpit itself but ship with it. They are ordinary tools on your `PATH`, with their own `--help` and man pages, and Cockpit never depends on them --- remove them and nothing in the app changes.

-   **ftpsuite** (`ftpush`, `ftpull`, `ftps-cli`, `ftps-gui`) --- scripted file transfer to a site you own. Sites and local-to-remote path pairs live in a JSON config, so one tool serves several sites: `ftpush --add-site`, then `ftpush --add-pair`, then `ftpush -p1 <files>`. Credentials stay in that config (`chmod 600`) and are never passed on the command line.
-   **secrets** (`secrets`, `secrets-cli`, `secrets-gui`) --- an encrypted store for your own keys and logins, held as a GPG-encrypted Markdown file. Several stores, several templates, a template editor, and a re-key command for rotating the passphrase without leaving old copies behind. `secrets init` creates the first store.

Both have dark/light themes in their GUIs and `man ftpush` / `man secrets` for the details. If you are following the manual steps in this guide, neither is installed --- fetch them from the tools pages on the site if you want them.

------------------------------------------------------------------------

## Step 11 --- Worker provider keys (optional) {#step-11}

If you want to use online LLM providers as workers:

1.  Click the gear icon next to **WORKERS** → settings modal
2.  For each provider you want:
    -   Click **Get key** --- opens the provider's key page in a new tab
    -   Sign up / log in, create an API key
    -   Paste the key into the input field → click **Save**
    -   Click **Disabled** to toggle to **Enabled**
3.  Close the modal --- the workers dropdown is now populated

Recommended starting point: **Groq** is free with generous limits and makes a good first test. Once you have a key, smoke-test it via:

1.  Click the WORKERS card
2.  Pick a Groq model (e.g. "Llama 3.3 70B Versatile")
3.  Type a prompt → press Execute
4.  Response should appear within a few seconds

------------------------------------------------------------------------

## Step 12 --- Personalization {#step-12}

### Default browser (for links Cockpit opens outside its window)

::: {#cb30 .sourceCode}
``` {.sourceCode .bash}
xdg-settings set default-web-browser brave-browser.desktop
```
:::

### Auto-start cockpit on login

The scripted installer offers this; by hand it is one desktop entry. `cockpit-start` opens Cockpit's own window, which brings the web server and the agent sessions up itself and shows what it is doing --- no `sleep`, no browser to launch:

::: {#cb31 .sourceCode}
``` {.sourceCode .bash}
mkdir -p ~/.config/autostart

cat > ~/.config/autostart/ai-cockpit.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=AI Cockpit
Exec=cockpit-start
Icon=ai-cockpit
Terminal=false
StartupWMClass=ai-cockpit
X-GNOME-Autostart-enabled=true
EOF
```
:::

### A key that summons Cockpit

`Ctrl+Alt+C` brings the window to the front from any application, puts it down when it is already there, and starts Cockpit when it is not running. The installer offers it (not on WSL: Windows owns the keyboard there --- use the Start-menu shortcut); to add or remove it later:

::: {.sourceCode}
``` {.sourceCode .bash}
~/scripts/install_hotkey.sh                 # Ctrl+Alt+C (Cinnamon, GNOME, XFCE, KDE, MATE)
~/scripts/install_hotkey.sh "<Super>c"      # a different combination
~/scripts/install_hotkey.sh --remove        # take it out again
```
:::

### Fill logins from Bitwarden (optional)

Cockpit's own login forms can be filled from your Bitwarden vault through the official CLI. The master password is typed into `bw`'s own prompt in a terminal Cockpit opens --- never into Cockpit:

::: {.sourceCode}
``` {.sourceCode .bash}
~/scripts/install_bw.sh     # official release binary into ~/.local/bin (sha256-checked)
~/.local/bin/bw login       # once
```
:::

Name the vault items `AI Cockpit Local`, `AI Cockpit SAAS` and `AI Cockpit Admin Token` and each form finds its own.

### Dark theme (you've already got this --- Linux Mint dark variant)

The cockpit has its own dark theme baked in. No system-level config needed.

### Default project

Edit `~/scripts/cockpit_data/last_project.txt` to set the project that opens by default each time:

::: {#cb32 .sourceCode}
``` {.sourceCode .bash}
echo "myproject" > ~/scripts/cockpit_data/last_project.txt
```
:::

------------------------------------------------------------------------

## Troubleshooting

### Apache returns 403 Forbidden

::: {#cb33 .sourceCode}
``` {.sourceCode .bash}
# Permissions on the cockpit directory
sudo chown -R dario:www-data /var/www/html/cockpit/
sudo chmod -R g+rX /var/www/html/cockpit/

# Apache config — make sure /var/www/html is allowed
grep -A3 "Directory /var/www/" /etc/apache2/apache2.conf
                            # Should include "Require all granted"
```
:::

### "Bridge.php returned no response"

The PHP error log usually has the answer:

::: {#cb34 .sourceCode}
``` {.sourceCode .bash}
sudo tail -50 /var/log/apache2/error.log
```
:::

Common causes:

-   **php-curl missing**: `sudo nala install php8.3-curl && sudo systemctl restart apache2`
-   **paths.json missing or corrupt**: re-copy from the bundle
-   **bridge.php has a syntax error**: `php -l /var/www/html/cockpit/bridge.php`

### "Agent session not found in tmux"

::: {#cb35 .sourceCode}
``` {.sourceCode .bash}
# Check what sessions exist
tmux -S /tmp/cockpit_tmux.sock ls 2>&1

# If empty, restart cockpit
~/scripts/cockpit_stop.sh && ~/scripts/cockpit_start.sh

# If permission denied, the socket has wrong group
sudo chgrp www-data /tmp/cockpit_tmux.sock
sudo chmod 660 /tmp/cockpit_tmux.sock
```
:::

### Cockpit opens in a browser instead of its own window

`cockpit_shell` could not run here. Ask it why:

::: {.sourceCode}
``` {.sourceCode .bash}
~/scripts/cockpit_shell --check
```
:::

-   *cannot load libwebkit2gtk-4.1.so.0* --- install the runtime: `sudo apt install libwebkit2gtk-4.1-0` (Arch: `webkit2gtk-4.1`, Fedora: `webkit2gtk4.1`, openSUSE: `libwebkit2gtk-4_1-0`).
-   *cannot execute binary file* --- the prebuilt binary is x86-64; rebuild it for this CPU with `bash ~/scripts/cockpit_shell_src/build.sh ~/scripts/cockpit_shell` (needs `fpc`).
-   Everything else: `tail -20 ~/.cache/cockpit_shell.log`.

### The window says Cockpit did not start

The window brings the stack up itself and reports when that fails. Run the same thing in a terminal to see the error:

::: {.sourceCode}
``` {.sourceCode .bash}
cockpit-start
```
:::

Usual causes: Apache not installed or its port taken, the sudoers rule from [Step 7](#step-7) missing, or a full disk. `COCKPIT_NO_VERIFY=1 cockpit-start` skips the manifest check if that is what refuses to load the app (then use `~/scripts/cockpit_restore.sh` to put the shipped files back).

### Ctrl+Alt+C does nothing

-   Under Wayland the compositor owns shortcuts: add one for `cockpit-start --toggle` in the desktop's keyboard settings.
-   Another application may already hold the combination --- pick a different one: `~/scripts/install_hotkey.sh "<Super>c"`.
-   Check what is registered: `gsettings get org.cinnamon.desktop.keybindings custom-list` (Cinnamon) or the desktop's Keyboard settings.

### No tray icon

GNOME Shell shows tray icons only with the *AppIndicator* extension (`sudo apt install gnome-shell-extension-appindicator`, then enable it and log out and in). KDE, XFCE, Cinnamon and MATE show it as is. Notifications work regardless.
### Claude / Gemini OAuth fails

Both CLIs need a working browser OAuth flow:

::: {#cb36 .sourceCode}
``` {.sourceCode .bash}
# From a desktop environment with a browser available
claude   # Will print an auth URL; open it in your browser, sign in
gemini   # Same flow, separate auth
```
:::

If you're SSHing in headlessly, you'll need to do the auth on the machine's actual desktop session first.

You sign in **once**, in your own `~/.claude`. Agents the cockpit starts run against a cockpit-owned config
directory with your credential file symlinked in, so they use that same login and a refreshed token is written
back to the real file.

### The cockpit's agents answer in someone else's voice

Symptom: answers come back in a style the cockpit never asked for --- clipped, themed, or following house rules
you set somewhere else --- while the Style selector says something different.

Cause: a `SessionStart` hook or plugin in your personal CLI config (`~/.claude/settings.json`). It is injected
before the cockpit's own prompt, so nothing inside the cockpit can override it.

Fix: nothing to do --- since build 97 the cockpit's agents run against an isolated config and never see it. If
you are on an older build, or you switched the **Use my global CLI config** capability on, turn that capability
off (Settings --> Capabilities) or disable the hook in your own config.

### Ollama: "no models" in cockpit dropdown

::: {#cb37 .sourceCode}
``` {.sourceCode .bash}
# Confirm models exist
ollama list

# If empty, pull the defaults:
ollama pull qwen2.5-coder:1.5b

# Confirm OLLAMA_MODELS is being honored
ls ~/ollama/models/  # Should show downloaded blobs

# If models live in /usr/share/ollama/.ollama/, the systemd override didn't apply
sudo systemctl edit ollama.service   # Re-set the Environment line
sudo systemctl daemon-reload && sudo systemctl restart ollama
```
:::

### LocalAI: "no models" in cockpit dropdown

    # Confirm the service is actually running
    systemctl status localai

    # Confirm models exist
    curl http://127.0.0.1:8080/v1/models

    # If empty, pull a default
    curl -X POST http://127.0.0.1:8080/models/apply \
      -H "Content-Type: application/json" \
      -d '{"id":"qwen3-1.7b"}'

    # Confirm LOCALAI_MODELS_PATH is being honored
    ls ~/localai/models/  # Should show downloaded files

    # If the service won't start, check the unit for typos in the paths
    systemctl cat localai.service
    journalctl -u localai -n 50 --no-pager

### Tool detection always says "not found"

::: {#cb38 .sourceCode}
``` {.sourceCode .bash}
# Verify the binaries are in PATH that Apache can see
sudo -u www-data which ffmpeg
sudo -u www-data which whisper
sudo -u www-data which pandoc

# If www-data can't see them but you can, the binaries are in a path
# www-data doesn't search. Either:
#   (a) Use Tools settings to set absolute path
#   (b) Add the path to /etc/environment so it's system-wide
```
:::

### Workers HTTP 401 / 403

API key issue. Re-generate the key on the provider's site, paste it into Workers settings, save.

### Workers HTTP 429

Rate limited. Wait a few minutes or switch providers. The cockpit's usage tracker shows your call counts per provider in the settings modal.

### Plans tab is empty after Plan-mode submit

Check the chat for system messages like "Plan creation failed". Most common cause is one of the voter agents being unauthenticated or unreachable. Run `claude --print "test"` and `gemini --prompt "test"` from a terminal to confirm both are working.

### IPv6 / wget bug on Linux Mint

A known bug --- `wget` defaults to IPv6 and times out on some Mint installs. Already absorbed into `cockpit_start.sh`, but if you see the symptom elsewhere:

::: {#cb39 .sourceCode}
``` {.sourceCode .bash}
# Force IPv4 globally for wget
echo 'inet4_only = on' >> ~/.wgetrc
```
:::

### Apache logs filling up

The cockpit polls the bridge every 200 ms during streams, which generates a lot of access-log entries. If you don't need them:

::: {#cb40 .sourceCode}
``` {.sourceCode .bash}
# Disable access logging for /cockpit/bridge.php specifically
sudo bash -c 'cat > /etc/apache2/conf-available/cockpit-quiet.conf' << 'EOF'
SetEnvIf Request_URI "/cockpit/bridge\.php" cockpit_quiet
CustomLog ${APACHE_LOG_DIR}/access.log combined env=!cockpit_quiet
EOF
sudo a2enconf cockpit-quiet
sudo systemctl reload apache2
```
:::

------------------------------------------------------------------------

## Uninstall

If you ever need to wipe the cockpit:

::: {#cb41 .sourceCode}
``` {.sourceCode .bash}
# Stop everything
~/scripts/cockpit_stop.sh 2>/dev/null

# Web root
sudo rm -rf /var/www/html/cockpit/

# Scripts
rm -rf ~/scripts/cockpit_*.sh ~/scripts/agent_loop.sh ~/scripts/crud_executor.sh ~/scripts/install_capabilities.sh

# Data (this is destructive — projects under here are gone forever)
# Keep this if you want to preserve your chats/library/snippets
rm -rf ~/scripts/cockpit_data/

# Sudoers fragment
sudo rm /etc/sudoers.d/cockpit

# Apache PHP override (optional — only do this if no other PHP apps need it)
sudo rm /etc/php/8.3/apache2/conf.d/99-cockpit.ini
sudo systemctl restart apache2
```
:::

The Claude / Gemini / Ollama / LocalAI installations stay --- they're independent of the cockpit and you may want them for direct use. LocalAI\'s systemd service (`localai.service`) also stays enabled; disable it yourself with `sudo systemctl disable --now localai` if you no longer want it running.

------------------------------------------------------------------------

That's it. If you've followed all 12 steps, you have a fully working AI Cockpit. The User Guide covers what to do once it's running.

------------------------------------------------------------------------

# Update --- June 2026: Additional setup for new features

The base install above is unchanged. These extra steps enable features added later. All are optional --- the cockpit runs without them, and each feature degrades gracefully (with a hint) when its tool is missing.

## A. uv / uvx --- for MCP capabilities (Claude & Gemini)

Capabilities that run an MCP server (e.g. the bundled `time` capability) launch it via `uvx`, which ships with **uv** (Astral's Python tool).

::: {#cb42 .sourceCode}
``` {.sourceCode .bash}
# Official installer (adds ~/.local/bin to PATH)
curl -LsSf https://astral.sh/uv/install.sh | sh
# new shell, then verify:
uvx --version
```
:::

-   One-time network needed; after that `uvx <server>` is cached.
-   Must be on the PATH the agents see --- after installing, **restart the cockpit** (Stop → Start) so the agent sessions pick up the new PATH.
-   `npx` (from Node, Step 2) covers npm-based MCP servers and needs no extra setup.

## B. whisper.cpp + a model --- for offline voice input

The [mic]{.material-symbols-rounded .ico} Voice button transcodes mic audio with `ffmpeg` (already installed) and transcribes it locally with whisper.cpp.

::: {#cb43 .sourceCode}
``` {.sourceCode .bash}
# The installer's optional whisper.cpp step does all of this for you, into
# ~/ai-tools/whisper.cpp (the one place Cockpit looks first). By hand:
mkdir -p ~/ai-tools && git clone https://github.com/ggerganov/whisper.cpp ~/ai-tools/whisper.cpp
cd ~/ai-tools/whisper.cpp
cmake -B build && cmake --build build -j --config Release
# Grab a model — base is fast; large-v3-turbo is the best balance and fits a 4 GB GPU:
./models/download-ggml-model.sh large-v3-turbo
```
:::

-   The cockpit auto-detects the binary (`whisper-cli`). It uses the model **pinned in `cockpit_data/whisper_config.json`** --- the installer writes the one you chose --- and with none pinned it falls back to the **largest** installed `ggml-*.bin`. You can also pick a model per dictation in the voice options. To pin specific paths, set `bin`, `model`, `language` in that file.
-   Build with GPU support to use an AMD/NVIDIA card; CPU is fine for short clips.
-   The web tier (www-data) must be able to read the binary + model under your home dir. If transcription says "permission denied": `chmod -R a+rX ~/ai-tools/whisper.cpp`.

## C. Prism (syntax highlighting) --- already vendored

No install needed. `prism.js` ships in the web root (offline, MIT). It is loaded with `Prism.manual = true` so it only highlights the cockpit's code editor, not the chat console.

## D. New config files (created on first use)

Under `cockpit_data/`: `directives_global*.md`, `directives_config.json`, `claude_controls.json`, `gemini_controls.json`, `whisper_config.json`, `global_caps.json`, `help.json`. All are plain JSON/Markdown and editable in-app (the relevant panel's edit button opens them in the floating editor).


------------------------------------------------------------------------

# Update --- September 2026: Setup for the new features

The installer handles all of this on a supported Linux distribution --- this
section is for people installing by hand, or checking why one feature is
greyed out when the rest work.

## E. Bookshelf --- reading books {#setup-bookshelf}

    sudo apt install pandoc          # epub, docx, odt, fb2
    sudo apt install calibre         # optional: mobi/azw and friends

`pandoc` covers the common formats and is already installed for the guides.
`calibre` is only needed for Amazon-style formats; it is a large package, and
Bookshelf works without it for everything pandoc reads. Without either, the
Bookshelf panel will say so rather than silently accepting a file it cannot
split.

## F. PDF Vision --- rendering pages as images {#setup-pdf-vision}

    sudo apt install poppler-utils   # provides pdftoppm

Text extraction needs nothing extra; rendering the *pages* (for diagrams,
scans and drawn tables) uses `pdftoppm`. Pair it with an agent that can
actually accept an image --- see **Vision dispatch** in the User Guide.

## G. Audio analysis and sheet music {#setup-music}

    sudo apt install ffmpeg sox aubio-tools lilypond timidity

-   `ffmpeg`, `sox` --- decoding and level/loudness measurement.
-   `aubio-tools` --- `aubiotrack`, `aubionotes`, `aubioonset`: tempo, pitch
    and onset detection. These are measurements, not model guesses.
-   `lilypond` --- engraves detected notes into a sheet-music PDF.
-   `timidity` --- plays notation back with a piano-like voice.

Each tool preset checks for its own binary and reports the missing one by
name, so a partial install degrades to a clear message rather than an
obscure failure.

## H. Intercom --- the hands-free loop {#setup-intercom}

Intercom needs both halves of the voice path, and both are already covered
above: **whisper.cpp** (section B) to hear you, and **piper** to answer. The
installer offers piper as its own phase; by hand it lives in
`~/ai-tools/piper` (`Installs/install_piper.sh`).

For a language piper has no voice for, `espeak-ng` is used as the fallback and
is installed alongside it.

If dictation works but Intercom does not speak back, piper is the missing
piece --- not whisper.

## I. Isolated CLI configuration {#setup-isolated-cli}

Agents launched by Cockpit now get their own CLI config directory by default,
so your personal terminal settings do not change how Cockpit's agents answer.
Credentials are shared by reference, so you do **not** have to sign in twice.

To put a supplier back on your own configuration, enable **Use my global CLI
config** for that supplier in its slot settings.

## J. Everywhere relay --- naming a machine {#setup-relay-name}

Each rig now reports a name with its heartbeat, and the relay lists rigs by
that name instead of a 32-character machine id. Set it from the account panel;
it is sent on every heartbeat, so nothing has to be re-paired when it changes.

::: {#ug-search-box style="position:fixed;top:16px;right:16px;z-index:9999;
     background:#22262b;border:1px solid #3a3f46;border-radius:8px;
     padding:6px 8px;display:flex;align-items:center;gap:6px;
     box-shadow:0 4px 16px rgba(0,0,0,.4);font-family:system-ui,Segoe UI,sans-serif;
     font-size:13px;"}
[]{#ug-search-count style="color:#8a919c;min-width:44px;text-align:center;"}

↑

↓
:::
