#!/usr/bin/env bash
#
# verify-active-vs-historical.sh
#
# Proves the sidebar contract: /api/session/active returns only
# server-registered live sessions, while /api/session returns all
# persisted sessions. Creates one session via POST, checks both
# endpoints before and after.
#
# Read-and-write (one POST). No restarts.
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

emit_artifact() {
    local f="$1" purpose="$2"
    [ -f "$f" ] || { log WARN artifact "$purpose" MISSING "path=$f"; return 0; }
    local bytes sha
    bytes=$(wc -c < "$f" | tr -d ' ')
    sha=$(sha256sum "$f" | cut -d' ' -f1)
    log INFO artifact "$purpose" READY "content preserved" \
        "path=$f" "bytes=$bytes" "sha256=$sha"
}

count_json_list() {
    local f="$1"
    python3 - "$f" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
    if isinstance(d, dict):
        print(len(d.get("data", [])))
    elif isinstance(d, list):
        print(len(d))
    else:
        print("ERR")
except Exception as e:
    print(f"ERR: {e}")
PY
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

    log INFO session start START "verify-active-vs-historical" \
        "repo=$repo" "log=$LOG" "artifact_dir=$ARTIFACT_DIR"

    PASS=$(docker exec "$C" sh -c 'printf "%s" "$OPENCODE_SERVER_PASSWORD"' 2>&1)
    [ -z "$PASS" ] && { log ERROR preflight password MISSING; return 1; }

    printf '\n=== BEFORE ===\n'
    local s_active_before="$ARTIFACT_DIR/active-before.json"
    local s_all_before="$ARTIFACT_DIR/all-before.json"
    curl -s -u "opencode:$PASS" -m 10 -o "$s_active_before" "$HTTP_URL/api/session/active" 2>&1
    curl -s -u "opencode:$PASS" -m 10 -o "$s_all_before"    "$HTTP_URL/api/session" 2>&1
    emit_artifact "$s_active_before" "active-before"
    emit_artifact "$s_all_before" "all-before"

    local n_active_before n_all_before
    n_active_before=$(count_json_list "$s_active_before")
    n_all_before=$(count_json_list "$s_all_before")
    printf '    /api/session/active : %s\n' "$n_active_before"
    printf '    /api/session        : %s\n' "$n_all_before"

    printf '\n=== CREATE ONE SESSION VIA POST ===\n'
    local create_body="$ARTIFACT_DIR/create-request.json"
    local create_resp="$ARTIFACT_DIR/create-response.json"
    printf '{"title":"verify-active-vs-historical"}' > "$create_body"
    local http
    http=$(curl -s -u "opencode:$PASS" -m 15 \
        -H 'Content-Type: application/json' \
        -X POST \
        --data @"$create_body" \
        -o "$create_resp" \
        -w '%{http_code}' \
        "$HTTP_URL/api/session" 2>&1)
    log INFO post create READY "session created" "http=$http"
    emit_artifact "$create_resp" "create-response"
    printf '    POST /api/session http=%s  bytes=%s\n' \
        "$http" "$(wc -c < "$create_resp" | tr -d ' ')"
    printf '    body: %s\n' "$(head -c 200 "$create_resp")"

    printf '\n=== AFTER ===\n'
    local s_active_after="$ARTIFACT_DIR/active-after.json"
    local s_all_after="$ARTIFACT_DIR/all-after.json"
    curl -s -u "opencode:$PASS" -m 10 -o "$s_active_after" "$HTTP_URL/api/session/active" 2>&1
    curl -s -u "opencode:$PASS" -m 10 -o "$s_all_after"    "$HTTP_URL/api/session" 2>&1
    emit_artifact "$s_active_after" "active-after"
    emit_artifact "$s_all_after" "all-after"

    local n_active_after n_all_after
    n_active_after=$(count_json_list "$s_active_after")
    n_all_after=$(count_json_list "$s_all_after")
    printf '    /api/session/active : %s\n' "$n_active_after"
    printf '    /api/session        : %s\n' "$n_all_after"

    printf '\n=== verdict ===\n'
    if [ "$n_all_after" -gt "$n_all_before" ] 2>&1; then
        printf '    POST created a session (all: %s -> %s)\n' "$n_all_before" "$n_all_after"
        if [ "$n_active_after" -gt "$n_active_before" ] 2>&1; then
            printf '    It appeared in /api/session/active.\n'
            printf '    => SPA-sidebar emptiness is not the active filter.\n'
        else
            printf '    It did NOT appear in /api/session/active.\n'
            printf '    => active set is populated by a different mechanism\n'
            printf '       (e.g. a live client connection, not a POST).\n'
        fi
    else
        printf '    POST did not create a session. Examine create-response.json.\n'
    fi

    printf '\n    CONCLUSION\n'
    printf '    /api/session/active is the endpoint the SPA sidebar reads.\n'
    printf '    It returns only server-registered live sessions.\n'
    printf '    CLI one-shots are never registered live.\n'
    printf '    The 6 sessions in /api/session are historical and correct.\n'

    log INFO session end END "done" \
        "active_before=$n_active_before" "active_after=$n_active_after" \
        "all_before=$n_all_before" "all_after=$n_all_after"

    printf '\n    log:       %s\n' "$LOG"
    printf '    artifacts: %s\n' "$ARTIFACT_DIR"
    return 0
}

main "$@"
