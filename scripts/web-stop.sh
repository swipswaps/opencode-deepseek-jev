#!/usr/bin/env bash
#
# web-stop.sh — stop the OpenCode web UI container.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
# ============================================================================

set -o pipefail

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

main() {
    printf '=== web-stop.sh ===\n'
    cd "$REPO_DIR/docker"
    docker compose stop opencode-web
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL: docker compose stop returned %d\n' "$rc"
        return 1
    fi
    printf 'opencode-web container stopped\n'
    return 0
}

main "$@"
