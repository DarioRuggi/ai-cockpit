# Filesystem access

Allows the agent to read, write, list, and delete files **within the current project directory**.

## How it works per agent

- **Claude / Gemini**: connects via the official `@modelcontextprotocol/server-filesystem` MCP server, scoped to the project root.
- **Ollama**: uses cockpit's `%%FS_*%%` command shim — agent emits markers like `%%FS_READ:src/main.pas%%` and the cockpit's crud_executor handles them.

## Safety

Path traversal (`..`) is blocked. Symlinks pointing outside the project root are refused. Writes always go through the cockpit's approval drawer when running in interactive mode.
