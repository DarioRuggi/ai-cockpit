# ckdialog — GTK 3 dialogs for shell scripts, with a real wizard

Apache-2.0 · Free Pascal · GTK 3 bound at run time (no -dev packages to build, only the
GTK runtime to run). Written for the AI Cockpit installer; usable by any script.

```
ckdialog --wizard SPEC.json [--answers FILE] [--out FILE]   # pages → KEY=value lines, exit 1 on Cancel
ckdialog --progress [--title T] [--text T] [--total N] [--phase-match "▶ Phase "] [--auto-close] < log
ckdialog --askpass [PROMPT]              # SUDO_ASKPASS helper: password → stdout
ckdialog --question --text T             # exit 0 = Yes
ckdialog --entry --text T [--entry-text D] [--hide-text]
ckdialog --info | --error | --warning --text T
ckdialog --check                         # exit 0 when a display + GTK are available
Any mode: --dark / --light override the desktop's preference (GNOME color-scheme, "…-dark" GTK theme,
XFCE xsettings, KDE kdeglobals); the wizard and progress windows also have a ☾/☀ toggle.
```

## Wizard spec

```json
{ "title": "AI Cockpit Setup", "heading": "AI Cockpit", "subheading": "…", "logo": "logo_32.png",
  "icon": "logo_128.png", "width": 700, "height": 600, "finish_label": "Install",
  "pages": [
    { "id": "welcome", "title": "Welcome", "text": "Pango markup allowed here." },
    { "id": "p1", "title": "…", "show_if": { "EDITION": ["1", "3"] }, "fields": [
      { "key": "EDITION",  "type": "radio",     "label": "…", "default": "1", "options": [["1", "Full"], ["2", "Stand-alone"]] },
      { "key": "USER",     "type": "entry",     "label": "…", "hint": "…", "default": "…", "placeholder": "…" },
      { "key": "PROJECTS", "type": "folder",    "label": "…", "default": "/path" },
      { "key": "CODEX",    "type": "check",     "text": "…", "default": "y" },
      { "key": "MODELS",   "type": "checklist", "label": "…", "default": "all | id id", "options": [["id", "text"], …] },
      { "key": "WH_M",     "type": "select",    "label": "…", "default": "base", "options": [["base", "base — fast"], …] },
      { "key": "PASS",     "type": "password",  "label": "…" },
      { "key": "PASS2",    "type": "password",  "label": "Repeat", "confirm_of": "PASS" },
      { "type": "note", "text": "static <b>markup</b>", "dim": true, "show_if": { "CODEX": ["y"] } } ] },
    { "id": "summary", "title": "Ready", "type": "summary", "text": "…" } ] }
```

- `show_if` on a page or field: every listed key must hold one of the listed values.
- `summary` (per field) names it on the summary page; passwords are masked there.
- `--answers FILE` (KEY=value) pre-fills over the spec defaults — how a resumed install remembers.
- Output: `check` → `y`/`n`; `checklist` → selected ids separated by spaces; `radio`/`select` → id.
- Validation: a `password` shorter than 6 characters or a mismatching `confirm_of` blocks Next.

## Progress

Each stdin line goes to the log view (ANSI colours stripped). A line starting with `▶ `
counts as a phase: the bar shows `done / --total` and the phase text. The window refuses to
close before EOF — closing the reader would SIGPIPE the writer. At EOF: "Done", Close enabled.
Tip: follow a log file instead of piping the writer directly: `tail -n +1 -f --pid=$$ LOG | ckdialog --progress …`.

## Build

`bash build.sh` (fpc 3.2+). Only libgtk-3.so.0, libgdk-3.so.0, libgobject-2.0, libglib-2.0 at run time.
