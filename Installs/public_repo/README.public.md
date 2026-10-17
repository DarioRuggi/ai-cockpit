# AI Cockpit

**Your own AI workspace, on your own computer.**

AI Cockpit puts the AIs you already use (Claude, Codex, Gemini, models on your own machine through Ollama, and free cloud models) in one
window. Type a goal in your own words; it plans the steps, picks an AI for each, runs them (and carries on after a crash) and hands the
result back as files in your project.

- **Any AI, one place.** Cloud and local models side by side, per project.
- **Your work stays with you.** Nothing leaves your computer unless you ask. The Stand-alone edition never calls home.
- **Free for everything local.** No quotas. You bring your own AI keys; nothing here resells model usage.
- **49 project kinds** in 10 fields (writing, research, code, cooking, travel, personal finance, teaching, music and more); many have small
  tools that do real arithmetic and checking instead of asking a model to guess.
- **Translate it into your language from inside the app** (Translation Studio, with local-model drafts).

Try it without installing: https://cockpit.ruggi.site/try-it.php?ref=repo · Website and downloads: https://cockpit.ruggi.site/

## Install

Download the archive from https://cockpit.ruggi.site/download.php, then:

```bash
tar -xzf cockpit_install.tar.gz && cd cockpit && bash install_cockpit.sh
```

You need PHP 8 with curl, mbstring, xml and zip, plus tmux, jq and curl. The installer tells you what is missing.
Setup guide: `docs/guides/SETUP_GUIDE.md`. User guide: `docs/guides/USER_GUIDE.md`.

## What is in this repository

| Folder | What it is |
|---|---|
| `cockpit_app/` | The app: PHP and plain JavaScript, no framework and no build step |
| `scripts/` | The agent loop, start/stop scripts, the relay poller and helpers |
| `engine/`, `supervisor/` | The native engine and the supervisor (Free Pascal) |
| `shell/`, `ckdialog/` | The native window and the setup dialog (Free Pascal, GTK 3) |
| `tools/`, `webserver/` | Tool definitions and a small web server for user-mode installs |
| `Installs/` | Installers, the guide/translation generators and the checks |
| `docs/guides/` | The user guide and the setup guide (the app's Help is built from them) |
| `tests/` | The test scripts (`bash tests/<name>_test.sh`) |

**Not in this repository:** the account layer (sign-in, plans, entitlements, and the phone relay's server side), and the source of the two
websites. The Stand-alone edition is complete without them. The files `cockpit_app/saas.php`, `saas_config.php` and `entitle.php` here are
small stand-ins that answer "not part of the open-source release".

## Honest limits

- Small local models (2B to 7B) do not reliably drive the tool-call syntax. The Tools dialog is the dependable path, and larger models do better.
- On machines with little graphics memory, local models are at the edge: usable, but not at their best. Expect slower answers and weaker
  tool use; cloud models and bigger GPUs do better.
- **Platforms, as tested:** Linux is the platform it is developed on and is tested in full. On macOS (Apple Silicon) the installer and the
  checks passed in CI at build 124. On Windows it runs through WSL2, and the full install passed at an earlier build. We have not re-run the
  macOS and Windows checks on the latest build; we will test further, and we would be glad to hear from you how it goes on your system.

## Contributing

- **Translate it:** open the language menu in the app, choose *Translate Cockpit…*, and send the file from there (or see `docs/guides/USER_GUIDE.md`, *Translating Cockpit*).
- **Write a project kind or a tool:** see *Teach it a new kind* in the user guide.
- **Report what broke:** open an issue with your system, the version (shown in the top-left plates) and what you expected.
- See `CONTRIBUTING.md`.

## Security

Please report security problems privately to **security@cockpit.ruggi.site** (see `SECURITY.md`). Cockpit runs as your own user and is
meant for one person on one machine; it has a login lockout (5 wrong tries in 15 minutes) on the admin pages.

## Licence

Apache-2.0 with conditions (the name, branding and attestation rules): read `LICENSE.md`, `NOTICE` and `TERMS.md`.
© Ruggi Software.
