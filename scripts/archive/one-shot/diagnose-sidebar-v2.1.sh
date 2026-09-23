#!/usr/bin/env bash
#
# diagnose-sidebar-v2.1.sh
#
# v2 used sed twice on the bundle_path extraction line (violating P1.1).
# v2.1 replaces both with POSIX parameter expansion:
#   ${raw#src=\"}   strips leading src="
#   ${raw%\"}       strips trailing "
# and verifies the result with a case check.
#
# Full diagnostic content otherwise unchanged from v2.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
# no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

C="opencode-deepseek-web"
HTTP_URL="http://127.0.0.1:4096"
DATA_HOST_REL="data/opencode"

REPO=""; LOG=""; ARTIFACT_DIR=""; PASS=""

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"; return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

have() { command -v "$1" >/dev/null 2>&1; }

log() {
    local level="$1" phase="$2" stage="$3" status="$4" msg="$5"
    shift 5
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    local kv="" p
    for p in "$@"; do kv="$kv $p"; done
    local record="ts=$ts level=$level phase=$phase stage=$stage status=$status msg=\"$msg\"$kv"
    if [ -n "$LOG" ]; then printf '%s\n' "$record" >> "$LOG"; fi
    printf '%s\n' "$record"
}

emit_artifact() {
    local file="$1" purpose="$2"
    [ -f "$file" ] || { log WARN artifact "$purpose" MISSING "no file" "path=$file"; return 0; }
    local bytes sha
    bytes=$(wc -c < "$file" | tr -d ' ')
    sha=$(sha256sum "$file" | cut -d' ' -f1)
    log INFO artifact "$purpose" READY "content preserved" \
        "path=$file" "bytes=$bytes" "sha256=$sha"
}

# extract_bundle_path HTML_FILE
#   grep the first src="...js..." attribute, strip src=" and trailing ".
#   Pure shell, no sed.
extract_bundle_path() {
    local f="$1"
    local raw
    raw=$(grep -oE 'src="[^"]+\.js[^"]*"' "$f" | head -1)
    if [ -z "$raw" ]; then
        printf '%s' ""
        return 0
    fi
    # raw looks like: src="/assets/index-gyzZF0EC.js"
    # Strip leading src="
    raw=${raw#src=\"}
    # Strip trailing "
    raw=${raw%\"}
    printf '%s' "$raw"
}

main() {
    local script_dir repo ts
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    [ -z "$repo" ] && { printf 'GATE FAIL: cannot resolve repo\n'; return 2; }
    REPO="$repo"
    ts=$(date -u +%Y%m%dT%H%M%SZ)

    mkdir -p "$repo/logs"
    LOG="$repo/logs/telemetry-$(date -u +%Y-%m-%d).log"
    ARTIFACT_DIR="$repo/logs/artifacts-$ts"
    mkdir -p "$ARTIFACT_DIR"

    log INFO session start START "diagnose-sidebar-v2.1" \
        "repo=$repo" "log=$LOG" "artifact_dir=$ARTIFACT_DIR"

    have curl    || { log ERROR preflight curl MISSING; return 1; }
    have python3 || { log ERROR preflight python3 MISSING; return 1; }

    PASS=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
    [ -z "$PASS" ] && { log ERROR preflight password MISSING; return 1; }

    # ---- index.html ----
    local html="$ARTIFACT_DIR/index.html"
    curl -s -u "opencode:$PASS" -m 10 -o "$html" "$HTTP_URL/" 2>&1
    emit_artifact "$html" "index-html"

    local bundle_path
    bundle_path=$(extract_bundle_path "$html")
    if [ -z "$bundle_path" ]; then
        log ERROR parse index FAIL "no js bundle src found"
        return 1
    fi
    case "$bundle_path" in
        /*.js*) ;;
        *) log WARN parse bundle WARN "unexpected path shape" "path=$bundle_path" ;;
    esac
    log INFO parse index PASS "bundle found" "path=$bundle_path"

    # ---- fetch bundle ----
    local bundle="$ARTIFACT_DIR/bundle.js"
    curl -s -u "opencode:$PASS" -m 30 -o "$bundle" "$HTTP_URL$bundle_path" 2>&1
    emit_artifact "$bundle" "spa-bundle"

    local bundle_bytes
    bundle_bytes=$(wc -c < "$bundle" | tr -d ' ')
    log INFO fetch bundle READY "bundle fetched" \
        "path=$bundle_path" "bytes=$bundle_bytes"

    # ---- API paths in bundle ----
    printf '\n=== API paths referenced in bundle ===\n'
    local api_paths
    api_paths=$(grep -oE '/api/[a-zA-Z0-9_./?-]+' "$bundle" | sort -u)
    printf '%s\n' "$api_paths" | while IFS= read -r p; do
        printf '    %s\n' "$p"
    done
    log INFO parse bundle PASS "api paths extracted" \
        "n_paths=$(printf '%s\n' "$api_paths" | grep -c .)"

    # ---- SSE references ----
    printf '\n=== SSE / EventSource references in bundle ===\n'
    local sse_hits
    sse_hits=$(grep -oE 'EventSource|text/event-stream|/api/event[^"]*' "$bundle" | sort -u | head -20)
    if [ -n "$sse_hits" ]; then
        printf '%s\n' "$sse_hits" | while IFS= read -r h; do printf '    %s\n' "$h"; done
    else
        printf '    (none)\n'
    fi

    # ---- project / localStorage ----
    printf '\n=== localStorage / project references ===\n'
    grep -oE 'localStorage\.[a-zA-Z]+\([^)]{0,40}|sessionStorage\.[a-zA-Z]+\([^)]{0,40}' "$bundle" \
        | sort -u | head -20 | while IFS= read -r h; do printf '    %s\n' "$h"; done

    # ---- SSE capture ----
    printf '\n=== /api/event stream (3 s capture) ===\n'
    local event_file="$ARTIFACT_DIR/api-event.txt"
    curl -s -u "opencode:$PASS" -m 3 -o "$event_file" "$HTTP_URL/api/event" 2>&1
    emit_artifact "$event_file" "api-event"
    if [ -s "$event_file" ]; then
        printf '    --- raw (first 800 bytes) ---\n'
        head -c 800 "$event_file" | while IFS= read -r line; do printf '    %s\n' "$line"; done
        printf '\n    --- event types ---\n'
        grep -oE '"type":"[^"]+"' "$event_file" | sort | uniq -c | while IFS= read -r line; do printf '    %s\n' "$line"; done
    else
        printf '    (no data in 3 s)\n'
    fi

    # ---- compare session responses ----
    printf '\n=== /api/session — without vs with directory filter ===\n'
    local s1="$ARTIFACT_DIR/session-plain.json"
    local s2="$ARTIFACT_DIR/session-filtered.json"
    curl -s -u "opencode:$PASS" -m 10 -o "$s1" "$HTTP_URL/api/session" 2>&1
    curl -s -u "opencode:$PASS" -m 10 -o "$s2" "$HTTP_URL/api/session?directory=/workspace" 2>&1
    emit_artifact "$s1" "session-plain"
    emit_artifact "$s2" "session-filtered"

    if have python3 && [ -s "$s1" ] && [ -s "$s2" ]; then
        python3 - "$s1" "$s2" <<'PY'
import json, sys
a = json.load(open(sys.argv[1]))
b = json.load(open(sys.argv[2]))
da = a.get("data") or []
db = b.get("data") or []
print(f"    plain     count={len(da)}")
print(f"    filtered  count={len(db)}")

def keyset(lst):
    out = set()
    for item in lst:
        out.update(item.keys())
    return sorted(out)

ka, kb = keyset(da), keyset(db)
only_a = [k for k in ka if k not in kb]
only_b = [k for k in kb if k not in ka]
print(f"    keys only in plain:    {only_a}")
print(f"    keys only in filtered: {only_b}")
for k in only_b:
    print(f"    filtered-only field '{k}' sample: {[item.get(k) for item in db[:3]]}")
PY
    fi

    # ---- verdict ----
    printf '\n=== verdict ===\n'
    local refs_event
    if grep -q '/api/event' "$bundle" 2>&1; then
        refs_event="yes"
    else
        refs_event="no"
    fi
    printf '    bundle references /api/event: %s\n' "$refs_event"
    printf '    /api/event emitted data:      %s\n' \
        "$([ -s "$event_file" ] && printf yes || printf no)"
    printf '\n'
    printf '    If both yes: SPA is SSE-driven; empty sidebar is a browser-render\n'
    printf '    issue, not a data issue.\n'
    printf '    If bundle says yes, event says no: server is silent for pre-existing\n'
    printf '    sessions; needs hydration or emit-on-read.\n'
    printf '    If bundle says no: SPA is one-shot; look at /api/session shape.\n'

    log INFO session end END "done"
    printf '\n    log:       %s\n' "$LOG"
    printf '    artifacts: %s\n' "$ARTIFACT_DIR"
    return 0
}

main "$@"
