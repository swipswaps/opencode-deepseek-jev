#!/usr/bin/env bash
#
# test-sidebar-streaming.sh — regression test: is a session visible in
# the sidebar (SSE) while it is processing?
#
# Opens the /api/event SSE stream, triggers a real session with
# `opencode run` inside the web container, then asserts that
# session.created plus message.updated / session.updated events are
# emitted while the session processes.
#
# Host-side: requires docker, the running opencode-web container, and
# OPENCODE_SERVER_PASSWORD (or --insecure if the server is unauthenticated).
#
# Usage:
#   ./scripts/test-sidebar-streaming.sh
#   ./scripts/test-sidebar-streaming.sh --insecure
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill (TERM only), printf only,
#   main() wrapper.
#
set -o pipefail

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

C="opencode-deepseek-web"
MODEL="deepseek/deepseek-flash"
URL="http://127.0.0.1:4096"

main() {
    local insecure=0
    case "${1:-}" in
        --insecure) insecure=1 ;;
        "") ;;
        *) printf 'usage: %s [--insecure]\n' "$0"; return 2 ;;
    esac

    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi

    local pass=""
    if [ -f "$REPO/.env.local" ]; then
        while IFS='=' read -r k v; do
            [ "$k" = "OPENCODE_SERVER_PASSWORD" ] && pass="$v"
        done < "$REPO/.env.local"
    fi
    [ -z "$pass" ] && pass="${OPENCODE_SERVER_PASSWORD:-}"

    if [ -z "$pass" ] && [ "$insecure" -ne 1 ]; then
        printf 'GATE FAIL: OPENCODE_SERVER_PASSWORD unset; pass --insecure if the server has no auth\n'
        return 1
    fi

    if ! have docker; then
        printf 'GATE FAIL: docker not found\n'
        return 1
    fi
    if ! docker inspect -f '{{.State.Status}}' "$C" | grep -q '^running$'; then
        printf 'GATE FAIL: container %s not running\n' "$C"
        return 1
    fi

    local ts sse trigger
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    sse="/tmp/sidebar-sse-${ts}.log"
    trigger="/tmp/sidebar-trigger-${ts}.log"

    printf '=== test-sidebar-streaming.sh ===\n'
    printf 'SSE:     %s/api/event\n' "$URL"
    printf 'Capture: %s\n' "$sse"

    local auth=()
    [ -n "$pass" ] && auth=(-u "opencode:$pass")

    curl -s -N "${auth[@]}" "$URL/api/event" > "$sse" 2>&1 &
    local sse_pid=$!
    sleep 1

    printf 'triggering a session via opencode run ...\n'
    docker exec -w /workspace "$C" sh -c \
        "opencode run --model '$MODEL' 'Reply with exactly: PONG'" \
        > "$trigger" 2>&1
    local trig_rc=$?
    printf 'trigger exit=%s\n' "$trig_rc"

    sleep 3

    kill -TERM "$sse_pid" 2>&1 || true
    wait "$sse_pid" 2>&1 || true

    printf '\n=== event analysis ===\n'
    printf 'lines: %s\n' "$(wc -l < "$sse" | tr -d ' ')"
    local sc su mu
    sc=$(grep -c 'session.created' "$sse")
    su=$(grep -c 'session.updated' "$sse")
    mu=$(grep -c 'message.updated' "$sse")
    printf 'session.created: %s\n' "$sc"
    printf 'session.updated: %s\n' "$su"
    printf 'message.updated: %s\n' "$mu"

    printf '\nevent types seen (sample):\n'
    grep -oE '(session|message)\.[a-z.]+' "$sse" | sort -u | head -12 | while IFS= read -r l; do printf '  %s\n' "$l"; done

    if [ "$sc" -gt 0 ] && [ "$mu" -gt 0 ]; then
        printf '\nresult: PASS — session events stream while processing\n'
        return 0
    fi
    printf '\nresult: FAIL — session events not observed (auth or event-name mismatch?)\n'
    printf 'SSE head (last 8 lines):\n'
    tail -8 "$sse" | while IFS= read -r l; do printf '  %s\n' "$l"; done
    return 1
}

main "$@"
