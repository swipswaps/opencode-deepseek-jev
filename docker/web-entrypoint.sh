#!/bin/sh
#
# web-entrypoint.sh — merge DEEPSEEK_API_KEY into
# ~/.local/share/opencode/auth.json (preserving any other providers the
# user connected, e.g. OpenCode Zen for vision), then exec opencode web.
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

# Expose /workspace under $HOME so the SPA project picker can find it.
if [ ! -e /home/node/workspace ]; then
    ln -s /workspace /home/node/workspace
fi

if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
    node -e '
        const fs = require("fs");
        const path = require("path");
        const file = process.argv[1];
        const key = process.argv[2];
        fs.mkdirSync(path.dirname(file), { recursive: true });
        let data = {};
        try {
            const raw = fs.readFileSync(file, "utf8");
            if (raw.trim() !== "") { data = JSON.parse(raw); }
        } catch (e) { data = {}; }
        data.deepseek = { type: "api", key: key };
        fs.writeFileSync(file, JSON.stringify(data) + "\n");
        console.error("[web-entrypoint] merged deepseek into " + file + " (" + fs.statSync(file).size + " bytes)");
    ' "$AUTH_FILE" "$DEEPSEEK_API_KEY"
else
    printf '[web-entrypoint] DEEPSEEK_API_KEY empty; auth.json left untouched\n' >&2
fi

# Refuse to serve unauthenticated. Set OPENCODE_SERVER_PASSWORD in .env.local;
# bypass only with an explicit OPENCODE_ALLOW_INSECURE=1.
if [ -z "${OPENCODE_SERVER_PASSWORD:-}" ] && [ "${OPENCODE_ALLOW_INSECURE:-0}" != "1" ]; then
    printf '[web-entrypoint] OPENCODE_SERVER_PASSWORD is not set; refusing to start unsecured.\n' >&2
    printf '[web-entrypoint] set OPENCODE_SERVER_PASSWORD in .env.local, or set OPENCODE_ALLOW_INSECURE=1 to bypass.\n' >&2
    exit 1
fi

# Start the read-only observability dashboard on :5099. Bind 0.0.0.0 so the
# published port (127.0.0.1:5099 on the host) can reach it. The database is
# the same file opencode uses; read-only access coexists with the writer.
DASH_MJS="/workspace/scripts/dashboard.mjs"
if [ -f "$DASH_MJS" ]; then
    node --no-warnings --experimental-sqlite "$DASH_MJS" \
        "$DATA_DIR/opencode.db" 5099 0.0.0.0 /workspace/scripts/audit-config.sh >/tmp/dashboard.log 2>&1 &
    printf '[web-entrypoint] dashboard listening on :5099 (log /tmp/dashboard.log)\n' >&2
else
    printf '[web-entrypoint] dashboard.mjs not found; skipping dashboard\n' >&2
fi

exec opencode web --hostname 0.0.0.0 --port 4096
