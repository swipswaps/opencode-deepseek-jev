#!/usr/bin/env bash
#
# fix-webui-providers.sh — make the web UI show DeepSeek as a connected
# provider by writing auth.json from the environment at container start.
#
# ============================================================================
# AUDIT
# ============================================================================
#
# The web UI's Providers panel reads ~/.local/share/opencode/auth.json.
# The project config in opencode.json uses provider.options.apiKey, which
# is invisible to the UI. Result: "No connected providers" and an empty
# model list, even though the server can call the model.
#
# Fix: a small entrypoint that writes auth.json from DEEPSEEK_API_KEY
# before launching opencode web. The entrypoint lives in the repo and is
# referenced from the compose file; the repo is already mounted at
# /workspace, so no image rebuild is required.
#
#   OpenCode auth:
#     https://opencode.ai/docs/providers/#credentials
#   auth.json location:
#     $XDG_DATA_HOME/opencode/auth.json (default ~/.local/share/opencode)
#   OpenCode Web UI:
#     https://opencode.ai/docs/web/
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
[ -z "$REPO_DIR" ] && REPO_DIR=$(resolve_repo "$PWD")
if [ -z "$REPO_DIR" ]; then
    printf 'GATE FAIL: cannot resolve repo root\n'
    return 2
fi

ENTRY="$REPO_DIR/docker/web-entrypoint.sh"
COMPOSE="$REPO_DIR/docker/docker-compose.yml"
TS=$(date -u +%Y%m%dT%H%M%SZ)

section() { printf '\n=== %s ===\n' "$1"; }

main() {
    printf '=== fix-webui-providers.sh ===\n'
    printf 'Mode: %s\n' "$MODE"
    printf 'Repo: %s\n\n' "$REPO_DIR"

    if [ ! -f "$COMPOSE" ]; then
        printf 'GATE FAIL: %s not found\n' "$COMPOSE"
        return 1
    fi
    printf '  PASS: compose present\n'

    # --- 1. entrypoint script --------------------------------------
    section "1. docker/web-entrypoint.sh"

    if [ "$MODE" = "apply" ]; then
        cat > "$ENTRY" <<'ENTRY_EOF'
#!/bin/sh
#
# web-entrypoint.sh — write ~/.local/share/opencode/auth.json from
# DEEPSEEK_API_KEY, then exec opencode web.
#
# The web UI's Providers panel reads auth.json; the config file's
# apiKey field is used only at request time and is invisible to the UI.
# Writing auth.json at startup makes the UI show DeepSeek as connected.
#
# OpenCode providers:
#   https://opencode.ai/docs/providers/
# XDG Base Directory Specification:
#   https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
#
# ----------------------------------------------------------------------------

set -u

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/opencode"
AUTH_FILE="$DATA_DIR/auth.json"

mkdir -p "$DATA_DIR"

if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    # Escape double quotes and backslashes to keep the JSON valid.
    key_escaped=$(printf '%s' "$DEEPSEEK_API_KEY" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"deepseek":{"type":"api","key":"%s"}}\n' "$key_escaped" > "$AUTH_FILE"
    printf '[web-entrypoint] wrote %s (%d bytes)\n' "$AUTH_FILE" "$(wc -c < "$AUTH_FILE")"
else
    printf '[web-entrypoint] DEEPSEEK_API_KEY empty; auth.json not written\n' >&2
fi

exec opencode web --hostname 0.0.0.0 --port 4096
ENTRY_EOF
        chmod +x "$ENTRY"
        printf '  wrote %s\n' "$ENTRY"
    else
        printf '  would write %s\n' "$ENTRY"
    fi

    # --- 2. compose command change --------------------------------
    section "2. docker-compose.yml opencode-web command"

    if [ "$MODE" = "apply" ]; then
        cp "$COMPOSE" "$COMPOSE.bak.${TS}"
        printf '  backup: %s.bak.%s\n' "$COMPOSE" "$TS"

        python3 - "$COMPOSE" <<'PY_EOF'
import re, sys

path = sys.argv[1]
with open(path) as f:
    src = f.read()

# Replace the command of the opencode-web service with the entrypoint.
# We target the specific block; the opencode (TUI) service is unchanged.
old = '    command: ["web", "--hostname", "0.0.0.0", "--port", "4096"]\n'
new = '    command: ["/workspace/docker/web-entrypoint.sh"]\n'

if old not in src:
    # Try alternate quoting style
    old2 = "    command: ['web', '--hostname', '0.0.0.0', '--port', '4096']\n"
    if old2 in src:
        old = old2
    else:
        print("ERROR: command line not found in compose", file=sys.stderr)
        sys.exit(3)

src = src.replace(old, new, 1)
with open(path, "w") as f:
    f.write(src)
print("  command replaced")
PY_EOF
    else
        printf '  would replace the opencode-web command with /workspace/docker/web-entrypoint.sh\n'
    fi

    section "summary"
    printf '  mode: %s\n' "$MODE"
    if [ "$MODE" = "dry-run" ]; then
        printf '\n  DRY-RUN. Rerun with --apply, then restart the container:\n'
        printf '    ./scripts/web-stop.sh\n'
        printf '    ./scripts/web.sh\n'
    else
        printf '\n  APPLIED.\n'
        printf '\n  restart the container (no image rebuild needed):\n'
        printf '    ./scripts/web-stop.sh\n'
        printf '    export OPENCODE_SERVER_PASSWORD="$(openssl rand -base64 24)"\n'
        printf '    echo "Password: $OPENCODE_SERVER_PASSWORD"\n'
        printf '    ./scripts/web.sh\n'
    fi
    return 0
}

main "$@"
