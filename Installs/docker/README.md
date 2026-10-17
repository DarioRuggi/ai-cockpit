# AI Cockpit — Docker

Runs the same local app as the native install, in a container — for Windows
or macOS users who'd rather not set up WSL2/Homebrew by hand. Ollama **and**
LocalAI both run inside this same container (Power Combos can use either,
or both at once — see `combos_ollama_base()`/`combos_localai_base()` — and
both assume `127.0.0.1`, not a configurable host, so separate containers for
either wouldn't be reachable).

## 1. Get the app files

This bundle only has the Dockerfile/compose/entrypoint — it doesn't duplicate
the app itself. Choose an edition — same trade-off as the native install:

- **v2 (full)** — SaaS account, Marketplace, remote control from another device
- **v1 (no-account)** — fully local, zero network calls to our server, ever

Download the matching tarball from the
[download page](https://cockpit.ruggi.site/download.php) and extract its
`cockpit/web/` folder next to this Dockerfile, into a folder named after the
edition:

```bash
# v2 (full):
tar -xzf cockpit_full_project.tar.gz cockpit/web
mkdir -p v2 && mv cockpit/web v2/web && rmdir cockpit

# v1 (no-account) — only if you also want this edition available:
tar -xzf cockpit_v1_noaccount.tar.gz cockpit/web
mkdir -p v1 && mv cockpit/web v1/web && rmdir cockpit
```

You only need the edition(s) you actually plan to build. Side by side:
```
Dockerfile
docker-compose.yml
entrypoint.sh
v2/web/         <- v2 tarball's web/, if you want v2
v1/web/         <- v1 tarball's web/, if you want v1
```

## 2. Build and run

`docker-compose.yml` builds **v2** by default. To build v1 instead, either
edit `COCKPIT_EDITION: v2` to `v1` in `docker-compose.yml`, or pass it on
the command line:

```bash
docker compose build                                  # v2 (default)
docker compose build --build-arg COCKPIT_EDITION=v1   # v1 instead
docker compose up -d
```

Only one edition runs per container/build — this doesn't let both run at
once. To switch editions later, rebuild with the other `COCKPIT_EDITION`
(the `cockpit-data` volume — chats, library, CLI auth tokens — is shared
across rebuilds either way, only the app code changes).

## 3. One-time: authenticate the agent CLIs

```bash
docker compose exec cockpit su - cockpit -c claude   # walks through Claude login
docker compose exec cockpit su - cockpit -c gemini   # walks through Google auth
```

Tokens persist in the `cockpit-data` volume — you only do this once, even
across container rebuilds (as long as you don't delete the volume).

## 4. Open it

`http://localhost:8080` — same UI as a native install, in your normal
browser on the host machine. You never interact with the container directly
after this.

## GPU (optional, Linux hosts only)

Docker Desktop on Windows/macOS doesn't pass a GPU through to containers —
Ollama and LocalAI both run CPU-only there, fine for small models (1-4B). On
a Linux host with the NVIDIA Container Toolkit installed, uncomment the
`deploy:` block in `docker-compose.yml` for real GPU-accelerated inference.

## LocalAI models

LocalAI ships with no models pulled by default (same as Ollama). Pull one
after the container is up:
```bash
curl -X POST http://localhost:8080/models/apply \
  -H "Content-Type: application/json" \
  -d '{"id":"<model-name-from-the-gallery>"}'
```
Browse available models at `http://localhost:8080/models/available` once
running, or use LocalAI's own built-in web UI at that same address.

## Updating

Re-extract a newer tarball's `web/` folder over the old one (into `v2/web/`
or `v1/web/`, matching whichever edition you're running), then:
```bash
docker compose build
docker compose up -d
```
The `cockpit-data` volume (chats, library, CLI auth tokens) is untouched by
this — only the app code itself gets replaced.
