<?php
// =============================================================================
// chunk_pipeline.php — Sanitizer extraction + chunking pipeline
//
// Implements:
//   - Format_Extractor interface (format-agnostic)
//   - PDF_Extractor (pdftotext primary, pandoc fallback)
//   - chunk_pipeline() — the full pipeline from filepath to sized chunks
//   - pre_split()      — structural split by headings/paragraphs
//   - token_fit()      — ensure each chunk ≤ TOKEN_CEILING, recombine smalls
//
// Usage (from sanitizer.php):
//   require_once __DIR__ . '/chunk_pipeline.php';
//   $result = chunk_pipeline($filepath, $language_hint);
//   // $result = ['chunks' => [...], 'sections' => [...], 'book_title' => string, 'error' => string|null]
//
// Each chunk in $result['chunks']:
//   [
//     'index'   => int,          // 0-based chunk number
//     'text'    => string,       // the raw text to send to LLM
//     'tokens'  => int,          // estimated token count
//     'section' => string,       // nearest heading above this chunk
//   ]
//
// =============================================================================

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) ed_demo_stub();

// Token ceiling per chunk — 2,000 estimated tokens.
// qwen2.5-coder:1.5b has ~4K context; our prompt overhead is ~500 tokens,
// leaving ~3,500 for content. We cap at 2,000 to leave headroom for
// the model's output and to keep chunks manageable for small local models.
// The 7b fallback handles larger chunks fine with num_ctx:8192.
const TOKEN_CEILING  = 2000;

// Minimum chunk size before we try to recombine with the next chunk.
const TOKEN_MIN_RECOMBINE = 200;

// Rough characters-per-token estimate (English/code mix).
// GPT-family is ~4 chars/token; we use 3.5 to be conservative (err big).
const CHARS_PER_TOKEN = 3.5;

// =============================================================================
// Format_Extractor interface
// =============================================================================
interface Format_Extractor {
    // Returns true if this extractor handles the given filename
    public function supports(string $filename): bool;

    // Extract text + structure from the file.
    // Returns:
    //   [
    //     'markdown' => string,           // full extracted text (may not be true MD)
    //     'sections' => [                 // detected headings, in order
    //       ['title' => string, 'level' => int, 'char_offset' => int],
    //       ...
    //     ],
    //     'book_title' => string,         // best guess at book/document title
    //     'error'   => string|null,       // non-null if extraction failed
    //   ]
    public function extract(string $filepath): array;
}

// =============================================================================
// PDF_Extractor
//
// Strategy:
//   1. Try pdftotext (poppler) — fastest, best plain-text output for books
//   2. Fall back to pandoc if pdftotext fails or is missing
//   3. Post-process: strip form-feed chars (page breaks), normalise whitespace
//   4. Detect headings heuristically (ALL CAPS lines, or short lines followed
//      by a blank line, or lines that look like "Chapter N" / "N. Title")
// =============================================================================
class PDF_Extractor implements Format_Extractor {

    public function supports(string $filename): bool {
        return strtolower(pathinfo($filename, PATHINFO_EXTENSION)) === 'pdf';
    }

    public function extract(string $filepath): array {
        if (!is_file($filepath)) {
            return $this->_err("File not found: $filepath");
        }

        // --- Try pdftotext ---
        $text = $this->_pdftotext($filepath);

        // --- Fallback to pandoc ---
        if ($text === null) {
            $text = $this->_pandoc_pdf($filepath);
        }

        if ($text === null) {
            return $this->_err("Both pdftotext and pandoc failed to extract text from: $filepath");
        }

        // --- Post-process text layer ---
        $text = $this->_clean($text);

        // --- Vision augmentation ---
        // If the text layer is sparse (lots of image-only pages with code
        // in screenshots), extract code blocks via gemma3:4b vision model.
        // Threshold: fewer than 100 chars per page = mostly images.
        $page_count = $this->_pdf_page_count($filepath);
        $chars_per_page = $page_count > 0 ? (strlen($text) / $page_count) : 9999;
        if ($chars_per_page < 100 || $this->_looks_code_sparse($text)) {
            $vision_code = $this->_vision_extract($filepath, $page_count);
            if ($vision_code !== '') {
                $text .= "\n\n" . $vision_code;
            }
        }

        // --- Detect structure ---
        $sections   = $this->_detect_sections($text);
        $book_title = $this->_guess_title($filepath, $text, $sections);

        return [
            'markdown'   => $text,
            'sections'   => $sections,
            'book_title' => $book_title,
            'error'      => null,
        ];
    }

    // -------------------------------------------------------------------------
    // pdftotext extraction
    // -------------------------------------------------------------------------
    private function _pdftotext(string $filepath): ?string {
        $which = trim((string)shell_exec('which pdftotext 2>/dev/null'));
        if (!$which) return null;

        // -layout preserves spacing; -nopgbrk omits form-feeds.
        // MED-99: timeout 60s prevents a malformed PDF from hanging the request.
        $cmd = sprintf(
            '%s%s -layout -nopgbrk %s - 2>/dev/null',
            cockpit_timeout_cmd(60),
            escapeshellarg($which),
            escapeshellarg($filepath)
        );
        $output = shell_exec($cmd);
        if ($output === null || trim($output) === '') return null;
        return $output;
    }

    // -------------------------------------------------------------------------
    // pandoc fallback (PDF → plain text via pdftotext internal or native)
    // -------------------------------------------------------------------------
    private function _pandoc_pdf(string $filepath): ?string {
        $which = trim((string)shell_exec('which pandoc 2>/dev/null'));
        if (!$which) return null;

        $cmd = sprintf(
            '%s%s --from=pdf --to=plain %s 2>/dev/null',
            cockpit_timeout_cmd(60),
            escapeshellarg($which),
            escapeshellarg($filepath)
        );
        $output = shell_exec($cmd);
        if ($output === null || trim($output) === '') return null;
        return $output;
    }

    // -------------------------------------------------------------------------
    // Get PDF page count via pdfinfo
    // -------------------------------------------------------------------------
    private function _pdf_page_count(string $filepath): int {
        $which = trim((string)shell_exec('which pdfinfo 2>/dev/null'));
        if (!$which) return 0;
        $out = shell_exec(sprintf('%s%s %s 2>/dev/null',
            cockpit_timeout_cmd(15), escapeshellarg($which), escapeshellarg($filepath)));
        if (preg_match('/Pages:\s*(\d+)/i', (string)$out, $m)) {
            return (int)$m[1];
        }
        return 0;
    }

    // -------------------------------------------------------------------------
    // Heuristic: does the text look like it's missing code?
    // True if text has very few lines that look like code (indented, keywords)
    // -------------------------------------------------------------------------
    private function _looks_code_sparse(string $text): bool {
        $lines = explode("\n", $text);
        $code_lines = 0;
        foreach ($lines as $line) {
            // Lines that look like code: start with spaces/tabs, contain
            // Pascal/Delphi keywords, braces, semicolons, assignments
            if (preg_match('/^\s{2,}.*(:=|begin|end|procedure|function|var|type|uses|class|interface|implementation)/i', $line)) {
                $code_lines++;
            }
        }
        // If fewer than 5 code-looking lines in the whole document → sparse
        return $code_lines < 5;
    }

    // -------------------------------------------------------------------------
    // Vision extraction: rasterize each page with pdftoppm, send to
    // gemma3:4b via Ollama, collect code blocks.
    //
    // Uses gemma3:4b (3.3GB — fits in 4GB VRAM, runs on GPU, fast).
    // Falls back to gemma3:12b if 4b returns empty on the first page.
    //
    // Returns a string of all extracted code blocks joined by double newline,
    // or empty string if nothing found or vision unavailable.
    // -------------------------------------------------------------------------
    private function _vision_extract(string $filepath, int $page_count): string {
        $pdftoppm = trim((string)shell_exec('which pdftoppm 2>/dev/null'));
        if (!$pdftoppm) return '';

        // Pick vision model — prefer 4b (fits in VRAM), fallback to 12b
        $vision_model = $this->_pick_vision_model();
        if (!$vision_model) return '';

        $tmp_dir = sys_get_temp_dir() . '/cockpit_vision_' . getmypid();
        @mkdir($tmp_dir, 0700, true);

        $all_code = [];
        $pages = $page_count > 0 ? $page_count : 99;   // cap at 99 if unknown

        for ($page = 1; $page <= $pages; $page++) {
            // Rasterize one page to PNG at 150dpi (good balance of quality/speed)
            $prefix = $tmp_dir . '/page';
            $cmd = sprintf(
                '%s%s -r 150 -png -f %d -l %d %s %s 2>/dev/null',
                cockpit_timeout_cmd(30),
                escapeshellarg($pdftoppm),
                $page, $page,
                escapeshellarg($filepath),
                escapeshellarg($prefix)
            );
            shell_exec($cmd);

            // Find the generated PNG (pdftoppm names it prefix-NN.png)
            $pngs = glob($tmp_dir . '/*.png');
            if (!$pngs) continue;
            $png = $pngs[0];   // only one page at a time

            $code_blocks = $this->_vision_ocr_page($png, $vision_model);
            if ($code_blocks) {
                $all_code = array_merge($all_code, $code_blocks);
            }

            // Clean up PNG immediately to save disk space
            @unlink($png);
        }

        // Clean up temp dir
        @rmdir($tmp_dir);

        if (!$all_code) return '';

        // Format extracted code blocks as fenced markdown code blocks
        $out = [];
        foreach ($all_code as $block) {
            $block = trim($block);
            if ($block === '') continue;
            $out[] = "```\n{$block}\n```";
        }
        return implode("\n\n", $out);
    }

    // -------------------------------------------------------------------------
    // Send one page PNG to Ollama vision model, return array of code strings
    // -------------------------------------------------------------------------
    private function _vision_ocr_page(string $png_path, string $model): array {
        if (!is_file($png_path)) return [];

        $img_b64 = base64_encode((string)file_get_contents($png_path));
        if (!$img_b64) return [];

        $payload = [
            'model'   => $model,
            'prompt'  => 'Extract ALL code blocks from this image verbatim. Return ONLY a JSON array of strings, one string per code block. If no code is visible, return []. No explanation, no markdown fences around the array.',
            'images'  => [$img_b64],
            'stream'  => false,
            'options' => ['temperature' => 0.1, 'num_ctx' => 8192, 'num_predict' => 2048],
        ];

        $ch = curl_init();
        curl_setopt_array($ch, [
            CURLOPT_URL            => 'http://127.0.0.1:11434/api/generate',
            CURLOPT_POST           => true,
            CURLOPT_POSTFIELDS     => json_encode($payload, JSON_UNESCAPED_UNICODE),
            CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT        => 120,   // vision calls can be slow
        ]);
        $body = curl_exec($ch);
        curl_close($ch);

        if (!$body) return [];
        $j = json_decode($body, true);
        if (!is_array($j) || empty($j['response'])) return [];

        $response = trim($j['response']);

        // Strip markdown fences if model wrapped the array
        $response = preg_replace('/^```(?:json)?\s*/i', '', $response);
        $response = preg_replace('/\s*```\s*$/i', '', $response);
        $response = trim($response);

        // Find JSON array
        $start = strpos($response, '[');
        if ($start === false) return [];
        $response = substr($response, $start);

        $parsed = json_decode($response, true);
        if (!is_array($parsed)) return [];

        // Filter: only non-empty strings
        return array_values(array_filter(array_map('strval', $parsed), function($s) {
            return trim($s) !== '';
        }));
    }

    // -------------------------------------------------------------------------
    // Pick best available vision model for this hardware
    // Prefers gemma3:4b (fits in 4GB VRAM), falls back to gemma3:12b
    // -------------------------------------------------------------------------
    private function _pick_vision_model(): ?string {
        // Check which models are available via Ollama API
        $ch = curl_init();
        curl_setopt_array($ch, [
            CURLOPT_URL            => 'http://127.0.0.1:11434/api/tags',
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT        => 5,
        ]);
        $body = curl_exec($ch);
        curl_close($ch);

        if (!$body) return null;
        $j = json_decode($body, true);
        if (!is_array($j)) return null;

        $available = [];
        foreach (($j['models'] ?? []) as $m) {
            $available[] = $m['name'] ?? '';
        }

        // Automatic task: only ever auto-pick a vision model ≤4B (policy).
        // gemma3:12b is intentionally NOT here — it runs only on explicit user choice.
        $preferred = ['gemma3:4b'];
        foreach ($preferred as $model) {
            foreach ($available as $a) {
                if (str_starts_with($a, $model)) return $model;
            }
        }
        return null;
    }

    // -------------------------------------------------------------------------
    // Clean extracted text
    // -------------------------------------------------------------------------
    private function _clean(string $text): string {
        // Remove form-feed page separators (^L)
        $text = str_replace("\f", "\n\n", $text);

        // Normalise Windows line endings
        $text = str_replace("\r\n", "\n", $text);
        $text = str_replace("\r",   "\n", $text);

        // Collapse runs of 3+ blank lines to exactly 2 (paragraph separator)
        $text = preg_replace('/\n{3,}/', "\n\n", $text);

        // Strip trailing whitespace on each line
        $text = preg_replace('/[ \t]+$/m', '', $text);

        return trim($text);
    }

    // -------------------------------------------------------------------------
    // Heuristic heading detection
    //
    // We look for lines that are likely headings:
    //   - "Chapter N" / "Chapter N: Title" / "CHAPTER N"
    //   - "N. Title" / "N.N Title" (numbered section)
    //   - ALL CAPS short line (≤ 80 chars) preceded and followed by blank line
    //   - Short line (≤ 60 chars) preceded AND followed by a blank line
    //
    // Returns array of ['title'=>string, 'level'=>int, 'char_offset'=>int]
    // Level: 1 = chapter, 2 = section, 3 = subsection
    // -------------------------------------------------------------------------
    private function _detect_sections(string $text): array {
        $sections = [];
        $lines    = explode("\n", $text);
        $offset   = 0;

        for ($i = 0, $n = count($lines); $i < $n; $i++) {
            $line      = $lines[$i];
            $trimmed   = trim($line);
            $len       = strlen($trimmed);
            $line_len  = strlen($line) + 1;   // +1 for \n

            $prev_blank = ($i === 0)      || trim($lines[$i - 1]) === '';
            $next_blank = ($i === $n - 1) || trim($lines[$i + 1]) === '';

            $level = null;

            // Chapter patterns (level 1)
            if (preg_match('/^(chapter|part|appendix)\s+\d+/i', $trimmed)) {
                $level = 1;
            }
            // Numbered section: "1. Title" or "1.2 Title" or "1.2.3 Title"
            elseif (preg_match('/^\d+(\.\d+)*\.?\s+\S/', $trimmed) && $len <= 80) {
                $dots  = substr_count(explode(' ', $trimmed)[0], '.');
                $level = min(3, $dots + 2);   // "1." → level 2, "1.1." → level 3
            }
            // ALL CAPS heading (short, surrounded by blanks)
            elseif ($prev_blank && $next_blank && $len >= 3 && $len <= 80
                    && $trimmed === strtoupper($trimmed)
                    && !preg_match('/^\d+$/', $trimmed)) {
                $level = 2;
            }
            // Short line surrounded by blanks (generic heading)
            elseif ($prev_blank && $next_blank && $len >= 3 && $len <= 60
                    && !preg_match('/[.!?]$/', $trimmed)) {
                $level = 3;
            }

            if ($level !== null && $trimmed !== '') {
                $sections[] = [
                    'title'       => $trimmed,
                    'level'       => $level,
                    'char_offset' => $offset,
                ];
            }

            $offset += $line_len;
        }

        return $sections;
    }

    // -------------------------------------------------------------------------
    // Guess book title
    // -------------------------------------------------------------------------
    private function _guess_title(string $filepath, string $text, array $sections): string {
        // 1. First level-1 heading
        foreach ($sections as $s) {
            if ($s['level'] === 1) return $s['title'];
        }
        // 2. First non-blank line of text (often the title page)
        foreach (explode("\n", $text) as $line) {
            $t = trim($line);
            if ($t !== '' && strlen($t) <= 100) return $t;
        }
        // 3. Filename without extension
        return pathinfo($filepath, PATHINFO_FILENAME);
    }

    private function _err(string $msg): array {
        return ['markdown' => '', 'sections' => [], 'book_title' => '', 'error' => $msg];
    }
}

// =============================================================================
// TXT_Extractor — plain text files
//
// Strategy: read as-is, detect headings by ALL-CAPS lines or lines ending
// with a colon followed by a blank line. Very lightweight.
// =============================================================================
class TXT_Extractor implements Format_Extractor {

    public function supports(string $filename): bool {
        return in_array(strtolower(pathinfo($filename, PATHINFO_EXTENSION)),
                        ['txt', 'text', 'md', 'markdown', 'rst'], true);
    }

    public function extract(string $filepath): array {
        if (!is_file($filepath)) {
            return $this->_err("File not found: $filepath");
        }
        $text = file_get_contents($filepath);
        if ($text === false) {
            return $this->_err("Could not read file: $filepath");
        }
        // Normalise line endings
        $text = str_replace(["\r\n", "\r"], "\n", $text);
        $text = preg_replace('/\n{3,}/', "\n\n", $text);
        $text = trim($text);

        if ($text === '') {
            return $this->_err("File is empty: $filepath");
        }

        $sections   = $this->_detect_sections($text);
        $book_title = $this->_guess_title($filepath, $text, $sections);

        return ['markdown' => $text, 'sections' => $sections,
                'book_title' => $book_title, 'error' => null];
    }

    private function _detect_sections(string $text): array {
        $sections = [];
        $lines    = explode("\n", $text);
        $offset   = 0;
        for ($i = 0, $n = count($lines); $i < $n; $i++) {
            $line    = $lines[$i];
            $trimmed = trim($line);
            $len     = strlen($trimmed);
            $prev_blank = ($i === 0) || trim($lines[$i-1]) === '';
            $next_blank = ($i === $n-1) || trim($lines[$i+1]) === '';

            $level = null;
            // Markdown headings
            if (preg_match('/^(#{1,3})\s+\S/', $trimmed, $m)) {
                $level = strlen($m[1]);
            }
            // ALL CAPS short line surrounded by blanks
            elseif ($prev_blank && $next_blank && $len >= 3 && $len <= 80
                    && $trimmed === strtoupper($trimmed)
                    && !preg_match('/^\d+$/', $trimmed)) {
                $level = 2;
            }
            // RST underline style (line of === or --- after a text line)
            elseif ($len >= 3 && preg_match('/^[=\-~^]+$/', $trimmed) && $i > 0) {
                $prev = trim($lines[$i-1]);
                if ($prev !== '' && strlen($prev) <= 100) {
                    // Replace previous offset entry if it exists
                    $level = ($trimmed[0] === '=') ? 1 : 2;
                    $offset += strlen($line) + 1;
                    continue;
                }
            }

            if ($level !== null && $trimmed !== '') {
                $sections[] = ['title' => $trimmed, 'level' => $level,
                               'char_offset' => $offset];
            }
            $offset += strlen($line) + 1;
        }
        return $sections;
    }

    private function _guess_title(string $filepath, string $text, array $sections): string {
        foreach ($sections as $s) { if ($s['level'] === 1) return $s['title']; }
        foreach (explode("\n", $text) as $line) {
            $t = trim($line);
            if ($t !== '' && strlen($t) <= 100) return $t;
        }
        return pathinfo($filepath, PATHINFO_FILENAME);
    }

    private function _err(string $msg): array {
        return ['markdown' => '', 'sections' => [], 'book_title' => '', 'error' => $msg];
    }
}

// =============================================================================
// HTML_Extractor — HTML files
//
// Strategy: PHP DOMDocument strips tags, preserves text structure.
// Headings (h1-h4) become section markers.
// =============================================================================
class HTML_Extractor implements Format_Extractor {

    public function supports(string $filename): bool {
        return in_array(strtolower(pathinfo($filename, PATHINFO_EXTENSION)),
                        ['html', 'htm', 'xhtml'], true);
    }

    public function extract(string $filepath): array {
        if (!is_file($filepath)) {
            return $this->_err("File not found: $filepath");
        }
        $html = file_get_contents($filepath);
        if ($html === false) {
            return $this->_err("Could not read file: $filepath");
        }

        // Use DOMDocument to parse
        $dom = new DOMDocument();
        libxml_use_internal_errors(true);
        $dom->loadHTML('<?xml encoding="UTF-8">' . $html,
                       LIBXML_NOWARNING | LIBXML_NOERROR);
        libxml_clear_errors();

        // Remove script, style, nav, footer, header elements
        foreach (['script','style','nav','footer','noscript','aside'] as $tag) {
            foreach (iterator_to_array($dom->getElementsByTagName($tag)) as $el) {
                $el->parentNode && $el->parentNode->removeChild($el);
            }
        }

        // Extract text with heading markers
        $sections    = [];
        $text_parts  = [];
        $char_offset = 0;
        $book_title  = '';

        $this->_walk($dom->documentElement, $text_parts, $sections,
                     $char_offset, $book_title);

        $text = implode("\n\n", array_filter($text_parts, fn($p) => trim($p) !== ''));
        $text = preg_replace('/\n{3,}/', "\n\n", trim($text));

        if ($text === '') {
            return $this->_err("No text content found in HTML: $filepath");
        }
        if (!$book_title) {
            $title_els = $dom->getElementsByTagName('title');
            if ($title_els->length > 0) $book_title = trim($title_els->item(0)->textContent);
        }
        if (!$book_title) $book_title = pathinfo($filepath, PATHINFO_FILENAME);

        return ['markdown' => $text, 'sections' => $sections,
                'book_title' => $book_title, 'error' => null];
    }

    private function _walk(?\DOMNode $node, array &$parts, array &$sections,
                           int &$offset, string &$title): void {
        if (!$node) return;
        if ($node->nodeType === XML_TEXT_NODE) {
            $t = preg_replace('/\s+/', ' ', $node->textContent);
            if (trim($t) !== '') { $parts[] = $t; $offset += strlen($t) + 2; }
            return;
        }
        if ($node->nodeType !== XML_ELEMENT_NODE) return;

        $tag = strtolower($node->nodeName);

        // Headings become section markers
        if (preg_match('/^h([1-4])$/', $tag, $m)) {
            $level = (int)$m[1];
            $text  = trim($node->textContent);
            if ($text !== '') {
                $sections[] = ['title' => $text, 'level' => $level,
                               'char_offset' => $offset];
                $parts[]   = $text;
                $offset   += strlen($text) + 2;
                if ($level === 1 && !$title) $title = $text;
            }
            return;
        }

        // Block elements add spacing
        $block = in_array($tag, ['p','div','li','blockquote','pre','tr','article','section']);
        if ($block) $parts[] = '';

        foreach ($node->childNodes as $child) {
            $this->_walk($child, $parts, $sections, $offset, $title);
        }

        if ($block) $parts[] = '';
    }

    private function _err(string $msg): array {
        return ['markdown' => '', 'sections' => [], 'book_title' => '', 'error' => $msg];
    }
}

// =============================================================================
// DOCX_Extractor — Microsoft Word .docx files (via pandoc)
//
// Strategy: pandoc converts docx → markdown, preserving headings which
// become our section markers. Falls back to plain text if markdown fails.
// =============================================================================
class DOCX_Extractor implements Format_Extractor {

    public function supports(string $filename): bool {
        return in_array(strtolower(pathinfo($filename, PATHINFO_EXTENSION)),
                        ['docx', 'odt', 'odf', 'rtf'], true);
    }

    public function extract(string $filepath): array {
        if (!is_file($filepath)) {
            return $this->_err("File not found: $filepath");
        }
        $which = trim((string)shell_exec('which pandoc 2>/dev/null'));
        if (!$which) {
            return $this->_err("pandoc not found — required for DOCX extraction");
        }

        // Convert to markdown (preserves headings)
        $cmd = sprintf(
            '%s%s --from=docx --to=markdown --wrap=none %s 2>/dev/null',
            cockpit_timeout_cmd(60),
            escapeshellarg($which),
            escapeshellarg($filepath)
        );
        $text = shell_exec($cmd);

        if ($text === null || trim($text) === '') {
            // Fallback: plain text
            $cmd  = sprintf('%s%s --from=docx --to=plain --wrap=none %s 2>/dev/null',
                            cockpit_timeout_cmd(60), escapeshellarg($which), escapeshellarg($filepath));
            $text = shell_exec($cmd);
        }

        if ($text === null || trim($text) === '') {
            return $this->_err("pandoc returned no content from: $filepath");
        }

        // Normalise
        $text = str_replace(["\r\n", "\r"], "\n", $text);
        $text = preg_replace('/\n{3,}/', "\n\n", trim($text));

        // Detect sections from markdown headings
        $sections   = $this->_detect_md_sections($text);
        $book_title = $this->_guess_title($filepath, $sections);

        return ['markdown' => $text, 'sections' => $sections,
                'book_title' => $book_title, 'error' => null];
    }

    private function _detect_md_sections(string $text): array {
        $sections = [];
        $offset   = 0;
        foreach (explode("\n", $text) as $line) {
            if (preg_match('/^(#{1,4})\s+(.+)$/', $line, $m)) {
                $sections[] = ['title' => trim($m[2]), 'level' => strlen($m[1]),
                               'char_offset' => $offset];
            }
            $offset += strlen($line) + 1;
        }
        return $sections;
    }

    private function _guess_title(string $filepath, array $sections): string {
        foreach ($sections as $s) { if ($s['level'] === 1) return $s['title']; }
        return pathinfo($filepath, PATHINFO_FILENAME);
    }

    private function _err(string $msg): array {
        return ['markdown' => '', 'sections' => [], 'book_title' => '', 'error' => $msg];
    }
}

// =============================================================================
// EPUB_Extractor — EPUB ebooks (via pandoc)
//
// Strategy: pandoc converts epub → markdown. EPUB files are ZIP archives
// containing HTML chapters; pandoc handles the unpacking internally.
// =============================================================================
class EPUB_Extractor implements Format_Extractor {

    public function supports(string $filename): bool {
        return strtolower(pathinfo($filename, PATHINFO_EXTENSION)) === 'epub';
    }

    public function extract(string $filepath): array {
        if (!is_file($filepath)) {
            return $this->_err("File not found: $filepath");
        }
        $which = trim((string)shell_exec('which pandoc 2>/dev/null'));
        if (!$which) {
            return $this->_err("pandoc not found — required for EPUB extraction");
        }

        $cmd = sprintf(
            '%s --from=epub --to=markdown --wrap=none %s 2>/dev/null',
            escapeshellarg($which),
            escapeshellarg($filepath)
        );
        $text = shell_exec($cmd);

        if ($text === null || trim($text) === '') {
            return $this->_err("pandoc returned no content from EPUB: $filepath");
        }

        $text = str_replace(["\r\n", "\r"], "\n", $text);
        $text = preg_replace('/\n{3,}/', "\n\n", trim($text));

        $sections   = $this->_detect_md_sections($text);
        $book_title = $this->_guess_title($filepath, $sections);

        return ['markdown' => $text, 'sections' => $sections,
                'book_title' => $book_title, 'error' => null];
    }

    private function _detect_md_sections(string $text): array {
        $sections = [];
        $offset   = 0;
        foreach (explode("\n", $text) as $line) {
            if (preg_match('/^(#{1,4})\s+(.+)$/', $line, $m)) {
                $sections[] = ['title' => trim($m[2]), 'level' => strlen($m[1]),
                               'char_offset' => $offset];
            }
            $offset += strlen($line) + 1;
        }
        return $sections;
    }

    private function _guess_title(string $filepath, array $sections): string {
        foreach ($sections as $s) { if ($s['level'] === 1) return $s['title']; }
        return pathinfo($filepath, PATHINFO_FILENAME);
    }

    private function _err(string $msg): array {
        return ['markdown' => '', 'sections' => [], 'book_title' => '', 'error' => $msg];
    }
}

// =============================================================================
// CHM_Extractor — Compiled HTML Help files (.chm)
//
// Dependencies: archmage (sudo nala install archmage)
//
// Strategy:
//   1. Extract CHM to a temp directory using archmage
//   2. Find all HTML files in the extracted tree (sorted for reading order)
//   3. Feed each HTML file through HTML_Extractor
//   4. Merge all text + sections into one document
//   5. Clean up temp dir
// =============================================================================
class CHM_Extractor implements Format_Extractor {

    public function supports(string $filename): bool {
        return strtolower(pathinfo($filename, PATHINFO_EXTENSION)) === 'chm';
    }

    public function extract(string $filepath): array {
        if (!is_file($filepath)) {
            return $this->_err("File not found: $filepath");
        }

        $archmage = trim((string)shell_exec('which archmage 2>/dev/null'));
        if (!$archmage) {
            return $this->_err("archmage not found — install with: sudo nala install archmage");
        }

        // Create temp directory for extraction
        $tmp_dir = sys_get_temp_dir() . '/cockpit_chm_' . getmypid() . '_' . uniqid();
        @mkdir($tmp_dir, 0700, true);

        // Extract CHM
        $cmd = sprintf(
            '%s %s %s 2>/dev/null',
            escapeshellarg($archmage),
            escapeshellarg($filepath),
            escapeshellarg($tmp_dir)
        );
        shell_exec($cmd);

        // Find all extracted HTML files, sorted by path for reading order
        $html_files = [];
        $iter = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($tmp_dir, RecursiveDirectoryIterator::SKIP_DOTS)
        );
        foreach ($iter as $f) {
            if (in_array(strtolower(pathinfo($f, PATHINFO_EXTENSION)), ['html','htm'], true)) {
                $html_files[] = (string)$f;
            }
        }
        sort($html_files);

        if (empty($html_files)) {
            $this->_cleanup($tmp_dir);
            return $this->_err("archmage extracted no HTML files from: $filepath");
        }

        // Feed each HTML through HTML_Extractor and merge
        $html_extractor = new HTML_Extractor();
        $all_text       = [];
        $all_sections   = [];
        $book_title     = '';
        $char_offset    = 0;

        foreach ($html_files as $html_file) {
            $result = $html_extractor->extract($html_file);
            if ($result['error'] !== null) continue;

            $page_text = trim($result['markdown']);
            if ($page_text === '') continue;

            // Adjust section char_offsets to be relative to merged document
            foreach ($result['sections'] as $s) {
                $s['char_offset'] += $char_offset;
                $all_sections[]    = $s;
            }

            // Use first found title as book title
            if (!$book_title && $result['book_title']) {
                $book_title = $result['book_title'];
            }

            $all_text[]   = $page_text;
            $char_offset += strlen($page_text) + 2;
        }

        $this->_cleanup($tmp_dir);

        if (empty($all_text)) {
            return $this->_err("No text content extracted from CHM: $filepath");
        }

        $merged_text = implode("\n\n", $all_text);
        $merged_text = preg_replace('/\n{3,}/', "\n\n", $merged_text);

        if (!$book_title) {
            $book_title = pathinfo($filepath, PATHINFO_FILENAME);
        }

        return [
            'markdown'   => $merged_text,
            'sections'   => $all_sections,
            'book_title' => $book_title,
            'error'      => null,
        ];
    }

    private function _cleanup(string $dir): void {
        if (!is_dir($dir)) return;
        $iter = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($dir, RecursiveDirectoryIterator::SKIP_DOTS),
            RecursiveIteratorIterator::CHILD_FIRST
        );
        foreach ($iter as $f) {
            $f->isDir() ? @rmdir($f) : @unlink($f);
        }
        @rmdir($dir);
    }

    private function _err(string $msg): array {
        return ['markdown' => '', 'sections' => [], 'book_title' => '', 'error' => $msg];
    }
}

// =============================================================================
// Extractor registry — ordered by specificity
// =============================================================================
function get_extractor(string $filepath): ?Format_Extractor {
    $extractors = [
        new PDF_Extractor(),
        new CHM_Extractor(),    // chm — requires archmage
        new DOCX_Extractor(),   // docx, odt, rtf
        new EPUB_Extractor(),   // epub
        new HTML_Extractor(),   // html, htm
        new TXT_Extractor(),    // txt, md, rst
    ];
    foreach ($extractors as $e) {
        if ($e->supports($filepath)) return $e;
    }
    return null;
}

// =============================================================================
// Token estimation
// =============================================================================
function estimate_tokens(string $text): int {
    return (int)ceil(strlen($text) / CHARS_PER_TOKEN);
}

// =============================================================================
// pre_split() — structural split by headings then paragraphs
//
// Algorithm:
//   1. If sections were detected, use them as split points first.
//      Each section boundary starts a new raw chunk.
//   2. Within each section, split further by double-newline (paragraph).
//   3. Return flat list of raw text segments with their section label.
// =============================================================================
function pre_split(string $text, array $sections): array {
    $raw_chunks = [];

    if (empty($sections)) {
        // No structure detected — split purely by paragraph
        $paras = preg_split('/\n{2,}/', $text);
        foreach ($paras as $p) {
            $p = trim($p);
            if ($p === '') continue;
            $raw_chunks[] = ['text' => $p, 'section' => ''];
        }
        return $raw_chunks;
    }

    // Split text at each section boundary
    // Build list of [char_offset, title] pairs + a sentinel at end
    $boundaries = [];
    foreach ($sections as $s) {
        $boundaries[] = ['offset' => $s['char_offset'], 'title' => $s['title']];
    }
    $boundaries[] = ['offset' => strlen($text), 'title' => ''];   // sentinel

    for ($i = 0, $n = count($boundaries) - 1; $i < $n; $i++) {
        $start   = $boundaries[$i]['offset'];
        $end     = $boundaries[$i + 1]['offset'];
        $title   = $boundaries[$i]['title'];
        $section_text = substr($text, $start, $end - $start);

        // Split section text into paragraphs
        $paras = preg_split('/\n{2,}/', $section_text);
        foreach ($paras as $p) {
            $p = trim($p);
            if ($p === '') continue;
            $raw_chunks[] = ['text' => $p, 'section' => $title];
        }
    }

    return $raw_chunks;
}

// =============================================================================
// token_fit() — merge small chunks, split oversized ones
//
// Pass 1 — merge: walk raw_chunks, accumulate into a buffer.
//   When adding the next chunk would exceed TOKEN_CEILING, flush buffer.
//   If a single chunk already exceeds TOKEN_CEILING, it goes to pass 2.
//
// Pass 2 — split oversized: hard-split by sentence boundary up to ceiling.
//   If no sentence boundary found, hard-split by character count.
//
// Returns final chunk list with index, text, tokens, section.
// =============================================================================
function token_fit(array $raw_chunks): array {
    $merged = [];

    // Pass 1 — merge smalls
    $buf_text    = '';
    $buf_section = '';
    $buf_tokens  = 0;

    $flush = function() use (&$merged, &$buf_text, &$buf_section, &$buf_tokens) {
        $t = trim($buf_text);
        if ($t === '') return;
        $merged[] = ['text' => $t, 'section' => $buf_section, 'tokens' => estimate_tokens($t)];
        $buf_text    = '';
        $buf_tokens  = 0;
        // Note: buf_section is updated as we iterate, not reset here
    };

    foreach ($raw_chunks as $chunk) {
        $ct = estimate_tokens($chunk['text']);

        if ($ct >= TOKEN_CEILING) {
            // This single chunk exceeds ceiling — flush buffer first, then
            // mark it for pass-2 splitting
            $flush();
            $merged[] = ['text' => trim($chunk['text']), 'section' => $chunk['section'],
                         'tokens' => $ct, '_needs_split' => true];
            continue;
        }

        if ($buf_tokens + $ct > TOKEN_CEILING) {
            // Adding this would overflow — flush and start fresh
            $flush();
        }

        if ($buf_text === '') {
            // Starting a new buffer
            $buf_section = $chunk['section'];
        } elseif ($buf_tokens < TOKEN_MIN_RECOMBINE) {
            // Current buffer is tiny — keep same section label even if different
            // (we're stitching stubs together)
        }

        $buf_text   .= ($buf_text ? "\n\n" : '') . $chunk['text'];
        $buf_tokens += $ct;
    }
    $flush();

    // Pass 2 — split oversized chunks
    $final = [];
    foreach ($merged as $chunk) {
        if (empty($chunk['_needs_split'])) {
            $final[] = $chunk;
            continue;
        }
        // Hard-split by sentence boundaries, then by char count
        $sub_chunks = _hard_split($chunk['text'], $chunk['section']);
        foreach ($sub_chunks as $sc) {
            $final[] = $sc;
        }
    }

    // Assign sequential index
    foreach ($final as $i => $c) {
        $final[$i]['index'] = $i;
        unset($final[$i]['_needs_split']);
    }

    return $final;
}

// Hard-split a too-large text into TOKEN_CEILING-sized pieces.
// Tries to break at sentence ends (". " or "\n") first.
function _hard_split(string $text, string $section): array {
    $result  = [];
    $ceiling = (int)(TOKEN_CEILING * CHARS_PER_TOKEN);   // in chars
    $min     = (int)(TOKEN_MIN_RECOMBINE * CHARS_PER_TOKEN);

    while (strlen($text) > $ceiling) {
        // Try to find a sentence boundary before the ceiling
        $window = substr($text, 0, $ceiling);
        // Prefer paragraph break
        $break = strrpos($window, "\n\n");
        if ($break === false || $break < $min) {
            // Try sentence end
            $break = strrpos($window, '. ');
            if ($break !== false) $break += 2;   // include the ". "
        }
        if ($break === false || $break < $min) {
            // Last resort: hard break at ceiling
            $break = $ceiling;
        }
        $piece = trim(substr($text, 0, $break));
        if ($piece !== '') {
            $result[] = [
                'text'    => $piece,
                'section' => $section,
                'tokens'  => estimate_tokens($piece),
            ];
        }
        $text = trim(substr($text, $break));
    }

    // Remainder
    $text = trim($text);
    if ($text !== '') {
        $result[] = [
            'text'    => $text,
            'section' => $section,
            'tokens'  => estimate_tokens($text),
        ];
    }

    return $result;
}

// =============================================================================
// chunk_pipeline() — top-level entry point
//
// $filepath      — absolute path to the input file
// $language_hint — e.g. "pascal", "php", "c++" (user-supplied or guessed)
//
// Returns:
//   [
//     'chunks'      => [...],    // final sized chunks ready for LLM
//     'sections'    => [...],    // structural sections from extractor
//     'book_title'  => string,
//     'format'      => string,   // e.g. "pdf"
//     'total_tokens'=> int,      // sum of all chunk token estimates
//     'error'       => string|null,
//   ]
// =============================================================================
function chunk_pipeline(string $filepath, string $language_hint = ''): array {
    // 1. Find extractor
    $extractor = get_extractor($filepath);
    if (!$extractor) {
        return [
            'chunks' => [], 'sections' => [], 'book_title' => '',
            'format' => '', 'total_tokens' => 0,
            'error' => 'No extractor supports file: ' . basename($filepath),
        ];
    }

    $format = strtolower(pathinfo($filepath, PATHINFO_EXTENSION));

    // 2. Extract text + structure
    $extracted = $extractor->extract($filepath);
    if ($extracted['error'] !== null) {
        return [
            'chunks' => [], 'sections' => [], 'book_title' => '',
            'format' => $format, 'total_tokens' => 0,
            'error' => $extracted['error'],
        ];
    }

    $text       = $extracted['markdown'];
    $sections   = $extracted['sections'];
    $book_title = $extracted['book_title'];

    if (trim($text) === '') {
        return [
            'chunks' => [], 'sections' => $sections, 'book_title' => $book_title,
            'format' => $format, 'total_tokens' => 0,
            'error' => 'Extractor returned empty text — PDF may be image-only (needs OCR)',
        ];
    }

    // 3. Pre-split by structure
    $raw_chunks = pre_split($text, $sections);

    // 4. Token-fit sizing
    $chunks = token_fit($raw_chunks);

    // 5. Compute totals
    $total_tokens = 0;
    foreach ($chunks as $c) $total_tokens += ($c['tokens'] ?? 0);

    return [
        'chunks'       => $chunks,
        'sections'     => $sections,
        'book_title'   => $book_title,
        'format'       => $format,
        'total_tokens' => $total_tokens,
        'error'        => null,
    ];
}
