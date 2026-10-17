---
title: AI Cockpit — User Guide
---

# AI Cockpit --- User Guide

            . | .
             \|/
         .--- O ---.
        /    /|\    \
       '    / | \    '
            . | .

      AI Cockpit · One IDE. Every AI.

> A multi-agent orchestration interface for Claude, Gemini, Ollama, LocalAI (or both at once via Dual mode), online LLM providers (Workers), and local CLI tools (Tools).
>
> Built by Dario Ruggi · cockpit.ruggi.site

------------------------------------------------------------------------

## Table of contents

1.  [The Cockpit window](#cockpit-window)
1.  [The 30-second tour](#the-30-second-tour)
2.  [The supplier strip --- your 5 agents](#the-supplier-strip)
3.  [Sending a prompt](#sending-a-prompt)
4.  [Multi-agent modes](#multi-agent-modes)
5.  [Styles](#styles)
6.  [Projects and chats](#projects-and-chats)
7.  [Left sidebar](#left-sidebar)
8.  [Right-sidebar tabs](#right-sidebar-tabs)
9.  [Capabilities --- MCP, Skills, tool shims](#capabilities)
10. [The Orchestrator + Planner](#the-orchestrator-planner)
11. [Autopilot Cruise --- state a goal, it flies the task](#autopilot-cruise)
12. [AutoCognition --- the agent bus](#autocognition)
13. [Workers --- online LLM providers](#workers)
14. [Tools --- local CLI binaries](#tools)
15. [Library, Snippets, Sources](#library-snippets-sources)
16. [Search the web](#search-the-web)
17. [Keyboard shortcuts](#keyboard-shortcuts)
18. [Troubleshooting](#troubleshooting)
19. [Configuration files](#configuration-files)
20. [Context menus](#context-menus)
21. [Themed confirm & prompt dialogs](#themed-confirm-and-prompt-dialogs)
22. [Plan Re-Run](#plan-re-run)
23. [Spend-cap warnings](#spend-cap-warnings)
24. [Ollama runtime knobs](#ollama-runtime-knobs)
25. [Model Manager enhancements](#model-manager-enhancements)
26. [Media generation](#media-generation)
27. [Translation](#translation)
28. [Time tracking](#time-tracking)
29. [Terminal, Files, Browser](#terminal-files-browser)
30. [Accumulator](#accumulator)
31. [Skills system](#skills-system)
32. [Summarize](#summarize)
33. [Caveman mode](#caveman-mode)
34. [Themes & theming](#themes-and-theming)
35. [Typography controls](#typography-controls)
36. [Comprehensive help system](#comprehensive-help-system)
37. [Power Combos (Tier 0)](#power-combos)
38. [Your own combos](#user-combos)
39. [Delegate --- task auto-routing](#delegate)
40. [Multiple local users](#multiple-local-users)
41. [Cockpit Account & Marketplace](#cockpit-account-marketplace)
42. [Supplier Slots --- CLI aliasing](#supplier-slots)
43. [Background Tasks & Scheduler](#background-tasks-scheduler)
44. [Transcriber](#transcriber)
45. [Margin --- write in the margin of a file](#margin)
46. [Dossier --- a researched answer with sources](#dossier)
47. [Profile --- what agents should know about you](#profile)
48. [Intercom --- talk to the rig, hands free](#intercom)
49. [Bookshelf --- a book the agent can use](#bookshelf)
50. [PDF Vision --- the pages, not just the text](#pdf-vision)
51. [Vision dispatch --- images per agent](#vision-dispatch)
52. [Receipts --- which passage was used](#receipts)
53. [Dialects --- prompts shaped per supplier](#dialects)
54. [Audio analysis --- measured facts](#audio-analysis)
55. [Sheet music --- both directions](#sheet-music)
56. [Add your own agent](#agent-editor)
57. [Voice input --- choose the microphone](#voice-input-mic)
58. [Everywhere relay --- machines have names](#relay-machine-names)
59. [CLI agents get an isolated configuration](#isolated-cli-config)
60. [The icon font is local](#vendored-icons)

------------------------------------------------------------------------

## Launching Cockpit

The installer adds Cockpit to your applications menu under an **"AI"** category, and as terminal commands:

-   **AI Cockpit** --- command `cockpit-start` (the full V2 edition).
-   **AI Cockpit V1** --- command `cockpit-v1-start` (the Stand-alone edition, if you installed both).

Launching shows a splash while the agent sessions start, then opens Cockpit in a clean app window. Stop with `cockpit-stop` / `cockpit-v1-stop`; add `--force` to restart the sessions.

**Only one edition runs at a time.** If you start one while the other is running, a dialog says so and offers **Switch** (stop the other and start this one), **Cancel**, or **Close all running sessions** (shut everything down and start nothing --- the way out when the running edition cannot close its own sessions). Each edition names its window (*AI Cockpit* / *AI Cockpit V1*), so launching one again raises the window that is already open instead of starting a second.

**One edition at a time:** V1 and V2 use the same machine's agents, so only one runs at once. Launching the other while one is open asks whether to switch (stopping the first) or cancel.

### The Cockpit window and leaving {#cockpit-window}

Cockpit opens in its own native window (`cockpit_shell`, a small open-source program shipped with the app --- sources in `~/scripts/cockpit_shell_src/`, Apache-2.0). It is a window and nothing else: no address bar, no tabs, no extensions. Links that lead outside the app (ruggi.site, the guides) open in your normal browser.

**Every way of closing it runs the exit procedure.** The window's close button, Alt+F4 and the dock's *Quit* all open the same *Leaving Cockpit* dialog as the **Exit** button in the topbar: it shows what is still running (tool runs, replies in flight, agent sessions) and offers *Kill processes*, *Terminate sessions*, *Terminate and leave*, *Wait for completion* / *Stay*, or *Leave anyway*. The window closes only when you choose to leave. If the app itself is not loaded (server down), a close request simply closes.

**Keys.** **F11** fullscreen · **F5** or **Ctrl+R** reload · **Ctrl+Shift+R** (or Ctrl+F5) reload bypassing the cache. The window remembers its size between launches, and `COCKPIT_KIOSK=1 cockpit-start` runs it fullscreen without decorations for a dedicated screen.

**Window controls live in the sessions card** (top right, native window only): **Reopen** closes and reopens the window (applies a frame change under Wayland, picks up a new `cockpit_shell` after an upgrade), **Reload** hard-reloads bypassing the cache (a deploy triggers it by itself), **Refresh** re-reads status, account and machine state now, and **⛶** turns the frame off and on --- live on X11, on Reopen under Wayland and WSLg. Frameless, the ▁ ▢ glyphs beside **Exit** minimise and maximise; double-click the header to maximise. The window also has three buttons of its own, **–** minimise, **□** maximise / restore and **×** close (the same exit procedure as the window's close button): move the pointer to the empty strip along the right edge, near the top, and they appear over the top-right corner; move away and they go. They never appear while the window has a normal title bar. With no title bar, the **border is the handle**: thin invisible strips run along every edge and corner, and the pointer changes when you are on one. Drag an edge or a corner to resize; the **middle 15% of each side** has a different pointer (the move cross) and **moves the whole window** without resizing it. A maximised window ignores both. **The other windows the shell opens** (the Cockpit Browser, and the window of a web page worker when it comes on screen for a login) show other people's pages, which cannot draw handles, so when you run frameless the shell lays the same strips over their border itself: drag an edge or corner to resize, the middle of a side to move, and **Ctrl+W** to close a Browser window (a worker's window is only put away). Move the pointer into the **top-right corner** of such a window and three buttons appear: **–** minimises (bring it back from the taskbar or with Alt+Tab), **□** maximises and restores, **×** closes a Browser window (a worker's window is only put away). **Minimised Browser windows** are listed at the right end of the status bar, one small chip each (the page's title, with its address and a hint when you hover): click a chip to bring the window back, or right-click it for **Restore** and **Close window**. The list is kept by the shell on your machine, one small file per window, and a window that is gone drops off it by itself. The window also remembers its position and monitor. In a plain browser these controls are hidden.

**The rig line** under the strip names the OS, desktop, terminal and file manager Cockpit found (e.g. *Linux Mint 22.3 · Cinnamon · gnome-terminal · nemo*), then the CPU, RAM and GPU --- what the Terminal, Files and Browser buttons will open. With no browser installed the **Cockpit Browser** (this window in plain-browser mode) is registered as the system browser at install time.

**One key from anywhere.** **Ctrl+Alt+C** brings Cockpit to the front from any application; press it again while Cockpit is in front and it goes back down. When the installer registered the desktop shortcut (Cinnamon, GNOME, XFCE, KDE or MATE --- `~/scripts/install_hotkey.sh`, `--remove` to undo; not on WSL, where Windows owns the keyboard --- use the Start-menu shortcut), the same key also **starts** Cockpit when it is not running. Without that shortcut the app grabs the key itself while it runs; change it with `COCKPIT_HOTKEY="super+c" cockpit-start` or switch it off with `COCKPIT_HOTKEY=none`.

**It can bring Cockpit up by itself.** Opened when nothing is running (at login, from the dock, with the shortcut), the window shows a boot screen, starts the web server and the agent sessions, and loads the app as soon as it answers --- if that takes too long it says so and offers *Try again* instead of sitting there. The installer can add an "open at login" entry (`~/.config/autostart/ai-cockpit.desktop`; delete the file to stop it).

**It checks the build before it runs it.** Each launch the window hashes the shipped files that decide what runs (`index.html`, every `css/` and `js/` file, `auth.php`, `paths.php`, `integrity_lib.php`) against the build manifest; if one differs it says so and does not load the app --- a tampered page cannot vouch for itself. `COCKPIT_NO_VERIFY=1 cockpit-start` skips the check.

**Notifications and a tray icon.** Finished work raises real desktop notifications with an *Open Cockpit* button: an agent reply or a Tools run that finished **while the window was not in front**, a plan ready, the Accumulator or Transcriber done. Nothing pops up while you are looking at Cockpit. The tray icon offers *Show* / *Minimise* / *Exit Cockpit…* (Exit runs the exit procedure). On GNOME the tray needs the *AppIndicator* extension --- the installer enables it when present; KDE, XFCE, Cinnamon and MATE show it as is.

**Files keep their real path.** Drop a file on the prompt, pick one with the paper-clip *Attach* button, or paste one you copied in the file manager: it is attached **by its path** --- the native file dialog opens, nothing is uploaded or copied through a browser. The Tools card's file chooser fills the path field directly. A file dropped **elsewhere** on the window (not on the prompt) opens in Cockpit's floating editor, where you can edit and save it in place. In a browser window the file is uploaded instead, as before.

**The window talks to the desktop.** Next to a path in the chat you get *open folder* (the file manager with the file selected), *open a terminal here*, and *open the file* --- the desktop's own calls, made as you, not handed off to the web server. The agent cards' session buttons open a terminal attached to that tmux session. The GPU meter in the status row reads the driver itself: hover it for GPU busy, VRAM, CPU and RAM.

**Panels in their own window.** Every sidebar panel's title bar carries a small [open_in_new]{.material-symbols-rounded .ico}: click it and that panel --- Preview, Code, Attachments, Files, Usage, Plans --- opens as a separate window you can put on another monitor. It is the same panel, kept current on its own; **Escape** or **Ctrl+W** closes it, and closing it changes nothing in the main window. Up to six at a time, and only Cockpit's own pages can be opened this way.

**Signing in without typing.** The local login form has *Keep me signed in on this computer* (on by default). Cockpit then issues a sign-in token for this device and the window stores it in your **OS keyring** (GNOME Keyring or KWallet, through libsecret) --- not in Cockpit's files, not in a cookie. At the next launch the window presents the token and you are in without typing; **Sign out** revokes it on the server and removes it from the keyring. Tokens expire after 90 days.

**Fill from Bitwarden.** Cockpit's own login forms (the local app login, the Cockpit account login, the admin-token box) carry a *Fill from Bitwarden* button. It uses the official Bitwarden CLI (`bw`, offered by the installer; `~/scripts/install_bw.sh` later) --- run `bw login` once in a terminal. The first fill of a session opens a small terminal where you type your master password **into bw itself**; Cockpit never sees it, and the vault session lives only in the window's process. Items are found by name: `AI Cockpit Local`, `AI Cockpit SAAS`, `AI Cockpit Admin Token` (anything containing "AI Cockpit" is offered in a chooser when there is no exact match).

If the native window cannot run on a machine (no WebKitGTK 4.1 runtime, or a CPU the prebuilt binary does not cover and no `fpc` to rebuild it), `cockpit-start` falls back to a browser app window; there, the close button bypasses the exit procedure --- use **Exit** --- and everything above that needs the window is simply absent.

## The 30-second tour

**Terms and integrity.** On an account's first use Cockpit shows its Terms of Use and licence — Apache-2.0 with attribution and trademark conditions (also at logo → Terms and at cockpit.ruggi.site/license.php) and checks the install against the manifest shipped with its build. Logo → Integrity repeats the check at any time: a changed or missing file is listed, and the bundle the installer kept can put the shipped files back (Restore) without touching your configuration or data. A modified copy keeps working locally; the Cockpit account services are provided to official builds only. The installer also makes the shipped files root-owned and read-only (editing them takes sudo — a deliberate act) and starts **cockpit-guard**, a small service that logs any change to a shipped file, flags it in the app at once and puts the file back from the kept bundle (`cockpit_data/guard.log`; `sudo systemctl status cockpit-guard`).

**The top bar on a smaller screen.** From 1100 pixels wide the controls on the right (Help, Theme, About, Tour, Profile, Slots, Apps, Exit, Restart) always stay on screen; it is the row of supplier cards that gives way and scrolls on its own. **Latency** (the small "⇄ N ms" figure) measures the round trip to your own router by default, so it never contacts anything outside your network; click it to choose another host (a public address is then a call out of your machine, and you chose it). The **server clock** row is shown only in the Full edition while you are signed in, and is asked of your account server through Cockpit; the Stand-alone edition contacts no server at all.

**Hints, First Use and the Tour.** Hover over anything — a card, a button, a panel title — for a hint; leave the mouse there a moment longer and the hint expands with a summary from this guide (F1 opens the full topic). Hints are drawn by Cockpit itself, so they are never cut off at a screen edge. The **First use** toggle (top right, beside Help) shows the expanded form at once for everything. **Tour** (next to it) walks the whole screen step by step — every card, strip and sidebar, **every tab on both sides and every Toolbar button** (sixty-odd steps) — with Next / Back, Esc to leave, F1 for the matching help topic on any step. The tabs and Toolbar buttons come in three short sections, and **Skip section** on any of their steps jumps past the rest of that section. The tour opens each tab itself as it goes and puts your own tabs back when it ends.


The cockpit window has four regions:

    ┌──────────────────────────────────────────────────────────────────┐
    │ TOPBAR — 5 supplier cards · Exit/Stop/Restart · Clock · Settings │
    │          Project / Chat / Path · Account · Help · Tour           │
    ├──────────┬──────────────────────────────────────┬────────────────┤
    │ LEFT     │  CONSOLE (chat scroll)               │  RIGHT         │
    │ SIDEBAR  │                                      │  SIDEBAR       │
    │          │  user: ...                           │                │
    │ Chats    │  CLAUDE: ...                         │  Preview       │
    │ Projects │  GEMINI: ...                         │  Code          │
    │ Files    │  OLLAMA: ...                         │  Library       │
    │          │                                      │  Snippets      │
    │          │  ┌──────────────────────────────┐    │  Sources       │
    │          │  │  PROMPT  ·  Execute/Clear    │    │  Config        │
    │          │  │  Attach  ·  Save  ·  Voice   │    │  Search        │
    │          │  └──────────────────────────────┘    │  Capabilities  │
    │          │  Mode: Single·Pipeline·Broadcast·Plan│  Plans         │
    │          │  Style: Chat·Build·Debug·Research·…  │  Attachments   │
    │          │  Toolbar: Translate·Summarize·Skills…│  Usage         │
    ├──────────┴──────────────────────────────────────┴────────────────┤
    │ FOOTER — Caveman · Model selector                                │
    └──────────────────────────────────────────────────────────────────┘

To do anything:

1.  **Pick an agent** by clicking its card in the topbar
2.  **Type a prompt** in the textarea
3.  **Press Execute** (or Enter; Ctrl-Enter and Shift-Enter add a line)

For multi-agent flows, switch the mode strip below the prompt to Pipeline, Broadcast, or Plan before pressing Execute.

------------------------------------------------------------------------

## The supplier strip

Five cards run across the top of the cockpit. Each represents one provider class. Only the active card is expanded; the others show just an icon, the selected model name, and a thin progress bar.

  ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
  Card                      Color    What it is
  ------------------------- -------- -------------------------------------------------------------------------------------------------------------------------------------------------------
  CLAUDE                    amber    Anthropic Claude --- best at reasoning, refactoring, architecture

  GEMINI                    blue     Google Gemini --- fast iteration, broad knowledge, summaries

  OLLAMA / LOCALAI / DUAL   orange   Local models running on your GPU --- fully offline. Card 3\'s label follows whichever backend is assigned (Ollama, LocalAI, or Dual for both at once)

  WORKERS                   purple   Online LLM APIs --- Groq, HuggingFace, OpenRouter, etc.

  TOOLS                     teal     Local CLI binaries --- ffmpeg, whisper, pandoc, etc.
  ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

### Switching agents

Click any inactive card to make it active. The previous active card collapses to its icon-only state. The console border-color and Execute-button color follow the active agent so you always know what's loaded.

### Reading a card at a glance

**Inactive** --- icon + selected model name + 3px progress bar.

**Active** --- icon + agent name + AGENT button label, model dropdown, settings or open-tmux button, and a full usage line below.

The progress bar reflects different things per agent:

-   **Claude**: tokens used vs the \~44K context budget
-   **Gemini**: total prompt+response tokens estimated
-   **Ollama**: 0% (no quota --- local model)
-   **Workers**: aggregate tokens across all providers (informational)
-   **Tools**: enabled tool count vs total registered

------------------------------------------------------------------------

## Sending a prompt

1.  Click the prompt textarea at the bottom
2.  Type your message
3.  Click **Execute** or press **Enter** (Ctrl-Enter / Shift-Enter add a line)

While the agent is responding, you'll see a small ⏳ placeholder for that message which gets replaced as tokens stream in.

### Cancelling a stream

Click the **Stop** button next to Execute. The stream is aborted on both the frontend and the backend (the agent's tmux process is signaled). The partial response stays in the chat for context. The agent's session itself keeps running: before this was fixed (October 2026), pressing Stop also ended the agent's loop, the card still said "session running", and every later prompt sat unanswered until the session was restarted.

### Re-running a prompt

The Up arrow key in the empty textarea brings up your previous prompt for quick edit-and-resend.

**Finding an earlier prompt.** The **History** button in the prompt box (the clock icon, beside the microphone), or **Ctrl+R** while the prompt box has the focus, opens a list of everything you sent before. Type to filter it (every word you type must be in the prompt, in any order); **↑ ↓** choose, **Enter** puts the prompt in the box (it does not send it), **Esc** closes. The three tabs set the **scope** of the history, and the ↑ ↓ keys in the prompt box use the same scope: **This chat** (the default), **This project** (every chat of the project) or **Everywhere** (every prompt you have typed in Cockpit, so one you entered in another project can be reused here). Each chat keeps its last 200 prompts on this browser; the wider scopes show each distinct prompt once. Tab switches the scope while the list is open.

**Small screens.** Cockpit is a desktop program and does not squeeze itself into a phone layout. In a window narrower than 1100 pixels (or shorter than 580) the whole app stays at full size and the window scrolls sideways or down, whichever way the app is bigger. On a phone or small tablet the first screen says what Cockpit is (in the web demo, with a short tour in pictures) and offers **Open it anyway**: it then opens the whole app, scaled to fit, and you **pinch to zoom** and **drag with two fingers** to move around; turning the phone sideways gives more room. The old narrow layout (hamburger menu, sidebars as overlays) is still there for anyone who prefers it: add `?compact=1` to the address.

**Filters and Find.** Every list in the two sidebars has a filter box on top: Files, Code, Config, Capabilities, Plans, Artifacts, Attachments, Usage, Proposals, Toolbar, and the results of a web Search (the lists that already had a search keep it). Type words to hide what does not match; clear the box (or press Esc) to bring everything back. In the Files list a folder opens by itself while a file inside it matches. The **Preview** has its own **Find in the preview** bar at the top: type to highlight every match in the previewed text, Enter or the arrows step through them, and Ctrl+F while the Preview has the focus opens it.

### Attaching context

Click the **Attach** button (next to the prompt) or drag files onto the chat to attach. Text/code files are inlined as agent context; images go to vision-capable models. Manage attached files in the **Attachments** tab (right sidebar).

You can also attach reference material from the **Library**, **Snippets**, and **Sources** tabs --- click any item's attach icon to insert it into your next prompt as quoted context.

### Prompt-area buttons {#prompt-buttons}

  Button         Action
  -------------- ---------------------------------------------
  **EXECUTE**    Send prompt (same as Ctrl+Enter)
  **CLEAR**      Empty the prompt text area
  **SAVE**       Save prompt text to Snippets or Library
  **Attach**     Open file picker to attach files
  **Voice**   Record and transcribe locally (whisper.cpp)

------------------------------------------------------------------------

## Multi-agent modes

Below the prompt textarea is the mode strip:

    ┌─────────────────────────────────────────────────────────┐
    │  ◉ Single   ○ Pipeline   ○ Broadcast   ○ Plan           │
    └─────────────────────────────────────────────────────────┘

### Single mode (default)

Prompt goes to the active agent only. Standard chat behavior.

### Pipeline mode

Prompt goes to agent A; A's response becomes the prompt for agent B; B's response becomes the prompt for agent C; etc. Useful for refinement chains:

> Claude analyzes the spec → Gemini drafts code → Ollama runs the test suite

To configure pipeline order, the **Multi-agent panel** above the mode strip lets you select which agents to include and in what order.

### Broadcast mode

Same prompt sent to every selected agent in parallel. Responses appear side-by-side. Useful for getting different perspectives on a question or comparing model output quality.

### Plan mode

Treats the prompt as a goal and triggers the Orchestrator. All 3 main agents draft a plan in parallel; a synthesizer merges the votes; the result is saved to the **Plans** right-sidebar tab where you can review, edit, and execute it step-by-step. See [The Orchestrator + Planner](#the-orchestrator-planner).

------------------------------------------------------------------------

### Making a mode run durably {#durable-modes}

Pipeline and Broadcast normally run **in the page**: the browser drives each step, and closing the tab or losing power throws the run away. For a long chain of agents that is the wrong place to keep the work.

With Pipeline or Broadcast selected, the mode strip shows a **[link]{.material-symbols-rounded .ico} Durable** button. Press it instead of Enter and the same selection --- your prompt, the agents you ticked, each one's current model --- is turned into a checkpointed chain on the server and run through AutoCognition. Every step is a file with a status, so an interrupted run resumes at the step that died instead of starting over. It appears in **Hive → Chains** like any other chain.

**Enter is unchanged.** It always runs the mode in the page, exactly as before. Durable is something you press, never a setting that quietly changes what your keyboard does --- the older Cruise checkbox worked that way and was removed for exactly that reason.

When to use which:

-   **Enter** --- short runs, quick comparisons, anything you will watch finish.
-   **[link]{.material-symbols-rounded .ico} Durable** --- long pipelines, slow local models, anything where losing the first two steps would hurt.

Two other routes reach the same engine, and it is worth knowing why they are not the same thing: **[flight]{.material-symbols-rounded .ico} PLAN** lets the *planner model* decide the steps from your goal, and a Power Combo's **[link]{.material-symbols-rounded .ico}** runs a *recipe someone else wrote*. Only this button makes the selection **you** just built resumable.

(Durable chains need the Plus plan; parallel ones need Pro.)

------------------------------------------------------------------------

## Styles

The style strip (below modes) prepends an instruction to every prompt, steering **how** the agent responds:

  Style          Behavior
  -------------- -------------------------------------------------------------------
  **Chat**       Conversational --- answers in prose, no code unless asked
  **Outline**    Plan first, then implement
  **Research**   Explore and explain with sources and reasoning
  **Build**      Default builder mode --- writes working code directly
  **Debug**      Focus on finding and fixing bugs
  **Analyze**    Deep analysis of code, data, or architecture
  **Report**     Structured output --- formal report with sections and conclusions

In **Plan** mode, the style prefix is NOT prepended to the orchestrator goal --- it only applies to direct agent prompts.

------------------------------------------------------------------------

## Projects and chats

The cockpit organizes work into **projects** (folders on disk) containing **chats** (separate conversation threads).

### Default location

Projects live under:

    ~/Software/Programing/LocalAIProjs/

Each project is a directory; each chat is a `chat_<name>.json` file inside that directory.

### Creating a project

1.  Open the **Files** tab in the left sidebar
2.  Click the **+ New Project** button
3.  Type a name (alphanumeric, dashes, underscores)

The new project becomes the active one. The path appears in the topbar's info bar.

### Creating a chat

1.  Open the **Chats** tab in the left sidebar
2.  Click **+ New Chat**
3.  Type a name

The chat is created inside the active project. The textbox in the topbar shows the active chat name.

### Chat operations

-   **Double-click** a chat name to rename it.
-   **Export** --- save chat as JSON for backup or sharing.
-   **Import** --- load a previously exported chat JSON.
-   **Detach** --- move a chat to the Free (standalone) pool.
-   **Delete** --- permanently remove (with confirmation).

Each chat has independent history, attachments, and proposals.

### Switching context

Click any project name → that project becomes active. Click any chat name → that chat becomes active.

The info bar (`Project: foo · Chat: bar · /path/...`) always reflects the current context.

### Standalone mode

If no project is selected, the cockpit operates in `_standalone` mode --- chats live in `~/scripts/cockpit_data/_standalone/`. Useful for quick one-off questions.

------------------------------------------------------------------------

## Left sidebar

The left sidebar has three tabs:

  Tab            Purpose
  -------------- -------------------------------------------------------------------------------------------------
  **Chats**      List of chats in the current project. Create, rename, import/export, detach, delete.
  **Projects**   All projects. Create, switch, edit COCKPIT.md rules, delete.
  **Files**      Project directory file tree. Click to preview/edit. Map button generates a Pascal/PHP unit map.

------------------------------------------------------------------------

## Right-sidebar tabs

The right sidebar has 14 vertical icon tabs:

  Tab                Purpose
  ------------------ -----------------------------------------------------------------------------------------
  **Toolbar**        Every quick-launch tool in one place, in alphabetical order --- see [The Toolbar](#the-toolbar).
  **Proposals**      Agent suggestions (file edits, commands) awaiting your approval. A count shows on the tab icon from any tab.
  **Preview**        Live preview of HTML/Markdown files. Updates when you select a file from the file tree.
  **Code**           Inline code editor with syntax highlighting, find/replace, line numbers, word wrap.
  **Library**        Saved references --- URLs, file paths, notes. Scopeable to project or global.
  **Snippets**       Reusable code fragments with language tags. Save from chat (F2) or add manually.
  **Sources**        Source code files used as context or reference material for agents.
  **Config**         Configuration --- storage paths, attachment routes, import/export settings.
  **Search**         Web search (Brave/DDG). Results can be fetched and injected into prompt context.
  **Capabilities**   MCP servers and tool-shims. Toggle ON/OFF per capability.
  **Plans**          Orchestrator plans --- view steps, run/sequence/schedule, inspect votes.
  **Artifacts**      Everything this project produced --- files agents wrote, generated images/audio/video, tool outputs, transcripts, approved snippets --- with size, time, source and, where a chat named the file, which chat/agent/model. The line says **made by** only when a tool reported writing the file with its full path, and **mentioned by** when a chat merely talked about it --- provenance is read from what was said, so it is a label, not a record. Open, reveal or delete.
  **Attachments**    Files attached to the current chat. Upload, manage, and reference in prompts.
  **Usage**          Token usage, quota tracking, and paid API spend for all suppliers and workers.

Click any tab to open its panel. Only one panel is visible at a time. Tab state persists across page loads.

Approve or reject proposals individually or in batch from the **Proposals** tab.

### The Toolbar {#the-toolbar}

The **Toolbar** tab (the wrench, first in the right sidebar) holds every quick-launch tool, **in alphabetical order** so the one you want is easy to find: Accumulator, Bookshelf, Browser, Delegate, Dossier, Files, Image, Jobs, Keys, Notepad, Rules, Skills, Sound, Summarize, Tasks, Terminal, Track, Transcriber, Translate chat, Translate text and Video.

Counts sit on the buttons they belong to, as small chips:

-   **Jobs** --- how many scheduled jobs exist. The chip takes the accent colour while any are pending or running, and its tooltip says how many.
-   **Accumulator** --- how many results it has gathered.
-   **Stop** (**Start** when nothing is running) in the sessions block --- how many of the three agent sessions are up, for example `3/3`.


------------------------------------------------------------------------

## Capabilities

The **Capabilities** tab unifies three layers underneath:

-   **MCP servers** for Claude and Gemini (Anthropic's standard)
-   **Skills** for Claude (Anthropic-specific `SKILL.md` folders)
-   **Tool shims** for Ollama (which doesn't speak MCP natively)

You declare a capability **once** with up to three implementations; the cockpit routes correctly per agent.

### Use my global CLI config (off by default)

One built-in works the other way round: **Use my global CLI config** is **off** unless you turn it on. With it
off, a CLI agent the cockpit starts (Claude Code) runs against an isolated, cockpit-owned config directory that
holds only your login — your personal hooks, plugins, skills and global memory are not loaded, so what comes back
is shaped by the cockpit's Mode and Style alone. Your login is symlinked in, so you never sign in twice.

Turn it on when you *want* the agents to inherit your own setup.

It exists because the alternative is genuinely surprising: a caveman-mode `SessionStart` hook installed for the
terminal was rewriting every cockpit answer on the developer's own machine while the Style selector said
"Build (default)" — the hook, not the cockpit, was in charge.

### Adding an agent yourself

The agent list is data, not code. **Slots → Agents on this machine → Add new** writes an entry to
`cockpit_data/cli_suppliers.json`, which is merged over the shipped defaults and picked up on the next
prompt — no rebuild, no reinstall. You give it an id, the binary name (a name on `PATH`, not a path), the
prompt flag, and optionally a subcommand and extra flags.

The last field is the interesting one: **how the agent is given a picture**. Reading the CLI's documentation
is not enough, because an agent that *cannot* see an image does not say so — it invents a description. So the
editor has a **"Can it see?"** button: it runs that agent against a small shipped image of a red triangle and
a blue circle, scores the answer, and shows it to you. Keep the mode only if the answer is actually right.

Until an agent has been tested this way it stays on **Describe locally**, where a local vision model writes
what it sees and the agent reads that text — lossy, but never invented.

### Built-in capabilities

  ---------------------------------------------------------------------------
  ID             What                              Claude   Gemini   Ollama
  -------------- --------------------------------- -------- -------- --------
  `filesystem`   Read/write project files          MCP      MCP      shim

  `git`          Inspect/modify git repo           MCP      MCP      shim

  `web-search`   Brave/DDG search                  MCP      ---      shim

  `web-fetch`    Fetch URL → text                  MCP      MCP      shim

  `ssh`          Run commands on remote hosts      ---      ---      shim
  ---------------------------------------------------------------------------

### Enabling a capability

1.  Open the **Capabilities** tab
2.  Find the capability in the list
3.  Click the **ON/OFF switch** at the left of the row (a bordered box that reads OFF or ON)
4.  Cockpit refreshes the staged configuration with every prompt, so the change reaches the agent from your next prompt. If an agent still behaves as before, use **Restart** (the sessions block in the topbar)

### Creating your own capability

Click **+ New** in the Capabilities toolbar. Provide:

-   **ID** --- lowercase, alphanumeric + dash/underscore
-   **Name** --- display name
-   **Description** --- one sentence

This scaffolds an empty `CAP.json` at:

    ~/scripts/cockpit_data/capabilities/<id>/CAP.json

Edit the file to wire up implementations. See `CAPABILITIES_README.md` for the full schema.

### Adding a community MCP server

Browse the registry suggestions via the **cloud_download** button in the Capabilities toolbar. Suggested options include GitHub, Slack, GDrive, SQLite, and Memory. Currently you copy the package name into a custom capability manifest (auto-install is a future feature).

------------------------------------------------------------------------

## The Orchestrator + Planner

The Plan mode treats your prompt as a **goal** and breaks it into executable steps using all three agents collaboratively.

### How it works

    USER GOAL
        │
        ├──→ Claude  ─┐
        ├──→ Gemini  ─┼──→ 3 draft plans
        └──→ Ollama  ─┘
                           │
                           ▼
                      SYNTHESIZER (default: Claude)
                           │
                           ▼
                      MERGED PLAN — saved to Plans tab

If only one voter produces valid JSON, the synthesizer is skipped --- that voter's plan IS the plan. If the synthesizer fails, the longest valid voter plan is used as fallback.

### Running a plan

1.  Switch the prompt mode strip to **Plan**
2.  Type your goal
3.  Press **Execute**
4.  Watch system messages: voting → synthesis → "Plan ready"
5.  Open the **Plans** tab (right sidebar)
6.  Click your new plan → expanded step view with Run/Skip/Edit per step
7.  Click **[play_arrow]{.material-symbols-rounded .ico} Run** in the plan toolbar to execute end-to-end

### Plan controls

  ----------------------------------------------------------------------
  Button         What it does
  -------------- -------------------------------------------------------
  Run          Execute all remaining steps honoring auto-run mode

  Pause        Stop auto-progression after current step

  Votes        Show all 3 original voter plans side-by-side

  Delete       Remove the plan from disk

  (per step)   Run just that step now

  ⏭ (per step)   Mark step skipped

  (per step)   Edit the step's description
  ----------------------------------------------------------------------

### Auto-run modes

Click the **tune** icon in the Plans toolbar to cycle through:

  ------------------------------------------------------------------------------
  Mode                    Behavior
  ----------------------- ------------------------------------------------------
  `auto`                  Run all steps to completion, no prompts

  `approve_destructive`   Pause before any step marked destructive (default)

  `approve_each`          Pause before every step (browser confirm dialog)

  `manual_only`           Don't auto-progress; click Run on each step manually
  ------------------------------------------------------------------------------

A step is marked destructive when it writes files, modifies git, runs network commands beyond GET, or uses ssh.

### Editing plans mid-flight

Click the [edit]{.material-symbols-rounded .ico} pencil next to any **pending** step to rewrite its description. Already-running and done steps can't be edited (re-run them with the per-step [play_arrow]{.material-symbols-rounded .ico} button if needed). Edits persist on disk.

------------------------------------------------------------------------

## Autopilot Cruise

Everything above is the *manual* toolkit --- you pick a mode and drive. **Autopilot Cruise** lets Cockpit fly the whole task instead: type a goal in the main prompt box, press **[flight]{.material-symbols-rounded .ico} PLAN** in the Hive section of the left sidebar, and the answer lands back in your chat. You clear the one critical moment; the busywork runs itself.

Pressing **Enter** always does the same thing it has always done --- classic dispatch to the agent you picked. Planning happens only when you ask for it by pressing PLAN. There is no mode to remember and nothing hidden that changes what your keyboard does.

In one line: **one goal, broken into steps, run in order --- and it survives being killed.**

### What actually happens {#cruise-how}

1.  **A small local model writes a plan.** By default `qwen2.5:7b`, running on your own machine --- free, nothing leaves the box. If that plan comes back malformed (nothing parsed, a single step, an unrecognised tag) Cockpit automatically re-plans with a larger model, `qwen2.5:14b`, so you pay the slower model's time only when the fast one actually failed. It is told to break your goal into 2--5 ordered steps, each with one concrete instruction and a tag for the kind of thinking it needs (`text`, `code`, `reasoning`, `web`, `vision`).
2.  **The plan is shown before the work happens.** Which of two things follows depends on where you started it. Pressing **[flight]{.material-symbols-rounded .ico} PLAN** prints the plan and runs it straight through --- the fastest path. If you would rather read the steps before anything executes, open **Chains** in the Hive section and press **[link]{.material-symbols-rounded .ico} Draft a plan from the prompt box**: that creates the chain in a *building* state as a **Proposal** that sits in Task Chains until you press Run. Use it when the goal is expensive or destructive. Both read the same main prompt box --- there is only one place to type a goal.

    Either way you see the steps, because the planner is a small local model and small models get things wrong. In testing it once planned "edit the file" → "check the live site" with no deploy step in between --- structurally perfect, and it would have verified a page that never changed.
3.  **Steps run in order, each handed the previous one\'s output.** Step 2\'s prompt literally begins with a `%PREV%` marker that is replaced by whatever step 1 produced. That is the \"chain\".
4.  **Every step is a file on disk** with its own status --- `pending` → `running` → `done` --- and its output saved beside it.
5.  **The final answer returns to your chat.**

A **fast-path** skips planning for trivial one-line messages (they run as a single routed step). The classic modes stay as manual entry points that build the same underlying chains.

> **Changed in this release.** Cruise used to be a checkbox in the [hive]{.material-symbols-rounded .ico} panel that silently changed what the Enter key did, and it defaulted to on --- the same prompt could dispatch or plan depending on a setting you could not see from the chat. That toggle is gone, along with the *Manual Override* label. If you had set a preference, it is cleared automatically on first load. Enter dispatches; PLAN plans.

### Why it survives being killed {#cruise-resume}

Because each step is a file with a status, closing the laptop, crashing, or hitting Ctrl-C does not throw the run away. Finished steps stay `done` with their outputs intact; the interrupted step flips back to `pending`; **Resume re-runs only that one step**. You never redo completed work --- which is exactly what most one-shot agent tools lose.

It also degrades instead of dying: if the planner model is missing or returns nonsense, Cruise falls back to a single step containing your goal verbatim, behaving like an ordinary prompt.

### Practical examples {#cruise-examples}

-   **Write and file a changelog entry.** \"Draft a changelog entry for the site restructure and insert it into the updates page.\" → *reasoning*: collect what changed · *text*: draft the entry · *code*: insert it in the right place. Kill it during the draft and Resume re-drafts only --- the research survives.
-   **Subtitle a video.** \"Transcribe this interview and give me clean English subtitles.\" → transcribe · clean up and segment · translate. The 40-minute transcription is the expensive step; a crash during translation does not re-transcribe it.
-   **Digest your own notes.** \"Read my last three guides and produce a one-page overview.\" → extract key points · outline · write the page.

The pattern worth noticing: Cruise pays off most when **one step is slow or expensive** and the steps after it are fiddly.

(Autopilot Cruise needs the Plus plan.)

------------------------------------------------------------------------

## AutoCognition --- the agent bus {#autocognition}

**AutoCognition** is the brain underneath Cruise: a local multi-agent **bus** your agents share, opened from the **Hive** section of the left sidebar. (It used to be a floating [hive]{.material-symbols-rounded .ico} button in the corner; that button is gone --- it overlapped the sidebar that replaced it.) Where Cruise is the autopilot, AutoCognition is the crew and the intercom --- several separate AI tools that can see each other, pass notes, and vote, with you as the gatekeeper.

### The constraint it is built around {#autocognition-constraint}

AI agents are **not servers**. Claude Code, aider, goose, a Gemini CLI --- each exists only while its process is alive, and an idle agent is polling nothing. So AutoCognition is **a mailbox, not a phone call**: a message waits in a folder until its recipient next wakes up. Everything else follows from that one fact.

### The pieces {#autocognition-pieces}

-   **A shared folder as the town square.** Each message is its own small file, written to a temporary name and then renamed, so two agents never read a half-written file. No database, no daemon.
-   **Presence.** Every running agent drops a heartbeat file and refreshes it as it works, so the roster shows who is alive *right now* --- live, stale or down. Presence means recent activity, never a stuck \"online\" light.
-   **Four kinds of message:** `info` (FYI), `ask` (a question expecting an answer), `call` (please run this), `wake` (please start up).
-   **Capability routing.** A step marked `auto` asks \"who can do this right now?\" --- live agents are ranked, and **local is preferred over cloud**, so free beats paid by default.
-   **Quorum voting.** Send the same question to several models at once, then a judge model picks or synthesizes the best answer.
-   **Parallel steps.** Consecutive steps marked parallel run concurrently instead of one-by-one.
-   **A consent-gated broker** that can launch a CLI agent to deliver a queued message --- \"wake it if it isn\'t running\" --- plus an approvals queue, and one-click **turn any Power Combo into a durable chain**.

### The safety rule that makes it safe {#autocognition-safety}

A `call` **never runs by itself.** It is surfaced to you as a proposal, with a highlighted banner saying what it wants to do, and waits for your keypress. Anything arriving on the bus is treated as **data, never orders** --- the sender field is not trusted, because anything on the machine could write one. *Your consent is the actual protection.* Without that rule, a design like this would be a worm rather than an assistant.

### Practical examples {#autocognition-examples}

-   **Deploy notifications.** A deploy terminal is itself a participant: when it finishes it messages the agent that started it, which wakes on the message and reports the result --- instead of you having to relay \"it\'s done\" by hand.
-   **A second opinion.** \"Is this regular expression safe against catastrophic backtracking?\" goes to three cheap local models at once, and a judge compares them. Three small models disagreeing is a far better signal than one confident answer.
-   **Specialist hand-off.** One agent finds a bug but another is better at surgical single-file edits; it leaves an `ask`, which is answered when that agent next wakes. Neither has to be running at the same time.
-   **Cost control.** A step tagged as needing `code` routes to a live *local* agent instead of spending paid cloud tokens --- automatically, because the router prefers local.

Everything runs locally, on your own machine and models. (AutoCognition is a Pro-tier feature; both it and Autopilot Cruise are open free during beta.)

### How the two fit together {#cruise-vs-autocognition}

Cruise builds the chain. AutoCognition decides **who** runs each step, can run some of them **in parallel**, and can put a step **to a vote**. That is also where the tier line falls: planning plus sequential execution is Cruise (Plus plan); routing, quorum, parallel groups and the message bus are AutoCognition (Pro).

One honest caveat: small local models sometimes ignore instructions even when the text is right in front of them. Since the Cruise planner defaults to a 7b model, that is precisely why the plan arrives as a Proposal you approve rather than something that simply runs. Point it at a larger planner model and the plans get noticeably better.

------------------------------------------------------------------------

### A2A --- letting another agent reach this Cockpit {#a2a}

Cockpit can also be *called*. **Hive → A2A** exposes the A2A protocol subset (agent card, `message/send`, task
state, cancel) so another agent --- or another Cockpit on your network --- can hand this one work.

It is **off** until you switch it on, because a peer's message is dispatched to your active agent and can write
into your projects, exactly like a prompt you typed. When you turn it on:

- a **token** is minted; the caller must send it as `X-Cockpit-A2A-Token` (or `Authorization: Bearer …`),
- only callers from the **addresses you list** are accepted (an IP, a CIDR range such as `192.168.1.0/24`, or `*`);
  the default is this machine only,
- traffic may be Dario-10S encrypted for relay use with `X-Cockpit-Encrypted: 1`.

Treat the token like a password; **New token** revokes the old one instantly.


## Workers

Workers are **online LLM providers** used for tasks the main agents can't do (image generation, audio, niche translations) or as fallback when the main providers are exhausted.

### Built-in providers

  ---------------------------------------------------------------------------
  Provider          Free?            Specialty
  ----------------- ---------------- ----------------------------------------
  **Groq**          Yes (generous)   Ultra-fast text inference

  **HuggingFace**   Yes (hourly)     Text + image-gen + audio + translate

  **OpenRouter**    Has free tier    Universal LLM gateway

  **Together AI**   \$1 free         Open-weight models, image gen

  **DeepInfra**     Pay-per-use      Cheap inference
  ---------------------------------------------------------------------------

### Setup

1.  Click the gear icon next to the WORKERS button → settings modal opens
2.  For each provider you want to use:
    -   Click the **Get key** link → sign up on the provider's site
    -   Paste the API key into the input field → click **Save**
    -   Click **Disabled** to toggle to **Enabled**
3.  Close the modal --- the model dropdown above WORKERS now lists all enabled `<provider>:<model>` pairs

### API key storage

Keys are encrypted with **AES-256-GCM** at rest. The encryption key is derived from your machine's `/etc/machine-id` plus a fixed cockpit salt, which means:

-   Casual disk-grep won't find them
-   Accidental git-commit doesn't leak them
-   Copying the encrypted file to another machine fails to decrypt

This is **not** military-grade --- anyone with shell access on your machine can decrypt. Same security level as your `~/.ssh/` keys.

### Manual invocation

1.  Pick the WORKERS agent (click the card)
2.  Select a model from the dropdown
3.  Type a prompt → press Execute

The cockpit dispatches via HTTP, captures the response, and renders it inline:

-   **Text** → plain text in the chat
-   **Image** → embedded `<img>`
-   **Audio** → embedded `<audio controls>`

### Auto-route (per-project opt-in)

When enabled for a project, all main agents (Claude/Gemini/Ollama) get a system-prompt addition advising them about the marker:

    %%WORKER:provider:task:prompt%%

`crud_executor.sh` dispatches the markers and surfaces results inline. To enable, POST to `workers.php?action=set_auto_route` with `{"project":"myproject","enabled":true}`.

### Usage tracking

The WORKERS card's bar shows aggregate tokens used; the settings modal shows per-provider call counts, error counts, tokens in/out, and last-call timestamp. Right-click the card's usage area to reset all counters.

------------------------------------------------------------------------

## Tools

Tools are **local CLI binaries** for file → file transformations. No internet, no API keys, no usage tracking.

### Built-in tools

  ------------------------------------------------------------------------------
  Tool          Presets   What it does
  ------------- --------- ------------------------------------------------------
  **ffmpeg**    9         Audio/video conversion, extraction, resize, frames

  **whisper**   7         Speech-to-text (auto/EN/ES/HE), SRT, translate-to-EN

  **pandoc**    8         Document conversion (md ↔︎ pdf/docx/html/epub)
  ------------------------------------------------------------------------------

### Setup

1.  Click the gear icon next to the TOOLS button → settings modal
2.  Click **Detect** at the top to scan `$PATH` for binaries
3.  For each tool that shows "[close]{.material-symbols-rounded .ico} not found":
    -   Either install it (`sudo nala install ffmpeg whisper pandoc`)
    -   Or paste the absolute path in the **Override binary path** field
4.  Close the modal --- the preset dropdown shows enabled `<tool>:<preset>` pairs

### Running a tool

1.  Pick a preset from the dropdown
2.  Click the TOOLS card to make it the active agent
3.  Press **Execute** --- the input modal opens (the prompt text itself is not used: tools take a file, not instructions)
4.  Give the input file: **Browse** uploads a file from your computer into the chat's attachment store and fills in its server path; **Server** picks a file already on the machine; or paste an absolute path
5.  Optionally paste extra arguments (`name=value` pairs; put a path that contains spaces in quotes, `with="/home/me/My Project/list.csv"`; a file named without a folder, such as `with=list.csv`, is looked for next to the input file)
6.  Click **Run**

If the tool's program is not installed on the machine, the modal says so before Run, with the exact install line for your package manager (copy it, run it in a terminal — Cockpit never installs software itself), or set the binary override in Tools settings.

While it runs, the bubble shows the elapsed time and the last lines of the tool's log. The output appears inline as a clickable file path with size, runtime, and embedded preview if it's an image/audio/video. Every run — finished, failed or stopped — is recorded in the chat as a `TOOLS` turn with the input and output paths, so it survives a reload and the agents can find it later ("the file we converted earlier").

### Stopping a run, and runs that take too long

The **Stop** button stops everything the page started: the running tool, a worker call, a CLI agent's generation. If the server still reports something running afterwards, Cockpit says which and offers to kill again.

Anything that runs longer than two minutes (or the tool's own timeout, if shorter) raises a *Still running* question — **Stop it** or **Keep waiting** — and asks again every five minutes. Tool runs also have a hard timeout (five minutes by default, per preset). Closing the page stops your tool runs.

### Output paths

Default resolution order:

1.  **Per-preset override** (rare, set in tool JSON)
2.  **Per-tool override** (set in Tools settings → Override output dir)
3.  **Current project directory** (auto when working in a project)
4.  **Default**: `~/scripts/cockpit_data/tools_outputs/<tool>/<timestamp>/`

### Auto-route

Same pattern as Workers. When enabled per-project, agents emit:

    %%TOOL:tool:preset:input_path%%

    # or with extra args:
    %%TOOL:tool:preset:input_path|extra_args%%

------------------------------------------------------------------------

## Library, Snippets, Sources

Three right-sidebar tabs hold reference material:

### Library

Long-form reference texts --- design docs, specs, project briefs, AI persona descriptions. Stored as markdown files at:

    ~/scripts/cockpit_data/library/

To add: paste content into the chat with a `%%LIB:title%%` marker, or use the agent's "Save as Library entry" suggestion that follows substantive responses.

To use: click the [attach_file]{.material-symbols-rounded .ico} attach icon to insert the entry as quoted context in your next prompt.

Books filed by [Bookshelf](#bookshelf) show as **one row per book**, folded away: click the row to unfold its chapters (a book you have opened stays open while you work), or press **Remove book** on the row to delete all of its chapters at once. A novel is dozens of chapters, so the Library shows your books rather than reciting them.

### Snippets

Short, reusable code snippets --- boilerplate, regex patterns, useful one-liners. Same workflow as Library entries.

### Sources

URLs, file paths, or other external references the agent should be aware of. Linked rather than copied --- the agent fetches the content fresh each time the source is referenced.

------------------------------------------------------------------------

## Search the web

The **Search** right-sidebar tab provides web search via Brave Search (primary) → DuckDuckGo lite → DuckDuckGo HTML (fallback chain).

> **Search engines increasingly refuse automated queries.** On some networks every engine answers with a bot check or an error, so a search can come back empty even though your connection is fine. Cockpit now says *which* engine refused and why, instead of blaming the network. The **B** and **D** buttons below open the engine in a real browser window, which still works.

1.  Open the Search tab
2.  Type a query → press Enter
3.  Top 5--10 results appear with title, snippet, and link

Two extra buttons:

-   **B** --- opens Brave's AI summary for the query
-   **D** --- opens DuckDuckGo Chat for the query

Search results have a **fetch** button that retrieves the page's text content and adds it to the chat as quoted context.

------------------------------------------------------------------------

## Keyboard shortcuts

  Shortcut                   Action
  -------------------------- ----------------------------------------------------
  **Enter**                  Send prompt to active agent (Shift+Enter or Ctrl+Enter: new line)
  **Esc**                    Cancel current request / close the open dialog (asks first if you typed something in it)
  **Ctrl+F**                 Search in chat console (or find/replace in editor)
  **↑ / ↓**                  Cycle prompt history (in empty prompt box; scope = chat, project or everywhere)
  **Ctrl+R**                 Filter and pick an earlier prompt (in the prompt box)
  **F1**                     Context help for element under cursor
  **?**                      Open full help guide
  **F2**                     Save selected text to Snippets
  **F3**                     Save selected text to Library
  **F8**                     Open Ollama Model Manager
  **Double-click chat**      Rename chat
  **Tab (in editor)**        Insert 2 spaces
  **Right-click (chat)**     Copy, Select All, Save to Snippets/Library
  **Right-click (prompt)**   Cut, Copy, Paste, Select All, Save

------------------------------------------------------------------------

## Troubleshooting

### "Agent not responding"

1.  Click the open-tmux button (`open_in_new`) on the agent's card
2.  The tmux session opens --- check for error messages
3.  If the session is dead, click **Restart** in the topbar
4.  If `cockpit_start.sh` reports an error, check `~/scripts/cockpit.log`

### Stream stalls partway

Caused by:

-   Network blip during streaming
-   Model running out of context budget mid-response
-   tmux session crashed

Click **Stop** to abort, then re-send. The token cleanup runs every poll so stale state is cleared.

### "Capability not found" after enabling

Capabilities take effect on the **next agent session start**. Click **Restart** in the topbar to reload all sessions with the new capability configuration.

### "Worker call failed: HTTP 401"

API key is missing, expired, or invalid. Open Workers settings and re-paste the key.

### "Worker call failed: HTTP 429"

Rate limited --- you've hit the provider's per-minute or per-hour cap. Wait or switch to a different provider/model.

### Tool says "Binary not found"

Either:

-   Install the binary: `sudo nala install <name>`
-   Or paste an absolute path in the Tools settings → Override binary path

After installing, click **Detect** in Tools settings to refresh.

### Plan execution stops unexpectedly

Check the auto-run mode in Plans toolbar's **tune** button. If it's `approve_destructive` and a step is marked destructive, the orchestrator pauses for confirmation. Click [play_arrow]{.material-symbols-rounded .ico} on the next pending step to continue.

------------------------------------------------------------------------

## Configuration files

The cockpit's runtime configuration is split across these files:

    /var/www/html/cockpit/                     ← Web root (PHP backend + frontend)
    ├─ index.html                              ← UI
    ├─ bridge.php                              ← Stream/poll/cleanup
    ├─ files.php, status.php, ...              ← Other backends
    ├─ capabilities.php, orchestrator.php, ...
    ├─ paths.json                              ← Where cockpit_data lives
    ├─ workers_providers.json                  ← Worker provider catalog (seed)
    └─ tools_builtins/*.json                   ← Tool definitions (seed)

    ~/scripts/                                 ← Scripts run by Apache user
    ├─ cockpit_start.sh, cockpit_stop.sh
    ├─ agent_loop.sh                           ← Per-agent dispatch
    ├─ crud_executor.sh                        ← %%CRUD%% / %%TOOL:%% / %%WORKER:%%
    └─ cockpit_data/                           ← Per-user state
       ├─ library/, snippets/, sources/
       ├─ capabilities/_builtin/
       ├─ workers_state.json
       ├─ workers_keys.enc                     ← Encrypted API keys
       ├─ workers_usage.json
       ├─ tools/, tools_outputs/
       └─ tools_state.json

    ~/Software/Programing/LocalAIProjs/        ← Projects root
    ├─ <project>/
    │  ├─ chat_<name>.json
    │  ├─ capabilities.json                    ← Per-project enabled caps
    │  ├─ orchestrator.json                    ← Per-project plan settings
    │  └─ plans/plan_<id>.json

Most files are JSON; edit them directly with `xed` if needed. The cockpit re-reads configuration on each request, so changes take effect immediately (except agent capabilities, which require a session restart).

------------------------------------------------------------------------

# Update --- June 2026: New features

This section covers features added after the original guide. Everything here is local-first and offline unless noted.

## Directives (the "Rules" button)

Global standing rules that are prepended to **every** supplier's context at dispatch --- Claude, Gemini, Ollama, and text Workers alike. Write once; they apply everywhere.

-   Open with the **Rules** button (top bar).
-   **Full** directives go to Claude/Gemini; a **Compact** variant is used for tiny Ollama models so a long preamble doesn't crowd out the task.
-   Tick which suppliers use the compact variant.
-   Per-project rules still live in each project's `COCKPIT.md` and layer on top.
-   Stored in `cockpit_data/directives_global.md` (+ `_compact.md`, `_config.json`).

## Voice input (offline)

The [mic]{.material-symbols-rounded .ico} **Voice** button records your microphone and transcribes it **locally** with whisper.cpp --- audio never leaves the machine. Press it to start, press it again to stop. The words land in the prompt box, editable before sending, and a line under the chat says how long you recorded and **which whisper model ran** --- for example `whisper.cpp · large-v3-turbo`.

**You can see it working.** While you record, a bar with a pulsing red dot opens to the left of the button and moves with your voice, and the button itself fills as the level rises. "Nothing happened" has several causes that all look the same --- a muted microphone, the wrong input, a quiet room --- and the bar tells them apart: it moves, or it does not.

The **▾** menu beside the button holds three labelled choices and a test:

-   **Model: …** --- your installed whisper models (bigger = more accurate, slower). `Auto` uses the model pinned in `whisper_config.json`, else the largest installed; the label shows which one that is, and the result line always names the model that actually ran.
-   **Language: …** --- the language you *speak*: every language whisper supports (99), as a scrolling menu you can type into, **English by default** and remembered. *Auto-detect* is there too, but forcing the language avoids mistakes such as one language being taken for a similar one. (This is separate from the language Cockpit itself is shown in.)
-   **Mic: …** --- which input to record from. A machine's default input is often an empty analog jack that records only hum, while the real microphone sits on a USB camera or headset; pick it here.
-   **Test level** --- listens for four seconds and answers *Good*, *Silent* or *Clipping*, without transcribing anything.

If a microphone you picked earlier is no longer there, Cockpit forgets it, says so, and uses the default input instead of failing.

Requires whisper.cpp + a ggml model (see the Setup Guide).

## Effort and JSON-driven supplier controls

Each supplier card's dropdowns are driven by a JSON file, so options can be changed without touching code.

-   **Model** dropdown --- the value is the real CLI model string.
-   **Effort** dropdown (Claude) --- passes the real `claude --effort <level>` flag: `low, medium, high, xhigh (Extra), max`.
-   The **tune** [settings]{.material-symbols-rounded .ico} button on a card opens its control file (`cockpit_data/claude_controls.json` / `gemini_controls.json`) in the editor. Add an option to the `options` array, Save, and it appears in the dropdown.

## The floating code editor

Snippet/source/file editing now uses a draggable, **resizable** floating editor with:

-   **Syntax highlighting** (Prism, offline) for Pascal/PHP/Bash/JS/JSON/YAML/CSS/HTML, themed to your current cockpit theme.
-   **Find & replace** (Ctrl+F), **line numbers**, **word wrap**, a **language** picker (with custom suffix), **Tab** = 2 spaces, and **Save / Save as...**.
-   Used by the Files tree, Library/Snippets/Sources, and the Capabilities editor.

## Capabilities --- now GLOBAL

Capability enablement is a single global on/off per capability --- it applies to **all projects, free chats, and every supplier** the capability declares (the CLAUDE/GEMINI/OLLAMA badges are informational, set by the capability's `CAP.json`).

-   Built-ins default ON; user capabilities default OFF.
-   User capabilities have **edit** (opens `CAP.json` in the editor) and **delete**.
-   Enabling an MCP capability stages the server config that Claude/Gemini load; the staging is redone with every prompt, and Restart is the fallback if an agent has not picked it up.
-   Example included: a `time` capability (uvx `mcp-server-time`).

## Workers --- Discover and pick-and-add

In Workers settings, **Discover** probes each provider's `/models` endpoint and shows the full list. Click **+** next to a model to make it **selectable** (it's added to that provider, text kind). A filter box narrows long lists.

### Workers --- keeping models and prices current, and adding a supplier

The model lists and prices that ship with Cockpit are a snapshot, and they go out of date. Three things keep them useful without waiting for a new Cockpit build:

-   **Models and prices (the catalog feed).** At the top of Workers settings, a line says what date the lists are **as of** (amber once they are older than 90 days). **Turn ON…** lets Cockpit fetch one small file that the maker signs, from cockpit.ruggi.site, and add new models and prices to the lists. It is **off by default** and nothing is fetched while it is off; no account data and nothing that identifies you is sent. The signature is checked on your machine against a key that ships inside Cockpit, and a file that does not verify (or was altered afterwards) is ignored. A feed can only add or update models and prices for suppliers you already have: it can never change a supplier's address, touch your keys, or override what you added yourself. **Check now** fetches at once; **Check once a day automatically** is optional. A supplier the feed knows and you do not have appears under *New suppliers you can add*, with its address in plain sight; nothing is added until you click **Add**.
-   **Add model** and **Discover** put a model on a supplier you have. Add model takes an optional **price** (US dollars per million input and output tokens): with a price, a monthly cap can protect you on that model. Without one, Cockpit refuses to call a model under a cap, because it could not count the cost.
-   **Add custom provider** adds a supplier of your own that speaks the same API as one Cockpit already knows (most do: the **OpenAI shape** at its own **address**). Give it an id, a name, the API shape, the address (https, or plain http for this machine or a private network such as a local model server) and a first model. Your key for it, added afterwards, is sent to that address, so check it. A custom supplier with any paid model counts as paid: the consent switch and your caps apply to it like any other.

## Help system

See [Comprehensive help system](#comprehensive-help-system) below for the full, current description.

## Scheduler --- orphan recovery

A scheduled job left "running" for more than 15 minutes (its worker died) is now auto-marked **failed**, so the Jobs badge no longer shows stale "running" counts.

## Paid API workers + spend-safety gate

The same provider can be reached two ways: as a **supplier** (CLI subscription, via tmux --- Claude, Gemini, Ollama) and as a **worker** (HTTP API, BYOK). Alongside the free-tier workers (Groq, OpenRouter, ...) you can now add three **paid** API workers: **OpenAI (ChatGPT)**, **Claude (Anthropic API)**, and **Gemini (Google API)**. The CLI supplier roles are untouched --- this is purely additive.

Because these cost real money per call, they sit behind a deliberate safety stack (all enforced server-side, so no UI state can bypass it):

1.  **Global consent (default OFF).** In **Workers settings → Paid API spend**, "Turn ON..." opens a consent modal (real money, BYOK, best-effort caps, revocable). Until you accept, no paid provider can be enabled or called.
2.  **Per-provider enable.** Even with consent ON, each paid provider is still OFF until you enable it individually (and paste its key). Paid providers show a **[attach_money]{.material-symbols-rounded .ico} PAID API** badge; their toggle is locked until consent is given.
3.  **Spend caps (monthly).** Set a **global** cap and optional **per-model** caps. A call is blocked if it would breach either. Caps are **best-effort** --- the exact cost isn't known until a call returns, so spend can overshoot by about **one call**. The panel shows "Spent \$X of \$Y" with a warning near 80%.
4.  **Dual usage.** A provider reachable as both CLI and API shows as separate lines --- e.g. "Claude (CLI)" vs "Claude (Anthropic API)" --- so you always know which budget you're burning.
5.  **Streaming.** The answers of Anthropic and of the OpenAI-compatible workers (OpenAI, Groq, OpenRouter, Together, DeepInfra, Z.ai, Gemini) **stream**: the text appears as it is written, instead of all at the end. If a provider cannot stream, or ignores the request, you get the whole answer at once as before; if a stream stops half-way you get an error, never a half answer shown as complete. Providers that do not report token counts while streaming are marked as estimated. **Pictures reach the Anthropic worker as pictures.** While an Anthropic model is selected in Workers, an attached image is sent to the API as an image (up to 5 per message, each up to 3.5 MB; a bigger one is left out and said so), not as a text description from a local model. Other providers still get the description. **The Anthropic worker** also sends the identity line and the earlier conversation as a real *system prompt* (long ones are marked cacheable, which makes repeated long context cheaper and faster), not glued to your words. The real token counts, including cached tokens, go to the cost pill and the spend ledger. A cap cannot be enforced on a model whose price Cockpit does not know, so with a cap set such a model is refused until you add its price to the provider list. Test keys and Discover now send the header Anthropic expects; before, a good key was reported as rejected, and the provider showed "unknown" because it had no base address.
6.  **Web page workers (experimental).** A site that has no API, or whose API you do not have a key for, can be used through its own web page: **Duck.ai**, **Perplexity**, **Mistral Le Chat**, **DeepSeek** and **Meta AI** are in the list as *"(web page)"* providers. Cockpit's own window (`cockpit_shell --worker`) loads the site **where you cannot see it**, types your prompt into the site's own box, presses the site's own send button, and brings the answer back to the chat as it appears. Every send starts a fresh page (Cockpit already includes the earlier turns in the prompt), and the answer's token count is an estimate. Things to know:
    - **Logging in.** If the site wants a login, or you have to accept its terms, its window **comes on screen** and Cockpit says so; do it there once (the cookies are kept in `webworkers/<site>/profile`) and send again. Cockpit never types a password and never tries to pass a "prove you are a person" check: it shows the window and waits for you. After a login or a check that worker is left alone for 30 minutes so a window does not keep popping up.
    - **Always last.** In the Auto (cascade) rotation the web workers come after every API worker, whatever the saved order says, and they never count as spend.
    - **Fragile by nature.** A site can change its page any day. Settings → Workers has, for each: **Open window**, **Hide**, **Self-test** (sends a fixed question and checks the answer, so you learn when a site changed) and **Probe** (describes the page's boxes and buttons into the prompt box so the adapter's selectors can be fixed). Duck.ai and Perplexity were set up from their public pages; Mistral, DeepSeek and Meta AI need a login first, so their adapters are generic and will need one Probe after you have logged in.
    - **Terms and privacy.** Many sites do not allow automated use, and what you send goes to a consumer product with its own privacy rules. It is your account and your decision; leave them disabled if in doubt. The cookie banner of Perplexity is answered with the private choice (decline optional), never "accept all".

Why bother: a free/alternate API key can pick up when your paid CLI subscription hits a limit, and a Broadcast can fan out across mixed-cost providers at once.

> Pricing is editable per model (via the provider's controls); until provider cards carry pricing, edit the input/output rates in the worker config.

------------------------------------------------------------------------

## Context menus

Cockpit replaces **all** native browser right-click menus with themed, app-native context menus that follow the active theme.

### Chat panel (right-click on selected text)

-   **Copy** --- copy selection to clipboard
-   **Select All** --- select all chat text
-   **Save to Snippets** --- save selection as a code snippet
-   **Save to Library** --- save selection as a library reference

### Prompt area (right-click)

-   **Cut** --- cut selected text (when text is selected)
-   **Copy** --- copy selected text
-   **Paste** --- paste from clipboard
-   **Select All** --- select all prompt text
-   **Save to Snippets / Library** --- when text is selected

### Special right-clicks

-   **Ollama usage bar** → Reset Ollama session stats
-   **Workers usage bar** → Reset Workers usage counters
-   **Time button** → Open time report

Input fields (text inputs, textareas, dropdowns) retain the native browser menu for paste and spell-check.

## Themed confirm & prompt dialogs {#themed-confirm-and-prompt-dialogs}

All `confirm()` and `prompt()` browser dialogs have been replaced with Cockpit-native modals that follow the active theme.

-   **cockpitConfirm(title, message)** --- async, Promise-based. Returns `true`/`false`.
-   **cockpitPrompt(title, message, placeholder)** --- async input modal. Returns the typed string or `null`.
-   **cockpitChoice(title, message, options)** --- multi-option modal for scope selectors (e.g., Project vs Global).

All modals use CSS variables (`--bg-base`, `--border-mid`, `--text-base`, `--accent-*`) --- they adapt to every theme automatically, including dark, light, and custom themes.

## Plan Re-Run

Completed, halted, or failed plans now show a **Re-Run** button in the plan toolbar. Clicking it resets all steps to \"pending\" and restarts execution from step 1. Previous step results are cleared. Confirmation is required before re-running.

## Spend-cap warnings

When paid API spend reaches **80%** of any configured cap (global or per-model), a system message warns you in the chat. Warnings are checked after every paid API call and include the current percentage and cap value.

## Ollama runtime knobs

The Model Manager (F8) now includes a runtime knobs panel at the bottom:

  Knob             Default   What it controls
  ---------------- --------- ------------------------------------------------------
  `keep_alive`     5m        How long models stay loaded in memory after last use
  `num_ctx`        4096      Context window size in tokens (higher = more VRAM)
  `num_parallel`   1         Concurrent requests per loaded model
  `max_loaded`     1         Maximum models loaded simultaneously

Click **Save knobs** to persist to `cockpit_data/ollama_config.json`. Values are read by `agent_loop.sh` on session start via environment variables (`OLLAMA_KEEP_ALIVE`, etc.). Restart agent sessions for changes to take effect.

## Model Manager enhancements

-   **Probe** --- test if a model supports tool calls via a 4-check pipeline (health → model present → Messages API → tool-call round-trip). Result: AGENTIC CAPABLE or NOT AGENTIC.
-   **Variant** --- create an agentic-tuned variant with custom Modelfile parameters (num_ctx, temperature, repeat_penalty). Variants are tagged with an [AGENTIC]{style="background:#26a69a;color:#1a1d21;padding:1px 5px;border-radius:3px;font-size:9px;font-weight:600;"} badge in the model list.
-   **Browse** --- search a curated catalog of popular Ollama models. Click to pull directly.

## Media generation

Generate media **locally** using your GPU --- no internet, no cost.

  Type        Engine                          Time        Output
  ----------- ------------------------------- ----------- ----------------------------------------------------------
  **Image**   stable-diffusion.cpp (SD 1.5)   \~20 sec    PNG with presets: Logo, Icon, FavIcon, Background, Image
  **Sound**   Piper TTS                       \~5 sec     WAV spoken audio from text
  **Video**   sd.cpp + ffmpeg                 \~2-3 min   Animated GIF from varying-seed frames

Results appear inline in the chat with Save/Download/Delete buttons. All files go to `cockpit_data/generated/`.

## Translation

Translation uses **local LibreTranslate** --- no data leaves your machine.

-   **Translate chat** --- translates all messages in the current chat. Code blocks are excluded (preserved as-is). Pick source and target languages.
-   **Translate text** --- opens a free-text translation box. Paste any text, pick languages, translate. Result can be copied or inserted into the prompt.

### Translating Cockpit itself {#translating-cockpit}

The text of Cockpit's own screens can be shown in your language, and you can write the translation without leaving Cockpit.

1. Click the **translate** icon (the last small button under the clock, after **Aa**) and choose **Translate Cockpit…**.
2. Pick a language from the list, or **＋ A new language…** and fill in its code (`fr`, `pt-BR`), its English name, its own name, the direction (left-to-right or right-to-left) and your name.
3. Every text of Cockpit is listed with its English on the left and a box for your translation on the right. The bar shows how far you are; the filter starts on **Not translated yet**, so you only see what is left. Search finds a word in the English, the key or your translation.
4. **AutoTranslate** asks a model that runs on your own computer (through Ollama; nothing leaves the machine) to draft the empty lines. Pick the model beside the button (the list starts with the best translator you have installed, for example `gemma3:4b`; bigger models translate better and slower: expect about 2 to 3 seconds per line on a small graphics card, so a whole language takes hours and can run in the background while you do other things). It starts with the page you are on. A draft is **not text yet**: it appears as grey, slanted text in its box. Press **Tab** in an empty box to make that line's draft real text, or use **Accept page** (the drafts on this page) or **Accept all** (asks first). **Stop** keeps what is drafted so far; **Drop the drafts** throws them away; **Draft this line** under a box drafts just that one. A draft whose `{placeholders}` differ from the English is never offered. Always read the drafts: they are a start for a person who knows the language, not a finished translation.
5. **Save** writes your language into the `lang` folder of your Cockpit data folder; updates never touch it. **Use this language** switches Cockpit to it at once. **Download my file** saves it as a `.json` to share or keep; **Upload a file** merges one in (it is checked first).

The rules (they are also behind the **Rules** button in the Studio):

- Translate the meaning, not word by word; keep it short, because most of these texts sit in buttons.
- Keep every `{placeholder}` exactly as written (`{name}`, `{n}`). You may move it inside the sentence. The box turns red when one is missing or changed, and such a line is not saved.
- Leave a box empty to keep English there. A half-finished translation works.
- Do not translate product and file names (Cockpit, Ollama, Claude, Gemini, tmux, `.json`) or keyboard keys.
- If new texts arrive in a later Cockpit, open the Studio again: they are the ones still empty.
- A button, plate, tab or short label never grows with a long translation: it keeps its English size and the text scrolls inside it (a marquee), while its icon stays put. Prefer the shorter word anyway.
- **Right-to-left languages** (Hebrew, Arabic, Persian, Urdu…): choose *Direction: right-to-left*. The Studio then asks **Flip the layout?** — *Layout stays as it is* (only the text reads right to left; the safe choice) or *Mirror the whole layout* (sidebars, strips and buttons swapped left for right; experimental, so check it on every screen). Code, the console and file names always stay left-to-right. To try a mirror without saving it, add `&mirror=1` to the address.
- **Languages written vertically** (traditional Mongolian, vertical Japanese or Chinese): Cockpit supports as interface languages only languages written horizontally, as almost every program does. A language that is also written vertically can be a Cockpit language through its horizontal form, and its writing system is fully supported in your content (chats, notes, files). Vertical reading is not offered.

By hand: **Or download the empty template** in the same menu (the file carries the rules and how to send it back inside its `_meta`) (or `lang.php?action=template&code=he` for a language's own file with what it already has filled in), translate the empty values, save the file as `<code>.json` in that folder and reload. The downloaded file is a plain `.json`: keep it, or hand it to anyone who uses Cockpit, who puts it in the same folder. To have it included in Cockpit for everyone, press **Send it to us** in the Studio (it opens cockpit.ruggi.site/translate.php, where you choose the file and send it; the owner reads it before anything ships).

## Time tracking

The **Track** button starts/stops a timer for the current project.

-   Click to start. Click again to stop.
-   The button shows elapsed time while tracking.
-   **Right-click** → Time report: view logged entries with delete.
-   The counter in the top-right shows total tracked minutes for the session.

## Lazarus beside Cockpit {#lazarus-coexistence}

Lazarus stays your IDE; Cockpit sits beside it. Two things make that work:

-   **The viewer follows the file.** The file shown in the Preview panel is watched: when something else changes it on disk --- Lazarus, an agent, a chain, an applied Margin edit --- the viewer reloads itself, keeps its scroll position and says *changed on disk --- reloaded* for a few seconds. It waits while you have text selected in it (a Margin selection must not vanish) and while the window is hidden. It notices two saves within the same second, and files that are replaced rather than rewritten, which is how most editors save.
-   **Open in Lazarus.** For Pascal and Lazarus files (`.pas .pp .inc .lpr .lpi .lpk .lfm .lrs .dpr .dfm`) the viewer shows a **Lazarus** button when Lazarus is installed. It opens the file --- and, when the folder holds one `.lpi` (or the `.lpi` named like the `.lpr`), that project with it. On a machine set up before this feature, the installer or the next Cockpit deploy has to grant Cockpit permission to start Lazarus; until then the button says so instead of doing nothing.

## Project kinds {#project-kinds}

A project can say **what it is**. The small badge beside the project's goal in the info bar shows the kind; click it to choose one of the **49 kinds** that ship, listed in **10 fields**: *General*; *Writing & documents* (10, from Creative writing and Academic paper to Legal review and Meeting notes); *Home & life* (10: Cooking, Gardening, Pets, Health log, Collections, Genealogy, Hobby crafts, Tabletop, Travel, Home and DIY); *Software & games* (6); *Media* (7, with Music practice); *Research & learning* (4, with Teaching); *Hardware & making* (3: 3D printing, Electronics, Arduino); *Data & numbers* (3, with Personal finance); *Work & community* (3: Job search, Non-profit and events, Real estate); *System & servers* (2: System administration, Shell and DevOps). Kinds are open-ended: see *Making your own kind* below. Each kind carries a short standing note that is sent with every prompt in the project, beside the goal --- for example, that a Lazarus project is judged by the compiler and should change a `.pas` and its `.lfm` together, or that a Godot project must use the API of the version named in `project.godot`. The chooser also **detects** the kind from the folder (a `.lpi`, a `.vbp`, `CastleEngineManifest.xml`, `project.godot`) and marks it as suggested. Kinds are plain data files in the app's `kinds` folder. Every kind except *General* names the **tools** it works with, and the picker shows which are installed.

### Making your own kind {#own-kinds}

The picker is two panes. On the left the kinds are listed in **fields** (Writing & documents, Media, Research & learning, Data & numbers, Software & games, Hardware & making, System & servers, and any field you make for your own kinds): click a field's name to fold or unfold it, or type in the search box to find a kind by its name, description, explanation or examples. On the right, the selected kind is explained: what it is, a longer **About this kind** text, **Examples** of projects that fit it, what judges the work, the files that identify it and the tools it uses. Double-click a kind (or press Save) to choose it. **Export** at the bottom saves the selected kind, shipped or yours, as a `.kind.json` file; **Import** reads one back. To change a shipped kind, duplicate it into your own kinds (or export, edit and import it: yours then replaces it for you).

**Starter files.** A kind can carry up to 12 small starter files (a README, an outline, a template; each up to 20,000 characters, with relative paths such as `chapters/01.md`). When a project is open, the kind's page in the picker lists them with **Add these to this project…**. You see exactly which files would be created and which already exist, you confirm, and only the missing ones are written: an existing file is never overwritten, and nothing can be written outside the project folder (a link inside the project that points elsewhere is refused). Writing, Research, Meeting notes, Study and Learning and Podcast ship with starters. The starter is part of the kind, so Export and Import carry it; you edit them in the **+ New kind… / Edit** wizard: a **Starter files** list (a file name and its text for each, up to 12, with Add a file and ×), or in an exported `.kind.json` (a `"starter": [{"path": "...", "content": "..."}]` list).

**A kind that carries its own tool.** A `.kind.json` may hold a `"tool_defs"` list (up to 4 tools of up to 8 presets each) for a command-line program the kind needs, so a brand-new kind with a brand-new tool needs no change to Cockpit. Only a narrow form is accepted: a plain program name found on your PATH, and commands made of that program, plain arguments and the placeholders `{INPUT}`, `{OUTPUT}`, `{ARGS}`, `{NAME}`; no quotes, pipes, redirects, `$(...)`, `..`, helper scripts, options that run another command, and no shells, interpreters or launchers (`bash`, `python`, `env`, `sudo`, `curl` and similar). A tool whose name is one Cockpit already ships is refused. **Import shows you every command and asks before anything is installed**; the tools then go into your own tools (Tools panel, where you can delete them), and a tool that belongs to one kind is never replaced by another kind. The wizard has a **Tools this kind carries** box (JSON, advanced; leave it empty for none): saving shows you every command and asks first, and **emptying the box on a kind that had tools removes them from the kind** (the tools stay in your Tools panel, where you can delete them). Re-saving a kind without touching the box keeps its tools. The same checks apply to a kind installed from the Marketplace.

In the kind picker, **+ New kind…** opens a small wizard: a name, an icon (any Material Symbols name), one line saying what the kind of project is, the **standing note** (up to 900 characters: how an agent should work on this kind of project, what to check, what judges the result), the file names that identify it (for example `*.srt, *.vtt`: when a project folder contains such a file the picker suggests the kind), a short "what judges the work", and the **tools** it uses, ticked from the Tools list (a green tick means installed on this machine; hover a red cross for how to install it). Your kinds live in your own data folder (`kinds/` under your login), so **updates never touch them**, and a kind of yours with the id of a shipped one replaces it (delete yours to get the shipped one back). Each of your own kinds has *Edit*, *Duplicate*, *Export* and *Delete* under its explanation; the wizard also asks for the field it is listed under, a longer explanation and up to six examples.

**Draft with the agent…** puts a request in the prompt box asking the agent to write the kind (only from the tools you have installed); send it, then **Import…** and paste the answer: the dialog finds the JSON even when the agent wrapped it in words. **Export** saves one kind as a `.kind.json` file you can send to someone else; **Import…** reads such a file and asks before it replaces a kind with the same id. A kind can name tools but never carries a command line of its own, so importing one cannot run anything. When a project of a kind with installed tools is created or its kind is chosen, the standing note ends with a line naming those tools in the form an agent can run (`%%TOOL:fpc:check:path%%`).

### Where the kind and the goal live {#kind-goal-scope}

- **The kind belongs to the project.** Choose it once and every chat in that project inherits it; change it and all of them change.
- **The goal belongs to the chat.** Each chat has its own one-sentence goal (click the goal in the info bar). A chat that has none shows the project's older goal as its default, in the tooltip marked as inherited; saving a goal there gives that chat its own. Renaming a chat keeps its goal.
- **Free chats** (outside any project) have no project to hold a kind, so each keeps its own kind *and* its own goal.
- Both are sent with every prompt in the chat, exactly as before. The two chips in the info bar stay hidden for an instant while they load instead of flashing "General" and "+ goal" first.

### Descriptions {#descriptions}

When there are many chats in a project, or many projects, names stop being enough. Every chat and every project can carry a **description** of up to 300 characters: what it is for, the role it plays, or what it achieved.

- **Where to write it:** click the **+ note** chip in the info bar (after the kind and the goal). One dialog edits the description of the *chat* and, inside a project, of the *project*; a free chat has only its own.
- **Where it shows:** as an italic second line under the name in the **Chats** and **Projects** lists, and as the chip's tooltip. A chat with no description of its own shows its project's.
- **Searching:** both lists have a **filter box** that matches names *and* descriptions (a project also matches the names and descriptions of its chats).
- **Private by default.** A description is a note for you; agents do not see it. Tick **Also send this to the agent with every prompt** — separately for the chat and for the project — and it travels with each prompt as `[Chat description]` / `[Project description]`, beside the goal and the kind.

## Building Pascal and Lazarus projects {#pascal-build}

Two tools in the Tools list build Pascal without opening the IDE. **Lazarus build** runs `lazbuild` on a project (`.lpi`) or package (`.lpk`): *Build project*, *Build, errors and warnings only*, and *Rebuild everything*. **Free Pascal compile** takes one program or unit (`.pas`, `.pp`, `.lpr`): *Check* (compile without linking, keeps nothing) and *Compile* (errors, warnings and hints). Each run saves the compiler's whole output as a text file, with file and line for every message and a last line `[exit code N]`, **even when the build fails**: the messages are the point. Units and objects of a single-file compile go to a scratch folder, so nothing is left beside your source. An agent can run them too (`%%TOOL:lazarus:build:path/to/project.lpi%%`) and then read the errors and propose the fix. After a build or a check, the result in the chat says **how many errors and warnings** there were and lists the first eight errors with file and line; when there are errors, a **Fix with agent** button puts them (and the file names) into the prompt box, ready to send: the agent reads the files, fixes them and tells you what it changed. Nothing is sent until you press Execute.

**Starting a project:** the Lazarus tool also has *New console program*, *New Lazarus form application* (a form with a label and a button) and *New unit* (a class skeleton). Give it the project folder as the input and a name in the extra-arguments box (`project1` or `unit1` if you leave it empty); it writes the files there, never over an existing one (if any would be overwritten it writes nothing and says which), and what it writes builds as it is.

They need `fpc` and `lazbuild` (the Lazarus packages); without them the tool says so and how to install them.

## Installing without administrator rights {#user-mode-install}

On a machine where you cannot use `sudo` (a work computer, a locked-down account), the bundle has a second installer, `install_user_mode.sh`, that needs no Apache and no administrator rights at all. It puts everything inside your home folder: the web app in `~/.local/share/cockpit-web/cockpit`, the programs and scripts in `~/scripts`, your data in `~/scripts/cockpit_data`, your projects in `~/AI-Cockpit/projects` (change it with `--projects DIR`), and it switches on the self-contained mode (the supervisor runs `aicserver` and `php-cgi` as you on `http://127.0.0.1:8081`). Run it from the unpacked bundle:

```
bash install_user_mode.sh            # V2 (the full edition); --edition v1 or both for the others
cockpit-self-start                   # starts the agents, the web server and the window
cockpit-self-stop                    # stops them again
```

It installs nothing from the system. What must already be on the machine: PHP (command line) with its `php-cgi` program and the sqlite3, curl, mbstring and xml modules, `tmux`, `jq` and `curl`. If something is missing it says exactly what, with the package names, and changes nothing, so you can hand the list to whoever administers the machine. It will not touch an existing installation (`~/scripts/cockpit_start.sh`) unless you pass `--upgrade`, which replaces the programs and the web app and keeps your data and settings. In this mode the Start, Stop, Terminal, Files and Browser buttons run directly as you, with no `sudo`, and the integrity check against the build manifest still runs when the window opens. Not covered yet: Windows, and running several people on one machine.

## Data tools {#data-tools}

The **Data** tool (in the Tools list; the *Data Analysis* project kind uses it) works on CSV files: comma, semicolon or tab separated, with or without a byte-order mark, quoted fields with commas inside, any language in the header. Give it the file as the input; where a preset needs more, type it in the extra-arguments box. A **column** is its name (write `_` for a space) or its number (`1` is the first).

- **First rows**, **Describe every column** (rows, empty cells, distinct values, min and max, and for columns that really are numbers the sum and mean: a date such as 2026-01 is not a number), **Column statistics**, **Most frequent values**.
- **SQL query**: any `SELECT`; the file is the table `t`. For example `SELECT city, SUM(CAST("sales total" AS REAL)) AS total FROM t GROUP BY city ORDER BY total DESC`. The CSV is loaded into a private temporary database and the SQL runs in SQLite's safe, read-only mode: it cannot change or write anything, attach another database, load an extension or run a command, so it is safe to let an agent write the SQL. Your file is never modified.
- **Make a database file** writes `FILE.db` beside the CSV (never over an existing one) when you want to ask many questions.
- **Spreadsheet to CSV** turns the first sheet of an `.xlsx`, `.xls` or `.ods` file into CSV with LibreOffice (headless).
- **Charts**: *Bar* (category column, number column, title; leave the number out to count rows; repeated categories are added up, at most 30 bars), *Line*, *Scatter* and *Histogram* (the column, and optionally the number of bins). They are written as **SVG**: they open in the Preview panel and any browser, scale without blur, and can be turned into a PNG with the ImageMagick presets. Every chart says how many rows it used and how many it skipped because the cell was empty or not a number.

Answers come as markdown tables, so an agent can read them and you can paste them into a document. The tools need `sqlite3` (the answers) and PHP (the charts), which Cockpit already requires, and LibreOffice only for spreadsheets.

## Web site tools {#web-site-tools}

The **Web site** tool (in the Tools list; the *Web Site* project kind uses it) looks after a static site. Give it the site's folder as the input (the *Check* and *Pages* presets also accept one `.html` file). Nothing is fetched from the internet and nothing in the site is changed.

- **Preview in the browser** serves the folder on `127.0.0.1` (a free port from 8200) and shows the address as a link to click. Only this computer can open it. PHP files run. It behaves like a real web server in two ways that matter when you are checking links: a URL that matches no file answers **404** (it does not quietly show the home page), and hidden files and folders (`.git`, `.env`) and editor backups (`~`, `.bak`) are **never served**. It stops by itself after 30 minutes (type a number of minutes, 1-240, in the extra-arguments box to change that) or when you press **Stop the preview**.
- **Check the site** reads every page and style sheet and lists each problem with its file and line, in the same form as compiler errors, so the result shows the number of errors and warnings, the first errors, and a **Fix with agent** button that puts them in the prompt box. It finds: markup errors (a tag that was never closed), a missing `<title>`, `lang`, character set, viewport or `alt` text, duplicate ids, empty links, old tags such as `<font>`, links to pages, images, scripts and style sheets that do not exist, `#anchors` that point to nothing, `url(...)` references in CSS that do not exist, unbalanced braces and unclosed comments in CSS, and **file names whose case differs** from the link (`Logo.png` against `logo.png`: it works on Windows and fails on a Linux server). External links are counted, never visited.
- **Broken links only**, **List the pages** (a table with each page's title) and **Pack as a zip** (without hidden files, `.git`, `node_modules` and backups, ready to upload).

They need only PHP, which Cockpit already requires (the zip needs PHP's zip module).

## Music scores tools {#score-tools}

The **Music scores** tool (the *Music scores* kind uses it) writes, checks and plays sheet music in LilyPond. Give the `.ly` file as the input.

1. **Check** compiles the score and lists every error and warning as file, line and column, in the same summary box as the Pascal tools. A `barcheck failed` warning means the bar *before* that position has the wrong number of beats. **Build the PDF**, **MIDI file**, **first page as a PNG** and **Play** (an MP3 made through TiMidity++ and its sound font) give the outputs; the score needs a `\midi { }` block inside `\score { }` for the last two.
2. **Update the syntax** brings an old file to the installed LilyPond with `convert-ly`. **MusicXML to LilyPond** and **ABC to LilyPond** import scores from MuseScore, Finale, Sibelius and ABC tune books; run Check on the result. **New tune** starts a lead sheet (type the name, then optionally `key=d time=3/4 tempo=100`), always with whole bars for the time signature.

**Safety.** A LilyPond file can contain code that runs commands, and LilyPond removed its own safe mode because it could not be made safe: an untrusted score could delete files or read your home folder. So every run happens inside *bubblewrap*: no network, no home folder, a read-only system, and only a scratch copy of the project writable, so your folder gets no extra files either. Without bubblewrap installed the tool refuses to run LilyPond at all. Install it with `sudo apt install bubblewrap`.

## Photo tools {#photo-tools}

The **Photo tools** (the *Photo editing* kind uses them) read EXIF with PHP and edit with ImageMagick, and `exiftool` (when installed) adds **All tags** (privacy-sensitive ones first), **Set tags** (artist, copyright, title, keywords, written into a copy) and **Shift dates** (`+1d2h30m`, for a camera with the wrong clock). The type of a file is taken from its content and handed to ImageMagick as an explicit decoder, so a file named `.jpg` that is really an SVG or a script is refused. The originals are never changed.

1. **Info** shows size, camera, date taken and GPS for a photo, or a table for a whole folder. **Check** warns about a hidden **GPS location** (anyone you send the file to can see where it was taken), files over 8 MB, CMYK JPEGs, rotation tags that other tools ignore, images under 640 px, no date taken, mixed formats and files that are not photos.
2. **Strip metadata** removes everything (GPS, camera, dates) after applying the rotation. **Web-ready copy** also converts to sRGB and shrinks the long side (never enlarges): `max=1200 quality=75` in the extra arguments. **Batch** does a whole folder into one zip. **Enhance** auto-levels and sharpens gently.
3. **Contact sheet** shows a folder at a glance. **Duplicates** finds exact copies and near-duplicates (the same picture resized or re-saved, by a picture fingerprint) and deletes nothing. **Rename plan** proposes names by date taken (`2026-01-05_14-30-02.jpg`) and renames nothing.

## Documentation site tools {#docsite-tools}

The **Documentation site** tool (the *Documentation site* kind uses it) turns a folder of markdown pages into checked documentation. Give the folder as the input; `README.md` or `index.md` is the home page, and `node_modules`, `.git` and `site` folders are skipped.

1. **Check the pages** finds links between pages that point nowhere, links to a `#heading` that is not there, missing images, links whose file name differs only in letter case (they break on Linux), empty pages, pages with no title, skipped heading levels, repeated headings and pages nothing links to, with the page and line of each.
2. **Contents page** writes an index in folder and number-prefix order (`01-install.md` before `02-usage.md`). **Build the static site** makes a zip with one HTML page per markdown page, a sidebar, previous and next links, dark mode and a search box that works offline, with `.md` links rewritten to `.html`; unzip it anywhere and open `index.html`, or preview it with the Web site tools. **One page** makes a single self-contained HTML file with a table of contents, to print or send. Pandoc reads the pages with its sandbox on.

## System administration tools {#sysadmin-tools}

The **System administration** tool (the *System administration* kind uses it) diagnoses a machine **without changing it**. Every command only looks (`df`, `free`, `ps`, `ss`, `systemctl status`, `journalctl`, `du`); nothing is installed, started, stopped, edited or deleted, nothing needs `sudo`, and it sees only what the account running it can see (the report says which). A test checks that the tool contains no command that could change the system.

1. **Report** gives the system, load, memory, every disk and its inodes, the busiest processes, failed services, listening ports, clock sync and whether a reboot is needed, with the **findings (warnings first)** in the summary box. **Disk** shows where the space went under a folder; **Services** shows failed units and the state of units you name (`units=apache2,ollama` in the extra arguments); **Ports** lists what listens and warns when a port open to the network is one that usually should not be (VNC, SMB, NetBIOS, databases, Redis, memcached, the Docker API, Ollama).
2. **Log reader** digests any log file you give (the last 20 MB): counts by severity, the most repeated errors with numbers masked, and known trouble: out of memory, disk full, I/O errors, crashes, password guessing. **Journal** groups this boot's errors by program (the account must be in the group `adm` or `systemd-journal`).

To fix something, run the commands yourself with the findings in hand: the agent is told to write them out and say how to undo each, not to run them.

## Shell scripts tools {#shell-tools}

The **Shell scripts** tool (the *Shell and DevOps* kind uses it) reads scripts and systemd unit files and **never runs them**. Give it a script or a folder; scripts are found by their extension or their `#!` line.

1. **Check** runs ShellCheck and lists each finding as `file(line,column)` with its code (`SC2086` and so on); **Syntax** asks bash, sh or dash only to parse (`-n`) the file, which executes nothing.
2. **Scan** looks for risky patterns: `rm -rf` on a variable that may be empty, `curl | sh`, `eval`, unquoted `$@`, `sudo` inside scripts, `chmod 777`, no `set -e`/`-u` and similar. **Unit** checks a `.service` file with `systemd-analyze verify`.

## E-book tools {#ebook-tools}

The **E-book** tool (the *E-book publishing* kind uses it) builds and checks EPUB files.

1. **Check** runs EPUBCheck (needs Java) and lists errors as `file(line,column)`; **Inspect** shows what is inside: title, language, author, chapters, images, and what is missing.
2. **Build** turns a folder of Markdown chapters (with optional `metadata.yaml`, `style.css` and `cover.jpg`) into an EPUB 3 with a table of contents. Before building, the tool **refuses a book that points outside its own folder** (absolute or `..` paths, remote images, raw HTML `src`/`href`, a stylesheet elsewhere), so a book cannot pull private files into the result. **New book** writes a skeleton.

## 3D printing tools {#scad-tools}

The **3D tools** (the *3D printing* kind uses them) work with OpenSCAD models and STL files. A `.scad` file can read files, so OpenSCAD only ever runs **inside a bubblewrap sandbox**: no network, no home folder, the system read-only, and a scratch copy of your model as the only writable place. If bubblewrap is missing the tool refuses to run.

1. **Check** compiles the model and lists errors and warnings as `file(line)`, plus whether the result is a valid solid. **STL / 3MF / PNG** export. **Parameters** lists the numbers at the top of a model (with their groups and comments) so you can change them.
2. **Info** and **Print check** read an STL (ASCII or binary) or a model: size, volume, watertight or not, inside-out triangles, overhang share, and whether it fits your bed (give `bed=220x220x250`). It is arithmetic on the mesh, not a slicer. **New part** writes a parametric box.

## Electronics tools {#kicad-tools}

The **Electronics** tool (the *Electronics* kind uses it) reads KiCad 7 or 8 schematics and boards. KiCad 7's command line has no ERC or DRC, so **Check** is a *lite* check made by reading the file (duplicate or unannotated references, parts with no value or footprint, lonely net labels, no board outline, footprints off the board, very thin tracks and small vias) — run the real ERC/DRC in KiCad before you order boards. **Info**, **BOM** (CSV, identical parts grouped), **PDF**, **Netlist**, **Gerbers** (with drill files, zipped) and **Placement** use the real `kicad-cli` on a scratch copy.

## Hugo site tools {#hugo-tools}

The **Hugo** tool (the *Documentation site* kind uses it too) builds a Hugo site inside the same kind of sandbox: no network, no home folder. **Check** builds into a scratch folder and reports errors with the template file and line; **List** shows every page with its date and whether it is a draft or expired; **Build** gives a zip of the finished site (drafts excluded); **New site** writes a small site with plain layouts and no theme.

## Arduino tools {#arduino-tools}

The **Arduino** tool (the *Arduino and embedded* kind) never downloads anything. **Lint** and **Info** read the sketch only: a missing `setup()`, `Serial` without `Serial.begin`, `digitalWrite` without `pinMode`, work inside interrupt handlers, `String` use, text that should be in `F("...")`, and arrays that eat the RAM. **Compile** needs the board's core: if it is missing, the result says so and prints the exact commands for **you** to run (for example `arduino-cli core install arduino:avr`), then compile with `fqbn=arduino:avr:uno`. **Cores** shows what is installed. **New sketch** writes a blink that uses no `delay()`.

## Creative writing tools {#writing-tools}

The **Creative writing** tool (the *Creative writing* kind uses it) reads a manuscript: give a chapter file or a folder of `.md`/`.txt` chapters (in name order). It points at places to look; you and the agent decide, and nothing is changed or run.

1. **Statistics**: words, sentences, paragraphs, how much is dialogue, the share of `-ly` adverbs, the English reading level and the very long sentences, per chapter.
2. **Repeated phrases** finds phrases of four words used three times or more and a word used again within six words, each with its file and line. Some are on purpose, such as a refrain.
3. **Names** counts the capitalised names and flags the ones spelled almost the same (Catherine and Katherine), which are often a slip in a long manuscript. A name that starts a sentence is not counted, because its capital is grammar.

Every kind now names the tools it works with, except *General*, which names none on purpose: the audio and video, document, image, translation, Lazarus, learning, research and writing kinds were the last ones without any.

## Translation tools {#translate-tools}

The **Translation** tool (the *Translation* kind uses it) translates whole files with the **LibreTranslate that runs on your own machine**: no cloud, no key, the text goes nowhere else. Put the target in the extra arguments, `to=he` (or `en`, `es`, ...; `from=auto` by default). The kind of file is read from the input's extension: **.md** keeps headings, lists, quotes, front matter and code blocks; **.srt** and **.vtt** keep cue numbers and times and translate only the words; **.txt** is translated paragraph by paragraph.

Code, `inline code`, URLs, link targets, HTML tags, `{placeholders}` and `%s` are **never sent for translation** and come back exactly. If a machine translation loses one of them (or the brackets of a link), **that line is left in the original language and reported** with its line number, never a half-broken line; a report is written next to the output (`.report.md`). Right-to-left lines that mix code and links most often need a second look. **Check** says whether LibreTranslate answers; **Languages** lists what it has.

## Image generation tools {#imagegen-tools}

The **Image generation** tool (the *Image generation* kind uses it) makes pictures with the local stable-diffusion.cpp, the same one as the Generate window, from a prompt you keep in a **text file** (so it can be edited and versioned). **Make an image**, **Logo**, **Icon** and **Favicon** add the matching style; **Variants** makes 2 to 6 seeds of the same prompt as one contact sheet. Extra arguments: `steps=20`, `seed=N`, `size=512x512`, `negative="blurry, text"`. Every image gets a **`.prompt.json` next to it** (prompt, preset, steps, **seed**, size, model): the record that lets you make the same picture again or change one thing. Sizes are capped at 512 per side because a 4 GB GPU runs out of memory above that, and Ollama's models are released from the GPU first. The prompt is read as text and the program is started without a shell, so nothing in a prompt can run. **Check** says whether it is installed and which model it will use.

## Legal review tools {#legal-tools}

The **Legal review** tool (the *Legal review* kind uses it) reads contracts the way a careful reviewer does. It is a reading aid, **not legal advice**: it finds what to look at and a lawyer decides. Give a `.docx`, `.odt`, `.pdf` (with a text layer), `.rtf`, `.txt` or an older office file. Wording in several languages (more can be added) is recognised, and the original is never changed.

1. **Compare two versions**: the input is the old version and the new one goes in the extra arguments as `with=/path/to/new_version.docx`. The result is a redline (~~removed~~, **added**) with the changed clauses in order, and **the points to check first**: a changed figure or date (number words such as "thirty" count), *shall* becoming *may*, a negation, *and*/*or*, *any*/*all*, a removed or added paragraph, each with its line in the new document.
2. **Check the document** finds placeholders left in (`[•]`, `____`, `TBD`), references to clauses that do not exist, gaps in the clause numbering, defined terms never used, capitalised terms that look defined but are not, a number in words that disagrees with the figure ("sixty (30)"), and mixed date formats, with the line of each, in the same summary box as the Pascal tools.
3. **Clauses** outlines the numbered clauses and where each is referred to. **Key terms** pulls out money, percentages, durations, dates and the paragraphs on governing law, term and termination, payment, liability, confidentiality and assignment; "nothing found" for a topic may mean a clause is missing. **Plain text** extracts the text for reading.

## Bookkeeping tools {#books-tools}

The **Bookkeeping** tool (the *Bookkeeping* kind uses it) works on a CSV ledger or a bank export. Columns are found by name in several languages (more can be added): date, description, amount or debit and credit, category, invoice, tax, currency; amounts such as `1,234.56`, `1.234,56`, `(12.50)` and `12.50-` and Windows-1252 or 1255 files are read. It is plain arithmetic on your own data, not accounting or tax advice.

1. **Check the ledger** finds unreadable dates and amounts, future dates, duplicates, zero amounts, an amount more than eight times the usual for its category, repeated invoice numbers, rows with no category, gaps in the invoice numbers and mixed currencies, with the line of each.
2. **Summary** gives income, expenses and net, by category and by month, and the biggest payees (type `positive=expense` in the extra arguments if a positive amount in your file means money spent). **Reconcile** takes the bank file as `with=/path/to/bank.csv` and lists what matches (same amount, dates within three days), what is only in the ledger and what is only in the bank file.
3. **Tax by rate and by quarter** totals the tax inside gross amounts: a column called "tax rate" (or numbers with a `%`) holds rates, any other tax column holds tax amounts. Free-form questions on the same file are in the Data analysis tool.

## PHP project tools {#php-tools}

The **PHP projects** tool (the *PHP project* kind uses it) checks a project by reading it: nothing is run or included, and `vendor/`, `node_modules/` and `.git/` are skipped.

1. **Syntax check** runs `php -l` on every file with this machine's PHP, each error as file and line, with **Fix with agent**. **Security scan** lists candidates: command and code execution with request data, SQL built from request data, unescaped output, include of request data, `unserialize`, removed functions, TLS checks switched off, weak hashes and randoms, hard-coded secrets. It works by patterns: expect false alarms, and a person decides.
2. **Guard check** lists the scripts that read a request but do not include your auth file (`auth=login_check.php` in the extra arguments if it is not `auth.php`): the kind of endpoint that answers with no login check. **Outline** lists classes, functions and methods with their line. **Minimum PHP version** finds the oldest PHP the code needs from its language features.

## Podcast tools {#podcast-tools}

The **Podcast audio** tool (in the Tools list; the *Podcast* project kind uses it) prepares a recording for publishing. Give the audio file as the input; the original is never changed.

1. **Check** measures the episode against podcast norms: integrated loudness (-16 LUFS for stereo, -19 for mono, give or take 2), true peak (under -1 dBTP), loudness range, silence at the start and end, long pauses, sample rate and bit rate. Problems come back with the second they occur, in the same summary box as the Pascal tools.
2. **Normalise loudness** brings the episode to the podcast level (-16 LUFS stereo, -19 mono) in two passes without clipping (to MP3 or M4A). **Clean up the voice** adds a high-pass at 80 Hz, noise reduction and light compression first. **Trim silence** cuts both ends and shortens every pause over 2 seconds to 0.8.
3. **Chapters** lists every pause of 3 seconds or more as a candidate chapter point. **Set the tags** writes title, artist, album and more without re-encoding: type `title=Episode 12;artist=Dario;album=My Show` in the extra arguments.

The transcript and show notes come from **Transcribe to SRT** in the Whisper tool; the Meeting notes tool can clean and structure them.

## Meeting notes tools {#meeting-tools}

The **Meeting notes** tool (the *Meeting notes* kind uses it) works on a transcript: plain text (one utterance per line, optionally `Name: ...`) or an `.srt`/`.vtt` from the Whisper tool.

1. **Clean transcript** joins the cues into timestamped paragraphs (a new one at a pause, a new speaker or every minute) and removes fillers (um, uh, eh and their equivalents in the supported languages) and stuttered repeats.
2. **Candidates** finds sentences that look like a decision, an action item (with the owner when the line names one), a deadline or a question, in several languages (more can be added), with where each was said. It works by wording only: check each against the recording.
3. **Statistics** gives the length, words, pace, questions and, for `Name:` lines, each speaker's turns, words, share and longest stretch. **Minutes skeleton** writes a markdown document to fill in: attendees, agenda, decisions, an action table, open questions. **Markdown to DOCX** (Pandoc tool) makes the Word version.

## Everyday-life tools {#life-tools}

Sixteen project kinds are for ordinary life and work rather than software. Each has a small tool that does real arithmetic and checking on plain files (text, CSV) in your project; none of them changes your original, none looks anything up on the internet, and all say what they assumed. Where a field touches health, money, law or safety, the tool and the kind's standing note say that the result is arithmetic on your numbers, not advice.

- **Cooking and recipes** (*Recipes* tool): scale a recipe to any number of servings (fractions are kept), convert cups, spoons, grams, ounces and degrees (volume to weight is marked as an estimate), merge several recipes into one shopping list grouped by aisle, and check a recipe for missing quantities and allergen words (read the labels as well).
- **Gardening and plants** (*Garden planner*): say your hemisphere and get a sowing and harvest calendar from your plant list, how many plants fit a bed, a checked garden log and a day-by-day to-do list.
- **Pets and animals** (*Pet care*): what is due or overdue from a care log, vaccinations against the schedule you type in, weight trend and the feeding amount read off your package table. Not veterinary advice.
- **Health and fitness log** (*Health log*): check a training plan for rest days and jumps in weekly volume, total a food diary from the numbers you wrote, track appointments and measurements. Not medical advice; it never diagnoses.
- **Collections** (*Collections*): a catalogue of books, coins, stamps, cards or records with your own columns: missing fields and duplicates, a comparison with your want-list, a summary and an insurance valuation sheet totalled from the values you wrote.
- **Genealogy and family history** (*Genealogy*): impossible dates in a tree (a child born before a parent), people entered twice, descendants or ancestors as a tree, ages and anniversaries. A CSV or a GEDCOM file.
- **Hobby crafts** (*Hobby crafts*): pack parts into boards with saw cuts, estimate yarn and fabric from your own swatch, check a pattern's rows and stitch counts, total materials and cost.
- **Tabletop games and role-play** (*Tabletop*): repeatable dice rolls, exact odds, initiative order, a character sheet checked against rules you give it, and an index of the people and places in your campaign notes.
- **Travel planning** (*Travel planning*): an itinerary checked for impossible or tight connections and nights without lodging (time zones included), a budget in your own exchange rates, a packing list.
- **Personal finance and taxes** (*Personal finance*): budget against actual spending, regular payments found in a bank export, tax documents still missing from a folder, loan and savings projections.
- **Home and DIY** (*Home and DIY*): paint, flooring, concrete and lumber quantities, a job estimate with contingency, overdue maintenance. Electrical, gas and structural work is for licensed people.
- **Real estate and rentals** (*Real estate*): overdue rent and leases ending soon, yield, mortgage payment and cash flow, a listing checked for missing facts and claims nobody can verify.
- **Teaching** (*Teaching*): a lesson plan whose minutes add up and whose objectives each have an assessment, a rubric whose weights total 100, a gradebook summary, a worksheet checked against its answer key.
- **Job search and CV** (*Job search*): date gaps and weak phrasing in a CV, the words of a job ad it honestly lacks (it never adds a skill you do not have), an application tracker with follow-ups due, interview questions from the ad.
- **Non-profit and events** (*Non-profit and events*): double-booked volunteers, uncovered shifts, a run-of-show timeline, budget against actual, grant sections over their word limit.
- **Music practice and songbook** (*Songbook*): practice minutes against a goal, a set list checked for length and flow, chord charts transposed with a capo suggestion, lyric sheets checked for missing verses, a songbook index ready for Pandoc. Notation and engraving stay in the *Music scores* kind.

Problems come back as `file(line)` with **Fix with agent**, like the other tools.

An agent can also run these tools itself with a marker such as `%%TOOL:recipe:scale:pancakes.md|servings=8%%` (extra arguments after a `|`; a relative path means a file of the project). If the tool refuses, its own message comes back in the chat, for example *give the number of servings wanted*, so the agent can correct the call. Small local models often get the marker wrong: the **Tools** dialog, where you pick the preset yourself, is the dependable way to run them.

## Language study tools {#lang-tools}

The **Language study** tool (the *Language study* kind uses it) is built around a vocabulary list: one entry per line, term and translation separated by a tab, `;`, `,`, ` - ` or `: `, an optional example sentence and optional tags, in UTF-8.

1. **Check the vocabulary list** finds a term with no translation, repeats, the same text on both sides, invisible characters and very long entries, with the line of each.
2. **Anki cards** writes the file Anki imports (File > Import), with an optional `both` for reverse cards. **Word frequency** ranks the words of a text so you learn the useful ones first (vowel marks are ignored) and says how many words cover 80% of it.
3. **Listen** makes an audio file that says the term, pauses for you to answer, then says the translation: type `term=fr trans=en pause=2 max=100` in the extra arguments (Piper is used where a voice is installed, otherwise eSpeak-NG).
4. **Compare my reading with the text** takes a recording and, in the extra arguments, `text=/path/to/expected.txt lang=en`. Whisper transcribes it and the report lists the words said differently, not heard or added. It shows what Whisper understood, not a pronunciation score.

## Document formats tools {#office-tools}

The **Document formats** tool (in the Tools list; the *Document formats* project kind uses it) moves office files between Microsoft Office (`doc docx docm xls xlsx xlsm ppt pptx pptm`), LibreOffice and OpenOffice (`odt ods odp`, `sxw sxc sxi`), RTF, CSV, Gnumeric, and what LibreOffice reads of AbiWord, WordPerfect and Apple iWork, in both directions. Give the file as the input; the converted file is the output. A text document cannot become a spreadsheet or the other way round: that is refused with the reason.

**Macros are the point.** VBA macros do not survive every conversion: LibreOffice drops them silently going to `.doc`, `.docx` or `.xlsx`, and its own Basic never becomes VBA. So:

1. **A conversion that would lose macros is refused**, and nothing is written. The message names the modules and says which formats keep them (`.xlsm`, `.xls`, `.ods` for spreadsheets; `.docm`, `.odt` for documents). Type `drop-macros` in the extra arguments to convert anyway.
2. **Macros** lists every module in any file (VBA, LibreOffice Basic, Python): its size, the procedures that run by themselves (`Auto_Open`, `Workbook_Open`, ...) and the risky calls (`Shell`, `CreateObject`, downloads, deleting files). **Extract the macros as text** writes them all into one UTF-8 file with a header per module (accents and non-Latin letters decoded from the file's code page), for reading, reviewing and porting. The macros are only read, never run.
3. **Put a macro module into an .ods / .odt / .odp** adds Basic or VBA source (a `.bas` or `.txt` file named in the extra arguments) as a new module of a LibreOffice document, so it runs there (VBA source gets `Option VBASupport 1`). It never replaces a module.
4. **Inspect** counts what is inside: sheets, formulas, pictures, comments, tracked changes, links to other workbooks, pivot tables, protection, macros, and says what a conversion could lose. **Verify** converts to another format and back, then compares the text (documents) or the cell values (spreadsheets) and the macros.

Every conversion runs in a throw-away LibreOffice profile with macro security at its maximum, so your own LibreOffice settings are never touched and no macro is executed. Macros from a Microsoft file are read by Cockpit's own reader, which has been checked against LibreOffice's but not against a file made by Microsoft Office itself.

## Academic paper tools {#latex-tools}

The **LaTeX papers** tool (in the Tools list; the *Academic paper* project kind uses it) writes, builds and checks a paper in LaTeX. Give the main `.tex` file, or the project folder.

1. **Check** builds the paper in a scratch copy and reads the log for you: errors with file and line, undefined references and citations, lines that run more than 10 pt into the margin, characters missing from the font, and a missing TeX package named together with the `apt` package to install. It uses the same summary box as the Pascal tools, with **Fix with agent**.
2. **Build the PDF** compiles to a PDF: the engine is chosen from the preamble (`pdflatex`, or `lualatex` for Unicode-font papers (Arabic, Hebrew, CJK, ...)), bibtex and as many passes as the cross-references need are run. The project folder is never written to, so no `.aux`, `.log` or `.pdf` litters it.
3. **Check the bibliography** compares every citation key with the `.bib` files: a citation with no entry, a key defined twice, an entry with no author, title or year, an entry that is never cited.
4. **Word count** counts the words of the text by section, without maths, commands or the bibliography. **New paper** creates a starter article with a bibliography (it builds with only `texlive-latex-base`). **LaTeX to Word** and **Markdown to LaTeX** convert with pandoc.

Papers from somewhere else are safe to build: TeX runs with file access restricted to the project (no absolute paths, no `..`) and shell escape off, so a paper cannot read your files or run commands.

**What you need installed:** a TeX Live. The installer asks (none, **recommended** by default, or full) and `bash Installs/install_tex.sh recommended` (or `full`, or `--dry-run` to see the size first) does it later. **Recommended** (about 22 MB to download) is what most papers need: `xcolor`, `booktabs`, `hyperref`'s `etoolbox`, `microtype` and the standard fonts. **Full** (about 217 MB to download, 640 MB on disk) adds LuaTeX with `fontspec` for Unicode-font papers, `biber` for `biblatex`, `latexmk`, `bibtex-extra` and the extra packages. `texlive-latex-base` alone builds only the starter paper. A paper that needs a package that is not installed is told which one and how to install it. On Fedora, Arch and openSUSE the package names are best effort and untested; on macOS install MacTeX or BasicTeX yourself.

## Presentation tools {#slides-tools}

The **Presentations** tool (in the Tools list; the *Presentation* project kind uses it) makes, reads and checks slide decks: `.pptx`, `.odp`, and older `.ppt` (read through LibreOffice). The original deck is never changed, and macros in a deck are neither read nor run.

1. **Markdown to PowerPoint** builds a `.pptx` from a markdown file with pandoc: a `#` heading starts a slide, bullets are the content, a `::: notes` block is the speaker notes, and `![description](picture.png)` is a picture. Keep the markdown as the source: an agent edits text well and binary decks badly. A missing picture file stops the build and names the file.
2. **Check the deck** finds what a good deck avoids: a slide with no title or no content, more than 50 words on a slide, a line of more than 25 words, text under 14 pt, a picture with no description (alt text; a file name or "Picture 1" does not count), more than three fonts, repeated titles and missing speaker notes. Problems come back with the slide number in the same summary box as the Pascal tools, with **Fix with agent**.
3. **Outline** lists every slide's title, text, notes and pictures as markdown: the way for an agent to read a deck.
4. **Contact sheet** draws every slide as a thumbnail on one picture, to see the deck at a glance.
5. **Deck to PDF**, **Deck to .odp** and **Deck to .pptx** convert through LibreOffice in a throw-away profile (so your own LibreOffice settings are never touched, and macro security is at its maximum). A deck's macros are not carried into the result.

## Subtitling tools {#subs-tools}

The **Subtitles** tool (in the Tools list; the *Subtitling* project kind uses it) works on `.srt`, `.vtt` and `.ass` files. Give the subtitle file as the input. The original is never changed, and the text of the cues (tags, non-Latin text, right-to-left marks) is carried through untouched.

1. **Check** lints the file the way a broadcaster would: times that cannot be read or run backwards, cues that overlap or are out of order, empty cues, lines over 42 characters, more than two lines, text shown faster than 20 characters a second, cues shorter than 0.83 seconds or longer than 7, and whether the file is UTF-8. Each problem comes back with its line in the file, in the same summary box as the Pascal tools, with **Fix with agent**.
2. **Convert to SRT / WebVTT / ASS** goes between the formats (through ffmpeg).
3. **Shift or stretch the times** moves every cue. Type the amount in the extra arguments: `+1500` or `-800` for milliseconds, `2.5s` for seconds, or a stretch for a frame-rate mismatch, `*1.04271` or `*25/23.976`. A cue that would start before zero is set to zero, and one that would end before zero is dropped and counted.

To make subtitles from the sound, use **Transcribe to SRT** in the Whisper tool; to put them into the picture, **Burn subtitles** in the ffmpeg tool. Then check the result here.

## Godot tools {#godot-tools}

The **Godot** tool (in the Tools list; the *Godot* project kind uses it) runs the real Godot 4 engine headless, with no editor window, so it can judge a game project the way a compiler judges code. Give the project's folder (the one with `project.godot`) as the input.

1. **Check scripts** parses every GDScript of the project (the `addons` folder is skipped) and lists each error as file and line. Give one `.gd` file instead to check only that script. The same summary box as for Pascal appears, with **Fix with agent**, which puts the errors in the prompt box. This is the check the agent should run after every edit.
2. **Run headless for a few seconds** starts the main scene without a window for N seconds (type N in the extra arguments; 5 by default, 60 at most) and shows what it printed, including runtime errors. It is for game logic, not for graphics.
3. **Export presets** lists the presets in `export_presets.cfg`.
4. **Godot version of the project** compares the version in `project.godot` with the installed engine. A Godot 3 project cannot be opened by the Godot 4 binary; this tells you before you try.

Nothing in your project is changed except Godot's own `.godot` cache folder. Godot is not installed by Cockpit: fetch the official Godot 4 Linux build (the standard one, not .NET) from godotengine.org and put the binary at `~/.local/share/cockpit/tools/godot/godot` (no administrator rights needed). Cockpit also finds a `godot` on the PATH.

## Castle Game Engine tools {#castle-tools}

The **Castle Game Engine** tool (in the Tools list; the *Castle Game Engine* project kind uses it) drives the engine's own `castle-engine` build tool and the Free Pascal compiler. Give the project's folder (the one with `CastleEngineManifest.xml`) as the input.

1. **New game project** creates a project from the engine's empty template in a subfolder of the folder you give; type the name in the extra arguments. It never overwrites.
2. **Check** compiles the whole game, engine included, into a throw-away folder and changes nothing in your project. It takes about 40 seconds because the engine is compiled each time. Errors come back as file, line and column, in the same summary box as the Pascal tools, with **Fix with agent**.
3. **Compile** builds the game's executable into the project. The first build compiles the engine (about 40 seconds); later ones only what changed.
4. **Clean** removes the build leftovers. **Package** writes a Linux archive beside the project and can take minutes.
5. **Engine, compiler and project manifest** shows the versions in use and the manifest.

The engine is not installed by Cockpit and is not part of it. Fetch the official Linux x86-64 release (about 715 MB) from the engine's GitHub releases page and unpack it into `~/.local/share/cockpit/tools/castle/`, so that `castle_game_engine/bin/castle-engine` exists (no administrator rights needed). It needs `fpc` as well. The engine is licensed LGPL with a linking exception and its tools GPL: fetch it for your own use, do not redistribute it with Cockpit.

## VB6 migration tools {#vb6-tools}

The **VB6 migration** tool (in the Tools list; the *VB6 migration* project kind uses it) prepares a Visual Basic 6 project for porting to Free Pascal and Lazarus. Give it the project's folder, the one with the `.vbp`. It never changes your originals.

1. **Encodings of the sources** (read-only) tells you the encoding of every text file (`.vbp`, `.frm`, `.bas`, `.cls` ...), how sure it is, and which files a person should look at, with the same lines decoded each way so you can see which reads as words. VB6 files are ANSI: Windows-1252 for Western European accents, Windows-1251 for Cyrillic, Windows-1255 for Hebrew; the form font's charset is used as a tie-break.
2. **Convert to UTF-8 copies** writes a complete copy of the project in the sibling folder `FOLDER_utf8` (it refuses if that folder already exists), with the `.frx` binaries and every other file copied along unchanged. Port from the copy, never from the originals.
3. **Verify the round trip** converts the copies back to the original encodings and compares them with the originals byte for byte: if every file is identical, nothing was lost; if one differs it tells you which byte and line, so a wrongly guessed encoding is caught before it costs you a day.
4. **Project inventory and port order** lists the forms, modules and classes, the references and OCX controls (each needs a replacement), the Windows API declares, the controls used with their Lazarus equivalents, and per file the places where VB6 and Pascal behave differently (16-bit Integer, Currency, Variant, `On Error`, `GoSub`, `Option Base`, COM objects, database objects ...), in an order to port in: leaf modules first, then classes, then forms.
5. **VB6 to Pascal cheat sheet** prints the mapping tables for you and for the agent.

There is no automatic translator: the agent translates one file at a time, you build with the Lazarus tool after each, and the compiler judges. The tools give you clean sources, a map and a checker.

## Standards check for Lazarus projects {#standards-check}

In the file viewer, a Pascal or Lazarus file shows a **Standards** button. It checks the whole project --- read-only --- against four house rules: **text typed into code** (captions, hints, dialog and exception messages written straight into the source or a form instead of a `resourcestring`), **Windows-only code** (units such as Windows or ShellAPI, API calls, drive-letter paths and a typed backslash outside an `{$IFDEF MSWINDOWS}` block), **a dark/light switch** (does the project mention one at all) and **comment density** (units under 5% comment lines). Comments and string contents are read properly, so a rule never fires on a comment. **Copy a resourcestring unit** gives you a ready unit holding every typed string; your project is not changed. The same check runs from a terminal with `php pascal_standards.php DIR`. It is a static scan: it finds what it can see in the text and says nothing about whether the program works.

## Redesign mode {#redesign-mode}

**REDESIGN**, beside PLAN under the prompt box, restructures a project in small steps that you approve and can undo. Type what should change --- *split the main unit*, *take the database code out of the form* --- and press it. You need a project open and a model agent selected (it uses the one you picked).

1.  **Proposal.** The agent is asked for a written proposal only --- structure now, problems, structure after (a before → after list of moves), numbered steps, risks --- and told to change nothing. It appears in the chat and is saved in the project as `redesign/PLAN-<time>.md`.
2.  **Approval.** You see the steps and can untick any. Nothing runs until you press *Start step by step*. If the agent did not write its steps as `Step N: …`, Cockpit says so and asks you to request that form, rather than guessing at prose.
3.  **One step at a time.** Before each step Cockpit takes a **checkpoint** of the project files; the agent does only that step and checks the build the way the project kind says, then reports. You choose *keep it, next step*, *stop here*, or *undo this step* --- the project goes back to the checkpoint (files changed come back, files added since are removed, and a safety checkpoint of what you undid is kept).

Honest limits: checkpoints are file snapshots, not git, so your own repository is never touched; they skip `.git`, `lib`, `backup` and compiled output, and a project over 300 MB is refused. The agent --- not Cockpit --- runs the compiler, so a step is only as checked as the agent's report says; there is no automatic repair loop yet. Checkpoints live in `cockpit_data/checkpoints/<project>/`.
## Backup and restore {#backup-restore}

The **Backup** button in the Toolbar makes one archive of your settings, library, chats and projects --- a plain `.tar.gz` you can open without Cockpit --- under `cockpit_data/backups/`. Use it before a reinstall, a move to a new machine or a risky change.

-   **Test** restores the archive into a scratch folder, compares every file with the checksum recorded when it was made, and deletes the scratch folder. A backup you have not tested is a hope, not a backup.
-   **Restore** puts the files back over your current data. It first saves the current state as a *pre-restore* backup, so a restore can itself be undone, and it refuses an archive that fails its own checksums.
-   **Download** gives you the file, to keep off this machine too.

Left out because they can be rebuilt: the Shelf index, the Python environments, installer copies and caches. API keys and the account file are left out unless you tick them. Archives carry a *data version*; when a later build changes how data is stored, restoring an older archive migrates it (today there is only version 1). Chats can also still be exported one at a time as Markdown and JSON from the chat menu.

## Personal archive {#personal-archive}

The **Archive** button files your own papers --- warranties, invoices, insurance, contracts, IDs, manuals --- as searchable Library items and shows what is due soon. Pick scans, photos or PDFs and press **Add**. Each is read **on this computer**: text PDFs with `pdftotext`; scans and photos with `tesseract` if it is installed, otherwise a local vision model (about 20 seconds a page; it needs a vision model such as gemma3:4b in Ollama). Nothing is sent to an online service. If nothing can read a scan the file is still kept, marked *not read*.

Cockpit works out a type, the amounts, and a **due date** --- the date written beside words such as *expires*, *valid until* or *renew*; a document with no such date gets none. These are guesses and are editable on the row. The text goes into the Library tagged `archive`, so searching the Library, or asking in chat with Library context, finds it. *Due in the next 60 days* is worked out when you open the dialog; no background job runs, so Cockpit does not remind you unless you look. Originals are kept under `cockpit_data/archive/` and are included in a Backup.
## Terminal, Files, Browser {#terminal-files-browser}

Three toolbar buttons open tools without leaving Cockpit:

-   **Terminal** --- the **command window** (below): one simple command at a time, confined to your Public folder.
-   **Files** --- the **file window** (below): a small desktop-style file manager.
-   **Browser** --- opens the **Cockpit Browser**: Cockpit's own small web window (the same WebKit as the app), which is **the default browser on every system**, because it starts in about a second and Cockpit controls it. Useful for checking docs, testing local dev servers, or viewing generated HTML. Your own browser stays installed and is used only when the Cockpit window is not available on the machine, or when you pick it yourself in the **Apps** panel (an explicit choice there always wins). In the same spirit the **terminal and the file manager** are the system's own ones; Cockpit's own versions are only a fallback for machines where those are missing or locked, until they are mature enough to be the default too.

The file window and the command window are real floating windows: drag them by the title bar, resize from any edge or corner, minimise (they wait as small buttons at the bottom of the screen), maximise (double-click the title bar), close. Each remembers where you left it. On a narrow screen they open full-size. The small monitor button in a window's title bar opens the *system's own* file manager or terminal, when this machine has one.

### The file window {#file-window}

Your own folder is **Public**, inside your projects folder (it is not a project, and never appears in the project list). Everything works there: new folder, new file, rename (F2), move (drag and drop), copy (Ctrl+C, Ctrl+V), upload (drag files in from your computer, or the upload button), download, and delete. Delete moves things to the **Trash**; delete inside the Trash is permanent, and "empty the trash" clears it. A file you upload under a name that exists gets the next free name, `name (2).ext`.

Everything else is **read-only**: your project folders (the *Projects* place) and any area an admin added. You can look, open (pictures, PDF, audio, video and text open in a viewer window), download, and **copy into Public**. You cannot create, change, move or delete anything there. A lock mark shows which places are read-only.

Other keys: arrows, Enter (open), Backspace (up), Delete, Ctrl+A, Ctrl+Shift+N (new folder), F5 (refresh), Ctrl+L (type a path), and right-click for a menu. On the machine itself, the menu also offers *Open with the system*, which uses the system's default application. It starts the program and leaves it running (earlier it was closed again after six seconds). In Public, the menu also offers **Edit** for text files up to 1 MB. It opens Cockpit's own code editor (the one used for project files: colours, line numbers, Ctrl+F find and replace); Save writes the file back.

Symbolic links are never followed, so a link inside Public or an area cannot lead anywhere else on the disk; `..` in a path is refused. An admin can add read-only areas (a file `fm_areas.json` in the shared data folder, or the `areas_set` call); an area the account running Cockpit does not own is not shown at all. A viewer account can look and download but not change anything. Every change, and every refused attempt, is written to `fm_audit.jsonl` in the shared data folder with who did it.

### The command window {#command-window}

Type a simple command and see what it printed. It is **not** a full terminal: one command line at a time, no full-screen programs (nano, vim, top), nothing that asks for input or a password. `cd` changes the folder between lines, Up and Down bring back earlier commands, `help` explains the limits, `clear` empties the window. The line goes to the shell, so pipes, redirects and `&&` work, and so does any program installed in the system's program folders: for example `ls -la`, `cat`, `head`, `grep -rn word .`, `find . -name "*.txt"`, `wc -l`, `sort`, `sed`, `awk`, `diff`, `tar`, `zip`, `git status`, `date`, `df -h`, `ps aux`, `top -bn1`, `curl` (the network is not restricted), or a compiler on a file in Public. What you cannot do: write outside Public, read outside the places listed below, become another user (`sudo` does nothing), or leave a program running after the 20 seconds.

What confines it is the operating system, not a list of allowed words: the command runs as the account that runs Cockpit, and the kernel (Landlock) lets it **write only in your Public folder**, read your project folders and the usual system programs, and see nothing else on the disk. It gets a small fixed environment (none of Cockpit's own secrets), 20 seconds and 256 KB of output per command, and it cannot gain privileges. Network access is **not** restricted. If a machine cannot confine commands (not Linux, or a kernel without Landlock) the window says so and runs nothing: there is no unprotected mode. Viewers cannot run commands.

Both windows need the engine's service (`cockpit_engine`), which the process supervisor hosts. Until the agents are started, the windows say that the service is not running. The status bar's runtime chip shows whether it is. These windows are not available in the web demo, where a short notice describes them. A dedicated low-privilege account and a Windows version of the confinement are not built yet.

## Accumulator

Extracts reusable knowledge from PDFs and documents using a local pipeline:

1.  **Extract** --- PDF → text (pdftotext, tika, or Ollama OCR fallback)
2.  **Chunk** --- split into overlapping segments
3.  **Summarize** --- Ollama generates a summary per chunk
4.  **Store** --- results saved as JSON for retrieval

Panel tabs: Queue (pending files), Results (processed documents), Health (pipeline checks). Click **Run** to process. Progress is shown live.

## Power Buttons {#power-buttons}

A **Power Button** is a saved prompt you run with one click on text you copied: proofread it, summarise it, make it polite, explain an error message. Cockpit applies your prompt through the supplier you chose and puts the answer where you want it — without you opening a chat.

**Make one.** Toolbar → **Power Buttons**. **Add** one of the starters (*Proofread*, *Make it polite*, *Summarise*, *Explain this*, *Plain language*, *Shorter*) or choose **+ New button**. A button has:

-   an **icon** and a **colour** — choose the icon by looking at it: **Change…** opens a picker with common icons and a search over all of them (type a word such as *mail* or *heart*, or an idea such as *write*, *fix*, *translate* or *shorter*), the same picker the *New kind* dialog uses;
-   a **prompt** — what the AI should do. The copied text is added below it automatically, under a line of dashes and a sentence saying it is data to work on, not instructions. `{clipboard}` in your prompt reads as "the text below the line"; `{date}` is today's date;
-   the **supplier** that answers — **a model on this computer** by default (nothing leaves the machine, no key, no cost), or any enabled cloud worker;
-   the **input** — what you copied, what you selected, **a picture you copied**, a file, or nothing. A picture needs a model that can look at one: a picture-capable model on this computer (for example *llava* or *gemma3*; Cockpit picks an installed one), or Anthropic as the supplier;
-   the **output** — the clipboard, a notification, a file, or the panel;
-   **Ask before sending** — for a supplier outside your computer: the first time for each supplier, every time, or never.

**Run it.** The quickest way: once you have a button, a row of them appears **between the prompt and the status bar** under *Power Buttons:* (the chat panel above gives up one row for it). Until you have your first button, that row shows a one-line hint with an **Add one…** button; the **×** at its end hides the hint for good. The **Mode** and **Style** rows above the prompt are always exactly one line: in Pipeline, Broadcast or Plan mode their extra controls scroll sideways (mouse wheel, or the thin bar) instead of making the row taller. Copy something, click the button, and the answer appears in a small card at the bottom right (with **Copy the answer**, and **Save as a file** for a button whose output is a file); a button whose output is the clipboard copies it for you. If your browser will not let Cockpit read the clipboard, a small box asks you to paste the text (or the picture) there instead. In the panel, you can also paste text into **Try it** (or leave it empty to use your clipboard) and press **Run**. From outside Cockpit a launcher, a keyboard shortcut or a script runs

    php power_run "Proofread"

which reads your clipboard, asks Cockpit on this machine to run the button, and puts the answer back (by default it asks the button what it needs — the clipboard, what you selected, or a picture on the clipboard — and reads that; or say `--from clipboard|selection|image|stdin|file=PATH`, and `--to clipboard|notify|stdout|file=PATH`). It exits with 0 when done, 1 on an error and 2 when it stopped on purpose (for example: a first confirmation is needed in Cockpit). It needs the clipboard tool of your system (`xclip`, or `wl-clipboard` on Wayland, `pbcopy` on macOS) and, for notifications, `notify-send`. Launchers and shortcuts that Cockpit creates for you come in a later release.

**More ways to run a button.**

-   **A small window.** Set a button's *Answer goes to* to **A small window**: from a launcher or hotkey the answer opens in its own small window (a Cockpit Browser window) with **Copy** and **Save…**; inside Cockpit it opens as a floating window.
-   **Paste where the cursor is.** *Answer goes to* **Pasted where the cursor is** is for launchers and hotkeys: the answer is copied, a notification gives you two seconds to click where it should go, and then the paste keys are pressed. It works on X11 (needs `xdotool`), macOS and Windows/WSL. **Wayland does not allow one program to type into another**, so there the answer stays on the clipboard and you press Ctrl+V yourself. Control characters in the answer are dropped, but a newline is kept: pasting into a terminal can run the line, so use this for text fields.
-   **A hotkey per button.** In a button, type a key such as `ctrl+alt+1` (one to three of ctrl, alt, shift, super and one letter, digit or F1–F12). While the Cockpit window runs, the key works anywhere on the desktop. This is X11 only (a Wayland session lets no program grab keys: add the shortcut in your desktop settings with the command shown by *Create launcher*), and it needs the Cockpit window, not a browser tab. A key another program already holds, or one already used by another button, is skipped, and the panel says so.
-   **Create launcher…** In a button: *Add to my applications menu* or *Put an icon on the desktop* (Linux, written for you), or download a launcher for **Linux** (`.desktop`), **macOS** (`.command`) or **Windows** (`.cmd`; inside WSL a `.cmd` that calls `wsl.exe`). A launcher holds only the button's name and where Cockpit is: no key, no password. The macOS and Windows launchers need PHP and Cockpit on that same computer. *These two were checked here with stand-in system tools, not on a real Mac or Windows PC; the Mac and WSL install tests are the ones to watch.*
-   **In a Cockpit Browser window**: a **⚡** button joins the window buttons (top right). Select text on a page, click ⚡, pick a button: it works on the selected text (X11).
-   **Right-click a file.** In Cockpit's file manager: right-click a text file or picture → **Power Buttons…** → pick a button. For your desktop's own file manager, **File manager** (panel header) writes one right-click action per button: in *Files* under *Scripts*, in *Dolphin* under *Cockpit*. The answer is saved next to the file as `NAME.button.md`.
-   **Command line.** **Command line** (panel header) installs `cockpit-run` into `~/.local/bin`: `cockpit-run proofread < draft.txt > clean.txt` reads standard input when text is piped and prints the answer; `cockpit-run --list` shows your buttons. `power_run` accepts `--from file=PATH` for a text file, a picture, a **PDF** (needs `pdftotext`) or an **audio file** (needs ffmpeg and whisper.cpp, the same as voice input), and `--from folder=PATH` for all the text files in a folder.
-   **Packs.** **Packs → Export my buttons** saves your buttons as one file to give to someone; **Add from a file…** shows what a pack contains and adds the buttons you tick. A pack never carries a key, and every button from a pack starts on a **model on your own computer**, with *allow secrets*, the hotkey and *paste* switched off, so a pack cannot decide where your text goes. Copies never overwrite your own buttons. (Sharing through the Marketplace needs the Marketplace server and is not in this version.)
-   **Automations.** **Automations** (panel header): *Watch a folder* — drop a text file, a PDF or an audio file into it and the button runs and writes `FILE.button.md` beside it (files already there are left alone, and a file is run once per change); or run a button **every day at a time** or **every N minutes** on a file or folder ("every morning summarise this folder"). They ride Cockpit's scheduler (the one-minute cron job), so they need the scheduler to be installed and your computer to be on. A button that needs a confirmation (a cloud supplier for the first time) or that sees a secret simply stops; the panel shows the latest log lines.
-   **From your phone (Everywhere).** In the Everywhere chat send `/power` for the list, then `/power Proofread` with the text on the next line (or `/power "Make it polite" your text`). The button runs on your home computer with its own supplier and safety rules, and the answer comes back to the phone. Only the button's name travels from the phone; a stop that needs your confirmation says so and waits for you at the home computer.
**Safety.**

-   Copied text is **untrusted**: a web page can contain "ignore your instructions". It is sent below a line with a sentence telling the model it is data, not instructions — but a small model can still be fooled by instructions hidden in the text, so the real protection is that a button has **no tools** in this release and its answer is text only, put on your clipboard — never executed. Read an answer before you rely on it.
-   A supplier outside this computer receives what you copied, so it is asked about **once** before the first run (and the panel says which supplier). Text that **looks like a password, an API key, a private key or a card number** is **not sent** to such a supplier. In Cockpit you are asked what to do: **use a model on this computer** instead, **send it anyway, this once**, or cancel; or switch on *Allow text that looks like a password or key* for that button. From a launcher there is no "anyway": it stops with exit code 2. A model on this computer never needs this check. The first-run question shows which supplier gets the text and the first part of it.
-   Paid suppliers go through the same **consent switch and monthly caps** as chat, and the usage meter counts them.
-   Very long text is cut to fit (and the answer says so); the **History** button in the panel lists the last runs — button, supplier, time, size, whether it worked — and never the text itself; **Clear history** forgets them.

## Skills system

Skills are reusable prompt templates with auto-trigger capability.

-   Open Skills manager → **+ New**. Each skill has: Name, Description (with coach scoring), Tier (priority), and Content (prompt template with variables).
-   **Auto-trigger** --- when enabled, skills auto-fire based on keyword overlap + trigram similarity against your prompt. The best match above threshold is injected.
-   **Folder skills** --- defined as `SKILL.md` files in `cockpit_data/skills/<name>/` directories with YAML frontmatter.
-   Built-in: **Plan-and-Sequence** skill teaches the planner to emit atomic, verifiable steps for weak local model execution.

## Summarize

The **Summarize** button generates a summary of the current chat session using the active agent. The summary appears as a new message. Useful for creating a recap before switching tasks or sharing context.

## Caveman mode

The **Caveman** toggle (bottom-right of prompt area) controls token compression for online suppliers (Claude, Gemini, Workers). Ollama (local) is never affected.

  Level          Effect                                                                         Savings
  -------------- ------------------------------------------------------------------------------ ----------
  **Off**        Normal prompts and responses                                                   ---
  **Strip**      Removes filler words, articles, pleasantries from your prompt before sending   \~30%
  **Strip+AI**   Strip mode + asks the agent to respond in terse caveman style                  \~60-75%

## Themes & theming {#themes-and-theming}

-   Several built-in themes (dark, light, mixed). Switch via the theme toggle button. In the **Mixed** themes (dark top bar, sidebars and status bar; light content) each area has its own text colours --- light text on the dark areas, the theme's dark text on the light content and on buttons and cards --- so text stays readable on both. A theme can carry an optional `textChrome` group (light text for the dark areas); one without it uses sensible defaults.
-   **Theme Editor** --- full color editor with grouped pickers: backgrounds, text, borders, agent colors, accents. Live preview in a sandbox strip.
-   **Apply** (session), **Save As** (persist), **Delete** (user themes only).
-   **Import VS Code themes** --- paste a .json VS Code theme; colors map automatically.
-   **Export/Import** --- transfer all themes as JSON between machines.
-   **Protanopia-safe** --- no red/green-only indicators. Blue, cyan, amber, orange, violet palette.
-   All UI elements follow the theme: modals, context menus, confirm dialogs, sidebar tabs, code blocks, data bars.

## Typography controls

-   **−** / **+** buttons and the size picker (the **Settings** card, top right of the top bar) --- change font size by 1px, or pick a size.
-   **Tt Aa** button (next to them) --- full typography panel (font family, line height, spacing).
-   **B / I / U** toggles (right sidebar footer) --- bold, italic, underline for console text.
-   All settings persist in localStorage.

## Comprehensive help system

The help system has been expanded to cover every Cockpit feature:

-   **75+ topics** organized by area: suppliers, modes, styles, prompt, chat, plans, workers, tools, skills, models, account, marketplace, and more.
-   **F1 context help** --- hover over any element and press F1 for context-specific help. Uses `data-help` attributes across the UI (an ancestor\'s attribute covers all its children, so most panels are wired via one attribute on the panel itself).
-   **Search bar** --- filter topics by title and content with highlight matching.
-   **Walkthrough** button --- 40+ step guided tour of all features.
-   **Settings** button --- comprehensive reference for every settings surface.
-   **Resizable and movable** --- drag the title bar to reposition; resize from edges/corners. Position and size persist across sessions.
-   **Setup Guide** button --- opens this guide\'s install/setup companion in a new tab.

------------------------------------------------------------------------

## Power Combos (Tier 0) {#power-combos}

Multi-model recipes --- several small local models run **together** on one task and merge into a single answer, instead of one model answering alone. Works with **Ollama models, LocalAI models, or a mix of both** (see \"Dual-mode\" below). **705 combos across 8 categories** --- 150 free (50 per backend: Ollama, LocalAI, Dual) plus 555 more (185 per backend), with the Plus plan (open to every registered account during the beta). Full per-combo descriptions live in `cockpit_data/ Cockpit_AllCombos_Reference.md` (quick lookup table) and `Cockpit_AllCombos_Explained.md` (detailed rationale per combo) --- too long to usefully inline here.

### Patterns {#combo-patterns}

  ---------------------------------------------------------------------------------------------------------------
  Pattern          What happens
  ---------------- ----------------------------------------------------------------------------------------------
  **Parallel**     Several models answer the same prompt independently; results shown side by side (or merged).

  **Sequential**   Models run in a chain --- each sees the previous step\'s output.

  **Judge**        Parallel candidates, then a judge model picks/synthesizes the best answer.
  ---------------------------------------------------------------------------------------------------------------

### Using combos

The Ollama and LocalAI dropdowns each have their own combo catalog and identical layout --- a master row (total count, filter box, \"+ new\", ⊟/⊞ collapse-all), a categorized **Combos** section ([star]{.material-symbols-rounded .ico .ico-fill} favorites + one group per category, same 8 categories either side), a **Needs both backends** section for combos whose steps mix both servers (merged --- a dual combo shows up in *both* dropdowns regardless of which catalog it\'s actually saved in), then the model list. Ollama\'s catalog is `combos_ollama.json`; LocalAI\'s is `combos_localai.json`; Dual\'s is `combos_dual.json` (merged into both single-backend views too) --- same schema, same editor, kept separate since a \"combo\" is really \"a recipe of model names,\" and the backends don\'t share model names.

1.  Select the **Ollama**, **LocalAI**, or **Dual** card as active (Card 3).
2.  Pick a combo from whichever panel\'s own combo section --- filter box + [star]{.material-symbols-rounded .ico .ico-fill} favorites + category groups, same in both.
3.  Type your prompt and send as normal --- the combo runs instead of the single selected model.
4.  Combos needing models you haven\'t pulled are greyed out and unselectable; hovering shows exactly which model is missing from which backend. A combo you authored yourself stays editable even while it\'s missing a model --- that\'s what Edit is for.
5.  **Category groups collapse/expand** --- click a group header (or ⊟/⊞ all in the master row) to hide/show its combos. Collapse state persists across reloads. With 8 categories, browsing collapsed-by-default is usually easier than one long list.

### Dual-mode (Ollama + LocalAI together) {#combo-dual-mode}

Both Ollama and LocalAI run at the same time --- installing AI Cockpit sets up both, no separate choice needed. A combo can mix steps from both: each step in a combo carries a small O/L tag showing which server it runs on, and steps tagged for different servers genuinely run in parallel (not switched back and forth) when the combo\'s pattern allows it. Before a combo runs, a quick pre-flight check confirms every server it needs is actually reachable --- if one isn\'t running, you get a clear \"X not reachable\" message instead of a partial, confusing failure partway through.

### Dual-model regular chat (not just Combos) {#dual-model-chat}

The same idea works outside Power Combos too. Card 3\'s model list shows every Ollama model and every LocalAI model together --- pick one of each and both stay loaded at once, VRAM permitting. Picking a third model while both slots are full triggers a real fit-check: if the two wouldn\'t fit together in your detected VRAM, the other slot is freed automatically instead of silently over-committing.

With only one model picked (either backend), chat works exactly as before --- nothing changes unless you actually fill both slots. With both filled, sending a prompt first asks each model to rate its own confidence (a quick 1--10, not a full answer) --- you\'ll see both scores, then choose: use one model\'s answer, or run both together as parallel / sequential / judge, the same patterns Combos use.

**Known limit:** LocalAI has no confirmed reliable \"unload model\" API, so clearing its slot updates the app\'s own tracked state honestly but can\'t guarantee the model actually leaves memory yet --- the UI says so right next to the LocalAI chip.

### Free vs. protected combos {#combo-store}

The 150 free combos ship plaintext across `combos_ollama.json`, `combos_localai.json`, and `combos_dual.json` --- no account needed, works on any machine. The other 555 (and any future curated packs) are **encrypted at rest** in `combos_store.enc`, the key derived from this machine\'s ID + your account\'s license key --- a copied file is inert on someone else\'s install. This stops *casual* copying/redistribution; it doesn\'t and can\'t stop a determined person reverse-engineering a combo\'s idea by watching it run --- that\'s an accepted, honest limit shared by every local-execution product, not a Cockpit-specific weakness.

If a protected pack exists on disk but fails to decrypt (wrong machine, expired/missing license), Tier-0 shows an amber warning instead of silently returning fewer combos.

### Your own combos {#user-combos}

Click **＋ new** in either panel\'s master row to build your own --- id, name, pattern, category (pick one or type a brand-new one, which creates that group on the fly), description, and steps. Each step has its own **model dropdown** (populated from your actually-installed Ollama and LocalAI models --- not free-text, so you can\'t accidentally reference a model you don\'t have) and its own **backend picker** (Default / Ollama / LocalAI) --- set different steps to different backends and you\'ve built a dual combo, which then shows up under **Needs both backends** in both panels. Add a judge model + instructions for judge-pattern combos, same dropdown-driven picker. Saved instantly as plain JSON, never encrypted --- it\'s already yours, nothing to protect you from. Edit ([edit]{.material-symbols-rounded .ico}) or delete ([delete]{.material-symbols-rounded .ico}) anything tagged **· mine** --- the edit icon works even when the combo is currently missing a model, since that\'s exactly when you\'d want to open it and fix the model pick.

**Publish to the Marketplace** (Account panel → Marketplace → ⊕ Publish → kind *My Combo*, pick one of yours) to let others download it --- requires a Plus plan (browsing and downloading stay free), same as publishing a Skill or Tool. Unlike the admin-curated 185, your published combos are **not** admin-gated --- publishing your own combos is open to any registered user.

Downloading someone else\'s combo merges it into your own Tier-0 (tagged **· by \<name\>**). Before it downloads, Cockpit checks each of its models against your actually-installed Ollama and LocalAI models (each model checked against the specific backend it actually runs on, for a mixed-backend combo) and shows which you\'re missing, so you can back out instead of downloading something you can\'t run yet --- the same missing-model check already applies after download too (a combo needing an unpulled model just shows greyed-out, hover for which model is missing from which backend --- whether it\'s built-in, protected, or user-authored). Published something by mistake? The [language]{.material-symbols-rounded .ico}[close]{.material-symbols-rounded .ico} icon on your own published combos pulls it from the Marketplace; your local copy stays.

------------------------------------------------------------------------

## Delegate --- task auto-routing {#delegate}

Standing rules that automatically hand off matching tasks to a different supplier/model/combo **before** the normally-selected agent continues --- the delegated result gets folded into your prompt as context, then the original dispatch proceeds. Works identically no matter which mode (Single/Pipeline/Broadcast/Plan/Combos) is active, since every prompt funnels through one shared dispatch point.

*Not the same as the **Rules** (Directives) button* --- Directives inject static context into **every** prompt for every supplier; Delegate routes **specific** tasks to a **different** supplier.

### How a task gets matched {#delegate-matching}

1.  **Keyword/phrase** --- set when you create the rule. Fast, free, exact.
2.  **Small local model fallback** --- if no keyword hits (or several rules could apply), a tiny Ollama model classifies the task.
3.  **Ask you** --- if the model isn\'t confident either way, you\'re shown the candidate rules to pick from (or \"none --- continue normally\").

### Delegation targets {#delegate-targets}

Worker (REST API provider), Power Combo, or a specific Ollama model. Tool-kind targets are file-in/file-out (ffmpeg/whisper/etc.) and aren\'t supported for automatic prompt delegation --- that needs a file attached first, a different flow.

### Setting up a rule {#delegate-setup}

Toolbar → **Delegate** → **+ New Delegation Rule** → name it, list keywords/phrases (comma-separated), pick what it delegates to. Toggle rules on/off or delete them from the same panel.

------------------------------------------------------------------------

## Multiple local users

One Cockpit install can serve several people (family, work profiles) with fully separate data --- not just a login screen, genuinely separate tools/skills/combos/chat history/Cockpit Account subscriptions per person.

### Managing users

Account card (top-right of the supplier strip) → the button with your name → **Local users** button (in the Stand-alone edition the name button opens it directly) opens the User Manager: add a new local login (username + password + role), see who\'s registered, remove one. Each local user gets their own data folder automatically on first login --- nothing to configure.

### Switching users {#switching-user}

Sign out (account card) and the next person logs in with their own credentials. Switching users tears down any running agent sessions in the background --- the incoming user starts clean and clicks **Start** themselves; live agent sessions (the tmux processes) are still machine-wide, not per-user, so this avoids landing mid-conversation in someone else\'s chat.

### Change password {#account-password}

Same account card → **Pass** button --- changes the local login password (not your Cockpit Account/SaaS password, which is separate --- see below).

------------------------------------------------------------------------

## Cockpit Account & Marketplace

Your **online** AI Cockpit account --- separate from the local login above. Click the license status text (top-left), or the button showing your name in the account card (top-right of the supplier strip --- it carries a small cog in the Full edition), to sign in, register, or manage it. In the Stand-alone edition that same button opens the local user manager instead.

### Do you need one? {#account-required}

**Full edition (V2): yes, once.** On first run Cockpit shows an account panel with no close button and waits. A free account is enough --- there is no card and no paid step --- but the install has to be registered before you reach the app. The server, not the app, decides this: it checks whether this machine is registered to an account, so editing local files does not get around it.

**Closing dialogs.** **Esc**, a click on the dimmed area outside a dialog, and its **Close** or **Cancel** button all do the same thing. If you typed or changed something in the dialog, Cockpit asks *Close without saving?* first; answering Cancel (or pressing Esc again) keeps your edits. The sign-in screen and the one-time recovery-token screen do not close this way. Delete and other destructive confirmations start on **Cancel**, so a stray Enter cannot delete anything.

**Passwords for the Cockpit account (Full edition).** At least 8 characters, and not only digits, not one repeated character, and not a common password such as `password1`. The same rule applies when you create the account and when you change the password.

**One name per machine (Full edition).** The very first run goes account first: sign in or create the free account, then choose the password for this machine --- the local login takes the account name automatically (you cannot pick another name for that first login; the server flags it if a machine ever differs). More local logins on the same machine can have any name; they are managed under Users and never touch the account. The installer follows the same rule when you give it your account.

**Stand-alone edition (V1): no, ever.** V1 makes no network calls at all and has no account layer. If you want Cockpit with no registration, this is the edition to install --- it is the same download, you just choose Stand-alone when the installer asks.

Once past that, the account layer itself is still only about the online/shared-content side: marketplace, subscriptions, credits. Your local features --- agents, models, tools, media, projects --- neither check it nor report to it.

If the account panel appears on an install that *was* signed in, it means the server could not confirm this machine. Sign in again; if the network is simply down, a previously validated licence keeps working offline. One exception, in the Full edition: **Autopilot Cruise and AutoCognition pause while Cockpit cannot reach the account server** (the last check failed, or the last good answer is over a week old). They come back by themselves at the next successful check, which runs every ten minutes. Everything else keeps working.

### Tiers {#account-tiers}

Free / Plus / Pro / Max, plus Family and Founder --- shown as a chip next to your account name. **Free** is the complete local app, with a free account (browse and download from the Marketplace). **Plus** adds Autopilot Cruise, publishing to the Marketplace and the Power Combos. **Pro** adds AutoCognition (the agent bus, chains, broker and quorum). **Max** adds Everywhere (remote control of this machine from another device through the relay). **Family** gives up to five people the Pro features on one plan. **Founder** is the one-time lifetime plan: it never expires and covers the current major version and the next three, shown on your card as *Lifetime · covers versions up to N*. While Cockpit is in beta every plan is open to every registered account; the card then says so. The older names (Starter, Basic, Ultimate, Content, Combined) still work on old licences and map to Free, Plus, Max, Plus and Max.

**Family seats.** The person who bought the Family plan opens **Account portal → Family**: the list of the five seats (you are one), an e-mail box to invite someone, and Remove for a seat. An invited person takes the seat when they sign in to Cockpit with that e-mail address *verified*, so an address that is not theirs cannot take it.

**Agent-to-Agent (A2A) is part of the free local app.** It runs on your own machine, off until you switch it on (Hive → A2A), and no plan is needed for it.

**The Agents row** (Pipeline, Broadcast and Plan) ticks an agent only while that agent is running, until you tick or untick it yourself; after that your choice stays.

### Marketplace {#marketplace-browse}

Browse and download community skills/tools/themes/prompts/worker cards/pipelines, and Power Combos. Downloads install straight into the matching local panel --- no manual file placement. **＋ Publish** lets you share something you made (combo publishing is admin-curated, not open upload).

### Account portal

Profile, registered machines (deregister old ones), and your subscription/renewal choice --- all in one Account portal.

### Several SaaS accounts, one machine {#multi-account-roster}

**Change user** (account modal) switches between several *registered Cockpit Accounts* on this machine without re-entering credentials --- a roster, separate from the local-login \"Users\" feature above (you can have several local logins AND several SaaS accounts; they\'re independent systems).

### Recovering your account after a reinstall {#account-recovery}

Your subscription tier lives on the Cockpit server, tied to this machine. If you reinstall your OS (or move to a new machine), the local license is gone and Cockpit would otherwise drop to Free. To get back in, use your **recovery token** --- a one-time secret (`CRT-XXXX-XXXX-XXXX-XXXX-XXXX`) shown once, right after you first created the account. Save it in a password manager.

To recover: open the account modal and start creating an account with the *same username and email* --- Cockpit detects the existing account and switches to the recovery form --- or click **\"Reinstalled or new machine? Recover an existing account\"** on the sign-up screen. Enter username, email, and the recovery token; your real tier and license are restored and this machine is bound. Lost the token? An admin can reset it (issuing a new one) --- the old token can never be retrieved, only replaced.

------------------------------------------------------------------------

## Supplier Slots --- CLI aliasing {#supplier-slots}

Card 1 (\"Claude\") and Card 2 (\"Codex\") aren\'t hardwired --- each slot can be reassigned to a different paid CLI supplier (e.g. Qwen Code) or a free agent (Aider, Goose, opencode) on your local models, or, for Card 2, a free REST fallback (Gemini\'s free-tier key, Groq, etc.).

### Reassigning a slot

Gear/tune icon on the supplier card, or the **Slots** button on the account card. Pick a different supplier from the catalog (`cli_suppliers.json`, user-editable) --- the card\'s displayed name, its model dropdown, the status pill, and the \"Open CLI in terminal\" button all follow the assigned supplier automatically.

A REST-only fallback (no local binary) hides the CLI-launch button automatically; a genuine CLI alias (has a binary) keeps it, retitled.

Card 3\'s slot works the same way, with its own option list: Ollama, LocalAI, or **Dual --- Ollama + LocalAI**. Picking plain Ollama or plain LocalAI gives you that one backend only, same as before this option existed. Picking Dual is what turns on everything described above under \"Dual-mode\" and \"Dual-model regular chat\" --- the merged model list, the O/L chips, and mixed-backend combos. Switching away from Dual hides all of that again and restores the single-backend picker.

------------------------------------------------------------------------

## Background Tasks & Scheduler

### Background Tasks

Long-running autonomous goals that keep working while you do something else --- set a goal, Cockpit keeps making progress on it in the background instead of blocking the console for one prompt at a time.

### Jobs (Scheduler) {#scheduler-jobs}

Cron-driven recurring tasks (e.g. \"summarize new files every night at 2am\") --- separate from the Orchestrator\'s own one-off \"Schedule\" option inside Plan mode, which is for scheduling a single plan, not a repeating job.

------------------------------------------------------------------------

## Transcriber

Batch audio/video → text extraction (local whisper.cpp), beyond the quick mic-dictation button in the prompt bar. Analyze a file, compile the transcript, download it, or export as HTML.


------------------------------------------------------------------------

# Update --- September 2026: New features

Everything below is in the current build. The short version: Cockpit reads
more kinds of material (books, PDF pages, images, audio), tells you where an
answer came from, and can be driven without the keyboard.

## Margin --- write in the margin of a file {#margin}

Select a few lines in the Files viewer, say what should
change, and the agent answers with the replacement for exactly those lines.
Nothing is written until you have seen the diff and pressed **Apply**.

The agent never edits the file. It produces text; Cockpit does the splice,
against the file as it is on disk at that moment, and only after you agree.
The anchor travels with the request --- file, line range, and the exact text
selected --- so the agent is not asked to find the place again and cannot
drift onto a similar-looking passage further down. And only the *replacement*
is requested: asking a model to re-emit a whole file to change three lines
invites silent losses in the parts nobody reviews.

**Apply checks first.** It re-reads the file and looks for your selected lines again. If they have changed since you asked, or now appear in more than one place, it refuses with *those lines no longer match the file* and writes nothing --- an edit elsewhere in the file is fine, because the lines are found again wherever they now are. After a successful Apply the open preview re-reads the file, so you see the change at once; the viewer's header also has a **refresh** button that re-reads the file from disk whenever it has been changed by something else.

## Dossier --- a researched answer with sources you can check {#dossier}

Ask a question. Cockpit searches several framings of it, reads the pages, and
hands the agent a numbered source pack with one instruction: answer from these
and cite them. The report is saved into the project as Markdown, so it lands in
**Artifacts** with everything else the project produced.

The gathering is deterministic: the same question fetches the same pages
whichever agent writes the report, so a small local model can do the writing
without having to drive a search loop it would get lost in.

> **Status.** Dossier's first step is a web search, and public search engines increasingly refuse automated queries --- on some networks every one answers with a bot check, and Dossier comes back empty. It is paused until it can draw on sources that do not depend on them.

**The honest limit**, which the report states about itself: this reads the
first pages a search engine returns. It is a fast survey, not a literature
review --- and the sources are listed precisely so you can judge them yourself.

## Profile --- what every agent should know about you {#profile}

Directives say how agents should *behave*. Profile says who they are working
*with*: units, language, timezone, how you like answers, what you are building.

It rides on every prompt, which is why the editor shows its size and caps it
--- a profile that grows into an essay quietly taxes every request and crowds
out the actual question. Two ways in: the editor, or **Remember this** on any
message, which appends a single line (it refuses duplicates).

**The first time you open it, you see a sample** that says plainly that it is one. Nothing is saved until you save, and no agent has seen it: the sample is never written to disk, because anything on disk is put in front of every agent.

## Intercom --- talk to the rig, hands free {#intercom}

Press once: Cockpit listens, notices when you stop talking, transcribes what
you said, sends it, speaks the answer, and listens again. Press again to stop.

Two behaviours worth knowing:

-   **Silence ends your turn, not a timer.** The turn closes about 1.5 seconds
    after you stop speaking, because a fixed window either cuts people off or
    makes them wait. A minimum length stops a cough being sent as a prompt.
-   **It speaks the answer, not the markup.** Code blocks, tables and marker
    syntax are stripped before the text reaches the voice, and long answers are
    cut with a spoken note rather than read aloud for four minutes.

## Bookshelf --- a book the agent can actually use {#bookshelf}

Press the **Bookshelf** button in the [Toolbar](#the-toolbar), pick a book with **Browse…** (epub, docx, odt, fb2 via pandoc; mobi and friends via calibre) and
Cockpit splits it into chapters and files them in the Library, where it appears as a single foldable row. Conversion markup left over from the book's source is stripped when the text is read, so books filed earlier read cleanly too.

Converting was never the hard part --- scale was. Over ~50 KB of extracted text
an agent only gets a file path and a preview, which is fine for an agent with
file tools and useless for a local model. Because chapters are filed
individually, retrieval pulls only the chapter that matches your question and
**Receipts** names it, so a 400-page book works with a 7B model: it never sees
more than the chapter it needs.

**Books can live anywhere.** *Browse…* in the native window opens the system file chooser and uses the real path; in a plain browser the file dialog hands the bytes over and Cockpit keeps a copy in your data folder; or type a path. A typed path must be inside a folder Cockpit may read (your projects and data folders); if it is not, the message names them and offers **Allow &lt;folder&gt;**, which records that folder as approved. Cockpit never reads a folder you have not approved, and it never copies in a file on your behalf from a path you typed. Browse remembers the last folder you used.

**Chapters are sized to your machine.** Each chapter is cut to about 12, 20 or 40 KB depending on the video memory Cockpit detects, because a chapter too large for a small card made prompt processing take minutes. A book whose headings are marked in a way Cockpit does not recognise falls back to numbered parts (*Part 1, Part 2, ...*).

The chapter list is shown **before** anything is written, because a bad split
(a book with no headings, a PDF that extracts as one blob) is obvious in a
preview and invisible afterwards.

## PDF Vision --- the pages, not just the text {#pdf-vision}

Attaching a PDF extracts its text (with `pdftotext`) and puts it in your prompt. But text extraction loses whatever was never text: diagrams, scans, tables that were drawn rather than typed, handwriting --- a scanned book has no text at all.

Turn on the **PDF Vision** capability (Capabilities tab; it is off by default because rendering pages costs time) and Cockpit also renders the **first six pages** as images and hands them to an agent that can see, so a page is read as a page. Claude opens the page images itself; other agents receive them the way their catalog entry says, or a local description of the first three pages.

Ask your question **in the same message as the attachment**. The page images belong to that one message; a question sent afterwards no longer has them.

## Vision dispatch --- each agent gets the image the way it can take one {#vision-dispatch}

Attached images are no longer handled one single way. Each supplier entry in
the agent catalog declares how it accepts an image, and Cockpit dispatches
accordingly --- one agent is given the file path to open itself, another takes
an explicit image flag. Where an agent genuinely cannot see, Cockpit says so
and falls back to a description rather than pretending: a CLI that silently
invents a description of an image it never received is worse than an error.

The *describe locally* route needs a local vision model (`ollama pull gemma3:4b`). If it is not installed, Cockpit tells **you** in the chat that this agent cannot see the picture and how to fix that, and tells the **agent** in plain words not to describe or guess it. (A small model given only a file path will otherwise invent a picture --- the same file once came back as a blue circle and a red square, then as a red circle, a blue square and a green triangle.) The agent editor's *Can it see?* test says *could not run here* when the agent is not signed in or has no key in the test, rather than blaming its eyes: for those, test from a chat on a card.

## Privacy and spending --- what may leave this computer {#privacy-spending}

The **Privacy** button in the Toolbar holds three rules. They run before a prompt is queued for an agent, so a refused prompt leaves nothing behind.

**Sensitivity gate.** A prompt headed for an *online* agent is checked for private keys, API keys and tokens, passwords in assignments, passwords inside connection strings, and payment-card, IBAN and US social-security numbers that pass their own checksum. If something is found, nothing is sent until you choose **Redact and send** (each item is replaced by `[REDACTED:type]` and the chat says what was removed), **Use the local model instead**, **Send anyway**, or **Cancel**. In *Privacy & spending* you can instead choose a standing rule: **Ask me every time** (the default), **Never send them online, unless I choose to, each time** (the safe choices come first and *Send anyway* needs a second, explicit confirmation), **Redact automatically and tell me**, or **Never send them online, no exceptions**. It is deliberately conservative: there is no rule for names, e-mail addresses or phone numbers, and obvious placeholders (`your_api_key`, `${TOKEN}`, `xxxx`) are ignored, because a gate that cries wolf gets switched off. Local agents are never checked, since nothing leaves the machine; Workers are checked the same way as the cards. Nothing found is stored: only the type and the first four characters are ever shown.

**Free agents only.** Refuses agents that need a paid plan, with a plain message. It is **linked with *Stay Free*** in the Suppliers dialog: *Stay Free* is the one-time action that picks free agents for the cards, and *Free agents only* is the standing rule that refuses paid ones at send time. Pressing *Stay Free* also turns the rule on and tells you so; while the rule is on, the Suppliers dialog shows a banner, disables the paid agents ("paid, blocked") and warns if a card still holds one. If you want the two to work independently, untick **Link with Stay Free in the Suppliers dialog** in *Privacy & spending*. "Paid" means the same in both places: an agent that needs a paid plan and is not flagged free in the agent catalog. It is **on by default for a new install** and **off for an install that already has history**, so an update never starts refusing the agent you have been using.

**Monthly budget.** A limit on prompts to paid agents per calendar month (0 means no limit). Cockpit cannot see what a subscription bills, so it counts what it can measure. It warns at 80%, stops at 100%, and lets you send one prompt anyway.

The *Try the gate* box is a dry run: paste any text, press *Check*, and it lists what the gate would catch (the kind of item and its first four characters) and shows the text **as it would be sent after redaction**. Use it to see what the gate understands before you rely on it, or to check a snippet you are unsure about. It runs on this machine's own rules; nothing pasted there is stored or sent anywhere.

## Drop-down lists {#dropdowns}

Every drop-down in Cockpit (themes, languages, models, modes, dialogs) now opens a list drawn by Cockpit itself instead of the system's menu, so it follows your theme: its colours, its font, its dark or light mode. The control you click is unchanged and every setting works as before; only the opened list is new.

- **The chosen entry** has a check mark and is **bold** (never colour alone). The row under the pointer or the keyboard has an outline.
- **Groups** have labels, **disabled entries** are dimmed and cannot be chosen, and the list opens **upward** when there is no room below.
- **The theme picker** shows three colour swatches (background, text, accent) for every theme and a **Dark**, **Light** or **Mixed** tag in words.
- **Keyboard:** Enter, Space, F4 or Alt+Down open it; Up and Down move (disabled entries are skipped); Home, End, Page Up, Page Down jump; Enter or Space choose; Esc cancels; Tab leaves; typing jumps to a matching entry.
- **Look:** the same as the Ollama model picker (panel, border, shadow, a header per group, a tinted chosen row), in your theme's own colours. Checked under all 36 themes for legibility; in the Mixed themes the list is a dark panel with light text.
- **The chosen entry is shown:** every list, including the Workers, Tools, Ollama and LocalAI pickers, opens scrolled to the entry you have selected; if that entry is inside a collapsed group, the group is opened for you. A group's heading floats on the top row (under the filter box) while its entries scroll past.
- **On a phone or tablet** the device's own picker is used, because it is the better control there.
- **If you prefer the system list**, open the browser console and run `localStorage.setItem('ck.nativeSelects','1')`; `localStorage.removeItem('ck.nativeSelects')` brings Cockpit's list back.

**Supplier-card lists.** A drop-down opened from a supplier card (Claude, Gemini, Ollama, Workers, Tools) takes that card's colour for its border, tint and chosen row. Any list is only as tall as its entries; only a ceiling is imposed.

### Auto Generate: palette types and picked colours {#theme-autogen}

**+ New** in the Theme Editor opens the new-theme panel; **Auto Generate** makes a random theme of the chosen mode. The row *For Auto Generate* shapes it:

- **Palette:** *Normal* (a random hue, the agents spread round the colour wheel); *High contrast* (near-black or near-white surfaces, pure text, saturated bright agent colours); *Protanopia*, *Deuteranopia*, *Tritanopia* (colours that stay apart for red-, green- or blue-weak or -blind eyes; the milder forms, protanomaly, deuteranomaly and tritanomaly, are covered by the same sets); *Achromatopsia* (no colour at all: greys, the six agents told apart by lightness).
- **Background colour, Panels / dark areas, Accent colour:** each has a colour box and a **random** tick. Untick it to choose the colour yourself. The *hue* of what you pick is used; the lightness follows the mode, so a mid blue gives a dark-blue background in a Dark theme and a pale blue one in a Light theme. In a *Mixed* theme, *Panels / dark areas* is the dark chrome.
- **Mixed** now produces a real Mixed theme (light content, dark chrome, with its own light text set); before, Auto Generate made a dark theme and called it Mixed, and a Mixed theme saved through the editor was stored as Dark.
- **How well the colour-vision palettes work** was measured with a colour-vision simulation: in the colour-blind palettes the two closest agent colours stay clearly apart (distance 16 to 24 on the CIE76 scale), where in the Normal palette two agents can look identical to a protanope (distance about 1). It is an aid, not a medical guarantee, and the agent names are always shown as well.
- **Plates, not gradients.** The "AI Cockpit" name and your plan are engraved metal plates with two screws, in solid colours with fixed text colours: the text reads the same on every theme and for every kind of colour vision, because the contrast does not depend on the theme or on how a viewer sees hues. Each plan has its own finish (Free steel, Plus brass, Pro bronze, Max gold, Family teal, Founder obsidian; Unregistered graphite, Offline red), and they differ in lightness as well as in hue. The Everywhere add-on is a second, indigo plate joined to the plan's plate (Max includes it, so it always shows there). A plan bought with a discount (education, non-profit, regional) shows as the ordinary plan. Next to the version number a small plate names the release stage of this build: BETA (gold), PRE-RELEASE (bronze) or RC n for release candidate n (teal). A final release shows none.
- Whatever is generated passes through the readability guard below, so the saved theme is already readable.

### Readability guard for every theme {#theme-guard}

Whenever a theme is applied -- built-in, one you made, edited or imported -- Cockpit checks each text colour against the surfaces it sits on and repairs any that cannot be read, in the applied copy (your saved theme is not rewritten):

- **Text:** primary and base 4.5:1, dim 4:1, muted 3.3:1, on the content surfaces (and, in a Mixed theme, the light text of the dark areas on the dark surfaces).
- **Agent and accent colours** (agent names, clock, supplier labels, active buttons) 3.3:1 on the content surfaces.
- **Mixed themes** are checked per area: dark text on the light content, light text (*textChrome*) on the dark chrome.

Saving a theme in the Theme Editor lists the colours that were too faint ("Readability: ..."). The 36 built-in themes are verified on every build.

Also fixed in the same change: in the nine *Mixed* themes the Theme Editor's own drop-downs showed dark text on a dark background, and the project-kind picker could open with an empty list if the first request was made before you were signed in.
## Very long answers no longer empty a chat {#long-answers}

Until build 189, an agent answer of about 128 KB or more (a large generated file, a long document) made the step that saves the turn fail, and that step then replaced the **whole chat file with an empty one**: every earlier turn of that chat was lost and the answer was not saved either. This is fixed: the turn goes into the chat file through a temporary file, and the chat file is left untouched if saving fails. Nothing to configure.

## The native agent runtime (optional, off by default) {#native-runtime}

Cockpit's agent loop is a long Bash script. Three of its jobs now also exist as small native programs that do the same thing without `jq`, `awk`, `sed`, `sqlite3` or `python3`: starting the agent's command line (`aicengine`, written in Free Pascal and installed beside the scripts), choosing and rendering the earlier turns of a chat (`history_cli.php`), and carrying out the `%%CREATE%%`, `%%READ%%` and similar commands in a reply (`crud_cli.php`). Each was checked against the Bash it replaces on the same inputs: more than 290 comparisons, including your own chat files.

They are **off**. To try them, create an empty file called `use_engine` in your Cockpit data folder (`~/scripts/cockpit_data/use_engine`), or start the loop with `COCKPIT_ENGINE=1`. Delete the file to go back. If the engine is missing or refuses a request, the loop uses its Bash exactly as before.

The engine also makes the **Gemini** call (card 2 when it points at Google's API): it speaks HTTPS itself and **checks the server's certificate and host name every time**; a certificate that is not trusted, or is for another name, is refused and nothing is sent. The API key goes in a request header, not in the web address, and never appears on a command line. A prompt of any size goes through (the Bash path stopped working around 128 KB). A failed connection now says why instead of ending with an empty error line. In both paths a Gemini reply that holds no text (a safety block, an empty candidate) now shows the reason ("[GEMINI ERROR] SAFETY") instead of a blank answer.

The engine also **assembles the prompt** for each turn (the project's goal, kind and descriptions, `COCKPIT.md`, your profile, the global directives, the identity line and the layout for the agent), without `jq` and about twice as fast. It was proven identical to the shell version on 156 cases, including the awkward ones (a goal cut mid-character, `COCKPIT.md` at exactly 8 KB, broken JSON files). One shell habit is gone with it: a prompt that is *exactly* `-n` or `-e` is no longer swallowed as an option.

The engine also does the **clean-up after the agent answers**: it strips terminal artifacts from an Ollama or Gemini reply (carriage returns, colour codes, Ollama's progress line, the Gemini CLI's colour warnings and fallback notices), times the turn, writes the Ollama usage line, and adds the "installed but not signed in" hint to a short reply that says so. It was proven identical to the shell version on 304 cases. Two shell weaknesses are gone with it: it needs no `sed`, `bc` or GNU `date` (on macOS the shell version could not even time a turn), and the Ollama usage line is valid JSON whatever the chat is called (a backslash in a chat name used to make that line unreadable for the Usage page).

The engine also does the **start of every turn**: it finds the request's details (project, chat, models, per-user folders), the Ollama model file and the supplier controls, puts the effort text in front of the prompt, keeps the extra command-line arguments only when they pass the safety whitelist, and removes the queue files. It was proven identical to the shell version on 56 cases (including pretty-printed and CRLF request files, escaped slashes, awkward base64 and an empty or `-n` prompt), and by running the whole loop twice with a stand-in agent. When a control is not clean base64, the engine steps aside before touching anything and the shell version does the turn.

What changes when it is on: a faster history step (about 35 ms instead of 60, and a new chat's first call 20 ms instead of 220); the agent's standard input is closed so an agent that waits for input cannot look stuck; pressing **Stop** ends the agent and everything it started; and `%%DELETE:.%%` can no longer delete a whole project folder. One cosmetic difference: some agents (Aider, for one) print a note that their input is not a terminal.

**Markers that call Cockpit's own pages now work.** When an agent writes `%%FETCH:url%%`, `%%SEARCH:terms%%`, `%%WORKER:...%%`, `%%TOOL:...%%` or `%%PROPOSE:...%%`, the agent loop asks `search.php`, `workers.php`, `tools.php` or `library.php` on this machine. Those requests carried no login, so every one was answered "Authentication required" and the markers silently did nothing (the Workers and Tools lists the loop offers the agent were empty for the same reason). The loop now keeps a small secret in the data folder (`internal_key`, readable only by you and the web server's group, created by the loop, never by a web page) and sends it with the name of the person the request belongs to. The pages accept it only when the request comes from this machine without passing through a proxy, names one of exactly these page-and-action pairs (`search`/`fetch`, `models`/`invoke`, `presets`/`run`, `proposal_add`), and names a person who exists, with the role that person has (a viewer stays a viewer). Everything else on the site still needs a login. A second bug lay behind the first: `%%PROPOSE%%` used names `library.php` did not know, so a proposal would have failed even with a login; it now works. A V1 loop also used to call V2's pages; it now calls its own edition's.

#### The whole agent loop as a native program (optional, off by default)

With a file called `use_native_loop` in the Cockpit data folder (or `use_native_loop_ollama`, `use_native_loop_claude`, `use_native_loop_gemini` for one agent only), each agent's queue loop runs as one native program (`aicengine loop`) instead of the shell script: it finds the request, works out which supplier the card means, applies the project's capabilities and auto-route lists, assembles the prompt, runs the agent, cleans the answer, carries out the `%%markers%%`, saves the exchange and signals that it is done. It needs none of `jq`, `sed`, `bc`, `python3` or `curl`. PHP is still used for two things, as before: the chat history and saving the turn (`history_cli.php`) and the markers (`crud_cli.php`). Without PHP there is no history, and the turn is saved by the program itself.

It was proven against the shell loop by running both on the same thirteen requests (a stand-in Claude, a catalog CLI on card 1 and on card 2, a mock Ollama, a marker that creates a file, effort text and arguments, the not-signed-in hint, a request with no details file, and follow-ups with earlier turns in the chat): the answer, a hash of the whole prompt, the saved chat, the files created and the log lines are identical. The old script is not removed: delete `use_native_loop` and restart the agents to go back. tmux and the supervisor start the same command as before, which hands over to the native program.

Also in this build: the capabilities and auto-route steps of the shell loop can run in the engine too (69 cases proven identical), and the engine's loop keeps one loop per agent through the same pid file.

The native loop also does the **chat history** itself: deciding whether a prompt needs the earlier turns, picking the relevant ones from the chat's search index, and saving each turn into the chat file. It uses the same index file as before (SQLite, loaded from the system's library when it is there; without it the loop sends the last turns instead, as the shell version does) and needs no PHP for this. It was proven identical to the PHP helper on 1,743 cases. For the few inputs it does not copy exactly (text that is not valid UTF-8, an unusual character, a chat file written by a very old version), it hands that one request to the PHP helper if there is one.

The **markers** an agent writes (`%%CREATE%%`, `%%APPEND%%`, `%%READ%%`, `%%DELETE%%`, `%%MKDIR%%`, `%%LIST%%`, `%%FETCH%%`, `%%SEARCH%%`, `%%WORKER%%`, `%%TOOL%%`, `%%PROPOSE%%` and the library markers) are carried out by the engine as well, in the same process, with the same one-line results the agent has always been shown (148 checks against the shell executor and the PHP helper, including the requests sent to Cockpit's own pages). It sends the loop's private key only to those pages, never to a catalog entry's address. A few worker or tool answers it will not format itself (numbers with decimals, lists, objects); for those the PHP helper does that one marker. With the native loop on, a machine without PHP runs chat, history and markers entirely natively; the shell loop's marker step uses the engine too when the engine switch is on.

The **free-REST suppliers** of card 2 (Groq, HuggingFace, Cloudflare) are called by the engine too: it opens your encrypted Workers key store (the same AES-256-GCM file, the same machine-bound key) and makes the one request the PHP relay would make, with the same answer and the same error texts (46 checks against `worker_relay.php`, including the request each side sends). It hands the job to the PHP relay for what it will not reproduce exactly: another provider, a store it cannot read, a redirect, an answer of an unusual shape. The one visible difference: when the provider cannot be reached at all, the message reads "curl: " followed by this program's own reason. With the native loop on, no PHP is needed for card 2 either.

The **web front** is a second, optional way to serve Cockpit. With a file called `use_aicserver` in the Cockpit data folder (put a port number in it to choose the port; otherwise 8081 for the full edition and 8082 for the stand-alone one), the supervisor also runs `aicserver` (a small Free Pascal web server) and `php-cgi` as you, and Cockpit answers on `http://127.0.0.1:8081/cockpit/` as well as on Apache's port. Apache is untouched and stays the default; this is for trying the replacement and for machines without Apache. It needs `php-cgi` (`sudo apt install php8.3-cgi`) and the supervisor switched on. It refuses the same files Apache refuses (your settings, usage log, quota file, the queue and response folders). Remove the file to stop using it.

**Starting Cockpit without Apache.** The menu has a second entry, **AI Cockpit (self-contained)** (and **AI Cockpit V1 (self-contained)**), and the terminal commands `cockpit-self-start` and `cockpit-v1-self-start`. They do what the ordinary start does (agents, splash, the same native window) but serve the app from `aicserver` instead of Apache: the supervisor runs the web server and PHP as you, the window opens on `http://127.0.0.1:8081/cockpit/` (V1: port 8082), and Apache is not started. The first time, it creates the two switch files for you (`use_supervisor` and `use_aicserver` in that edition's data folder); after that the web server simply stays part of the supervisor, so both ways of starting work side by side. It needs `aicserver`, `php-cgi` and the supervisor; if one is missing it says so and opens the Apache address instead. Both editions work: V1 has its own supervisor folder and its own port. In this mode PHP already runs as you, so the Start, Stop, Terminal, Files and Browser buttons start things directly instead of going through `sudo` (no entry in `/etc/sudoers.d` is needed, which is what a machine without administrator rights lacks). Under Apache nothing changes: the same `sudo -u you` calls as before. In this mode **Stop** and **Restart** stop only the agents: the web server that is showing you the page stays up (the Exit dialog's *Terminate and leave* is the full shutdown, web server included). One window per edition: close the running one first (Exit) when you switch between the two ways of starting. With the web front on, the server also answers the chat's progress polls (the "new text of the answer" call, many times a second while an agent writes) itself, without starting PHP, whenever it can see you are signed in and the agent is running; every other case goes to PHP unchanged.

#### Seeing which runtime is in use

While the optional native parts exist next to the shell ones, the **status bar** shows what is really running, read from the processes themselves and not from the switch files. Next to each agent's name a small tag says which loop runs: `native` (the native loop) or `shell` (the shell script). The process supervisor is the usual host and is not repeated on every tag; when an agent runs in a tmux session instead, the tag says so (`tmux · shell`). The native loop's tag is bold. Hover a tag for the plain-words description, who keeps the loop alive and the process number. A tag is hidden while that agent is not running.

The thin **status bar** at the very bottom of the window, under the prompt and its buttons, shows the last thing that happened (`Ready.`, `Loaded chat: …`, the latest system message, a success or an error). It had slipped out of view because the Attach button added a fourth row to the button column; CLEAR, SAVE and Attach now share one row, and the bar is back.

The three labels at the left of the status bar name the agent and its model (`Claude · Sonnet 4.6`, `OpenCode · qwen2.5:7b`, `Local · Dual`); the dot beside each says whether it is running, and the full text is in the hover.

Three one-word tags beside the usage figures, in this order: the **native engine** (`on` or `off`; the file `use_engine`), the **scheduler tick** (`sup` for a supervised job, `cron` otherwise) and the **web server** that answered the page you are looking at (`apache`, the default, or `aic` for the optional `aicserver` front on port 8081). Hover each one for its name in plain words. Hover it for the full list: how the loops are hosted, whether the engine program is installed, and which `use_native_loop` files ask for the native loop. If a tag does not match what you switched on, the loop that is running started before the switch: restart the agents.

### The process supervisor (optional, off by default) {#supervisor}

By default each agent's loop (Claude, Gemini, Ollama) runs in its own **tmux** session. Cockpit can instead run them under **aicsupervisor**, a small native program (Free Pascal, installed beside the scripts). Nothing changes on screen except the points below.

**Switch it on:** create an empty file called `use_supervisor` in your Cockpit data folder (`~/scripts/cockpit_data/use_supervisor`, or `cockpit_data_v1` for V1), then **Restart** the sessions (or run `cockpit_stop.sh` and `cockpit_start.sh`). **Switch it off:** delete the file and restart. If the supervisor program is missing or does not answer, Cockpit uses tmux exactly as before, and the status block still shows an agent as running if it is running in tmux.

What is different when it is on:

- **A loop that dies comes back.** The supervisor restarts it (after a pause that grows from 1 to 30 seconds; after more than ten crashes in two minutes it shows as *failed* and stays down until you Start again). With tmux a dead loop left a session that still counted as "running" and requests that were never answered.
- **Stop** sends the interrupt to the agent's process group, as Ctrl-C in a terminal does, instead of typing it into a tmux pane. The loop itself carries on (it has an interrupt handler since build 198); an older loop that dies from it is restarted at once.
- **Open session** on an agent's card shows the agent's **live log** in a terminal (the lines a tmux pane would have shown) instead of attaching to tmux. You cannot type into it; the loop takes no typing anyway.
- **Edition rule unchanged:** V1 and V2 still cannot run together; the other edition's supervisor is stopped when you switch.
- The **Tools** session stays in tmux.
- The supervisor's own files (control socket, token, logs: `~/scripts/cockpit_data/supervisor/`) are reachable by the web server's account through the same group arrangement as the tmux socket; nobody else on the machine can read them.

**Start it by itself at login (also optional).** `~/scripts/cockpit_sup_autostart.sh install` (add `--edition v1` for V1) writes a systemd *user* service, starts it, and turns the switch on; no administrator rights are needed. The service regenerates the supervisor's configuration before each start. `cockpit_stop.sh` still stops everything for good (a clean stop is not restarted); the next login starts it again. To start at *boot* without logging in, run once, yourself: `sudo loginctl enable-linger $USER`. `status` shows what is installed, `print` shows the unit without installing anything, `remove` takes it away (the switch file stays: delete `use_supervisor` to go back to tmux).

**Never two loops for one agent.** Two loops reading the same queue would answer every prompt twice. Since build 202 a loop refuses to start when a live loop of the same agent already serves its queue (it says so and exits), `cockpit_start.sh` ends a leftover tmux loop of an agent it hands to the supervisor, and `cockpit_sup_autostart.sh install` ends the tmux agent sessions too (the Tools session stays). If you installed the autostart service before build 202 while tmux sessions were running, end them once: `tmux -S /var/www/html/cockpit/tmux.sock kill-session -t cockpit_claude` (and `cockpit_gemini`, `cockpit_ollama`).

**The scheduler tick.** With the supervisor on, the minute tick of the Jobs panel (`scheduler.php`, which a crontab line runs today) is also a supervised job: it runs at start and then every 60 seconds, never two at once. If your crontab line is still there, both tick; the scheduler takes a lock, so a job still runs only once.

## How big a file can I add? {#upload-sizes}

| What | Largest | Where the limit lives |
|---|---|---|
| Chat attachment (paperclip, drag and drop) | 50 MB | Cockpit |
| Book for Bookshelf | 80 MB | Cockpit |
| Scan or photo for the Personal archive | 25 MB | Cockpit |
| Voice recording for dictation | 25 MB (about 13 minutes) | Cockpit |
| Video or audio for the Transcriber | 1 GB as an upload; larger files: pick them with *Browse* and Cockpit reads them in place | the web server's PHP settings |
| Chat import | 1 GB | the web server's PHP settings |

Until build 187, anything over **2 MB** in the last three rows was dropped without a word on a standard install (PHP's own default), and the three "Cockpit" rows above 35 MB ended in a blank error. Both are fixed: the limits in the table are the real ones, and if a limit is hit the message now says which one and how to raise it (Setup Guide, *Raising the upload size limit*).
## Who on my network can see Cockpit? {#network-exposure}

Cockpit's web page is served by Apache, which answers on **every network interface** of your computer, so another device on your Wi-Fi or LAN can open the login page. Everything behind it needs a login, and that has not changed. What *did* change (build 187) is what Apache will hand out **without** a login:

- **Folder listings are off** for Cockpit, so nobody can browse its folders.
- **`queue/` and `responses/` are never served.** These hold the prompts waiting for an agent and the agents' replies. Before this fix, anyone on the network could list them and read the files.
- **Internal data files are never served**: `paths.json`, the usage log (`*.jsonl`), `project_state.json`, `workers_quotas.json`, lock files.

Cockpit itself never reads these over the network (PHP reads them from disk), so nothing in the app changes. The installer does this on a new install and the update does it on an existing one. If you set Apache up by hand, see *Keep the working folders private* in the Setup Guide. To make Cockpit reachable **only from this computer**, change Apache's `Listen 80` to `Listen 127.0.0.1:80` and restart Apache.

## Receipts --- which passage the answer actually used {#receipts}

When retrieved material is put in front of an agent, the answer now cites which
passage it drew on. This is what makes Library, Sources and Bookshelf
trustworthy at a glance: you can see whether an answer came from your own
material or from the model's memory.

**Cockpit also warns when the model is the wrong tool.** If a question that the Library can answer is about to go to an embedding model (it makes vectors, it does not answer), a model tuned for code, or one below about 3B parameters (the floor measured for grounded answers), Cockpit says so and offers to switch to a suitable model.

**Cockpit also knows when to say nothing.** If some items in your library matched loosely but none covers what you actually asked, nothing is added, and the chat says so: *"Your library has N loosely related items, but none covers what you asked, so nothing was added."* The agent then answers from its own knowledge instead of leaning on an unrelated passage. An item has to cover at least half of what the question is about, measured against your own library --- common words count for little, rare ones for a lot. A library of fewer than twelve items is too small to measure, so this check stands down there.

## Dialects --- prompts shaped per supplier {#dialects}

Different agents respond best to differently shaped prompts. Retrieved context
is now placed where each model actually reads it, wrapped in the structure that
supplier prefers. Nothing to configure --- it follows the agent catalog.

## Audio analysis --- measured facts, no model involved {#audio-analysis}

Point Cockpit at a sound file and get measurements: tempo, duration, loudness,
peak level and silences. (Musical **key** is deliberately not reported: the local
tools cannot detect it reliably, and a wrong key is worse than none.) These are computed by local audio tooling, not guessed by a language
model, so they are reproducible --- the same file gives the same numbers every
time.

A file that is not audio --- a text file, a video with no sound track --- is
**refused** with a plain message instead of getting a report that looks like
measurements. Lyrics transcription refuses silence, and also a pure tone or
noise, which whisper would otherwise answer with a lone full stop.

## Sheet music --- both directions {#sheet-music}

-   **Sound to notation.** Hum, whistle, or play a melody, and Cockpit
    transcribes it to engraved sheet music as a PDF.
-   **Notation to sound.** Give it notation and it plays the piece back with a
    piano-like voice.

Lyrics can be attached to a transcription. Two honest limits, both enforced
rather than merely warned about: the transcription is **melody only** --- one
line, such as humming or a solo instrument. Cockpit measures whether the
recording really is one line, and **refuses** chords, a band or a full mix with
an explanation, instead of engraving a confident wrong tune. And a *photograph
or scan* of sheet music is not supported; reading printed music optically is a
different problem, and Cockpit refuses that input with an explanation too.
(A melody over a much quieter accompaniment is still transcribed: the melody is
what the tool follows.)

## Add your own agent, and test it before trusting it {#agent-editor}

The agent catalog is editable from inside Cockpit. If a new CLI agent appears,
you can describe how it is invoked --- binary, model flag, how it takes an
image, how it likes its prompt --- and **test it from the editor** before
putting it on a card. No rebuild, no reinstall, no waiting for a Cockpit
release.

**Removing** an agent you added deletes it; removing your changes to a shipped agent puts it back to its default. If a removed agent was sitting on a card, that card goes back to its default agent (never the same agent on both cards), and Cockpit tells you.

## Voice input --- choose the microphone, and see it working {#voice-input-mic}

Dictation lets you pick which microphone to use and shows a live input level --- a bar beside the mic button while you speak --- so "nothing happened" is immediately distinguishable from "the wrong device was selected" or "the mic is muted". See [Voice input (offline)](#voice-input-offline) for the details.

## Language of Cockpit {#language}

The translate button beside the font-size picker (top bar, Settings) chooses the language Cockpit is shown in. **English is the default.** Every label, hint and message in the app can be translated; language packs ship for a few languages but so far cover only a small part, and anything not translated stays English. Buttons keep exactly the size they have in English: a translated label that is too long for its button scrolls slowly inside it instead of stretching it. The choice is remembered per browser. **Right-to-left languages** (Arabic, Hebrew, Persian, Urdu and others) are supported: their text is shown and aligned correctly in answers, tools and files; mirroring the whole screen layout is not done yet.

**Add a language:** open the menu, download the empty template, save it as `<code>.json` (for example `fr.json`), fill in `_meta` and the values, and put it in the `lang` folder inside your Cockpit data folder (the menu shows the path). Anything left empty stays English. Add `?lang=fr` to the address to try it without choosing it. Developers: see `lang/README.md`.

The voice **Language** list is separate: it is the language you *speak*, and offers every language whisper supports (English by default).

## Everywhere relay --- machines have names {#relay-machine-names}

The relay used to identify a rig by its machine id: correct, unreadable, and
useless once you have two machines. Each machine now carries a name you choose,
and that name is what the relay page lists and what you pick from on your
phone.

## CLI agents get an isolated configuration {#isolated-cli-config}

Agents launched by Cockpit now run with their own CLI configuration by default,
separate from the one you use in your own terminal. This stops your personal
CLI settings leaking into Cockpit's agents and changing how they answer.

If you *want* an agent to use your normal setup, **Use my global CLI config**
turns it back on per supplier.

## The icon font is local {#vendored-icons}

Cockpit no longer fetches its icon font from Google at page load. The interface
draws correctly with no internet connection, and nothing about your use of
Cockpit is announced to a third party in order to render a button.

::: {#ug-search-box style="position:fixed;top:16px;right:16px;z-index:9999;
     background:#22262b;border:1px solid #3a3f46;border-radius:8px;
     padding:6px 8px;display:flex;align-items:center;gap:6px;
     box-shadow:0 4px 16px rgba(0,0,0,.4);font-family:system-ui,Segoe UI,sans-serif;
     font-size:13px;"}
[]{#ug-search-count style="color:#8a919c;min-width:44px;text-align:center;"}

↑

↓
:::
