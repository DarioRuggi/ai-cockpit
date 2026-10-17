<?php
// =============================================================================
// themes.php — Cockpit theme system backend
// Dario Ruggi / Cockpit
//
// Stores user theme palettes and the currently-active theme id. Themes are
// keyed by id, schema-versioned, and split into builtin (read-only) vs user
// (editable). The frontend's Theme Editor calls these endpoints to list, get,
// save, delete, and switch themes.
//
// Storage: ~/scripts/cockpit_data/themes.json (rooted via paths.php's
// $PATHS['cockpit_data']).
//
// Endpoints:
//   GET  ?action=list          → all themes + active id
//   GET  ?action=get&id=X      → one theme's full color object
//   POST ?action=save          → create/update a user theme
//                                body: {id, name, mode, colors}
//   POST ?action=delete&id=X   → delete a user theme (builtins protected)
//   POST ?action=set_active    → set active theme
//                                body: {id}
//   GET  ?action=defaults      → return the 4 builtin themes (for re-seed)
// =============================================================================

header('Content-Type: application/json');

// ──────────────────────────────────────────────────────────────────────
// Path resolution — centralized via paths.php
// ──────────────────────────────────────────────────────────────────────
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
$cockpitDataDir = $PATHS['cockpit_data'];
$THEMES_F = $cockpitDataDir . '/themes.json';

// Ensure the directory exists (www-data should already have write access here)
if (!is_dir($cockpitDataDir)) {
    @mkdir($cockpitDataDir, 0775, true);
}

// ──────────────────────────────────────────────────────────────────────
// BUILTIN themes — shipped with cockpit, can't be deleted or overwritten.
// User edits to a builtin go through "Save As" creating a new user theme.
// ──────────────────────────────────────────────────────────────────────
function builtinThemes(): array {
    return [
        'cockpit_original_dark' => [
            'id'      => 'cockpit_original_dark',
            'name'    => 'Cockpit Original',
            'mode'    => 'dark',
            'builtin' => true,
            'colors'  => [
                'background' => [
                    'base'      => '#0e0e10',
                    'panel'     => '#141416',
                    'sidebar'   => '#111113',
                    'console'   => '#0a0a0c',
                    'hover'     => '#1c1c20',
                    'active'    => '#1e1e24',
                    'darker'    => '#0a0a0c',
                    'codeblock' => '#0d1117',
                ],
                'border' => [
                    'dim'    => '#222226',
                    'mid'    => '#2a2a32',
                    'bright' => '#38383f',
                ],
                'text' => [
                    'primary' => '#d8d8dc',
                    'base'    => '#cfd0d4',
                    'dim'     => '#888890',
                    'muted'   => '#555560',
                ],
                'agents' => [
                    'claude'      => '#e0b84e',
                    'claudeDim'   => '#7a6430',
                    'gemini'      => '#5b8fd4',
                    'geminiDim'   => '#324f80',
                    'ollama'      => '#d4873a',
                    'ollamaDim'   => '#7a4a20',
                    'workers'     => '#9d8fe8',
                    'workersDim'  => '#5e548e',
                    'tools'       => '#7dc4a3',
                    'toolsDim'    => '#4a7a64',
                ],
                'accents' => [
                    'amber'  => '#e0b84e',
                    'blue'   => '#4a9eff',
                    'green'  => '#4caf50',
                    'warm'   => '#e8a44a',
                    'ui'     => '#4a9eff',
                    'uiDim'  => '#28568c',
                ],
            ],
        ],
        'soft_terminal_dark' => [
            'id'      => 'soft_terminal_dark',
            'name'    => 'Soft Terminal',
            'mode'    => 'dark',
            'builtin' => true,
            'colors'  => [
                // Lower-contrast dark palette inspired by the user's terminal.
                // Backgrounds are slightly cooler, text is softer (not pure white).
                'background' => [
                    'base'      => '#1d1f21',
                    'panel'     => '#22252a',
                    'sidebar'   => '#1f2126',
                    'console'   => '#181a1d',
                    'hover'     => '#2a2d33',
                    'active'    => '#2f3239',
                    'darker'    => '#15171a',
                    'codeblock' => '#15171a',
                ],
                'border' => [
                    'dim'    => '#2a2d33',
                    'mid'    => '#363a42',
                    'bright' => '#4a4f58',
                ],
                'text' => [
                    'primary' => '#d4d4d8',
                    'base'    => '#bfc1c6',
                    'dim'     => '#8a8d94',
                    'muted'   => '#5e6168',
                ],
                'agents' => [
                    'claude'      => '#d4a84a',   // softer amber
                    'claudeDim'   => '#6e5825',
                    'gemini'      => '#5ec4d5',   // cyan-leaning blue
                    'geminiDim'   => '#306875',
                    'ollama'      => '#e88c5a',   // warm orange
                    'ollamaDim'   => '#7a4a30',
                    'workers'     => '#9590d8',   // softer violet
                    'workersDim'  => '#544f80',
                    'tools'       => '#7ab896',   // muted sage
                    'toolsDim'    => '#446854',
                ],
                'accents' => [
                    'amber'  => '#d4a84a',
                    'blue'   => '#5ec4d5',
                    'green'  => '#7ab896',
                    'warm'   => '#e89850',
                    'ui'     => '#5ec4d5',
                    'uiDim'  => '#336b75',
                ],
            ],
        ],
        'cockpit_original_light' => [
            'id'      => 'cockpit_original_light',
            'name'    => 'Cockpit Original (Light)',
            'mode'    => 'light',
            'builtin' => true,
            'colors'  => [
                'background' => [
                    'base'      => '#f8f8f8',
                    'panel'     => '#ffffff',
                    'sidebar'   => '#f2f2f2',
                    'console'   => '#fafafa',
                    'hover'     => '#ececec',
                    'active'    => '#e0e0e0',
                    'darker'    => '#eaeaea',
                    'codeblock' => '#f0f3f6',
                ],
                'border' => [
                    'dim'    => '#dadadd',
                    'mid'    => '#c4c4c8',
                    'bright' => '#9c9c9f',
                ],
                'text' => [
                    'primary' => '#1a1a1d',
                    'base'    => '#2a2a30',
                    'dim'     => '#5a5a64',
                    'muted'   => '#888892',
                ],
                'agents' => [
                    'claude'      => '#a07020',
                    'claudeDim'   => '#d4b87a',
                    'gemini'      => '#3060a0',
                    'geminiDim'   => '#80a0d0',
                    'ollama'      => '#a05010',
                    'ollamaDim'   => '#d4985a',
                    'workers'     => '#5b4ea0',
                    'workersDim'  => '#9890d0',
                    'tools'       => '#3a8060',
                    'toolsDim'    => '#80b095',
                ],
                'accents' => [
                    'amber'  => '#a07020',
                    'blue'   => '#2070d0',
                    'green'  => '#3a8050',
                    'warm'  => '#c07020',
                    'ui'     => '#2070d0',
                    'uiDim'  => '#113d72',
                ],
            ],
        ],
        'soft_paper_light' => [
            'id'      => 'soft_paper_light',
            'name'    => 'Soft Paper',
            'mode'    => 'light',
            'builtin' => true,
            'colors'  => [
                // Warm, low-contrast light theme
                'background' => [
                    'base'      => '#f5f1e8',
                    'panel'     => '#fbf7ee',
                    'sidebar'   => '#efe8d8',
                    'console'   => '#fcf8ef',
                    'hover'     => '#e8e0cc',
                    'active'    => '#dcd0b8',
                    'darker'    => '#e8e0cc',
                    'codeblock' => '#ede5d0',
                ],
                'border' => [
                    'dim'    => '#d8cfb8',
                    'mid'    => '#c0b598',
                    'bright' => '#998c70',
                ],
                'text' => [
                    'primary' => '#2c2820',
                    'base'    => '#3c3830',
                    'dim'     => '#6a6450',
                    'muted'   => '#9a9078',
                ],
                'agents' => [
                    'claude'      => '#8a6818',
                    'claudeDim'   => '#c4a878',
                    'gemini'      => '#3060a0',
                    'geminiDim'   => '#80a0d0',
                    'ollama'      => '#a04818',
                    'ollamaDim'   => '#d09870',
                    'workers'     => '#6048a0',
                    'workersDim'  => '#a098d0',
                    'tools'       => '#3a7058',
                    'toolsDim'    => '#80b095',
                ],
                'accents' => [
                    'amber'  => '#8a6818',
                    'blue'   => '#3060a0',
                    'green'  => '#3a7058',
                    'warm'  => '#b06020',
                    'ui'     => '#3060a0',
                    'uiDim'  => '#1a3458',
                ],
            ],
        ],

        // ── DARK PRESETS ──────────────────────────────────────────────────────

        'dracula_dark' => [
            'id' => 'dracula_dark', 'name' => 'Dracula', 'mode' => 'dark', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#282a36','panel'=>'#21222c','sidebar'=>'#1e1f29','console'=>'#282a36','hover'=>'#44475a','active'=>'#44475a','darker'=>'#191a21','codeblock'=>'#1e1f29'],
                'border'     => ['dim'=>'#44475a','mid'=>'#6272a4','bright'=>'#bd93f9'],
                'text'       => ['primary'=>'#f8f8f2','base'=>'#cdd6f4','dim'=>'#6272a4','muted'=>'#44475a'],
                'agents'     => ['claude'=>'#bd93f9','claudeDim'=>'#6272a4','gemini'=>'#50fa7b','geminiDim'=>'#2d6940','ollama'=>'#ffb86c','ollamaDim'=>'#7a5530','workers'=>'#8be9fd','workersDim'=>'#2d6472','tools'=>'#ff79c6','toolsDim'=>'#6d2d52'],
                'accents'    => ['amber'=>'#ffb86c','blue'=>'#8be9fd','green'=>'#50fa7b','warm'=>'#ff9955','ui'=>'#8be9fd','uiDim'=>'#4c808b'],
            ],
        ],

        'nord_dark' => [
            'id' => 'nord_dark', 'name' => 'Nord', 'mode' => 'dark', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#2e3440','panel'=>'#272c36','sidebar'=>'#242933','console'=>'#2e3440','hover'=>'#3b4252','active'=>'#434c5e','darker'=>'#1e2228','codeblock'=>'#242933'],
                'border'     => ['dim'=>'#3b4252','mid'=>'#4c566a','bright'=>'#88c0d0'],
                'text'       => ['primary'=>'#eceff4','base'=>'#d8dee9','dim'=>'#4c566a','muted'=>'#3b4252'],
                'agents'     => ['claude'=>'#88c0d0','claudeDim'=>'#3d6e78','gemini'=>'#a3be8c','geminiDim'=>'#4a5e40','ollama'=>'#ebcb8b','ollamaDim'=>'#6e5e38','workers'=>'#81a1c1','workersDim'=>'#3d5268','tools'=>'#b48ead','toolsDim'=>'#5a445c'],
                'accents'    => ['amber'=>'#ebcb8b','blue'=>'#88c0d0','green'=>'#a3be8c','warm'=>'#d08770','ui'=>'#88c0d0','uiDim'=>'#4a6972'],
            ],
        ],

        'monokai_dark' => [
            'id' => 'monokai_dark', 'name' => 'Monokai', 'mode' => 'dark', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#272822','panel'=>'#1e1f1c','sidebar'=>'#1a1b18','console'=>'#272822','hover'=>'#3e3d32','active'=>'#49483e','darker'=>'#141410','codeblock'=>'#1e1f1c'],
                'border'     => ['dim'=>'#3e3d32','mid'=>'#75715e','bright'=>'#a6e22e'],
                'text'       => ['primary'=>'#f8f8f2','base'=>'#cfcfbe','dim'=>'#75715e','muted'=>'#49483e'],
                'agents'     => ['claude'=>'#ae81ff','claudeDim'=>'#5a3d8a','gemini'=>'#a6e22e','geminiDim'=>'#4a6614','ollama'=>'#fd971f','ollamaDim'=>'#7a480e','workers'=>'#66d9e8','workersDim'=>'#2d6472','tools'=>'#f92672','toolsDim'=>'#6d1230'],
                'accents'    => ['amber'=>'#fd971f','blue'=>'#66d9e8','green'=>'#a6e22e','warm'=>'#fd9720','ui'=>'#66d9e8','uiDim'=>'#38777f'],
            ],
        ],

        'one_dark' => [
            'id' => 'one_dark', 'name' => 'One Dark', 'mode' => 'dark', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#282c34','panel'=>'#21252b','sidebar'=>'#1d2025','console'=>'#282c34','hover'=>'#2c313a','active'=>'#363a42','darker'=>'#181a1f','codeblock'=>'#21252b'],
                'border'     => ['dim'=>'#3e4452','mid'=>'#5c6370','bright'=>'#61afef'],
                'text'       => ['primary'=>'#abb2bf','base'=>'#9da5b4','dim'=>'#5c6370','muted'=>'#3e4452'],
                'agents'     => ['claude'=>'#61afef','claudeDim'=>'#2d5270','gemini'=>'#98c379','geminiDim'=>'#3d5430','ollama'=>'#e5c07b','ollamaDim'=>'#6e5a2e','workers'=>'#56b6c2','workersDim'=>'#264d54','tools'=>'#e06c75','toolsDim'=>'#5e2428'],
                'accents'    => ['amber'=>'#e5c07b','blue'=>'#61afef','green'=>'#98c379','warm'=>'#d19a66','ui'=>'#61afef','uiDim'=>'#356083'],
            ],
        ],

        'gruvbox_dark' => [
            'id' => 'gruvbox_dark', 'name' => 'Gruvbox', 'mode' => 'dark', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#282828','panel'=>'#1d2021','sidebar'=>'#1b1c1c','console'=>'#282828','hover'=>'#3c3836','active'=>'#504945','darker'=>'#161819','codeblock'=>'#1d2021'],
                'border'     => ['dim'=>'#3c3836','mid'=>'#665c54','bright'=>'#d79921'],
                'text'       => ['primary'=>'#ebdbb2','base'=>'#d5c4a1','dim'=>'#928374','muted'=>'#504945'],
                'agents'     => ['claude'=>'#83a598','claudeDim'=>'#3a4e4a','gemini'=>'#b8bb26','geminiDim'=>'#565910','ollama'=>'#fabd2f','ollamaDim'=>'#7a5a12','workers'=>'#8ec07c','workersDim'=>'#3e5438','tools'=>'#fb4934','toolsDim'=>'#6e1c12'],
                'accents'    => ['amber'=>'#fabd2f','blue'=>'#83a598','green'=>'#b8bb26','warm'=>'#fe8019','ui'=>'#83a598','uiDim'=>'#485a53'],
            ],
        ],

        'tokyo_night_dark' => [
            'id' => 'tokyo_night_dark', 'name' => 'Tokyo Night', 'mode' => 'dark', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#1a1b26','panel'=>'#13141f','sidebar'=>'#11121c','console'=>'#1a1b26','hover'=>'#24253a','active'=>'#292a3e','darker'=>'#0d0e17','codeblock'=>'#13141f'],
                'border'     => ['dim'=>'#292a3e','mid'=>'#414868','bright'=>'#7aa2f7'],
                'text'       => ['primary'=>'#c0caf5','base'=>'#a9b1d6','dim'=>'#414868','muted'=>'#292a3e'],
                'agents'     => ['claude'=>'#7aa2f7','claudeDim'=>'#2d4270','gemini'=>'#9ece6a','geminiDim'=>'#3c5226','ollama'=>'#e0af68','ollamaDim'=>'#664d24','workers'=>'#7dcfff','workersDim'=>'#2d5a72','tools'=>'#f7768e','toolsDim'=>'#6d2434'],
                'accents'    => ['amber'=>'#e0af68','blue'=>'#7aa2f7','green'=>'#9ece6a','warm'=>'#ff9e64','ui'=>'#7aa2f7','uiDim'=>'#435987'],
            ],
        ],

        // ── LIGHT PRESETS ─────────────────────────────────────────────────────

        'solarized_light' => [
            'id' => 'solarized_light', 'name' => 'Solarized Light', 'mode' => 'light', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#fdf6e3','panel'=>'#eee8d5','sidebar'=>'#e8e2cf','console'=>'#fdf6e3','hover'=>'#e8e2cf','active'=>'#ddd6c0','darker'=>'#ede8d4','codeblock'=>'#eee8d5'],
                'border'     => ['dim'=>'#d3cdb8','mid'=>'#b0a898','bright'=>'#268bd2'],
                'text'       => ['primary'=>'#657b83','base'=>'#586e75','dim'=>'#93a1a1','muted'=>'#b0a898'],
                'agents'     => ['claude'=>'#268bd2','claudeDim'=>'#a8cce8','gemini'=>'#859900','geminiDim'=>'#c8dfa0','ollama'=>'#b58900','ollamaDim'=>'#e8d5a0','workers'=>'#2aa198','workersDim'=>'#a0d4d0','tools'=>'#dc322f','toolsDim'=>'#eda0a0'],
                'accents'    => ['amber'=>'#b58900','blue'=>'#268bd2','green'=>'#859900','warm'=>'#cb4b16','ui'=>'#268bd2','uiDim'=>'#144c73'],
            ],
        ],

        'github_light' => [
            'id' => 'github_light', 'name' => 'GitHub Light', 'mode' => 'light', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#ffffff','panel'=>'#f6f8fa','sidebar'=>'#f0f2f5','console'=>'#ffffff','hover'=>'#eaeef2','active'=>'#dde2e8','darker'=>'#f0f2f5','codeblock'=>'#f6f8fa'],
                'border'     => ['dim'=>'#d0d7de','mid'=>'#b0bac5','bright'=>'#0969da'],
                'text'       => ['primary'=>'#1f2328','base'=>'#24292f','dim'=>'#8c959f','muted'=>'#b0bac5'],
                'agents'     => ['claude'=>'#0969da','claudeDim'=>'#a8c7f0','gemini'=>'#1a7f37','geminiDim'=>'#a0d4b0','ollama'=>'#9a6700','ollamaDim'=>'#e0c878','workers'=>'#0550ae','workersDim'=>'#a0c0e8','tools'=>'#cf222e','toolsDim'=>'#f0a0a0'],
                'accents'    => ['amber'=>'#9a6700','blue'=>'#0969da','green'=>'#1a7f37','warm'=>'#d18616','ui'=>'#0969da','uiDim'=>'#043977'],
            ],
        ],

        'catppuccin_latte' => [
            'id' => 'catppuccin_latte', 'name' => 'Catppuccin Latte', 'mode' => 'light', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#eff1f5','panel'=>'#e6e9ef','sidebar'=>'#dce0e8','console'=>'#eff1f5','hover'=>'#ccd0da','active'=>'#bcc0cc','darker'=>'#e6e9ef','codeblock'=>'#e6e9ef'],
                'border'     => ['dim'=>'#ccd0da','mid'=>'#acb0be','bright'=>'#1e66f5'],
                'text'       => ['primary'=>'#4c4f69','base'=>'#5c5f77','dim'=>'#9ca0b0','muted'=>'#acb0be'],
                'agents'     => ['claude'=>'#1e66f5','claudeDim'=>'#a8c0f8','gemini'=>'#40a02b','geminiDim'=>'#a8d8a0','ollama'=>'#df8e1d','ollamaDim'=>'#f0d098','workers'=>'#04a5e5','workersDim'=>'#a0d8f0','tools'=>'#d20f39','toolsDim'=>'#f0a0a8'],
                'accents'    => ['amber'=>'#df8e1d','blue'=>'#1e66f5','green'=>'#40a02b','warm'=>'#df6e1d','ui'=>'#1e66f5','uiDim'=>'#103886'],
            ],
        ],

        'papercolor_light' => [
            'id' => 'papercolor_light', 'name' => 'PaperColor', 'mode' => 'light', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#eeeeee','panel'=>'#e4e4e4','sidebar'=>'#d8d8d8','console'=>'#eeeeee','hover'=>'#d0d0d0','active'=>'#c4c4c4','darker'=>'#e4e4e4','codeblock'=>'#e4e4e4'],
                'border'     => ['dim'=>'#c4c4c4','mid'=>'#adadad','bright'=>'#0087af'],
                'text'       => ['primary'=>'#444444','base'=>'#5f5f5f','dim'=>'#8a8a8a','muted'=>'#adadad'],
                'agents'     => ['claude'=>'#0087af','claudeDim'=>'#a0ccd8','gemini'=>'#5f8700','geminiDim'=>'#b8d0a0','ollama'=>'#af5f00','ollamaDim'=>'#e0b888','workers'=>'#005f87','workersDim'=>'#a0b8d0','tools'=>'#af0000','toolsDim'=>'#e0a0a0'],
                'accents'    => ['amber'=>'#af5f00','blue'=>'#0087af','green'=>'#5f8700','warm'=>'#af5f00','ui'=>'#0087af','uiDim'=>'#004a60'],
            ],
        ],

        'quiet_light' => [
            'id' => 'quiet_light', 'name' => 'Quiet Light', 'mode' => 'light', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#f5f5f5','panel'=>'#ebebeb','sidebar'=>'#e0e0e0','console'=>'#f5f5f5','hover'=>'#d8d8d8','active'=>'#cccccc','darker'=>'#ebebeb','codeblock'=>'#ebebeb'],
                'border'     => ['dim'=>'#cccccc','mid'=>'#b0b0b0','bright'=>'#5c99d6'],
                'text'       => ['primary'=>'#333333','base'=>'#4d4d4d','dim'=>'#888888','muted'=>'#aaaaaa'],
                'agents'     => ['claude'=>'#5c99d6','claudeDim'=>'#b0cce8','gemini'=>'#4c8c4a','geminiDim'=>'#b0d4b0','ollama'=>'#b05040','ollamaDim'=>'#e0b0a8','workers'=>'#6464c0','workersDim'=>'#b0b0e0','tools'=>'#c04040','toolsDim'=>'#e8b0b0'],
                'accents'    => ['amber'=>'#b05040','blue'=>'#5c99d6','green'=>'#4c8c4a','warm'=>'#c05a30','ui'=>'#5c99d6','uiDim'=>'#325475'],
            ],
        ],

        // ── MIXED PRESETS (dark UI + light content) ───────────────────────────

        'cockpit_mixed' => [
            'id' => 'cockpit_mixed', 'name' => 'Cockpit Mixed', 'mode' => 'mixed', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#e7e7e9','panel'=>'#28282f','sidebar'=>'#212122','console'=>'#e7e7e9','hover'=>'#dcdcdf','active'=>'#d1d1dc','darker'=>'#1e1e25','codeblock'=>'#f0f0f0'],
                'border'     => ['dim'=>'#2a2a32','mid'=>'#c0c0c8','bright'=>'#7ecfff'],
                'text'       => ['primary'=>'#1a1a2e','base'=>'#2a2a3e','dim'=>'#67676d','muted'=>'#555560'],
                'textChrome' => ['primary'=>'#e8eaf0','base'=>'#c9ccd6','dim'=>'#9da1ae','muted'=>'#8b8f9e'],   // light text for the DARK areas (top bar, status bar, sidebars)
                'agents'     => ['claude'=>'#d4a843','claudeDim'=>'#6a5220','gemini'=>'#4a9fd4','geminiDim'=>'#1e4860','ollama'=>'#e07840','ollamaDim'=>'#6a3818','workers'=>'#6db06d','workersDim'=>'#2a4e2a','tools'=>'#9678c8','toolsDim'=>'#3e2860'],
                'accents'    => ['amber'=>'#d4a843','blue'=>'#7ecfff','green'=>'#6db06d','warm'=>'#d08040','ui'=>'#7ecfff','uiDim'=>'#45718c'],
            ],
        ],

        'nord_mixed' => [
            'id' => 'nord_mixed', 'name' => 'Nord Mixed', 'mode' => 'mixed', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#dfe2e6','panel'=>'#393f49','sidebar'=>'#31353e','console'=>'#dfe2e6','hover'=>'#d9dce3','active'=>'#cdd3dc','darker'=>'#2c2f34','codeblock'=>'#f0f0f0'],
                'border'     => ['dim'=>'#3b4252','mid'=>'#b0b8c8','bright'=>'#88c0d0'],
                'text'       => ['primary'=>'#2e3440','base'=>'#3b4252','dim'=>'#5c606a','muted'=>'#5c6068'],
                'textChrome' => ['primary'=>'#f9f9fb','base'=>'#dee0e6','dim'=>'#b8bbc5','muted'=>'#a5a9b4'],   // light text for the DARK areas (top bar, status bar, sidebars)
                'agents'     => ['claude'=>'#5e81ac','claudeDim'=>'#c8d8ec','gemini'=>'#a3be8c','geminiDim'=>'#d0e8c0','ollama'=>'#ebcb8b','ollamaDim'=>'#f0e0b8','workers'=>'#88c0d0','workersDim'=>'#c0e0e8','tools'=>'#bf616a','toolsDim'=>'#e8b8bc'],
                'accents'    => ['amber'=>'#ebcb8b','blue'=>'#88c0d0','green'=>'#a3be8c','warm'=>'#d08770','ui'=>'#88c0d0','uiDim'=>'#4a6972'],
            ],
        ],

        'monokai_mixed' => [
            'id' => 'monokai_mixed', 'name' => 'Monokai Mixed', 'mode' => 'mixed', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#ebebeb','panel'=>'#33342f','sidebar'=>'#282927','console'=>'#ebebeb','hover'=>'#e3e3e3','active'=>'#d9d9d9','darker'=>'#232320','codeblock'=>'#f0f0f0'],
                'border'     => ['dim'=>'#3e3d32','mid'=>'#c0c0b8','bright'=>'#a6e22e'],
                'text'       => ['primary'=>'#272822','base'=>'#3e3d32','dim'=>'#686862','muted'=>'#676763'],
                'textChrome' => ['primary'=>'#e8eaf0','base'=>'#cccfd8','dim'=>'#a9adb8','muted'=>'#9a9eaa'],   // light text for the DARK areas (top bar, status bar, sidebars)
                'agents'     => ['claude'=>'#ae81ff','claudeDim'=>'#e0d0f8','gemini'=>'#a6e22e','geminiDim'=>'#d8f0a8','ollama'=>'#fd971f','ollamaDim'=>'#fde0b8','workers'=>'#66d9e8','workersDim'=>'#c0f0f8','tools'=>'#f92672','toolsDim'=>'#fcc0d8'],
                'accents'    => ['amber'=>'#fd971f','blue'=>'#66d9e8','green'=>'#a6e22e','warm'=>'#fd9720','ui'=>'#66d9e8','uiDim'=>'#38777f'],
            ],
        ],

        // ── PROTANOPIA DARK (6 themes — no red/green distinctions) ───────────

        'dalton_blue_dark' => [
            'id' => 'dalton_blue_dark', 'name' => 'Dalton · Blue Steel (Dark)', 'mode' => 'dark', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#0d1117','panel'=>'#090d13','sidebar'=>'#070b10','console'=>'#0d1117','hover'=>'#161b22','active'=>'#1c2128','darker'=>'#050810','codeblock'=>'#090d13'],
                'border'     => ['dim'=>'#1c2128','mid'=>'#30363d','bright'=>'#58a6ff'],
                'text'       => ['primary'=>'#e6edf3','base'=>'#b1bac4','dim'=>'#484f58','muted'=>'#30363d'],
                'agents'     => ['claude'=>'#58a6ff','claudeDim'=>'#1a3a60','gemini'=>'#79c0ff','geminiDim'=>'#1a3050','ollama'=>'#ffa657','ollamaDim'=>'#6a3a18','workers'=>'#d2a8ff','workersDim'=>'#4a2870','tools'=>'#e3b341','toolsDim'=>'#6a4a10'],
                'accents'    => ['amber'=>'#ffa657','blue'=>'#58a6ff','green'=>'#79c0ff','warm'=>'#ffa657','ui'=>'#58a6ff','uiDim'=>'#305b8c'],
            ],
        ],

        'dalton_amber_dark' => [
            'id' => 'dalton_amber_dark', 'name' => 'Dalton · Amber Night (Dark)', 'mode' => 'dark', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#1a1400','panel'=>'#140f00','sidebar'=>'#100c00','console'=>'#1a1400','hover'=>'#2a2000','active'=>'#382c00','darker'=>'#0a0800','codeblock'=>'#140f00'],
                'border'     => ['dim'=>'#2a2000','mid'=>'#503c00','bright'=>'#ffb000'],
                'text'       => ['primary'=>'#fff8e0','base'=>'#e8d8a0','dim'=>'#806040','muted'=>'#503c00'],
                'agents'     => ['claude'=>'#ffb000','claudeDim'=>'#604200','gemini'=>'#ffe060','geminiDim'=>'#605800','ollama'=>'#80c8ff','ollamaDim'=>'#183060','workers'=>'#d080ff','workersDim'=>'#401860','tools'=>'#60e0e0','toolsDim'=>'#185858'],
                'accents'    => ['amber'=>'#ffb000','blue'=>'#80c8ff','green'=>'#ffe060','warm'=>'#ff9030','ui'=>'#80c8ff','uiDim'=>'#466e8c'],
            ],
        ],

        'dalton_cyan_dark' => [
            'id' => 'dalton_cyan_dark', 'name' => 'Dalton · Cyan Abyss (Dark)', 'mode' => 'dark', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#001a1a','panel'=>'#001212','sidebar'=>'#000e0e','console'=>'#001a1a','hover'=>'#002828','active'=>'#003636','darker'=>'#000808','codeblock'=>'#001212'],
                'border'     => ['dim'=>'#002828','mid'=>'#004848','bright'=>'#00d8d8'],
                'text'       => ['primary'=>'#d0ffff','base'=>'#a0e8e8','dim'=>'#408080','muted'=>'#004848'],
                'agents'     => ['claude'=>'#00d8d8','claudeDim'=>'#005050','gemini'=>'#80ffff','geminiDim'=>'#206060','ollama'=>'#ffd060','ollamaDim'=>'#604800','workers'=>'#c080ff','workersDim'=>'#401860','tools'=>'#ff9020','toolsDim'=>'#602800'],
                'accents'    => ['amber'=>'#ffd060','blue'=>'#00d8d8','green'=>'#80ffff','warm'=>'#ff9030','ui'=>'#00d8d8','uiDim'=>'#007676'],
            ],
        ],

        'dalton_purple_dark' => [
            'id' => 'dalton_purple_dark', 'name' => 'Dalton · Purple Haze (Dark)', 'mode' => 'dark', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#120820','panel'=>'#0c0618','sidebar'=>'#090412','console'=>'#120820','hover'=>'#1e1030','active'=>'#2a1840','darker'=>'#060210','codeblock'=>'#0c0618'],
                'border'     => ['dim'=>'#1e1030','mid'=>'#3a2060','bright'=>'#b060ff'],
                'text'       => ['primary'=>'#ecdcff','base'=>'#c8a8f0','dim'=>'#604888','muted'=>'#3a2060'],
                'agents'     => ['claude'=>'#b060ff','claudeDim'=>'#401880','gemini'=>'#e0a0ff','geminiDim'=>'#602080','ollama'=>'#60c8ff','ollamaDim'=>'#183860','workers'=>'#ffd040','workersDim'=>'#604800','tools'=>'#40d8d8','toolsDim'=>'#105050'],
                'accents'    => ['amber'=>'#ffd040','blue'=>'#60c8ff','green'=>'#e0a0ff','warm'=>'#ff8020','ui'=>'#60c8ff','uiDim'=>'#346e8c'],
            ],
        ],

        'dalton_orange_dark' => [
            'id' => 'dalton_orange_dark', 'name' => 'Dalton · Orange Ember (Dark)', 'mode' => 'dark', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#1a0e00','panel'=>'#140900','sidebar'=>'#100700','console'=>'#1a0e00','hover'=>'#281400','active'=>'#381c00','darker'=>'#0a0400','codeblock'=>'#140900'],
                'border'     => ['dim'=>'#281400','mid'=>'#502800','bright'=>'#ff7800'],
                'text'       => ['primary'=>'#fff0d8','base'=>'#f0d0a0','dim'=>'#805030','muted'=>'#502800'],
                'agents'     => ['claude'=>'#ff7800','claudeDim'=>'#602800','gemini'=>'#ffc040','geminiDim'=>'#604000','ollama'=>'#40c0ff','ollamaDim'=>'#103860','workers'=>'#c060ff','workersDim'=>'#401878','tools'=>'#40e0d8','toolsDim'=>'#105850'],
                'accents'    => ['amber'=>'#ff7800','blue'=>'#40c0ff','green'=>'#ffc040','warm'=>'#ff8020','ui'=>'#40c0ff','uiDim'=>'#23698c'],
            ],
        ],

        'dalton_white_dark' => [
            'id' => 'dalton_white_dark', 'name' => 'Dalton · White Noise (Dark)', 'mode' => 'dark', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#181818','panel'=>'#121212','sidebar'=>'#0e0e0e','console'=>'#181818','hover'=>'#242424','active'=>'#303030','darker'=>'#080808','codeblock'=>'#121212'],
                'border'     => ['dim'=>'#303030','mid'=>'#505050','bright'=>'#e0e0e0'],
                'text'       => ['primary'=>'#ffffff','base'=>'#d8d8d8','dim'=>'#707070','muted'=>'#505050'],
                'agents'     => ['claude'=>'#ffffff','claudeDim'=>'#505050','gemini'=>'#c8c8c8','geminiDim'=>'#404040','ollama'=>'#ffc040','ollamaDim'=>'#604000','workers'=>'#60c8ff','workersDim'=>'#183860','tools'=>'#d060ff','toolsDim'=>'#401878'],
                'accents'    => ['amber'=>'#ffc040','blue'=>'#60c8ff','green'=>'#c8c8c8','warm'=>'#ff8030','ui'=>'#60c8ff','uiDim'=>'#346e8c'],
            ],
        ],

        // ── PROTANOPIA LIGHT (6 themes) ───────────────────────────────────────

        'dalton_sky_light' => [
            'id' => 'dalton_sky_light', 'name' => 'Dalton · Sky (Light)', 'mode' => 'light', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#f0f8ff','panel'=>'#e0f0f8','sidebar'=>'#d0e8f0','console'=>'#f0f8ff','hover'=>'#d8eef8','active'=>'#c8e4f0','darker'=>'#e0f0f8','codeblock'=>'#ffffff'],
                'border'     => ['dim'=>'#b0d0e8','mid'=>'#80b0d0','bright'=>'#0070c0'],
                'text'       => ['primary'=>'#002040','base'=>'#003060','dim'=>'#4080a0','muted'=>'#80b0d0'],
                'agents'     => ['claude'=>'#0070c0','claudeDim'=>'#b0d0f0','gemini'=>'#0050a0','geminiDim'=>'#a0c8f0','ollama'=>'#d07800','ollamaDim'=>'#f0d0a0','workers'=>'#6030c0','workersDim'=>'#d0b8f0','tools'=>'#c05800','toolsDim'=>'#f0d0b0'],
                'accents'    => ['amber'=>'#d07800','blue'=>'#0070c0','green'=>'#0050a0','warm'=>'#c06800','ui'=>'#0070c0','uiDim'=>'#003d69'],
            ],
        ],

        'dalton_sun_light' => [
            'id' => 'dalton_sun_light', 'name' => 'Dalton · Sunshine (Light)', 'mode' => 'light', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#fffff0','panel'=>'#f8f8d8','sidebar'=>'#f0f0c0','console'=>'#fffff0','hover'=>'#f0f0c8','active'=>'#e8e8b0','darker'=>'#f8f8d8','codeblock'=>'#ffffff'],
                'border'     => ['dim'=>'#d8d890','mid'=>'#b8b860','bright'=>'#807000'],
                'text'       => ['primary'=>'#302800','base'=>'#484000','dim'=>'#807840','muted'=>'#b8b060'],
                'agents'     => ['claude'=>'#806000','claudeDim'=>'#e8d880','gemini'=>'#505000','geminiDim'=>'#d8d880','ollama'=>'#005880','ollamaDim'=>'#a0c8e0','workers'=>'#500080','workersDim'=>'#d0a8e8','tools'=>'#004060','toolsDim'=>'#a0c8d8'],
                'accents'    => ['amber'=>'#806000','blue'=>'#005880','green'=>'#505000','warm'=>'#a05800','ui'=>'#005880','uiDim'=>'#003046'],
            ],
        ],

        'dalton_lavender_light' => [
            'id' => 'dalton_lavender_light', 'name' => 'Dalton · Lavender (Light)', 'mode' => 'light', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#f5f0ff','panel'=>'#ece0ff','sidebar'=>'#e0d0f8','console'=>'#f5f0ff','hover'=>'#e8d8ff','active'=>'#d8c8f0','darker'=>'#ece0ff','codeblock'=>'#ffffff'],
                'border'     => ['dim'=>'#c8b0e8','mid'=>'#a880d0','bright'=>'#6020c0'],
                'text'       => ['primary'=>'#200840','base'=>'#381060','dim'=>'#806090','muted'=>'#b090d0'],
                'agents'     => ['claude'=>'#6020c0','claudeDim'=>'#d0b8f0','gemini'=>'#3000a0','geminiDim'=>'#c0a8f0','ollama'=>'#c06000','ollamaDim'=>'#f0d0a0','workers'=>'#0060c0','workersDim'=>'#a8c8f0','tools'=>'#006080','toolsDim'=>'#a8d0e0'],
                'accents'    => ['amber'=>'#c06000','blue'=>'#0060c0','green'=>'#3000a0','warm'=>'#c06800','ui'=>'#0060c0','uiDim'=>'#003469'],
            ],
        ],

        'dalton_ice_light' => [
            'id' => 'dalton_ice_light', 'name' => 'Dalton · Ice (Light)', 'mode' => 'light', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#f0ffff','panel'=>'#d8f8f8','sidebar'=>'#c0f0f0','console'=>'#f0ffff','hover'=>'#d0f0f0','active'=>'#b8e8e8','darker'=>'#d8f8f8','codeblock'=>'#ffffff'],
                'border'     => ['dim'=>'#90d8d8','mid'=>'#60b8b8','bright'=>'#007878'],
                'text'       => ['primary'=>'#002828','base'=>'#003838','dim'=>'#408080','muted'=>'#60a8a8'],
                'agents'     => ['claude'=>'#007878','claudeDim'=>'#a0d8d8','gemini'=>'#005050','geminiDim'=>'#90c8c8','ollama'=>'#a06000','ollamaDim'=>'#f0d8a0','workers'=>'#500090','workersDim'=>'#d0a8f0','tools'=>'#0040a0','toolsDim'=>'#a0b8f0'],
                'accents'    => ['amber'=>'#a06000','blue'=>'#007878','green'=>'#005050','warm'=>'#a05800','ui'=>'#007878','uiDim'=>'#004242'],
            ],
        ],

        'dalton_sand_light' => [
            'id' => 'dalton_sand_light', 'name' => 'Dalton · Sand (Light)', 'mode' => 'light', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#fdf8f0','panel'=>'#f5ede0','sidebar'=>'#ece0d0','console'=>'#fdf8f0','hover'=>'#ede0d0','active'=>'#e0d0b8','darker'=>'#f5ede0','codeblock'=>'#ffffff'],
                'border'     => ['dim'=>'#d0c0a8','mid'=>'#b0a080','bright'=>'#805030'],
                'text'       => ['primary'=>'#302010','base'=>'#483018','dim'=>'#806040','muted'=>'#b09870'],
                'agents'     => ['claude'=>'#805030','claudeDim'=>'#e8d0b8','gemini'=>'#503010','geminiDim'=>'#d8c0a0','ollama'=>'#003880','ollamaDim'=>'#a8c0e0','workers'=>'#480080','workersDim'=>'#d0a8f0','tools'=>'#006070','toolsDim'=>'#a0d0d8'],
                'accents'    => ['amber'=>'#805030','blue'=>'#003880','green'=>'#503010','warm'=>'#804800','ui'=>'#003880','uiDim'=>'#001e46'],
            ],
        ],

        'dalton_contrast_light' => [
            'id' => 'dalton_contrast_light', 'name' => 'Dalton · High Contrast (Light)', 'mode' => 'light', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#ffffff','panel'=>'#f0f0f0','sidebar'=>'#e0e0e0','console'=>'#ffffff','hover'=>'#e8e8e8','active'=>'#d0d0d0','darker'=>'#f0f0f0','codeblock'=>'#f8f8f8'],
                'border'     => ['dim'=>'#b0b0b0','mid'=>'#808080','bright'=>'#000080'],
                'text'       => ['primary'=>'#000000','base'=>'#101010','dim'=>'#505050','muted'=>'#808080'],
                'agents'     => ['claude'=>'#000080','claudeDim'=>'#a0a0e0','gemini'=>'#004080','geminiDim'=>'#a0c0e0','ollama'=>'#804000','ollamaDim'=>'#e0c0a0','workers'=>'#400080','workersDim'=>'#c0a0e0','tools'=>'#006060','toolsDim'=>'#a0d0d0'],
                'accents'    => ['amber'=>'#804000','blue'=>'#000080','green'=>'#004080','warm'=>'#804000','ui'=>'#000080','uiDim'=>'#000046'],
            ],
        ],

        // ── PROTANOPIA MIXED (6 themes — dark UI + light content) ────────────

        'dalton_blue_mixed' => [
            'id' => 'dalton_blue_mixed', 'name' => 'Dalton · Blue Mixed', 'mode' => 'mixed', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#e3eaf0','panel'=>'#1d2126','sidebar'=>'#181b20','console'=>'#e3eaf0','hover'=>'#d4e3ea','active'=>'#c6dce3','darker'=>'#161920','codeblock'=>'#f0f0f0'],
                'border'     => ['dim'=>'#1c2128','mid'=>'#90c0e0','bright'=>'#58a6ff'],
                'text'       => ['primary'=>'#002040','base'=>'#003060','dim'=>'#484f58','muted'=>'#30363d'],
                'textChrome' => ['primary'=>'#e8eaf0','base'=>'#c9ccd6','dim'=>'#9a9eac','muted'=>'#838897'],   // light text for the DARK areas (top bar, status bar, sidebars)
                'agents'     => ['claude'=>'#58a6ff','claudeDim'=>'#1a3a60','gemini'=>'#79c0ff','geminiDim'=>'#1a3050','ollama'=>'#ffa657','ollamaDim'=>'#6a3a18','workers'=>'#d2a8ff','workersDim'=>'#4a2870','tools'=>'#e3b341','toolsDim'=>'#6a4a10'],
                'accents'    => ['amber'=>'#ffa657','blue'=>'#58a6ff','green'=>'#79c0ff','warm'=>'#ffa657','ui'=>'#58a6ff','uiDim'=>'#305b8c'],
            ],
        ],

        'dalton_amber_mixed' => [
            'id' => 'dalton_amber_mixed', 'name' => 'Dalton · Amber Mixed', 'mode' => 'mixed', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#f0f0e3','panel'=>'#282312','sidebar'=>'#201c12','console'=>'#f0f0e3','hover'=>'#eaeacd','active'=>'#e3e3b8','darker'=>'#1b1912','codeblock'=>'#f0f0f0'],
                'border'     => ['dim'=>'#2a2000','mid'=>'#c0b080','bright'=>'#ffb000'],
                'text'       => ['primary'=>'#302800','base'=>'#484000','dim'=>'#806040','muted'=>'#6e6a3a'],
                'textChrome' => ['primary'=>'#e8eaf0','base'=>'#c9ccd6','dim'=>'#9a9eac','muted'=>'#878b9a'],   // light text for the DARK areas (top bar, status bar, sidebars)
                'agents'     => ['claude'=>'#ffb000','claudeDim'=>'#604200','gemini'=>'#ffe060','geminiDim'=>'#605800','ollama'=>'#80c8ff','ollamaDim'=>'#183060','workers'=>'#d080ff','workersDim'=>'#401860','tools'=>'#60e0e0','toolsDim'=>'#185858'],
                'accents'    => ['amber'=>'#ffb000','blue'=>'#80c8ff','green'=>'#ffe060','warm'=>'#ff9030','ui'=>'#80c8ff','uiDim'=>'#466e8c'],
            ],
        ],

        'dalton_cyan_mixed' => [
            'id' => 'dalton_cyan_mixed', 'name' => 'Dalton · Cyan Mixed', 'mode' => 'mixed', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#e3f0f0','panel'=>'#122828','sidebar'=>'#121e1e','console'=>'#e3f0f0','hover'=>'#cdeaea','active'=>'#b8e3e3','darker'=>'#121919','codeblock'=>'#f0f0f0'],
                'border'     => ['dim'=>'#002828','mid'=>'#60b8b8','bright'=>'#00d8d8'],
                'text'       => ['primary'=>'#002828','base'=>'#003838','dim'=>'#387171','muted'=>'#417272'],
                'textChrome' => ['primary'=>'#e8eaf0','base'=>'#c9ccd6','dim'=>'#9a9eac','muted'=>'#878b9a'],   // light text for the DARK areas (top bar, status bar, sidebars)
                'agents'     => ['claude'=>'#00d8d8','claudeDim'=>'#005050','gemini'=>'#80ffff','geminiDim'=>'#206060','ollama'=>'#ffd060','ollamaDim'=>'#604800','workers'=>'#c080ff','workersDim'=>'#401860','tools'=>'#ff9020','toolsDim'=>'#602800'],
                'accents'    => ['amber'=>'#ffd060','blue'=>'#00d8d8','green'=>'#80ffff','warm'=>'#ff9030','ui'=>'#00d8d8','uiDim'=>'#007676'],
            ],
        ],

        'dalton_purple_mixed' => [
            'id' => 'dalton_purple_mixed', 'name' => 'Dalton · Purple Mixed', 'mode' => 'mixed', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#e7e3f0','panel'=>'#21192d','sidebar'=>'#1a1521','console'=>'#e7e3f0','hover'=>'#dfd4f0','active'=>'#d4c6ea','darker'=>'#171420','codeblock'=>'#f0f0f0'],
                'border'     => ['dim'=>'#1e1030','mid'=>'#c0a8e0','bright'=>'#b060ff'],
                'text'       => ['primary'=>'#200840','base'=>'#381060','dim'=>'#765884','muted'=>'#715c85'],
                'textChrome' => ['primary'=>'#e8eaf0','base'=>'#c9ccd6','dim'=>'#9a9eac','muted'=>'#7f8494'],   // light text for the DARK areas (top bar, status bar, sidebars)
                'agents'     => ['claude'=>'#b060ff','claudeDim'=>'#401880','gemini'=>'#e0a0ff','geminiDim'=>'#602080','ollama'=>'#60c8ff','ollamaDim'=>'#183860','workers'=>'#ffd040','workersDim'=>'#604800','tools'=>'#40d8d8','toolsDim'=>'#105050'],
                'accents'    => ['amber'=>'#ffd040','blue'=>'#60c8ff','green'=>'#e0a0ff','warm'=>'#ff8020','ui'=>'#60c8ff','uiDim'=>'#346e8c'],
            ],
        ],

        'dalton_orange_mixed' => [
            'id' => 'dalton_orange_mixed', 'name' => 'Dalton · Orange Mixed', 'mode' => 'mixed', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#f0eae3','panel'=>'#281e12','sidebar'=>'#201812','console'=>'#f0eae3','hover'=>'#eadfd4','active'=>'#e3d4c6','darker'=>'#1b1512','codeblock'=>'#f0f0f0'],
                'border'     => ['dim'=>'#281400','mid'=>'#d0b090','bright'=>'#ff7800'],
                'text'       => ['primary'=>'#301800','base'=>'#482400','dim'=>'#805030','muted'=>'#866149'],
                'textChrome' => ['primary'=>'#e8eaf0','base'=>'#c9ccd6','dim'=>'#9a9eac','muted'=>'#838897'],   // light text for the DARK areas (top bar, status bar, sidebars)
                'agents'     => ['claude'=>'#ff7800','claudeDim'=>'#602800','gemini'=>'#ffc040','geminiDim'=>'#604000','ollama'=>'#40c0ff','ollamaDim'=>'#103860','workers'=>'#c060ff','workersDim'=>'#401878','tools'=>'#40e0d8','toolsDim'=>'#105850'],
                'accents'    => ['amber'=>'#ff7800','blue'=>'#40c0ff','green'=>'#ffc040','warm'=>'#ff8020','ui'=>'#40c0ff','uiDim'=>'#23698c'],
            ],
        ],

        'dalton_contrast_mixed' => [
            'id' => 'dalton_contrast_mixed', 'name' => 'Dalton · High Contrast Mixed', 'mode' => 'mixed', 'builtin' => true,
            'colors' => [
                'background' => ['base'=>'#f0f0f0','panel'=>'#121212','sidebar'=>'#1b1b1b','console'=>'#f0f0f0','hover'=>'#e3e3e3','active'=>'#d4d4d4','darker'=>'#161616','codeblock'=>'#f0f0f0'],
                'border'     => ['dim'=>'#202020','mid'=>'#a0a0a0','bright'=>'#0060ff'],
                'text'       => ['primary'=>'#000000','base'=>'#101010','dim'=>'#505050','muted'=>'#6c6c6c'],
                'textChrome' => ['primary'=>'#ffffff','base'=>'#f2f2f2','dim'=>'#d8d8d8','muted'=>'#bdbdbd'],   // light text for the DARK areas (top bar, status bar, sidebars)
                'agents'     => ['claude'=>'#0060ff','claudeDim'=>'#a0b8ff','gemini'=>'#6464d9','geminiDim'=>'#a0a0f0','ollama'=>'#a86200','ollamaDim'=>'#f0d890','workers'=>'#a850a8','workersDim'=>'#e0a0e0','tools'=>'#0e7f7f','toolsDim'=>'#a0e0e0'],
                'accents'    => ['amber'=>'#a86200','blue'=>'#0060ff','green'=>'#6464d9','warm'=>'#b45a00','ui'=>'#0060ff','uiDim'=>'#00348c'],
            ],
        ],
    ];
}

// ──────────────────────────────────────────────────────────────────────
// Storage helpers
// ──────────────────────────────────────────────────────────────────────
function loadStore(string $path): array {
    if (!file_exists($path)) {
        return ['schemaVersion' => 1, 'active' => 'cockpit_original_dark', 'user_themes' => []];
    }
    $raw = file_get_contents($path);
    $data = json_decode($raw, true);
    if (!is_array($data)) {
        return ['schemaVersion' => 1, 'active' => 'cockpit_original_dark', 'user_themes' => []];
    }
    if (!isset($data['user_themes']) || !is_array($data['user_themes'])) {
        $data['user_themes'] = [];
    }
    if (empty($data['active'])) {
        $data['active'] = 'cockpit_original_dark';
    }
    return $data;
}

function saveStore(string $path, array $data): bool {
    $json = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    if ($json === false) return false;
    $tmp = $path . '.tmp';
    if (file_put_contents($tmp, $json, LOCK_EX) === false) return false;
    return rename($tmp, $path);
}

// Validate a theme id — restrict to safe characters, no path traversal
function safeThemeId(string $s): string {
    return preg_replace('/[^a-z0-9_-]/i', '', $s);
}

// Combined view: builtins + user themes, with a 'merged' index
function allThemes(array $store): array {
    $merged = builtinThemes();
    foreach ($store['user_themes'] as $id => $t) {
        $t['builtin'] = false;   // safety: a user theme can't claim builtin status
        $merged[$id] = $t;
    }
    return $merged;
}

// ──────────────────────────────────────────────────────────────────────
// Action dispatch
// ──────────────────────────────────────────────────────────────────────
$action = $_GET['action'] ?? $_POST['action'] ?? '';
$rawIn  = file_get_contents('php://input');
$in     = json_decode($rawIn, true);
if (!is_array($in)) $in = [];

$store = loadStore($THEMES_F);

if ($action === 'list') {
    $themes = allThemes($store);
    // Slim payload — frontend asks for full theme via 'get' when needed
    $list = [];
    foreach ($themes as $id => $t) {
        $list[] = [
            'id'      => $id,
            'name'    => $t['name'],
            'mode'    => $t['mode'] ?? 'dark',
            'builtin' => !empty($t['builtin']),
            // three colours for the swatch in the custom drop-down list: page background, text, accent (hex strings only)
            'swatch'  => array_values(array_filter([
                $t['colors']['background']['base'] ?? null,
                $t['colors']['text']['primary'] ?? null,
                $t['colors']['accents']['ui'] ?? null,
            ], fn($c) => is_string($c) && preg_match('/^#[0-9a-fA-F]{3,8}$/', $c))),
        ];
    }
    echo json_encode([
        'ok'     => true,
        'active' => $store['active'],
        'chosen' => !empty($store['chosen']),   // false until the person picks one — the page then follows the desktop's light/dark
        'themes' => $list,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'get') {
    $id = safeThemeId($_GET['id'] ?? $in['id'] ?? '');
    $themes = allThemes($store);
    if (!isset($themes[$id])) {
        echo json_encode(['ok' => false, 'error' => 'Theme not found: ' . $id], JSON_UNESCAPED_UNICODE);
        exit;
    }
    echo json_encode(['ok' => true, 'theme' => $themes[$id]], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'defaults') {
    echo json_encode(['ok' => true, 'themes' => array_values(builtinThemes())], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'save') {
    $id   = safeThemeId($in['id']   ?? '');
    $name = trim((string)($in['name'] ?? ''));
    $mode = in_array($in['mode'] ?? '', ['light', 'mixed'], true) ? $in['mode'] : 'dark';   // 'mixed' was silently stored as 'dark' until 2026-10-06
    $cols = $in['colors'] ?? null;

    if (!$id || !$name || !is_array($cols)) {
        echo json_encode(['ok' => false, 'error' => 'Missing id, name, or colors'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    // Builtin protection: cannot save under a builtin id
    if (isset(builtinThemes()[$id])) {
        echo json_encode(['ok' => false, 'error' => 'Cannot overwrite builtin theme — use a different id'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    $store['user_themes'][$id] = [
        'id'      => $id,
        'name'    => $name,
        'mode'    => $mode,
        'builtin' => false,
        'colors'  => $cols,
    ];
    if (!saveStore($THEMES_F, $store)) {
        echo json_encode(['ok' => false, 'error' => 'Failed to write themes file'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    echo json_encode(['ok' => true, 'id' => $id], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'delete') {
    $id = safeThemeId($_GET['id'] ?? $in['id'] ?? '');
    if (isset(builtinThemes()[$id])) {
        echo json_encode(['ok' => false, 'error' => 'Cannot delete builtin theme'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    if (!isset($store['user_themes'][$id])) {
        echo json_encode(['ok' => false, 'error' => 'User theme not found'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    unset($store['user_themes'][$id]);
    // If we just deleted the active theme, fall back to cockpit_original_dark
    if ($store['active'] === $id) {
        $store['active'] = 'cockpit_original_dark';
    }
    if (!saveStore($THEMES_F, $store)) {
        echo json_encode(['ok' => false, 'error' => 'Failed to write themes file'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    echo json_encode(['ok' => true], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'set_active') {
    $id = safeThemeId($in['id'] ?? '');
    $themes = allThemes($store);
    if (!isset($themes[$id])) {
        echo json_encode(['ok' => false, 'error' => 'Theme not found: ' . $id], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $store['active'] = $id;
    $store['chosen'] = true;
    if (!saveStore($THEMES_F, $store)) {
        echo json_encode(['ok' => false, 'error' => 'Failed to write themes file'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    echo json_encode(['ok' => true, 'active' => $id], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok' => false, 'error' => 'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
