#!/usr/bin/env bash
#
# test-jev-preflight.sh — validate the "missing type: local" hypothesis
# BEFORE running fix-jev-mcp-spawn.sh.
#
# Read-only. No writes to repo, no container restart, no mutations.
#
# What it answers:
#   T1  Full opencode.json, unfiltered and numbered
#   T2  Does mcp.servers.jev-review have "type"? What value?
#   T3  What "opencode mcp" subcommands actually exist
#   T4  Can the MCP server binary start manually?
#   T5  Is jev-guard a well-formed plugin package?
#   T6  What opencode version — schema may have drifted
#   T7  Full DEBUG output, saved for inspection (not truncated)
#   T8  OPENCODE_DISABLE_DEFAULT_PLUGINS — where set, what value
#
# Constraints:
#   No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
#   No python at all in this script. No bare kill (timeout -> TERM).
#
set -o pipefail

C="opencode-deepseek-web"
MODEL="deepseek/deepseek-flash"
PROBE_PROMPT="Reply with exactly: JEVPING"

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"; return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

section() { printf '\n=== %s ===\n' "$1"; }

indent() {
    local line
    while IFS= read -r line; do
        printf '    %s\n' "$line"
    done
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO=$(resolve_repo "$SCRIPT_DIR")
[ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
if [ -z "$REPO" ]; then
    printf 'GATE FAIL: cannot resolve repo\n'
    return 2
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
OC="$REPO/opencode.json"
DBG="/tmp/jev-preflight-debug-${TS}.log"

printf '=== test-jev-preflight.sh ===\n'
printf 'Repo: %s\n' "$REPO"
printf 'TS:   %s\n' "$TS"

# --------------------------------------------------------------------------
section "T1  full opencode.json (numbered)"
# --------------------------------------------------------------------------
if [ -f "$OC" ]; then
    nl -ba "$OC" | indent
else
    printf 'MISSING: %s\n' "$OC"
fi

# --------------------------------------------------------------------------
section "T2  'type' presence in opencode.json"
# --------------------------------------------------------------------------
if [ -f "$OC" ]; then
    printf 'all lines containing "type":\n'
    grep -n '"type"' "$OC" | indent
    printf '\n(raw view; do not trust parsing, trust the file)\n'
fi

# --------------------------------------------------------------------------
section "T3  opencode mcp subcommands"
# --------------------------------------------------------------------------
printf '--- opencode mcp --help ---\n'
docker exec -w /workspace "$C" sh -c 'opencode mcp --help 2>&1' | indent

printf '\n--- probing common subcommand forms ---\n'
for sub in list ls status show test; do
    printf '\n  $ opencode mcp %s\n' "$sub"
    docker exec -w /workspace "$C" sh -c "opencode mcp $sub 2>&1 | head -20" | indent
done

# --------------------------------------------------------------------------
section "T4  manual MCP spawn (5 s timeout)"
# --------------------------------------------------------------------------
printf 'attempting: node /opt/jev-review/dist/server.js\n'
printf '(inside container, 5 s, TERM on timeout)\n\n'
docker exec "$C" sh -c '
    cd /opt/jev-review || exit 9
    JEV_API_KEY="probe_only" timeout 5 node dist/server.js 2>&1 | head -40
' | indent
printf '\n(if timeout reported "not found", the image lacks coreutils timeout)\n'

# --------------------------------------------------------------------------
section "T5  jev-guard plugin package layout"
# --------------------------------------------------------------------------
docker exec "$C" sh -c '
    P=~/.cache/opencode/packages/jev-guard@0.3.1/node_modules/jev-guard
    echo "--- $P ---"
    ls -la "$P" 2>&1
    echo
    echo "--- package.json ---"
    cat "$P/package.json" 2>&1
    echo
    echo "--- plugin* files anywhere under $P ---"
    find "$P" -maxdepth 3 -iname "plugin*" 2>&1
' | indent

# --------------------------------------------------------------------------
section "T6  opencode version + top of --help"
# --------------------------------------------------------------------------
docker exec -w /workspace "$C" sh -c 'opencode --version 2>&1' | indent
printf '\n'
docker exec -w /workspace "$C" sh -c 'opencode --help 2>&1 | head -8' | indent

# --------------------------------------------------------------------------
section "T7  full DEBUG output (saved to $DBG)"
# --------------------------------------------------------------------------
docker exec -w /workspace "$C" sh -c \
    "opencode run --print-logs --log-level DEBUG --model '$MODEL' '$PROBE_PROMPT'" \
    > "$DBG" 2>&1
n=$(wc -l < "$DBG" | tr -d ' ')
printf 'lines saved: %s\n' "$n"
printf '\n--- first 40 lines ---\n'
head -40 "$DBG" | indent
printf '\n--- last 40 lines ---\n'
tail -40 "$DBG" | indent
printf '\n--- every line matching mcp|plugin|guard|jev ---\n'
grep -inIE 'mcp|plugin|guard|jev' "$DBG" | indent
printf '(end grep)\n'
printf '\nfull log retained at: %s\n' "$DBG"

# --------------------------------------------------------------------------
section "T8  OPENCODE_DISABLE_DEFAULT_PLUGINS — where set"
# --------------------------------------------------------------------------
printf 'container env:\n'
docker exec "$C" sh -c 'env | grep -i OPENCODE 2>&1' | indent
printf '\nrepo docker-compose.yml references:\n'
grep -nI 'OPENCODE' "$REPO/docker/docker-compose.yml" 2>&1 | indent
printf '\nrepo Dockerfile references:\n'
grep -nI 'OPENCODE' "$REPO/docker/Dockerfile" 2>&1 | indent

# --------------------------------------------------------------------------
section "verdict guide"
# --------------------------------------------------------------------------
printf 'Read T1/T2 first:  does "type" already exist in mcp.servers.jev-review?\n'
printf 'Read T4 next:      does the server binary start at all?\n'
printf 'Read T7 last:      does the runtime log ANY MCP/plugin activity?\n'
printf '\n'
printf 'Interpretation:\n'
printf '  T2 says type is present + T4 starts clean + T7 no mcp log\n'
printf '    -> registration problem; fixer is the right next step\n'
printf '  T2 says type is absent  + T4 starts clean + T7 no mcp log\n'
printf '    -> fixer likely right; run it (but drop the enabled field, see A1)\n'
printf '  T4 exits non-zero quickly\n'
printf '    -> server binary is broken; JSON patch will not help\n'
printf '  T7 shows mcp lines but no server process\n'
printf '    -> plugin registered MCP but spawn is silently failing; capture full log\n'
printf '\n'
return 0
