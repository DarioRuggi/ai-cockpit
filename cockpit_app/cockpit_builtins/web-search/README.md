# Web search

Web search via cockpit's existing `search.php` endpoint.

## Per agent

- **Claude**: connects to Anthropic's Brave Search MCP server. Set `BRAVE_API_KEY` env var if you have one (free tier available); otherwise falls through to the cockpit's scrape-based search.
- **Gemini**: not yet wired up (Gemini doesn't have a stable web-search MCP server). Falls through to manual Search tab in the cockpit UI.
- **Ollama**: uses the same `search.php` backend via shell shim.

The cockpit's existing Search panel (right sidebar) also exposes this manually.
