#!/usr/bin/env bash
#
# rebuild-and-restart-web.sh — rebuild the opencode image, restart the
# web container, and wait for readiness.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# The Dockerfile was patched (xdg-open shim inserted) but the image was
# not rebuilt. `docker compose up -d` reused the existing image. The
# container continued to run the old image, which still crash-loops on
# `xdg-open` ENOENT. Every readiness probe returned 000.
#
# The rebuild path:
#
#   docker compose build opencode-web    # uses the compose build section
#   docker compose up -d opencode-web    # recreates the container
#
# This script does both in sequence, then polls port 4096 until the
# server answers with anything other than HTTP 000 (no listener).
#
#   Docker Compose build:
#     https://docs.docker.com/engine/reference/commandline/compose_build/
#   Docker Compose up:
#     https://docs.docker.com/engine/reference/commandline/compose_up/
#   HTTP status 000 from curl -w means no TCP response:
#     https://curl.se/docs/manpage.html#-w
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   Docker Compose build:
#     https://docs.docker.com/engine/reference/commandline/compose_build/
#   Docker Compose up:
#     https://docs.docker.com/engine/reference/commandline/compose_up/
#   curl -w:
#     https://curl.se/docs/manpage.html#-w
#   OpenCode Web:
#     https://opencode.ai/docs/web/
#   POSIX printf(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §6.2 "Idempotence".
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

DOCKER_DIR="$REPO_DIR/docker"
ENV_FILE="$REPO_DIR/.env.local"

main() {
    printf '=== rebuild-and-restart-web.sh ===\n'
    printf 'Repo: %s\n\n' "$REPO_DIR"

    if ! command -v docker > /dev/null; then
        printf 'GATE FAIL: docker not found\n'
        return 1
    fi
    if ! docker info > /dev/null; then
        printf 'GATE FAIL: docker daemon not reachable\n'
        return 1
    fi
    if [ ! -f "$DOCKER_DIR/docker-compose.yml" ]; then
        printf 'GATE FAIL: %s/docker-compose.yml not found\n' "$DOCKER_DIR"
        return 1
    fi
    printf '  PASS: gates\n\n'

    # ---- Load .env.local so compose can substitute the keys ----------
    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r k v; do
            case "$k" in
                DEEPSEEK_API_KEY) DEEPSEEK_API_KEY="$v" ;;
                JEV_API_KEY)      JEV_API_KEY="$v" ;;
            esac
        done < "$ENV_FILE"
        export DEEPSEEK_API_KEY
        export JEV_API_KEY
        printf 'loaded %s\n' "$ENV_FILE"
    fi

    if [ -z "$OPENCODE_SERVER_PASSWORD" ]; then
        export OPENCODE_SERVER_PASSWORD="$(openssl rand -base64 24)"
        printf 'generated OPENCODE_SERVER_PASSWORD\n'
    fi

    cd "$DOCKER_DIR" || return 1

    # ---- 1. Rebuild --------------------------------------------------
    printf '\n=== 1. docker compose build opencode-web ===\n'
    docker compose build opencode-web
    local build_rc=$?
    if [ "$build_rc" -ne 0 ]; then
        printf 'FAIL: build returned %d\n' "$build_rc"
        return 1
    fi
    printf '  image rebuilt\n'

    # ---- 2. Restart --------------------------------------------------
    printf '\n=== 2. docker compose up -d opencode-web ===\n'
    docker compose up -d --force-recreate opencode-web
    local up_rc=$?
    if [ "$up_rc" -ne 0 ]; then
        printf 'FAIL: up returned %d\n' "$up_rc"
        return 1
    fi
    printf '  container recreated\n'

    # ---- 3. Wait for readiness ---------------------------------------
    printf '\n=== 3. wait for server on 127.0.0.1:4096 ===\n'
    local tries=0
    local code=""
    while [ "$tries" -lt 60 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4096/ 2>&1 || true)
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            printf '  ready after %d probe(s): HTTP %s\n' "$((tries + 1))" "$code"
            break
        fi
        tries=$((tries + 1))
        printf '  probe %d/60: HTTP %s\n' "$tries" "$code"
        sleep 1
    done

    if [ -z "$code" ] || [ "$code" = "000" ]; then
        printf '\nFAIL: no listener on 127.0.0.1:4096 after 60s\n'
        printf 'last 40 container log lines:\n'
        docker compose logs --tail=40 opencode-web
        return 1
    fi

    printf '\n=== OpenCode web UI is running ===\n'
    printf 'URL:      http://127.0.0.1:4096\n'
    printf 'HTTP:     %s\n' "$code"
    if [ -n "$OPENCODE_SERVER_PASSWORD" ]; then
        printf 'Username: %s\n' "${OPENCODE_SERVER_USERNAME:-opencode}"
        printf 'Password: %s\n' "$OPENCODE_SERVER_PASSWORD"
    else
        printf 'Auth:     none\n'
    fi
    printf '\nstop: ./scripts/web-stop.sh\n'
    printf 'logs: ./scripts/web-logs.sh\n'
    return 0
}

main "$@"
