#!/usr/bin/env bash
#
# dashboard.sh — thin read-only observability sidecar for the opencode
# database. Serves cost, balance, live activity, and todos on a local port.
#
# Usage:
#   ./scripts/dashboard.sh              serves on http://127.0.0.1:5099
#   DASH_PORT=8080 ./scripts/dashboard.sh
#   DASH_HOST=0.0.0.0 ./scripts/dashboard.sh   (only if you know why)
#
# Port note: Firefox blocks a hard-coded list of non-web ports (6000-6010
# X11, 6665-6669, 6697, 10080, etc.). The default 5099 is safe; if you
# override DASH_PORT, avoid that list or use 8080/3000/etc.
#
# Read-only; no docker. Runs on the host or inside the container (the
# database is mounted at data/opencode/opencode.db from either side).
# Requires node (>= 22.5, for node:sqlite).
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
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
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi

    local db="$REPO/data/opencode/opencode.db"
    if [ ! -f "$db" ]; then
        printf 'FAIL: no database at %s\n' "$db"
        return 1
    fi
    if ! have node; then
        printf 'FAIL: node is required to serve the dashboard\n'
        return 1
    fi

    local port="${DASH_PORT:-5099}"
    local host="${DASH_HOST:-127.0.0.1}"

    # Balance card: expose DEEPSEEK_API_KEY to the server if not already set.
    if [ -z "${DEEPSEEK_API_KEY:-}" ] && [ -f "$REPO/.env.local" ]; then
        while IFS='=' read -r k v; do
            [ "$k" = "DEEPSEEK_API_KEY" ] && DEEPSEEK_API_KEY="$v"
        done < "$REPO/.env.local"
        export DEEPSEEK_API_KEY
    fi

    printf '=== dashboard.sh ===\n'
    printf 'Serving: http://%s:%s\n' "$host" "$port"
    printf 'DB:      %s\n' "$db"
    printf 'Ctrl-C to stop\n\n'

    exec node --no-warnings --experimental-sqlite "$REPO/scripts/dashboard.mjs" "$db" "$port" "$host"
}

main "$@"
