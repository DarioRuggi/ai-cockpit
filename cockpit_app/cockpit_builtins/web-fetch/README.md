# Web fetch

Lets the agent retrieve a URL's content as plain text. HTML is stripped, results are capped at 16KB.

Useful for:
- Reading docs (e.g., "fetch the FPC reference manual page on `TStringList`")
- Pulling release notes
- Following up on search results

Uses Anthropic's official `mcp-server-fetch` for Claude/Gemini, and cockpit's `search.php?action=fetch` for Ollama.
