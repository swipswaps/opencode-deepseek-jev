#!/usr/bin/env bash
#
# web-restart.sh — restart the opencode-web container so :5099 serves the
# current checkout, then verify the served revision matches HEAD.
#
# Why this script exists: `opencode-web` is a compose SERVICE name, not a
# command — typing it bare at a shell prints "command not found". This
# wrapper is the command. Run it from anywhere inside the repo checkout:
#
#   ./scripts/web-restart.sh
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
    printf '=== web-restart.sh ===\n'
    local head
    head=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>&1) || head="unknown"
    printf 'HEAD: %s\n' "$head"
    cd "$REPO_DIR/docker"
    docker compose restart opencode-web
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL: docker compose restart returned %d\n' "$rc"
        printf 'hint: is the docker daemon reachable? try: docker ps\n'
        return 1
    fi
    printf 'restart issued; waiting for :5099 (boot + health pre-warm ~25s)\n'
    local i served
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sleep 5
        served=$(curl -s --max-time 8 http://127.0.0.1:5099/api/rev 2>&1 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("served","?") + " stale=" + str(d.get("stale", "?")))' 2>&1) || served=""
        if [ -n "$served" ]; then
            printf 'rev: %s (HEAD %s)\n' "$served" "$head"
            case "$served" in
                "$head"*stale=False*) printf 'PASS: :5099 serves current checkout\n'; return 0 ;;
            esac
        fi
    done
    printf 'FAIL: :5099 did not serve %s within 60s (last: %s)\n' "$head" "$served"
    printf 'hint: docker logs --tail 20 opencode-deepseek-web\n'
    return 1
}

main "$@"
