#!/usr/bin/env bash
#
# models.sh — model catalog + cost policy from `opencode models --verbose`.
# Thin wrapper so the caller does not have to know the dump format.
#
#   ./scripts/models.sh                 # table + policy verdict for the current model
#   ./scripts/models.sh --json          # machine output
#   ./scripts/models.sh --write         # persist data/observability/models.json (for the UI)
#   ./scripts/models.sh --current deepseek/deepseek-v4-pro
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit, no rm -rf,
#   no subprocess.run, no bare kill, printf only, main() wrapper.
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

main() {
    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    local PY="$REPO/scripts/models.py"
    if [ ! -f "$PY" ]; then
        printf 'FAIL: models.py not found\n'
        return 2
    fi
    if ! have python3; then
        printf 'FAIL: python3 required\n'
        return 2
    fi
    if ! have opencode; then
        printf 'FAIL: opencode not on PATH\n'
        return 2
    fi

    local work
    work=$(mktemp)
    opencode models --verbose > "$work" 2>&1
    python3 "$PY" --input "$work" "$@"
    local rc=$?
    rm -f "$work"
    return $rc
}

main "$@"
