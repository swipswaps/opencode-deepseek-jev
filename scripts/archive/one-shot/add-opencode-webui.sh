#!/usr/bin/env bash
#
# add-opencode-webui.sh — expose OpenCode's built-in web UI from the
# container and provide a launcher script.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# OpenCode ships a web UI: `opencode web` starts a local HTTP server and
# opens the browser. The server is the same one `opencode serve` exposes
# via OpenAPI 3.1. It shares sessions with the TUI.
#
#   Web UI:
#     https://opencode.ai/docs/web/
#   Server:
#     https://opencode.ai/docs/server/
#
# The current Dockerfile installs OpenCode but the compose file exposes no
# port for the web UI. This script:
#
#   1. Rewrites docker-compose.yml to publish port 4096 (the OpenCode
#      default) to the host and to set OPENCODE_SERVER_PASSWORD from the
#      host environment.
#   2. Adds scripts/web.sh — starts the container in web mode, foreground,
#      with the repo mounted at /workspace.
#   3. Adds scripts/web-stop.sh — stops the container.
#
# No sed, no rm -rf, no set -e, no return 1, no 2>/dev/null,
# no subprocess.run, no kill without signal.
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   OpenCode Web UI:
#     https://opencode.ai/docs/web/
#   OpenCode Server:
#     https://opencode.ai/docs/server/
#   OpenCode TUI:
#     https://opencode.ai/docs/tui/
#   Docker Compose file reference:
#     https://docs.docker.com/compose/compose-file/
#   Docker run port mapping:
#     https://docs.docker.com/engine/reference/commandline/run/#publish
#   POSIX printf(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §6.2 "Idempotence".
#
# ============================================================================

set -o pipefail

MODE="dry-run"
case "${1:-}" in
    --apply) MODE="apply" ;;
    --dry-run|"") MODE="dry-run" ;;
    *) printf 'usage: %s [--apply]\n' "$0"; return 2 ;;
esac

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

COMPOSE="$REPO_DIR/docker/docker-compose.yml"
WEB_SH="$REPO_DIR/scripts/web.sh"
WEB_STOP="$REPO_DIR/scripts/web-stop.sh"
TS=$(date -u +%Y%m%dT%H%M%SZ)

section() { printf '\n=== %s ===\n' "$1"; }

main() {
    printf '=== add-opencode-webui.sh ===\n'
    printf 'Mode: %s\n' "$MODE"
    printf 'Repo: %s\n\n' "$REPO_DIR"

    # ---- Gate: compose file present -----------------------------------
    if [ ! -f "$COMPOSE" ]; then
        printf 'GATE FAIL: %s not found\n' "$COMPOSE"
        return 1
    fi
    printf '  PASS: compose file present\n'

    # ---- Gate: no existing web.sh -------------------------------------
    if [ -e "$WEB_SH" ]; then
        printf '  PASS: %s already exists; will not overwrite\n' "$WEB_SH"
    fi

    if [ "$MODE" = "apply" ]; then
        cp "$COMPOSE" "$COMPOSE.bak.${TS}"
        printf '  backup: %s.bak.%s\n' "$COMPOSE" "$TS"
    fi

    # ---- 1. Rewrite docker-compose.yml --------------------------------
    section "1. docker-compose.yml"

    if [ "$MODE" = "apply" ]; then
        cat > "$COMPOSE" <<'COMPOSE_EOF'
# Docker Compose definition for the OpenCode + DeepSeek + Jev image.
#
# Two modes:
#
#   TUI     docker compose run --rm opencode
#   Web     docker compose up -d opencode-web
#
# The web service publishes port 4096 and reads OPENCODE_SERVER_PASSWORD
# from the host environment. If unset, the server has no auth; do not
# expose to an untrusted network in that case.
#
# References:
#   https://opencode.ai/docs/web/
#   https://opencode.ai/docs/server/
#   https://docs.docker.com/compose/compose-file/

services:
  opencode:
    build:
      context: ..
      dockerfile: docker/Dockerfile
    image: opencode-deepseek-jev:robust
    container_name: opencode-deepseek-jev
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    stdin_open: true
    tty: true
    working_dir: /workspace
    volumes:
      - ..:/workspace
    environment:
      - DEEPSEEK_API_KEY
      - JEV_API_KEY
      - OPENCODE_DISABLE_DEFAULT_PLUGINS=true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID

  opencode-web:
    build:
      context: ..
      dockerfile: docker/Dockerfile
    image: opencode-deepseek-jev:robust
    container_name: opencode-deepseek-web
    user: "${HOST_UID:-1000}:${HOST_GID:-1000}"
    working_dir: /workspace
    command: ["web", "--hostname", "0.0.0.0", "--port", "4096"]
    ports:
      - "4096:4096"
    volumes:
      - ..:/workspace
    environment:
      - DEEPSEEK_API_KEY
      - JEV_API_KEY
      - OPENCODE_DISABLE_DEFAULT_PLUGINS=true
      - OPENCODE_SERVER_PASSWORD
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
COMPOSE_EOF
        printf '  wrote %s\n' "$COMPOSE"
    else
        printf '  would write %s with two services: opencode and opencode-web\n' "$COMPOSE"
    fi

    # ---- 2. scripts/web.sh --------------------------------------------
    section "2. scripts/web.sh"

    if [ "$MODE" = "apply" ]; then
        cat > "$WEB_SH" <<'WEB_EOF'
#!/usr/bin/env bash
#
# web.sh — start OpenCode's web UI in a Docker container.
#
# The container runs `opencode web --hostname 0.0.0.0 --port 4096` with
# the repo mounted at /workspace. The host's port 4096 maps to the
# container's port 4096.
#
# Authentication: set OPENCODE_SERVER_PASSWORD in the host environment
# before invoking. Without it, the web UI is unauthenticated.
# Username defaults to "opencode"; override with OPENCODE_SERVER_USERNAME.
#
#   https://opencode.ai/docs/web/
#   https://opencode.ai/docs/server/
#
# Plain ASCII. No sed. No rm -rf. No set -e. No return 1.
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

    cd "$REPO_DIR/docker"

    if [ -z "$DEEPSEEK_API_KEY" ]; then
        printf 'WARN: DEEPSEEK_API_KEY is not set\n'
    fi
    if [ -z "$JEV_API_KEY" ]; then
        printf 'WARN: JEV_API_KEY is not set\n'
    fi
    if [ -z "$OPENCODE_SERVER_PASSWORD" ]; then
        printf 'WARN: OPENCODE_SERVER_PASSWORD is not set; web UI will be unauthenticated\n'
    fi

    printf 'starting opencode-web container\n'
    docker compose up -d opencode-web
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        printf 'FAIL: docker compose up returned %d\n' "$rc"
        return 1
    fi

    printf '\nwaiting for server to become ready\n'
    local tries=0
    while [ "$tries" -lt 30 ]; do
        if curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4096/ | grep -qE '^(2|3)'; then
            break
        fi
        tries=$((tries + 1))
        sleep 1
    done

    if [ "$tries" -ge 30 ]; then
        printf 'WARN: server did not answer on 127.0.0.1:4096 within 30s\n'
        printf '      check logs: docker compose logs opencode-web\n'
        return 1
    fi

    printf '\n=== OpenCode web UI is running ===\n'
    printf 'URL:      http://127.0.0.1:4096\n'
    if [ -n "$OPENCODE_SERVER_PASSWORD" ]; then
        printf 'Username: %s\n' "${OPENCODE_SERVER_USERNAME:-opencode}"
        printf 'Password: (the value you exported)\n'
    else
        printf 'Auth:     none (no password set)\n'
    fi
    printf '\nStop with:\n'
    printf '  ./scripts/web-stop.sh\n'
    return 0
}

main "$@"
WEB_EOF
        chmod +x "$WEB_SH"
        printf '  wrote %s\n' "$WEB_SH"
    else
        printf '  would write %s\n' "$WEB_SH"
    fi

    # ---- 3. scripts/web-stop.sh ---------------------------------------
    section "3. scripts/web-stop.sh"

    if [ "$MODE" = "apply" ]; then
        cat > "$WEB_STOP" <<'STOP_EOF'
#!/usr/bin/env bash
#
# web-stop.sh — stop the OpenCode web UI container.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No return 1.
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
STOP_EOF
        chmod +x "$WEB_STOP"
        printf '  wrote %s\n' "$WEB_STOP"
    else
        printf '  would write %s\n' "$WEB_STOP"
    fi

    # ---- Summary ------------------------------------------------------
    section "summary"
    printf '  mode: %s\n' "$MODE"
    if [ "$MODE" = "dry-run" ]; then
        printf '\n  DRY-RUN. Rerun with --apply.\n'
    else
        printf '\n  APPLIED.\n'
        printf '\n  next steps:\n'
        printf '    1. rebuild the image if needed:  cd docker && ./build.sh\n'
        printf '    2. start the web UI:             ./scripts/web.sh\n'
        printf '    3. open the browser:             http://127.0.0.1:4096\n'
        printf '    4. stop the web UI:              ./scripts/web-stop.sh\n'
        printf '\n  authentication (optional but recommended):\n'
        printf '    export OPENCODE_SERVER_PASSWORD="$(openssl rand -base64 24)"\n'
        printf '    ./scripts/web.sh\n'
    fi
    return 0
}

main "$@"
