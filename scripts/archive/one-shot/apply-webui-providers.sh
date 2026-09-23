#!/usr/bin/env bash
#
# apply-webui-providers.sh — install the web entrypoint, patch the
# compose command, restart the container, and wait for readiness.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# D1. The previous fix script was staged but not applied.
# D2. Its entrypoint used sed for JSON escaping, violating the stated
#     constraint. This script uses node, which is present in the image.
# D3. web.sh probes 60 times over 60 s. Real startup is 15-30 s on a
#     cold container. The prior Ctrl-C at probe 10 killed the wait
#     before the server was up.
#
# Entry point of the web UI's Providers panel is auth.json. The config
# file's apiKey field is invisible to the UI. This script writes
# auth.json from DEEPSEEK_API_KEY at container start.
#
#   OpenCode providers:
#     https://opencode.ai/docs/providers/
#   XDG Base Directory Specification:
#     https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
#
# ============================================================================
# CITATIONS
# ============================================================================
#
#   OpenCode providers:
#     https://opencode.ai/docs/providers/
#   OpenCode Web:
#     https://opencode.ai/docs/web/
#   XDG Base Directory Specification:
#     https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
#   Node.js fs API:
#     https://nodejs.org/api/fs.html
#   Docker Compose command:
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

ENTRY="$REPO_DIR/docker/web-entrypoint.sh"
COMPOSE="$REPO_DIR/docker/docker-compose.yml"
ENV_FILE="$REPO_DIR/.env.local"
TS=$(date -u +%Y%m%dT%H%M%SZ)

section() { printf '\n=== %s ===\n' "$1"; }

main() {
    printf '=== apply-webui-providers.sh ===\n'
    printf 'Repo: %s\n\n' "$REPO_DIR"

    if [ ! -f "$COMPOSE" ]; then
        printf 'GATE FAIL: %s not found\n' "$COMPOSE"
        return 1
    fi
    printf '  PASS: compose present\n'

    # --- 1. entrypoint ----------------------------------------------
    section "1. write docker/web-entrypoint.sh"

    cat > "$ENTRY" <<'ENTRY_EOF'
#!/bin/sh
#
# web-entrypoint.sh — write ~/.local/share/opencode/auth.json from
# DEEPSEEK_API_KEY, then exec opencode web.
#
# Uses node for JSON serialisation because node is installed in the
# image; no sed, no shell escaping pitfalls.
#
# OpenCode providers:
#   https://opencode.ai/docs/providers/
# XDG Base Directory Specification:
#   https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
# Node.js fs API:
#   https://nodejs.org/api/fs.html
# ----------------------------------------------------------------------------

set -u

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
AUTH_FILE="$DATA_DIR/auth.json"

mkdir -p "$DATA_DIR"

if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    node -e '
        const fs = require("fs");
        const path = require("path");
        const file = process.argv[1];
        const key = process.argv[2];
        fs.mkdirSync(path.dirname(file), { recursive: true });
        const data = { deepseek: { type: "api", key: key } };
        fs.writeFileSync(file, JSON.stringify(data) + "\n");
        console.error("[web-entrypoint] wrote " + file + " (" + fs.statSync(file).size + " bytes)");
    ' "$AUTH_FILE" "$DEEPSEEK_API_KEY"
else
    printf '[web-entrypoint] DEEPSEEK_API_KEY empty; auth.json not written\n' >&2
fi

exec opencode web --hostname 0.0.0.0 --port 4096
ENTRY_EOF
    chmod +x "$ENTRY"
    printf '  wrote %s\n' "$ENTRY"

    # --- 2. compose command -----------------------------------------
    section "2. patch compose command"

    cp "$COMPOSE" "$COMPOSE.bak.${TS}"
    printf '  backup: %s.bak.%s\n' "$COMPOSE" "$TS"

    python3 - "$COMPOSE" <<'PY_EOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

# Try the common quoting styles for the old command line.
candidates = [
    '    command: ["web", "--hostname", "0.0.0.0", "--port", "4096"]\n',
    "    command: ['web', '--hostname', '0.0.0.0', '--port', '4096']\n",
    '    command: ["web", "--hostname", "0.0.0.0", "--port", "4096"]\r\n',
]

new = '    command: ["/workspace/docker/web-entrypoint.sh"]\n'

for old in candidates:
    if old in src:
        src = src.replace(old, new, 1)
        with open(path, "w") as f:
            f.write(src)
        print("  command replaced")
        sys.exit(0)

print("ERROR: command line not found in compose", file=sys.stderr)
sys.exit(3)
PY_EOF
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL: compose patch returned %d\n' "$rc"
        return 1
    fi

    # --- 3. restart container --------------------------------------
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

    # --- 4. wait with live progress --------------------------------
    section "4. wait for server"
    printf 'startup takes 15-30 s on a cold container; each line is one probe\n'

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

    # --- 5. verify auth.json ---------------------------------------
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
    printf '\nreload the browser to see DeepSeek as connected.\n'
    return 0
}

main "$@"
