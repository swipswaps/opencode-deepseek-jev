#!/usr/bin/env bash
#
# caddy-reload.sh — validate the Caddyfile, restart caddy, verify (durable).
#
# Each step is checkpointed via scripts/durable-run.sh, so an interrupted run
# resumes from its last step instead of repeating (pi-durable). Host-only: it
# needs docker + the running caddy container.
#
#   ./scripts/caddy-reload.sh            # validate -> restart -> verify
#   ./scripts/caddy-reload.sh --dry-run  # print the plan, run nothing
#   ./scripts/caddy-reload.sh --reset    # clear the checkpoints
#   ./scripts/caddy-reload.sh --self-test
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

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

self_test() {
    local fail=0 s
    s=$(cat "${BASH_SOURCE[0]}")
    printf '%s' "$s" | grep -q 'durable-run.sh' || { printf 'FAIL: not checkpointed\n'; fail=1; }
    for step in validate restart verify; do
        printf '%s' "$s" | grep -q -- "--step $step" || { printf 'FAIL: missing step %s\n' "$step"; fail=1; }
    done
    local o
    o=$(bash "${BASH_SOURCE[0]}" --dry-run 2>&1)
    printf '%s' "$o" | grep -q 'validate' || { printf 'FAIL: dry-run lacks validate\n'; fail=1; }
    printf '%s' "$o" | grep -q 'restart' || { printf 'FAIL: dry-run lacks restart\n'; fail=1; }
    printf 'caddy-reload: self-test %s\n' "$([ "$fail" -eq 0 ] && printf PASS || printf FAIL)"
    return "$fail"
}

main() {
    local REPO DR
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    [ -z "$REPO" ] && { printf 'GATE FAIL: cannot resolve repo root\n'; return 2; }
    DR="$REPO/scripts/durable-run.sh"
    [ -x "$DR" ] || { printf 'GATE FAIL: %s not executable\n' "$DR"; return 1; }
    case "${1:-}" in
        --self-test) self_test; return "$?" ;;
        --reset) exec "$DR" --job caddy-reload --reset ;;
        --dry-run)
            printf 'caddy-reload plan (checkpointed via durable-run):\n'
            printf '  1. validate  docker compose --project-directory %s/docker exec caddy caddy validate --config /etc/caddy/Caddyfile\n' "$REPO"
            printf '  2. restart   docker compose --project-directory %s/docker restart caddy\n' "$REPO"
            printf '  3. verify    curl -skf https://127.0.0.1:5099/api/rev\n'
            return 0 ;;
        -h | --help) printf 'usage: %s [--dry-run|--reset|--self-test]\n' "$0"; return 0 ;;
        "") : ;;
        *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
    esac
    have docker || { printf 'GATE FAIL: docker required (host-only)\n'; return 1; }
    "$DR" --job caddy-reload --step validate -- docker compose --project-directory "$REPO/docker" \
        exec caddy caddy validate --config /etc/caddy/Caddyfile || return 1
    "$DR" --job caddy-reload --step restart -- docker compose --project-directory "$REPO/docker" \
        restart caddy || return 1
    "$DR" --job caddy-reload --step verify -- curl -skf https://127.0.0.1:5099/api/rev || return 1
    printf 'caddy-reload: OK (validated, restarted, serving)\n'
    return 0
}

main "$@"
