#!/bin/bash
# =============================================================================
# crud_executor.sh - CRUD Command Executor for Cockpit (pure bash)
# Location: ~/scripts/crud_executor.sh
#
# Parses %%COMMAND%% blocks from agent responses and executes file operations.
# All operations are sandboxed to the project directory.
#
# Usage:
#   crud_executor.sh PROJECT_DIR RESPONSE_FILE
#
# Commands parsed:
#   %%CREATE:path%%  content  %%END%%
#   %%UPDATE:path%%  content  %%END%%   (alias for CREATE)
#   %%APPEND:path%%  content  %%END%%
#   %%READ:path%%
#   %%DELETE:path%%  (requires %%CONFIRM:DELETE%% in same response)
#   %%MKDIR:path%%
#   %%LIST%%  or  %%LIST:subpath%%
# =============================================================================

PROJECT_DIR="$1"
RESPONSE_FILE="$2"
PROPOSER="${3:-unknown}"   # claude / gemini / ollama — used for proposals queue
PROJECT_NAME="${4:-default}"

# The loop's own credential for search.php / workers.php / tools.php / library.php (cockpit_app/internal_auth.php). The key goes to curl in
# a header FILE (-H @file, curl 7.55+), never on the command line where `ps` would show it. Absent = those pages answer 401, as before.
_IH=""
if [ -n "${COCKPIT_INTERNAL_KEY:-}" ] && [ -n "${COCKPIT_INTERNAL_USER:-}" ]; then
    _IH=$(umask 077; mktemp "${TMPDIR:-/tmp}/ckih.XXXXXX" 2>/dev/null) || _IH=""
    if [ -n "$_IH" ]; then
        printf 'X-Cockpit-Internal: %s\nX-Cockpit-User: %s\n' "$COCKPIT_INTERNAL_KEY" "$COCKPIT_INTERNAL_USER" > "$_IH"
        trap 'rm -f "$_IH"' EXIT
    fi
fi

# ── Validate inputs ───────────────────────────────────────────────────────────
[ -z "$PROJECT_DIR" ] || [ ! -d "$PROJECT_DIR" ] && exit 0
[ -z "$RESPONSE_FILE" ] || [ ! -f "$RESPONSE_FILE" ] && exit 0

# Quick check — if no %% markers, nothing to do
grep -qF '%%' "$RESPONSE_FILE" || exit 0

PROJECT_DIR=$(realpath "$PROJECT_DIR")
COCKPIT_DATA="$HOME/scripts/cockpit_data"
PROPOSALS_FILE="$COCKPIT_DATA/proposals.json"
if [ -z "${COCKPIT_ROOT:-}" ]; then
    for _pj in "$HOME/.local/share/cockpit-web/cockpit/paths.json" /var/www/html/cockpit/paths.json /srv/http/cockpit/paths.json /srv/www/htdocs/cockpit/paths.json; do [ -f "$_pj" ] && break; done
    [ -f "$_pj" ] && command -v jq >/dev/null 2>&1 && COCKPIT_ROOT="$(jq -r '.projects_root // empty' "$_pj" 2>/dev/null)"
fi
PROJECTS_ROOT="${COCKPIT_ROOT:-$HOME/Software/Programing/LocalAIProjs}"
mkdir -p "$COCKPIT_DATA" 2>/dev/null

# Read size cap for READ command (HIGH-31). 16KB matches SNIP/SRC caps.
READ_MAX=16384

# ── Security: resolve path within project dir ─────────────────────────────────
# Returns full path or empty string if outside project.
# Trailing slash on PROJECT_DIR prevents prefix-match bug (CRIT-23):
# "/proj" should NOT match "/proj_evil/file".
safe_path() {
    local rel="${1#/}"                          # strip leading /
    rel=$(echo "$rel" | sed 's|\.\./||g')       # strip traversal
    local full="$PROJECT_DIR/$rel"
    local resolved
    resolved=$(realpath -m "$full" 2>/dev/null) || resolved="$full"
    # Use trailing-slash compare so PROJECT_DIR exactly OR with a / after matches,
    # but PROJECT_DIR_evil does not.
    case "$resolved/" in
        "$PROJECT_DIR"/*) echo "$resolved" ;;
    esac
}

# ── Check for DELETE confirmation in the whole file ───────────────────────────
HAS_CONFIRM=0
grep -qF '%%CONFIRM:DELETE%%' "$RESPONSE_FILE" && HAS_CONFIRM=1

# ── Parse the response file line by line ─────────────────────────────────────
# State machine:
#   mode=scan      — looking for a %% command
#   mode=collect   — inside a CREATE/UPDATE/APPEND block, collecting content

mode="scan"
cmd=""
cmd_path=""
collected=""

# We read the file twice for multi-line blocks and once for single-line commands.
# First pass: handle multi-line CREATE/UPDATE/APPEND blocks
while IFS= read -r line || [ -n "$line" ]; do

    if [ "$mode" = "scan" ]; then
        # Check for multi-line block openers — CREATE/UPDATE/APPEND or PROPOSE
        if [[ "$line" =~ %%([Cc][Rr][Ee][Aa][Tt][Ee]|[Uu][Pp][Dd][Aa][Tt][Ee]|[Aa][Pp][Pp][Ee][Nn][Dd]):([^%]+)%% ]]; then
            cmd="${BASH_REMATCH[1]^^}"
            cmd_path="${BASH_REMATCH[2]}"
            collected=""
            mode="collect"
            continue
        fi
        if [[ "$line" =~ %%[Pp][Rr][Oo][Pp][Oo][Ss][Ee]:([Ss][Nn][Ii][Pp][Pp][Ee][Tt]|[Ss][Oo][Uu][Rr][Cc][Ee]|[Ll][Ii][Bb][Rr][Aa][Rr][Yy])%% ]]; then
            cmd="PROPOSE"
            propose_kind="${BASH_REMATCH[1],,}"  # lowercase: snippet|source|library
            collected=""
            mode="collect"
            continue
        fi

    elif [ "$mode" = "collect" ]; then
        if [[ "$line" == *"%%END%%"* ]]; then
            if [ "$cmd" = "PROPOSE" ]; then
                # Parse the collected key:value block
                title=""; lang=""; location=""; kind_kv=""; notes=""; content_buf=""
                in_content=0
                while IFS= read -r kvline; do
                    if [ "$in_content" = "1" ]; then
                        if [ -z "$content_buf" ]; then
                            content_buf="$kvline"
                        else
                            content_buf="${content_buf}"$'\n'"$kvline"
                        fi
                        continue
                    fi
                    case "$kvline" in
                        title:*)    title="${kvline#title:}";    title="${title# }";    title="${title%$'\r'}" ;;
                        lang:*)     lang="${kvline#lang:}";      lang="${lang# }";      lang="${lang%$'\r'}" ;;
                        location:*) location="${kvline#location:}"; location="${location# }"; location="${location%$'\r'}" ;;
                        kind:*)     kind_kv="${kvline#kind:}";   kind_kv="${kind_kv# }"; kind_kv="${kind_kv%$'\r'}" ;;
                        notes:*)    notes="${kvline#notes:}";    notes="${notes# }";    notes="${notes%$'\r'}" ;;
                        content:*)
                            in_content=1
                            rest="${kvline#content:}"; rest="${rest# }"
                            if [ -n "$rest" ]; then content_buf="$rest"; fi
                            ;;
                    esac
                done <<< "$collected"

                # JSON-escape helper
                json_esc() {
                    local s="$1"
                    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
                    s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
                    echo "$s"
                }

                t_esc=$(json_esc "$title")
                l_esc=$(json_esc "$lang")
                loc_esc=$(json_esc "$location")
                kk_esc=$(json_esc "$kind_kv")
                n_esc=$(json_esc "$notes")
                c_esc=$(json_esc "$content_buf")

                # Build JSON payload depending on kind
                case "$propose_kind" in
                    library)
                        payload="{\"title\":\"$t_esc\",\"location\":\"$loc_esc\",\"kind\":\"${kk_esc:-path}\",\"notes\":\"$n_esc\"}"
                        ;;
                    snippet|source)
                        payload="{\"title\":\"$t_esc\",\"lang\":\"$l_esc\",\"notes\":\"$n_esc\",\"content\":\"$c_esc\"}"
                        ;;
                esac

                # POST to library.php proposal_add
                json_body="{\"action\":\"proposal_add\",\"propose_kind\":\"$propose_kind\",\"proposer\":\"$PROPOSER\",\"project\":\"$PROJECT_NAME\",\"payload\":$payload}"
                # Use curl if available, else just write to proposals file directly
                if command -v curl >/dev/null 2>&1; then
                    curl -s ${_IH:+-H "@$_IH"} -X POST -H "Content-Type: application/json" \
                        -d "$json_body" \
                        "${COCKPIT_BASE_URL:-http://localhost/cockpit}/library.php" >/dev/null 2>&1 \
                        && echo "[CRUD:OK] PROPOSE $propose_kind: \"$title\" — pending approval" \
                        || echo "[CRUD:ERR] PROPOSE $propose_kind: failed to enqueue"
                else
                    echo "[CRUD:ERR] PROPOSE $propose_kind: curl unavailable, cannot enqueue"
                fi

            else
                # CREATE/UPDATE/APPEND
                full_path=$(safe_path "$cmd_path")
                if [ -z "$full_path" ]; then
                    echo "[CRUD:ERR] $cmd rejected — path outside project: $cmd_path"
                else
                    mkdir -p "$(dirname "$full_path")"
                    case "$cmd" in
                        CREATE|UPDATE)
                            # printf '%s\n' adds the trailing newline POSIX files
                            # expect; the read loop strips it from the last line.
                            printf '%s\n' "$collected" > "$full_path"
                            chmod 664 "$full_path" 2>/dev/null
                            size=$(wc -c < "$full_path" 2>/dev/null || echo "?")
                            echo "[CRUD:OK] CREATE $cmd_path ($size bytes)"
                            ;;
                        APPEND)
                            printf '%s\n' "$collected" >> "$full_path"
                            size=$(wc -c < "$full_path" 2>/dev/null || echo "?")
                            echo "[CRUD:OK] APPEND $cmd_path ($size bytes)"
                            ;;
                    esac
                fi
            fi
            mode="scan"
            cmd=""; cmd_path=""; collected=""; propose_kind=""
        else
            # Accumulate content (preserve newlines)
            if [ -z "$collected" ]; then
                collected="$line"
            else
                collected="${collected}"$'\n'"$line"
            fi
        fi
    fi

done < "$RESPONSE_FILE"

# Second pass: handle single-line commands (READ, DELETE, MKDIR, LIST)
while IFS= read -r line || [ -n "$line" ]; do

    # Skip lines inside multi-line blocks (between opener and %%END%%)
    # We detect these by checking for the opening pattern — already handled above

    # %%FETCH:url%%  — fetch a URL's text content and return it inline (16KB cap).
    if [[ "$line" =~ %%[Ff][Ee][Tt][Cc][Hh]:([^%]+)%% ]]; then
        furl="${BASH_REMATCH[1]}"
        if ! command -v curl >/dev/null 2>&1; then
            echo "[CRUD:ERR] FETCH \"$furl\" — curl unavailable"
            continue
        fi
        # URL-encode inside the query param to localhost
        furl_enc=$(echo "$furl" | sed 's/&/%26/g; s/?/%3F/g; s/ /%20/g')
        result=$(curl -s ${_IH:+-H "@$_IH"} --max-time 20 \
            "${COCKPIT_BASE_URL:-http://localhost/cockpit}/search.php?action=fetch&url=$furl_enc" 2>/dev/null)
        if [ -z "$result" ]; then
            echo "[CRUD:ERR] FETCH \"$furl\" — no response"
            continue
        fi
        echo "[CRUD:INFO] FETCH $furl:"
        # Extract just the text field from the JSON response
        echo "$result" | awk '
        /"text"/ {
            s=$0; sub(/.*"text"[^"]*"/,"",s)
            # Unescape basic JSON
            gsub(/\\n/,"\n",s); gsub(/\\t/,"\t",s); gsub(/\\"/,"\"",s); gsub(/\\\\/,"\\",s)
            sub(/"[,}]?[[:space:]]*$/,"",s)
            print s
        }'
        echo ""
        continue
    fi

    # %%LOAD_SKILL:id%% — progressive disclosure: inject a folder skill's body
    # (cockpit_data/skills/<id>/SKILL.md) on demand. The model gets only the
    # skill catalog upfront and loads the full body when it decides it needs it.
    if [[ "$line" =~ %%[Ll][Oo][Aa][Dd]_[Ss][Kk][Ii][Ll][Ll]:([^%]+)%% ]]; then
        sk_id=$(echo "${BASH_REMATCH[1]}" | tr -cd 'a-zA-Z0-9._-')
        sk_file="$COCKPIT_DATA/skills/$sk_id/SKILL.md"
        if [ -n "$sk_id" ] && [ -f "$sk_file" ]; then
            echo "[CRUD:INFO] LOAD_SKILL $sk_id:"
            # Strip the leading YAML front matter (--- … ---), cap at READ_MAX.
            awk 'NR==1 && /^---[[:space:]]*$/ {fm=1; next} fm && /^---[[:space:]]*$/ {fm=0; next} !fm' "$sk_file" | head -c "$READ_MAX"
            echo ""
        else
            echo "[CRUD:ERR] LOAD_SKILL ${sk_id:-?} — skill not found"
        fi
        continue
    fi

    # %%READ:path%%
    if [[ "$line" =~ %%[Rr][Ee][Aa][Dd]:([^%]+)%% ]]; then
        rel="${BASH_REMATCH[1]}"
        full_path=$(safe_path "$rel")
        if [ -z "$full_path" ]; then
            echo "[CRUD:ERR] READ rejected — path outside project: $rel"
        elif [ ! -f "$full_path" ]; then
            echo "[CRUD:ERR] READ $rel — file not found"
        else
            echo "[CRUD:INFO] READ $rel:"
            head -c "$READ_MAX" "$full_path"
            echo ""
            if [ "$(wc -c < "$full_path")" -gt "$READ_MAX" ]; then
                echo "[... truncated to first ${READ_MAX} bytes]"
            fi
        fi
        continue
    fi

    # %%SEARCH:query%%  — perform a web search via the local search.php endpoint.
    # Returns top 5 results inline so the agent can reason about them in the next turn.
    if [[ "$line" =~ %%[Ss][Ee][Aa][Rr][Cc][Hh]:([^%]+)%% ]]; then
        sq="${BASH_REMATCH[1]}"
        if ! command -v curl >/dev/null 2>&1; then
            echo "[CRUD:ERR] SEARCH \"$sq\" — curl unavailable"
            continue
        fi
        # URL-encode the query (basic — replace spaces with +)
        sq_enc=$(echo "$sq" | sed 's/ /+/g; s/&/%26/g; s/?/%3F/g')
        result=$(curl -s ${_IH:+-H "@$_IH"} --max-time 12 \
            "${COCKPIT_BASE_URL:-http://localhost/cockpit}/search.php?action=search&n=5&q=$sq_enc" 2>/dev/null)
        if [ -z "$result" ]; then
            echo "[CRUD:ERR] SEARCH \"$sq\" — no response"
            continue
        fi
        echo "[CRUD:INFO] SEARCH \"$sq\":"
        # Pretty-print top results — pull title, url, snippet via awk
        echo "$result" | awk '
        BEGIN { RS=","; n=0 }
        /"title"/   { s=$0; sub(/.*"title"[^"]*"/,"",s); sub(/".*/,"",s); title=s; n++ }
        /"url"/     { s=$0; sub(/.*"url"[^"]*"/,"",s);   sub(/".*/,"",s); url=s }
        /"snippet"/ { s=$0; sub(/.*"snippet"[^"]*"/,"",s); sub(/".*/,"",s); snip=s
                      print n". "title
                      print "   "url
                      if (length(snip) > 0) print "   "snip
                      print ""
                    }
        '
        continue
    fi

    # %%WORKER:provider:task:prompt%%  — dispatch to the workers.php endpoint.
    # Pattern: %%WORKER:groq:text:Translate hello to Spanish%%
    # The provider must be configured (key + enabled) in workers.php.
    # The result is inlined as %%WORKER_RESULT:<provider>:<output excerpt>%%
    # so the next turn's prompt can reason about it.
    if [[ "$line" =~ %%[Ww][Oo][Rr][Kk][Ee][Rr]:([^:]+):([^:]+):([^%]+)%% ]]; then
        w_provider="${BASH_REMATCH[1]}"
        w_task="${BASH_REMATCH[2]}"
        w_prompt="${BASH_REMATCH[3]}"
        if ! command -v curl >/dev/null 2>&1; then
            echo "[CRUD:ERR] WORKER \"$w_provider\" — curl unavailable"
            continue
        fi
        # Read the workers state to find a default model for this provider
        # (the agent didn't specify one — pick the first enabled model).
        # workers.php?action=models returns the flat list with provider matches.
        models_resp=$(curl -s ${_IH:+-H "@$_IH"} --max-time 6 "${COCKPIT_BASE_URL:-http://localhost/cockpit}/workers.php?action=models" 2>/dev/null)
        # Pull the first model whose .provider matches w_provider
        w_model=$(echo "$models_resp" | grep -oE '"provider":"'"$w_provider"'","model":"[^"]+"' \
                  | head -1 | sed 's/.*"model":"\([^"]*\)".*/\1/')
        if [ -z "$w_model" ]; then
            echo "[CRUD:ERR] WORKER $w_provider — no enabled model. Configure provider via WORKERS settings."
            continue
        fi
        # Build the JSON payload — bash here-doc with jq for safe escaping (if jq present)
        if command -v jq >/dev/null 2>&1; then
            payload=$(jq -n \
                --arg p "$w_provider" \
                --arg m "$w_model" \
                --arg t "$w_task" \
                --arg q "$w_prompt" \
                '{provider:$p, model:$m, task:$t, prompt:$q, extra:{}}')
        else
            # Fallback: manual escaping (\ and ")
            esc_q="${w_prompt//\\/\\\\}"; esc_q="${esc_q//\"/\\\"}"
            payload="{\"provider\":\"$w_provider\",\"model\":\"$w_model\",\"task\":\"$w_task\",\"prompt\":\"$esc_q\",\"extra\":{}}"
        fi
        result=$(curl -s ${_IH:+-H "@$_IH"} --max-time 90 -X POST \
                 -H 'Content-Type: application/json' \
                 -d "$payload" \
                 "${COCKPIT_BASE_URL:-http://localhost/cockpit}/workers.php?action=invoke" 2>/dev/null)
        if [ -z "$result" ]; then
            echo "[CRUD:ERR] WORKER $w_provider — no response"
            continue
        fi
        # Extract output / error fields
        if command -v jq >/dev/null 2>&1; then
            ok_flag=$(echo "$result" | jq -r '.ok // false' 2>/dev/null)
            if [ "$ok_flag" = "true" ]; then
                kind=$(echo "$result" | jq -r '.kind // "text"' 2>/dev/null)
                output=$(echo "$result" | jq -r '.output // ""' 2>/dev/null)
                # Truncate to 4KB so the agent sees a reasonable excerpt
                if [ ${#output} -gt 4096 ]; then
                    output="${output:0:4096}... [truncated, $((${#output}-4096)) more chars]"
                fi
                echo "[CRUD:INFO] WORKER $w_provider · $w_model · $kind:"
                echo "$output"
                echo "[CRUD:OK] %%WORKER_RESULT:$w_provider:$kind:done%%"
            else
                err=$(echo "$result" | jq -r '.error // "unknown"' 2>/dev/null)
                echo "[CRUD:ERR] WORKER $w_provider — $err"
            fi
        else
            # No jq — best-effort grep
            echo "[CRUD:INFO] WORKER $w_provider · $w_model:"
            echo "$result" | head -c 4096
            echo ""
        fi
        continue
    fi

    # %%TOOL:tool:preset:input_path%%  — dispatch to the tools.php endpoint.
    # Pattern: %%TOOL:ffmpeg:to-mp3:/path/to/audio.flac%%
    # Pattern with extra args: %%TOOL:ffmpeg:burn-subtitles:/path/to/video.mp4|/path/to/subs.srt%%
    # The tool must be enabled and its binary detected in tools.php.
    # Result: output path inlined as %%TOOL_RESULT:<tool>:<output_path>%%
    # so the next turn's prompt can reference the output.
    if [[ "$line" =~ %%[Tt][Oo][Oo][Ll]:([^:]+):([^:]+):([^%]+)%% ]]; then
        t_tool="${BASH_REMATCH[1]}"
        t_preset="${BASH_REMATCH[2]}"
        t_rest="${BASH_REMATCH[3]}"
        # Split on | to separate input from extra_args
        if [[ "$t_rest" == *"|"* ]]; then
            t_input="${t_rest%%|*}"
            t_extra="${t_rest#*|}"
        else
            t_input="$t_rest"
            t_extra=""
        fi
        if ! command -v curl >/dev/null 2>&1; then
            echo "[CRUD:ERR] TOOL \"$t_tool\" — curl unavailable"
            continue
        fi
        # Build payload — prefer jq, fallback to manual escape
        if command -v jq >/dev/null 2>&1; then
            payload=$(jq -n \
                --arg t "$t_tool" \
                --arg p "$t_preset" \
                --arg i "$t_input" \
                --arg e "$t_extra" \
                --arg j "$PROJECT_NAME" \
                '{tool:$t, preset:$p, input:$i, extra_args:$e, project:$j}')
        else
            esc_i="${t_input//\\/\\\\}"; esc_i="${esc_i//\"/\\\"}"
            esc_e="${t_extra//\\/\\\\}"; esc_e="${esc_e//\"/\\\"}"
            esc_j="${PROJECT_NAME//\\/\\\\}"; esc_j="${esc_j//\"/\\\"}"
            payload="{\"tool\":\"$t_tool\",\"preset\":\"$t_preset\",\"input\":\"$esc_i\",\"extra_args\":\"$esc_e\",\"project\":\"$esc_j\"}"
        fi
        result=$(curl -s ${_IH:+-H "@$_IH"} --max-time 320 -X POST \
                 -H 'Content-Type: application/json' \
                 -d "$payload" \
                 "${COCKPIT_BASE_URL:-http://localhost/cockpit}/tools.php?action=run" 2>/dev/null)
        if [ -z "$result" ]; then
            echo "[CRUD:ERR] TOOL $t_tool — no response"
            continue
        fi
        if command -v jq >/dev/null 2>&1; then
            if ! echo "$result" | jq -e type >/dev/null 2>&1; then
                echo "[CRUD:ERR] TOOL $t_tool — the tools page did not answer in the expected form (wrong address or not signed in): $(echo "$result" | tr -s ' \n' '  ' | head -c 160)"
                continue
            fi
            ok_flag=$(echo "$result" | jq -r '.ok // false' 2>/dev/null)
            if [ "$ok_flag" = "true" ]; then
                output=$(echo "$result" | jq -r '.output // ""' 2>/dev/null)
                size=$(echo "$result" | jq -r '.output_size // 0' 2>/dev/null)
                ms=$(echo "$result" | jq -r '.elapsed_ms // 0' 2>/dev/null)
                echo "[CRUD:INFO] TOOL $t_tool · $t_preset done in ${ms}ms (${size} bytes):"
                echo "  Output: $output"
                echo "[CRUD:OK] %%TOOL_RESULT:$t_tool:$output%%"
            else
                err=$(echo "$result" | jq -r '.error // "unknown"' 2>/dev/null)
                rc=$(echo "$result" | jq -r '.rc // -1' 2>/dev/null)
                echo "[CRUD:ERR] TOOL $t_tool — $err (rc=$rc)"
                # Surface a snippet of the log for debugging
                log=$(echo "$result" | jq -r '.log // ""' 2>/dev/null | head -c 400)
                [ -n "$log" ] && echo "  Log: $log"
            fi
        else
            echo "[CRUD:INFO] TOOL $t_tool · $t_preset:"
            echo "$result" | head -c 2048
            echo ""
        fi
        continue
    fi

    # ── %%LIB:…%%  %%SNIP:…%%  %%SRC:…%% — read a catalog entry by title (partial,
    # case-insensitive) or id. The app keeps ONE index per scope, library_index.json
    # (global: the user's cockpit_data; project: <project>/library_index.json), with
    # arrays .library / .snippets / .sources and a file_path per stored item — the old
    # per-kind <kind>/index.json layout this read (with a hard-coded /home/user) no
    # longer exists, so every marker answered "no entry found" (QA, b87). Needs jq.
    cat_kind=""
    if   [[ "$line" =~ %%[Ll][Ii][Bb]:([^%]+)%%  ]]; then cat_kind="library";  cq="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ %%[Ss][Nn][Ii][Pp]:([^%]+)%% ]]; then cat_kind="snippets"; cq="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ %%[Ss][Rr][Cc]:([^%]+)%%     ]]; then cat_kind="sources";  cq="${BASH_REMATCH[1]}"
    fi
    if [ -n "$cat_kind" ]; then
        # ${x^^} is bash 4 only; macOS ships bash 3.2, so use tr.
        tag="$(printf '%s' "$cat_kind" | tr '[:lower:]' '[:upper:]')"; [ "$cat_kind" = "library" ] && tag="LIB"; [ "$cat_kind" = "snippets" ] && tag="SNIP"; [ "$cat_kind" = "sources" ] && tag="SRC"
        if ! command -v jq >/dev/null 2>&1; then echo "[CRUD:ERR] $tag \"$cq\" — jq not installed"; echo ""; continue; fi
        cq_lc=$(printf '%s' "$cq" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        # Global index (the user's data dir, then the daemon's), then the project's own.
        cat_hit=""; cat_scope=""
        for cat_idx in "${COCKPIT_DATA_USER:-}/library_index.json" "$COCKPIT_DATA/library_index.json" "$PROJECT_DIR/library_index.json"; do
            [ -f "$cat_idx" ] || continue
            cat_hit=$(jq -c --arg k "$cat_kind" --arg q "$cq_lc" '(.[$k] // [])[] | select(((.id // "") == $q) or ((.title // "" | ascii_downcase) == $q) or ((.title // "" | ascii_downcase) | contains($q)))' "$cat_idx" 2>/dev/null | head -1)
            [ -n "$cat_hit" ] && { cat_scope="$cat_idx"; break; }
        done
        if [ -z "$cat_hit" ]; then echo "[CRUD:ERR] $tag \"$cq\" — no entry found"; echo ""; continue; fi
        m_id=$(printf '%s' "$cat_hit" | jq -r '.id // ""'); m_title=$(printf '%s' "$cat_hit" | jq -r '.title // ""')
        m_file=$(printf '%s' "$cat_hit" | jq -r '.file_path // ""'); m_url=$(printf '%s' "$cat_hit" | jq -r '.url // ""'); m_path=$(printf '%s' "$cat_hit" | jq -r '.path // ""')
        # Library entries keep hand-typed or extracted text beside the index.
        [ -z "$m_file" ] && [ "$cat_kind" = "library" ] && [ -n "$m_id" ] && for d in "${COCKPIT_DATA_USER:-}" "$COCKPIT_DATA"; do [ -f "$d/library_text/$m_id.txt" ] && { m_file="$d/library_text/$m_id.txt"; break; }; done
        [ -z "$m_file" ] && [ -n "$m_path" ] && [ -f "$m_path" ] && m_file="$m_path"
        echo "[CRUD:INFO] $tag \"$m_title\":"
        if [ -n "$m_file" ] && [ -f "$m_file" ]; then
            head -c 16384 "$m_file"; echo ""
            [ "$(wc -c < "$m_file")" -gt 16384 ] && echo "[... truncated to first 16KB]"
        elif [ -n "$m_url" ] && command -v curl >/dev/null 2>&1; then
            curl -sL --max-time 20 "$m_url" 2>/dev/null | sed 's/<[^>]*>/ /g' | tr -s ' \n' | head -c 8192; echo ""
        else
            echo "[CRUD:ERR] $tag \"$m_title\" — nothing stored to read (no file, path or url)"
        fi
        echo ""
        continue
    fi
    if [[ "$line" =~ %%[Dd][Ee][Ll][Ee][Tt][Ee]:([^%]+)%% ]]; then
        rel="${BASH_REMATCH[1]}"
        if [ "$HAS_CONFIRM" -ne 1 ]; then
            echo "[CRUD:ERR] DELETE $rel — missing %%CONFIRM:DELETE%% in response"
            continue
        fi
        full_path=$(safe_path "$rel")
        if [ -z "$full_path" ]; then
            echo "[CRUD:ERR] DELETE rejected — path outside project: $rel"
        elif [ ! -e "$full_path" ]; then
            echo "[CRUD:ERR] DELETE $rel — not found"
        else
            rm -rf "$full_path"
            echo "[CRUD:OK] DELETE $rel"
        fi
        continue
    fi

    # %%MKDIR:path%%
    if [[ "$line" =~ %%[Mm][Kk][Dd][Ii][Rr]:([^%]+)%% ]]; then
        rel="${BASH_REMATCH[1]}"
        full_path=$(safe_path "$rel")
        if [ -z "$full_path" ]; then
            echo "[CRUD:ERR] MKDIR rejected — path outside project: $rel"
        else
            mkdir -p "$full_path"
            chmod 775 "$full_path" 2>/dev/null
            echo "[CRUD:OK] MKDIR $rel"
        fi
        continue
    fi

    # %%LIST:subpath%% or %%LIST%%
    if [[ "$line" =~ %%[Ll][Ii][Ss][Tt]:([^%]*)%% ]]; then
        rel="${BASH_REMATCH[1]}"
        if [ -z "$rel" ]; then
            list_dir="$PROJECT_DIR"
            list_label="."
        else
            list_dir=$(safe_path "$rel")
            list_label="$rel"
        fi
        if [ -z "$list_dir" ] || [ ! -d "$list_dir" ]; then
            echo "[CRUD:ERR] LIST ${rel:-.} — directory not found"
        else
            echo "[CRUD:INFO] LIST $list_label:"
            ls -la "$list_dir" | tail -n +4   # skip totals + . and ..
            echo ""
        fi
        continue
    fi
    # Plain %%LIST%%
    if [[ "$line" =~ %%[Ll][Ii][Ss][Tt]%% ]]; then
        echo "[CRUD:INFO] LIST .:"
        ls -la "$PROJECT_DIR" | tail -n +4
        echo ""
        continue
    fi

done < "$RESPONSE_FILE"
