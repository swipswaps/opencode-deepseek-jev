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
        fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
        let data = {};
        try {
            const raw = fs.readFileSync(file, "utf8");
            if (raw.trim() !== "") { data = JSON.parse(raw); }
        } catch (e) { data = {}; }
        data.deepseek = { type: "api", key: key };
        fs.writeFileSync(file, JSON.stringify(data) + "\n", { mode: 0o600 });
        try { fs.chmodSync(file, 0o600); } catch (e) { /* existing mount may forbid chmod */ }
        console.error("[web-entrypoint] merged deepseek into " + file + " (" + fs.statSync(file).size + " bytes, mode 0600)");
    ' "$AUTH_FILE" "$DEEPSEEK_API_KEY"
else
    printf '[web-entrypoint] DEEPSEEK_API_KEY empty; auth.json left untouched\n' >&2
fi

# JEV-OFF (2026-10-21): the image installs jev-guard GLOBALLY, so removing it
# from /workspace/opencode.json is not enough. patch-global-config.sh deactivates
# jev-guard/jev-review in the global config (and replaces a literal LiteLLM key
# with an env reference). Shared with the interactive entrypoint; idempotent.
if [ -f /workspace/docker/patch-global-config.sh ]; then
    sh /workspace/docker/patch-global-config.sh || printf '[web-entrypoint] global config patch failed (continuing)\n' >&2
fi
# jev-guard 0.3.1 ignores JEV_BASE_URL (typesafe-only); add the custom backend
# to the cached package. Must run every start: the cache is in the container FS.
if [ -f /workspace/docker/patch-jev-guard.sh ]; then
    sh /workspace/docker/patch-jev-guard.sh || printf '[web-entrypoint] jev-guard patch failed (continuing)\n' >&2
fi

# Load the repo's blacklist-guard for EVERY project. The interactive web UI
# creates sessions rooted at $HOME/.opencode (observed: directory=/home/node/.opencode
# via "booting location services"), NOT /workspace, so the project-scoped
# `{plugin,plugins}/*.{ts,js}` glob under /workspace/.opencode/ is never scanned
# for those sessions. opencode DOES scan the global plugin dir
# ($XDG_CONFIG_HOME/opencode/plugins), so symlink the guard there. Without this,
# the guard silently never loads and "Thinking" keeps using sed / 2>/dev/null /
# subprocess.run with no telemetry (proven: no guard.log heartbeat).
GUARD_SRC="/workspace/.opencode/plugins/blacklist-guard.js"
GUARD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins"
if [ -f "$GUARD_SRC" ]; then
    mkdir -p "$GUARD_DIR"
    # $HOME/.config/opencode is the HOST config bind-mounted into this
    # container. A symlink to the container-only /workspace path is DANGLING on
    # the host (proven twice), so COPY the plugin instead: a regular file is
    # valid in both namespaces and survives container restarts.
    RESOLVED_GUARD="$(readlink -f "$GUARD_SRC" 2>&1)"
    if [ -n "$RESOLVED_GUARD" ] && [ -f "$RESOLVED_GUARD" ]; then
        cp -f "$RESOLVED_GUARD" "$GUARD_DIR/blacklist-guard.js"
        chmod 0644 "$GUARD_DIR/blacklist-guard.js" 2>&1 || true
        printf '[web-entrypoint] blacklist-guard copied into %s\n' "$GUARD_DIR" >&2
    else
        printf '[web-entrypoint] WARN: cannot resolve %s; guard not linked\n' "$GUARD_SRC" >&2
    fi
fi

# Same root-cause fix for the process SKILLs: interactive sessions open at
# $HOME/.opencode, so the project-scoped `{skill,skills}/**/SKILL.md` glob
# misses /workspace/.opencode/skills. opencode scans the global config dir, so
# copy the repo skills there — otherwise they silently do not load for the
# sessions the operator actually uses, and symlinks dangle on the host.
SKILL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills"
for SKILL_SRC in /workspace/.opencode/skills/*; do
    [ -d "$SKILL_SRC" ] || continue
    skill="$(basename "$SKILL_SRC")"
    mkdir -p "$SKILL_DIR"
    # Same namespaces problem as the guard: replace a container-only symlink
    # with real files so the host sessions load the skills too.
    if [ -L "$SKILL_DIR/$skill" ]; then rm -f "$SKILL_DIR/$skill"; fi
    mkdir -p "$SKILL_DIR/$skill"
    cp -a "$SKILL_SRC/." "$SKILL_DIR/$skill/" 2>&1 || true
    printf '[web-entrypoint] skill %s copied into %s\n' "$skill" "$SKILL_DIR" >&2
done

# Refuse to serve unauthenticated. Set OPENCODE_SERVER_PASSWORD in .env.local;
# bypass only with an explicit OPENCODE_ALLOW_INSECURE=1.
if [ -z "${OPENCODE_SERVER_PASSWORD:-}" ] && [ "${OPENCODE_ALLOW_INSECURE:-0}" != "1" ]; then
    printf '[web-entrypoint] OPENCODE_SERVER_PASSWORD is not set; refusing to start unsecured.\n' >&2
    printf '[web-entrypoint] set OPENCODE_SERVER_PASSWORD in .env.local, or set OPENCODE_ALLOW_INSECURE=1 to bypass.\n' >&2
    printf '[web-entrypoint] recover: ./scripts/recovery-status.sh; ./scripts/web.sh\n' >&2
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

if ! command -v opencode > /dev/null; then
    printf '[web-entrypoint] opencode binary missing from PATH\n' >&2
    printf '[web-entrypoint] recover: ./scripts/recovery-status.sh; docker compose -f docker/docker-compose.yml logs opencode-web\n' >&2
    exit 127
fi

exec opencode web --hostname 0.0.0.0 --port 4096
