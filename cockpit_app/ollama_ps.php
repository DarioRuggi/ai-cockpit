<?php
// =============================================================================
// ollama_ps.php — VRAM monitor endpoint for the Power Combos UI.
// GET → loaded Ollama models + MB + GPU/CPU split. Read-only, local data.
// =============================================================================
header('Content-Type: application/json');
header('Cache-Control: no-store');
// combos_core.php defines combos_active_backend()/combos_backend_base() that
// ollama_ps() (in combos_lib.php) calls; requiring combos_lib alone left them
// undefined → fatal every poll. combos_core pulls in combos_lib itself.
// Local app authentication, like every other backend. This endpoint answered
// unauthenticated with the list of loaded models and their VRAM -- far less
// valuable than the account details saas.php was handing out, but the same
// class of gap, and it is polled from the Power Combos UI which is behind the
// login anyway. auth.php allows first-run and auto-sessions the demo edition.
require_once __DIR__ . '/auth.php';
require __DIR__ . '/combos_core.php';
echo json_encode(ollama_ps(), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
