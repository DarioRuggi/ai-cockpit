# SSH

Lets the agent run commands on remote hosts via SSH. Uses your existing `~/.ssh/config` for host aliases and authentication.

**Currently only available for Ollama** (via shim). Claude and Gemini can already shell out via their built-in shell tools, so a separate MCP server isn't needed for them.

## Safety

- Always passes through the cockpit's approval drawer for destructive commands.
- Read-only commands (ls, cat, ps, df, free, uptime) auto-approve.
- Refuses to run commands containing `rm -rf`, `dd`, `mkfs`, `> /dev/sd`, or other obviously destructive patterns without explicit user OK.
