#!/usr/bin/env bash
#
# diagnose-sidebar-empty.sh
#
# API says 6 sessions, sidebar says 0. This script enumerates the HTTP
# surface the SPA is likely to consume, dumps each response, and
# cross-references the sqlite project/session tables for the linkage the
# UI would need.
#
# Read-only. No writes, no restarts.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
# no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

C="opencode-deepseek-web"
HTTP_URL="http://127.0.0.1:4096"
DATA_HOST_REL="data/opencode"

REPO=""; LOG=""; ARTIFACT_DIR=""

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

fetch() {
    # fetch LABEL PATH OUTFILE
    local label="$1" path="$2" outfile="$3"
    local http
    http=$(curl -s -u "opencode:$PASS" -m 10 -o "$outfile" \
        -w '%{http_code}' "$HTTP_URL$path" 2>&1)
    local bytes=0 ctype=""
    if [ -f "$outfile" ]; then
        bytes=$(wc -c < "$outfile" | tr -d ' ')
        ctype=$(file -b "$outfile" 2>&1 | head -c 60)
    fi
    log INFO probe "$label" READY "probed" \
        "path=$path" "http=$http" "bytes=$bytes" "type=\"$ctype\""
    printf '%s' "$http"
}

main() {
    local script_dir repo ts
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo=$(resolve_repo "$script_dir")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    [ -z "$repo" ] && { printf '%s\n' 'GATE FAIL: cannot resolve repo'; return 2; }
    REPO="$repo"
    ts=$(date -u +%Y%m%dT%H%M%SZ)

    mkdir -p "$repo/logs"
    LOG="$repo/logs/telemetry-$(date -u +%Y-%m-%d).log"
    ARTIFACT_DIR="$repo/logs/artifacts-$ts"
    mkdir -p "$ARTIFACT_DIR"

    log INFO session start START "diagnose-sidebar-empty" \
        "repo=$repo" "log=$LOG" "artifact_dir=$ARTIFACT_DIR"

    have curl    || { log ERROR preflight curl MISSING; return 1; }
    have python3 || { log ERROR preflight python3 MISSING; return 1; }
    have sqlite3 || { log ERROR preflight sqlite3 MISSING; return 1; }

    local cstate
    cstate=$(docker inspect -f '{{.State.Status}}' "$C" 2>&1)
    if [ "$cstate" != "running" ]; then
        log ERROR preflight container ERROR "state=$cstate"
        return 1
    fi
    log INFO preflight container PASS "running"

    PASS=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
    [ -z "$PASS" ] && { log ERROR preflight password MISSING; return 1; }
    log INFO preflight password PASS "length=${#PASS}"

    # ---- HTTP probe ----
    log INFO probe start START "probing API surface"
    printf '\n=== HTTP probe ===\n'
    printf '    %-28s  %-5s  %-7s  %s\n' "path" "http" "bytes" "type"

    local paths=(
        "/api/session"
        "/api/session?directory=/workspace"
        "/api/project"
        "/api/projects"
        "/api/config"
        "/api/app"
        "/api/state"
        "/api/file"
        "/api/event"
    )
    local i=0
    for p in "${paths[@]}"; do
        i=$((i + 1))
        local outfile="$ARTIFACT_DIR/probe-${i}.json"
        local http
        http=$(fetch "probe-${i}" "$p" "$outfile")
        local bytes=0 ctype=""
        if [ -f "$outfile" ]; then
            bytes=$(wc -c < "$outfile" | tr -d ' ')
            ctype=$(file -b "$outfile" 2>&1 | head -c 40)
        fi
        printf '    %-28s  %-5s  %-7s  %s\n' "$p" "$http" "$bytes" "$ctype"
    done

    # ---- What does /api/project say ----
    printf '\n=== /api/project (if present) ===\n'
    if [ -f "$ARTIFACT_DIR/probe-3.json" ] && [ -s "$ARTIFACT_DIR/probe-3.json" ]; then
        head -c 800 "$ARTIFACT_DIR/probe-3.json"
        printf '\n'
    else
        printf '    (empty or absent)\n'
    fi

    # ---- sqlite cross-reference ----
    printf '\n=== sqlite: project table ===\n'
    local db="$repo/$DATA_HOST_REL/opencode.db"
    if [ ! -f "$db" ]; then
        printf '    (no db at %s)\n' "$db"
    else
        printf '    rows: '
        sqlite3 "$db" "select count(*) from project;" 2>&1
        printf '\n'
        sqlite3 -header "$db" "select id, path from project limit 10;" 2>&1 | head -20
    fi

    printf '\n=== sqlite: session.project_id linkage ===\n'
    if [ -f "$db" ]; then
        printf '    distinct project_id values in session:\n'
        sqlite3 "$db" "select distinct project_id from session;" 2>&1
        printf '\n    session rows sample (id, project_id, directory):\n'
        sqlite3 -header "$db" \
            "select substr(id,1,24) as id, substr(project_id,1,20) as pid, directory from session limit 5;" 2>&1
    fi

    printf '\n=== sqlite: do session.project_id values match project.id? ===\n'
    if [ -f "$db" ]; then
        local orphan
        orphan=$(sqlite3 "$db" "
            select count(*) from session s
            where s.project_id not in (select id from project);
        " 2>&1)
        printf '    orphan sessions (project_id not in project): %s\n' "$orphan"
    fi

    # ---- what the SPA bundle requests ----
    printf '\n=== index HTML (SPA entry) — grep for api endpoints ===\n'
    local html="$ARTIFACT_DIR/index.html"
    curl -s -u "opencode:$PASS" -m 10 -o "$html" "$HTTP_URL/" 2>&1
    if [ -s "$html" ]; then
        grep -oE '/api/[a-zA-Z0-9_/.-]+' "$html" | sort -u | head -30
        # Also look for the JS bundle path so we can grep it later.
        grep -oE 'src="[^"]+\.js[^"]*"' "$html" | head -5
    fi

    # ---- verdict ----
    printf '\n=== verdict ===\n'
    local api_count orphan
    api_count=$(python3 -c "
import json,sys
try:
    d=json.load(open('$ARTIFACT_DIR/probe-1.json'))
    print(len(d.get('data',[])))
except Exception:
    print('ERR')
" 2>&1)
    orphan=$(sqlite3 "$db" "
        select count(*) from session s
        where s.project_id not in (select id from project);
    " 2>&1)

    printf '    api /api/session count: %s\n' "$api_count"
    printf '    orphan session count:   %s\n' "$orphan"
    printf '\n'
    if [ "$api_count" = "6" ] && [ "$orphan" = "0" ]; then
        printf '    Data path is coherent. Sidebar emptiness is a frontend issue.\n'
        printf '    Next: check the SPA bundle path printed above; grep it for the\n'
        printf '    endpoint it actually requests.\n'
    elif [ "$api_count" = "6" ] && [ "$orphan" != "0" ]; then
        printf '    %s session rows have project_id not present in project table.\n' "$orphan"
        printf '    The SPA likely filters sessions by a valid project. Sessions\n'
        printf '    without a matching project row will not appear.\n'
    else
        printf '    api_count=%s — inspect probe-1.json for shape.\n' "$api_count"
    fi

    log INFO session end END "done" "api_count=$api_count" "orphan=$orphan"
    printf '\n    log:       %s\n' "$LOG"
    printf '    artifacts: %s\n' "$ARTIFACT_DIR"
    return 0
}

main "$@"
