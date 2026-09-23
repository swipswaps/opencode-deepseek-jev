#!/usr/bin/env bash
#
# find-sidebar-source.sh
#
# Answers: why does the sidebar show nothing while /api/session returns
# 7 sessions? Reads the SPA bundle around the exact fetch call, probes
# alternative session endpoints, and prints the definitive answer.
#
# Read-only. No restarts.
#
set -o pipefail

C="opencode-deepseek-web"
HTTP_URL="http://127.0.0.1:4096"

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

log() {
    local level="$1" phase="$2" stage="$3" status="$4" msg="$5"
    shift 5
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    local kv="" p; for p in "$@"; do kv="$kv $p"; done
    local record="ts=$ts level=$level phase=$phase stage=$stage status=$status msg=\"$msg\"$kv"
    [ -n "$LOG" ] && printf '%s\n' "$record" >> "$LOG"
    printf '%s\n' "$record"
}

main() {
    local script_dir repo ts
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    [ -z "$repo" ] && { printf 'GATE FAIL: cannot resolve repo\n'; return 2; }
    REPO="$repo"; ts=$(date -u +%Y%m%dT%H%M%SZ)

    mkdir -p "$repo/logs"
    LOG="$repo/logs/telemetry-$(date -u +%Y-%m-%d).log"
    ARTIFACT_DIR="$repo/logs/artifacts-$ts"
    mkdir -p "$ARTIFACT_DIR"

    log INFO session start START "find-sidebar-source" "repo=$repo"

    PASS=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
    [ -z "$PASS" ] && { log ERROR preflight password MISSING; return 1; }

    local html bundle_path bundle raw
    html="$ARTIFACT_DIR/index.html"
    curl -s -u "opencode:$PASS" -m 10 -o "$html" "$HTTP_URL/" 2>&1
    raw=$(grep -oE 'src="[^"]+\.js[^"]*"' "$html" | head -1)
    bundle_path=${raw#src=\"}
    bundle_path=${bundle_path%\"}
    bundle="$ARTIFACT_DIR/bundle.js"
    curl -s -u "opencode:$PASS" -m 30 -o "$bundle" "$HTTP_URL$bundle_path" 2>&1
    log INFO fetch bundle READY "cached" "bytes=$(wc -c < "$bundle" | tr -d ' ')"

    printf '\n===== A. exact fetch call for /api/session/active =====\n'
    python3 - "$bundle" <<'PY'
import sys
data = open(sys.argv[1], errors="replace").read()
needles = ["session/active", '"/api/session"', "experimental/session", "sidebar", "sidebarState", "selectedProject", "currentProject"]
for n in needles:
    i = data.find(n)
    if i < 0:
        print(f"\n[{n}] not found")
        continue
    lo = max(0, i - 200)
    hi = min(len(data), i + len(n) + 300)
    print(f"\n[{n}] at offset {i}")
    print("  " + data[lo:hi].replace("\n", " "))
PY

    printf '\n===== B. probe alternative session endpoints =====\n'
    local sid pid
    sid=$(sqlite3 "$repo/data/opencode/opencode.db" \
        "select id from session order by time_created desc limit 1;" 2>&1)
    pid=$(sqlite3 "$repo/data/opencode/opencode.db" \
        "select distinct project_id from session limit 1;" 2>&1)
    printf '    latest session id: %s\n' "$sid"
    printf '    project id:        %s\n\n' "$pid"

    local p
    for p in \
        "/api/session/$sid" \
        "/api/experimental/session" \
        "/api/experimental/session/" \
        "/api/session/" \
        "/api/project" \
        "/api/project/$pid" \
        "/api/project/$pid/session"
    do
        local slug out code bytes kind headc
        slug=$(printf '%s' "$p" | tr '/?=' '___')
        out="$ARTIFACT_DIR/probe-${slug}.out"
        code=$(curl -s -u "opencode:$PASS" -m 8 -o "$out" -w '%{http_code}' "$HTTP_URL$p" 2>&1)
        bytes=$(wc -c < "$out" | tr -d ' ')
        kind=$(file -b "$out" 2>&1 | head -c 25)
        printf '    %-62s http=%s bytes=%-6s %s\n' "$p" "$code" "$bytes" "$kind"
        headc=$(head -c 1 "$out")
        if [ "$headc" = "{" ] || [ "$headc" = "[" ]; then
            printf '        body: %s\n' "$(head -c 220 "$out" | tr -d '\n')"
        fi
    done

    printf '\n===== C. localStorage keys the bundle reads =====\n'
    grep -oE '"[^"]*(opencode|project|session|sidebar)[^"]*"' "$bundle" \
        | sort -u | head -25 | while IFS= read -r k; do
        printf '    %s\n' "$k"
    done

    log INFO session end END "done"
    printf '\n    log:       %s\n' "$LOG"
    printf '    artifacts: %s\n' "$ARTIFACT_DIR"
    return 0
}

main "$@"
