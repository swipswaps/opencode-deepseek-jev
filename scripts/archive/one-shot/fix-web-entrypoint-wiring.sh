#!/usr/bin/env bash
#
# fix-web-entrypoint-wiring.sh — change the compose spec from `command:`
# to `entrypoint:` so the web-entrypoint.sh replaces the image's
# ENTRYPOINT ["opencode"] instead of being appended as an argument.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# Docker semantics:
#   ENTRYPOINT defines the executable.
#   CMD/command defines the arguments passed to ENTRYPOINT.
#
# The Dockerfile has:
#   ENTRYPOINT ["opencode"]
#
# The compose override was:
#   command: ["/workspace/docker/web-entrypoint.sh"]
#
# Docker therefore ran:
#   opencode /workspace/docker/web-entrypoint.sh
#
# OpenCode parsed the argument as a project path and tried to cd into it.
# It is a file, so the cd failed and the process exited.
#
# The correct override is:
#   entrypoint: ["/workspace/docker/web-entrypoint.sh"]
#
# That replaces the ENTRYPOINT entirely, so the container runs the script
# directly. The script then execs `opencode web ...` at the end.
#
#   Dockerfile ENTRYPOINT:
#     https://docs.docker.com/engine/reference/builder/#entrypoint
#   Dockerfile CMD:
#     https://docs.docker.com/engine/reference/builder/#cmd
#   Compose entrypoint override:
#     https://docs.docker.com/compose/compose-file/05-services/#entrypoint
#   Compose command override:
#     https://docs.docker.com/compose/compose-file/05-services/#command
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   Docker ENTRYPOINT:
#     https://docs.docker.com/engine/reference/builder/#entrypoint
#   Docker CMD:
#     https://docs.docker.com/engine/reference/builder/#cmd
#   Compose entrypoint:
#     https://docs.docker.com/compose/compose-file/05-services/#entrypoint
#   Compose command:
#     https://docs.docker.com/compose/compose-file/05-services/#command
#   POSIX printf(1):
#     https://pubs.opengroup.org/onlinepubs/9699919799/utilities/printf.html
#
#   Kernighan & Pike, "The Practice of Programming", Addison-Wesley,
#   1999. ISBN-13: 978-0201615869. §5.1 "Debugging".
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
[ -z "$REPO_DIR" ] && REPO_DIR=$(resolve_repo "$PWD")
if [ -z "$REPO_DIR" ]; then
    printf 'GATE FAIL: cannot resolve repo root\n'
    return 2
fi

COMPOSE="$REPO_DIR/docker/docker-compose.yml"
ENTRY="$REPO_DIR/docker/web-entrypoint.sh"
ENV_FILE="$REPO_DIR/.env.local"
TS=$(date -u +%Y%m%dT%H%M%SZ)

section() { printf '\n=== %s ===\n' "$1"; }

main() {
    printf '=== fix-web-entrypoint-wiring.sh ===\n'
    printf 'Repo: %s\n\n' "$REPO_DIR"

    if [ ! -f "$COMPOSE" ]; then
        printf 'GATE FAIL: %s not found\n' "$COMPOSE"
        return 1
    fi
    printf '  PASS: compose present\n'

    if [ ! -f "$ENTRY" ]; then
        printf 'GATE FAIL: %s not found\n' "$ENTRY"
        printf '        re-run apply-webui-providers.sh first\n'
        return 1
    fi
    printf '  PASS: entrypoint present\n'

    section "1. patch compose: command -> entrypoint"

    cp "$COMPOSE" "$COMPOSE.bak.${TS}"
    printf '  backup: %s.bak.%s\n' "$COMPOSE" "$TS"

    python3 - "$COMPOSE" <<'PY_EOF'
import sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

# The prior patch left this line under the opencode-web service:
old = '    command: ["/workspace/docker/web-entrypoint.sh"]\n'
new = '    entrypoint: ["/workspace/docker/web-entrypoint.sh"]\n'

if old not in src:
    print("ERROR: command line not found", file=sys.stderr)
    sys.exit(3)

src = src.replace(old, new, 1)
with open(path, "w") as f:
    f.write(src)
print("  replaced command: with entrypoint:")
PY_EOF
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL: patch returned %d\n' "$rc"
        return 1
    fi

    section "2. verify compose around opencode-web"
    awk '/^  opencode-web:/{show=1} show && /^[a-z]/ && !/^  opencode-web:/{exit} show{print "  " $0}' "$COMPOSE" | head -40

    section "3. restart container"

    if [ -f "$ENV_FILE" ]; then
        while IFS='=' read -r k v; do
            case "$k" in
                DEEPSEEK_API_KEY) DEEPSEEK_API_KEY="$v" ;;
                JEV_API_KEY)      JEV_API_KEY="$v" ;;
            esac
        done < "$ENV_FILE"
        export DEEPSEEK_API_KEY
        export JEV_API_KEY
    fi

    if [ -z "$OPENCODE_SERVER_PASSWORD" ]; then
        export OPENCODE_SERVER_PASSWORD="$(openssl rand -base64 24)"
        printf 'generated OPENCODE_SERVER_PASSWORD\n'
    fi

    cd "$REPO_DIR/docker" || return 1
    docker compose up -d --force-recreate opencode-web
    local up_rc=$?
    if [ "$up_rc" -ne 0 ]; then
        printf 'FAIL: compose up returned %d\n' "$up_rc"
        return 1
    fi

    section "4. wait for server with live log"
    local tries=0
    local code=""
    local log_line=""
    while [ "$tries" -lt 90 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4096/ 2>&1 || true)
        log_line=$(docker compose logs --tail=1 opencode-web 2>&1 | tail -1)
        printf '  %2d/90  http=%-3s  %s\n' "$((tries + 1))" "$code" "$log_line"
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            break
        fi
        tries=$((tries + 1))
        sleep 2
    done

    if [ -z "$code" ] || [ "$code" = "000" ]; then
        printf '\nFAIL: no listener after 180 s\n'
        printf 'last 40 log lines:\n'
        docker compose logs --tail=40 opencode-web
        return 1
    fi

    section "5. auth.json inside the container"
    docker exec opencode-deepseek-web \
        sh -c 'ls -la "$HOME/.local/share/opencode/auth.json" && head -c 200 "$HOME/.local/share/opencode/auth.json" && echo'

    section "6. providers list inside the container"
    docker exec -w /workspace opencode-deepseek-web \
        sh -c 'opencode providers list 2>&1 | head -20'

    section "summary"
    printf 'URL:      http://127.0.0.1:4096\n'
    printf 'HTTP:     %s\n' "$code"
    printf 'Username: %s\n' "${OPENCODE_SERVER_USERNAME:-opencode}"
    printf 'Password: %s\n' "$OPENCODE_SERVER_PASSWORD"
    printf '\nreload the browser.\n'
    return 0
}

main "$@"
