#!/usr/bin/env bash
#
# web-restart.sh — restart the observability dashboard so :5099 serves the
# current checkout, then verify the served revision matches HEAD.
#
# Why this script exists: `opencode-web` is a compose SERVICE name, not a
# command — typing it bare at a shell prints "command not found". This
# wrapper is the command. Run it from anywhere inside the repo checkout:
#
#   ./scripts/web-restart.sh
#
# Two modes:
#   docker present  -> `docker compose restart opencode-web` (the host path)
#   docker absent   -> restart the local `dashboard.mjs` process (the sandbox
#                      path; this is why :5099 goes STALE after every commit
#                      here — nothing was restarting it)
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
# ============================================================================

set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"
            return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=$(resolve_repo "$SCRIPT_DIR")
if [ -z "$REPO_DIR" ]; then
    REPO_DIR=$(resolve_repo "$PWD")
fi
if [ -z "$REPO_DIR" ]; then
    printf 'GATE FAIL: cannot resolve repo root\n'
    return 2
fi

rev_json() {
    # Print "served stale=" from :5099. HTTPS first (caddy on the host), then
    # plain HTTP (the sandbox binds :5099 without TLS). Empty when unreachable.
    python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(str(d.get("served","?"))+" stale="+str(d.get("stale","?")))
except Exception:
    pass'
}

probe_rev() {
    local out
    out=$(curl -k -s --max-time 8 https://127.0.0.1:5099/api/rev 2>&1 | rev_json)
    [ -n "$out" ] || out=$(curl -s --max-time 8 http://127.0.0.1:5099/api/rev 2>&1 | rev_json)
    printf '%s' "$out"
}

dashboard_pid() {
    local p cl
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        cl=$(tr '\0' ' ' < "$p/cmdline" 2>&1)
        case "$cl" in
            *dashboard.mjs*5099*) basename "$p"; return 0 ;;
        esac
    done
    return 1
}

main() {
    printf '=== web-restart.sh ===\n'
    local head
    head=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>&1) || head="unknown"
    printf 'HEAD: %s\n' "$head"

    if have docker; then
        printf 'mode: docker compose restart opencode-web\n'
        ( cd "$REPO_DIR/docker" && docker compose restart opencode-web ) || {
            printf 'FAIL: docker compose restart failed\n'
            printf 'hint: is the docker daemon reachable? try: docker ps\n'
            return 1
        }
    else
        printf 'mode: dockerless (local dashboard.mjs process)\n'
        local pid args
        pid=$(dashboard_pid) || { printf 'FAIL: no dashboard.mjs process and docker absent\n'; return 1; }
        args=$(tr '\0' ' ' < "/proc/$pid/cmdline")   # read BEFORE killing
        printf 'restarting dashboard pid %s\n' "$pid"
        kill -TERM "$pid"
        sleep 2
        # shellcheck disable=SC2086
        setsid $args > /tmp/dashboard.log 2>&1 < /dev/null &
    fi

    printf 'restart issued; waiting for :5099 (boot + health pre-warm)\n'
    local i served
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sleep 5
        served=$(probe_rev)
        if [ -n "$served" ]; then
            printf 'rev: %s (HEAD %s)\n' "$served" "$head"
            case "$served" in
                "$head"*stale=False*) printf 'PASS: :5099 serves current checkout\n'; return 0 ;;
            esac
        fi
    done
    printf 'FAIL: :5099 did not serve %s within 60s (last: %s)\n' "$head" "$served"
    printf 'hint: docker logs --tail 20 opencode-deepseek-web (https probe; http:// -> 400 by design)\n'
    return 1
}

main "$@"
