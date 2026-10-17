<?php
// =============================================================================
// cli_catalog_default.php — the default Card-1/Card-2 agent catalog, shared by
// suppliers.php (serves + merges the saved override) and launch_cli.php (resolves
// the terminal-launch binary/interactive spec for the assigned alias supplier).
// Extracted 2026-09-04 so the direct terminal-launch path can resolve free_cli
// agents (opencode/aider/goose) even when no cli_suppliers.json override exists.
// Defines: $CLI_CATALOG_DEFAULT
// =============================================================================
// image_mode — how an attached image reaches this agent:
//   'path'     the file path goes in the prompt; the agent opens it itself
//   'flag'     image_flag FILE is added to the command line (image_needs_sep
//              adds `--` before the prompt for variadic flags)
//   'at'       the path is referenced as @file in the prompt text
//   'describe' (DEFAULT when absent) a local vision model describes the image
//              and the TEXT is injected
//
// Absent means describe, deliberately. An agent that cannot see an image does
// not say so — opencode, asked about a photo of a dog via @path, answered "a
// screenshot of image with text and images within that text". A confident wrong
// answer is worse than a plain description, so native handling is opt-in per
// agent and only after someone has actually tested it.
$CLI_CATALOG_DEFAULT = [
    'claude' => [
        'name'       => 'Claude',
        'vendor'     => 'Anthropic',
        'binary'     => 'claude',
        'kind'       => 'paid_cli',
        'cli_flag'   => '-p',
        'model_flag' => '--model',
        'effort_flag'=> '--effort',
        'models'     => [
            ['id' => 'opus',   'label' => 'Opus (strongest)'],
            ['id' => 'sonnet', 'label' => 'Sonnet (balanced)'],
            ['id' => 'haiku',  'label' => 'Haiku (fastest)'],
        ],
        // models.dev provider id → live model list (merged with the aliases above,
        // which the CLI auto-resolves to latest). See action=models.
        'models_provider' => 'anthropic',
        'auth'  => 'subscription',   // subscription | api_key | none
        'free'  => false,            // true → shown with a [Free] badge
        'local' => false,            // true → loads a local GPU model (VRAM modal + guard)
        'detect_cmd' => 'claude --version 2>/dev/null',
        // How this agent can be given an IMAGE (2026-09-23). See the note above
        // $CLI_CATALOG_DEFAULT for what each mode means and why the default is
        // 'describe'. Claude Code opens image files with its own Read tool.
        'image_mode' => 'path',
        // Dialect: Claude is trained to read XML-ish tags as structure separating
        // instructions from material — its own guidance recommends them. Other
        // agents get plain text, where tags are noise they must read past.
        'prompt_style' => 'xml',
    ],
    'gemini' => [
        'name'       => 'Gemini',
        'vendor'     => 'Google',
        'binary'     => 'gemini',
        'kind'       => 'free_rest',
        'cli_flag'   => '-p',
        'model_flag' => '-m',
        'effort_flag'=> '',
        'models'     => [
            ['id' => 'gemini-2.5-flash',      'label' => '2.5 Flash (all-around)'],
            ['id' => 'gemini-2.0-flash-lite', 'label' => '2.0 Flash-Lite (fastest)'],
        ],
        'models_provider' => 'google',
        'auth'  => 'api_key',
        'free'  => true,
        'local' => false,
        'notes' => 'Free tier needs an AI-Studio API key (OAuth login retired 2026-06; new key format required as of 2026-09).',
        'detect_cmd' => 'gemini --version 2>/dev/null',
    ],
    'codex' => [
        'name'       => 'Codex',
        'vendor'     => 'OpenAI',
        'binary'     => 'codex',
        'kind'       => 'paid_cli',
        // codex takes the prompt POSITIONALLY after `exec`; -p is not its prompt
        // flag. It also refuses to run outside a git repo without the skip flag,
        // and then silently waits on stdin, which looks exactly like a hang.
        'cli_flag'   => '',
        'subcmd'     => 'exec',
        'extra_args' => '--skip-git-repo-check',
        'model_flag' => '--model',
        'effort_flag'=> '',
        'models'     => [
            ['id' => 'o4-mini', 'label' => 'o4-mini'],
            ['id' => 'o3',     'label' => 'o3'],
        ],
        'models_provider' => 'openai',
        'auth'  => 'subscription',
        'free'  => false,
        'local' => false,
        'detect_cmd' => 'codex --version 2>/dev/null',
        // `codex exec --image FILE -- "prompt"`. The flag is VARIADIC: without the
        // separator it swallows the prompt as a second image path and then waits
        // on stdin forever. Verified 2026-09-23.
        'image_mode'       => 'flag',
        'image_flag'       => '--image',
        'image_needs_sep'  => true,
    ],
    'groq_build' => [
        'name'       => 'Groq',
        'vendor'     => 'Groq',
        'kind'       => 'free_rest',
        // Dispatched via worker_relay.php + the Workers engine's encrypted key
        // store (workers.php's set_key), NOT a local CLI — there's no "groq"
        // binary to install, so this deliberately has no binary/detect_cmd
        // (those implied a false "not installed" state for a working setup).
        'relay'      => 'groq',
        'cli_flag'   => '-p',
        'model_flag' => '--model',
        'effort_flag'=> '',
        'models'     => [
            ['id' => 'openai/gpt-oss-120b',              'label' => 'GPT-OSS 120B'],
            ['id' => 'openai/gpt-oss-20b',               'label' => 'GPT-OSS 20B (fast)'],
            ['id' => 'meta-llama/llama-4-scout-17b-16e-instruct', 'label' => 'Llama 4 Scout'],
        ],
        'models_provider' => 'groq',
        'auth'  => 'api_key',
        'free'  => true,
        'local' => false,
    ],
    'qwen_code' => [
        'name'       => 'Qwen Code',
        'vendor'     => 'Alibaba',
        'binary'     => 'qwen',
        'kind'       => 'paid_cli',
        'cli_flag'   => '-p',
        'model_flag' => '--model',
        'effort_flag'=> '',
        'models'     => [
            ['id' => 'qwen3-coder', 'label' => 'Qwen3 Coder'],
        ],
        'auth'  => 'api_key',
        'free'  => false,   // free hosted OAuth tier ended 2026-04 → bring your own backend/key
        'local' => false,
        'notes' => 'Free Alibaba OAuth tier ended 2026-04. Now needs a ModelStudio key or a third-party/local backend.',
        'detect_cmd' => 'qwen --version 2>/dev/null',
    ],
    // Free open-source agent → runs on your LOCAL Ollama models (no key, offline).
    // Dispatched via the generic-CLI path (binary + flags from here). model_prefix
    // turns the chosen Ollama tag into aider's "ollama_chat/<tag>" model string;
    // backend=ollama makes the loop export OLLAMA_API_BASE + counts toward the VRAM guard.
    'aider' => [
        'name'        => 'Aider',
        'vendor'      => 'Open Source',
        'binary'      => 'aider',
        'kind'        => 'free_cli',
        'cli_flag'    => '--message',       // one-shot prompt flag (non-interactive)
        'model_flag'  => '--model',
        'effort_flag' => '',
        'parse'       => 'text',
        'extra_args'  => '--no-auto-commits --yes --no-git --no-stream',
        'models_source'=> 'ollama',          // model list = local Ollama tags
        'model_prefix'=> 'ollama_chat/',     // aider's provider-qualified model form
        'backend'     => 'ollama',
        'auth'        => 'none',
        'free'        => true,
        'local'       => true,
        'notes'       => 'Free open-source agent on your local Ollama models — no key, offline. Installed in an isolated venv (no system Python changes); needs Ollama running.',
        // Interactive REPL (for "open CLI in a new terminal"): %MODEL% = the ollama
        // tag from the card, %OLLAMA% = the local Ollama base URL.
        'interactive' => ['cmd' => 'aider --model ollama_chat/%MODEL% --no-auto-commits', 'env' => 'OLLAMA_API_BASE=%OLLAMA%'],
        'detect_cmd'  => 'aider --version 2>/dev/null',
    ],
    // Goose (Block / Linux Foundation) — Rust CLI, no Python. Headless: env vars
    // GOOSE_PROVIDER/GOOSE_MODEL + `goose run -t "<prompt>"`.
    'goose' => [
        'name'         => 'Goose',
        'vendor'       => 'Open Source',
        'binary'       => 'goose',
        'kind'         => 'free_cli',
        'subcmd'       => 'run',
        'cli_flag'     => '-t',          // prompt/instruction text flag
        'model_flag'   => '',            // model comes via env, not a flag
        'model_prefix' => '',
        'env'          => 'GOOSE_PROVIDER=ollama GOOSE_MODEL=%MODEL%',
        'parse'        => 'text',
        'extra_args'   => '',
        'models_source'=> 'ollama',
        'backend'      => 'ollama',
        'auth'         => 'none',
        'free'         => true,
        'local'        => true,
        'notes'        => 'Free open-source agent (Block → Linux Foundation, Rust — no Python) on your local Ollama models. Needs Ollama running.',
        'interactive'  => ['cmd' => 'goose session', 'env' => 'GOOSE_PROVIDER=ollama GOOSE_MODEL=%MODEL% OLLAMA_API_BASE=%OLLAMA%'],
        'detect_cmd'   => 'goose --version 2>/dev/null',
    ],
    // opencode (SST) — Go binary, no Python. Headless: `opencode run --model
    // ollama/<tag> "<prompt>"` (positional prompt). Ollama model needs num_ctx >= 16k.
    'opencode' => [
        'name'         => 'opencode',
        'vendor'       => 'Open Source',
        'binary'       => 'opencode',
        'kind'         => 'free_cli',
        'subcmd'       => 'run',
        'cli_flag'     => '',            // positional prompt (no flag)
        'model_flag'   => '--model',
        'model_prefix' => 'ollama/',
        'parse'        => 'text',
        'extra_args'   => '',
        'models_source'=> 'ollama',
        'backend'      => 'ollama',
        'auth'         => 'none',
        'free'         => true,
        'local'        => true,
        'notes'        => 'Free open-source terminal agent (SST, Go — no Python) on your local Ollama models. Save the Ollama model with num_ctx >= 16k. Needs Ollama running.',
        'interactive'  => ['cmd' => 'opencode --model ollama/%MODEL%', 'env' => 'OLLAMA_API_BASE=%OLLAMA%'],
        'detect_cmd'   => 'opencode --version 2>/dev/null',
    ],
];
