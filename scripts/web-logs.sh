#!/usr/bin/env bash
#
# web-logs.sh — show opencode-web container logs.
#
# cd's into docker/ first so `docker compose` finds its configuration.
#
# Usage:
#   ./scripts/web-logs.sh            last 80 lines
#   ./scripts/web-logs.sh -f         follow
#   ./scripts/web-logs.sh 200        last 200 lines
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

main() {
    cd "$REPO_DIR/docker" || return 1
    case "${1:-}" in
        -f|--follow)
            docker compose logs -f opencode-web
            ;;
        ""|*[!0-9]*)
            docker compose logs --tail=80 opencode-web
            ;;
        *)
            docker compose logs --tail="$1" opencode-web
            ;;
    esac
}

main "$@"
