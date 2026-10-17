# Git

Lets the agent inspect and (with approval) modify the project's git repository.

## Safe commands (no approval needed)
status, diff, log, branch, show, blame, ls-files

## Destructive commands (approval required)
add, commit, push, pull, reset, rebase, checkout

## Per agent

- **Claude / Gemini**: official `mcp-server-git` (Python, requires `uvx`/`uv`).
- **Ollama**: shell shim — agent emits `%%GIT:status%%` etc., crud_executor handles dispatch.
