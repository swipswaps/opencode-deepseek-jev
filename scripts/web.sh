#!/usr/bin/env bash
#
# web.sh — start OpenCode's web UI in a Docker container.
#
# Sources .env.local so the container receives DEEPSEEK_API_KEY and
# JEV_API_KEY. Publishes port 4096. Requires OPENCODE_SERVER_PASSWORD
# for HTTP basic authentication (username defaults to "opencode");
# refuses to start without it unless --insecure is passed.
#
#   https://opencode.ai/docs/web/
#   https://opencode.ai/docs/server/
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

ENV_FILE="$REPO_DIR/.env.local"
COMPOSE_DIR="$REPO_DIR/docker"

main() {
    local insecure=0
    case "${1:-}" in
        --insecure) insecure=1 ;;
        "") ;;
        *) printf 'usage: %s [--insecure]\n' "$0"; return 2 ;;
    esac

    printf '=== web.sh ===\n'
    printf 'Repo: %s\n' "$REPO_DIR"

    if ! command -v docker > /dev/null; then
        printf 'GATE FAIL: docker not found\n'
        return 1
    fi
    if ! docker info > /dev/null; then
        printf 'GATE FAIL: docker daemon not reachable\n'
        return 1
    fi

    # ---- Load keys + password from .env.local (single source of truth) ----
    local shell_pass="${OPENCODE_SERVER_PASSWORD:-}"
    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r k v; do
            case "$k" in
                DEEPSEEK_API_KEY) DEEPSEEK_API_KEY="$v" ;;
                JEV_API_KEY)      JEV_API_KEY="$v" ;;
                OPENCODE_SERVER_PASSWORD) OPENCODE_SERVER_PASSWORD="$v" ;;
            esac
        done < "$ENV_FILE"
        export DEEPSEEK_API_KEY JEV_API_KEY OPENCODE_SERVER_PASSWORD
        printf 'loaded %s\n' "$ENV_FILE"
    else
        printf 'WARN: %s not found; container will lack keys\n' "$ENV_FILE"
    fi

    if [ -n "$shell_pass" ] && [ -n "$OPENCODE_SERVER_PASSWORD" ] && [ "$shell_pass" != "$OPENCODE_SERVER_PASSWORD" ]; then
        printf 'WARN: shell $OPENCODE_SERVER_PASSWORD differs from %s; using the file value\n' "$ENV_FILE"
    fi

    if [ -z "$DEEPSEEK_API_KEY" ]; then
        printf 'WARN: DEEPSEEK_API_KEY is empty\n'
    fi
    if [ -z "$JEV_API_KEY" ]; then
        printf 'WARN: JEV_API_KEY is empty\n'
    fi
    if [ -z "$OPENCODE_SERVER_PASSWORD" ] && [ "$insecure" -ne 1 ]; then
        printf 'GATE FAIL: OPENCODE_SERVER_PASSWORD is unset; refusing to start an unauthenticated server\n'
        printf '  set OPENCODE_SERVER_PASSWORD in %s, or pass --insecure to override\n' "$ENV_FILE"
        return 1
    fi
    if [ -z "$OPENCODE_SERVER_PASSWORD" ]; then
        printf 'WARN: --insecure: starting WITHOUT authentication\n'
    fi

    cd "$COMPOSE_DIR"
    printf 'starting opencode-web container\n'
    docker compose up -d opencode-web
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL: docker compose up returned %d\n' "$rc"
        return 1
    fi

    # ---- Readiness: accept any HTTP response other than 000 -------
    # 200 means ready; 401 means ready with auth challenge.
    # 000 means no TCP listener. RFC 7235 §4.1:
    #   https://www.rfc-editor.org/rfc/rfc7235#section-4.1
    printf '\nwaiting for server\n'
    local tries=0
    local code=""
    while [ "$tries" -lt 60 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4096/ 2>&1 || true)
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            break
        fi
        tries=$((tries + 1))
        printf '  probe %d/60: code=%s\n' "$tries" "$code"
        sleep 1
    done

    if [ -z "$code" ] || [ "$code" = "000" ]; then
        printf '\nFAIL: no listener on 127.0.0.1:4096 after 60s\n'
        printf 'last 40 lines of container log:\n'
        docker compose logs --tail=40 opencode-web
        return 1
    fi

    printf '\n=== OpenCode web UI is running ===\n'
    printf 'URL:      http://127.0.0.1:4096\n'
    printf 'HTTP:     %s\n' "$code"
    if [ -n "$OPENCODE_SERVER_PASSWORD" ]; then
        printf 'Username: %s\n' "${OPENCODE_SERVER_USERNAME:-opencode}"
        printf 'Password: (the value in %s)\n' "$ENV_FILE"
    else
        printf 'Auth:     none\n'
    fi
    printf '\nlogs:  ./scripts/web-logs.sh\n'
    printf 'stop:  ./scripts/web-stop.sh\n'
    return 0
}

main "$@"
