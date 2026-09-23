#!/usr/bin/env bash
#
# verify-from-inside.sh — self-check for the agent running INSIDE the
# opencode container (no docker). In-container counterpart to the
# host-side verify-api-keys.sh.
#
# Checks (fast, free by default):
#   V1  opencode binary + version
#   V2  auth.json present with a deepseek entry (key never printed)
#   V3  DEEPSEEK_API_KEY and JEV_API_KEY set in the environment
#   V4  opencode.json parses; model, provider, MCP servers listed
#   V5  jev-review server.js present
#   V6  (--full) live round-trip: opencode run replies "PONG"
#
# Exit 0 if every check passes, non-zero otherwise.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

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

FAILS=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "$2" ] && printf '        %s\n' "$2"; FAILS=$((FAILS + 1)); }
skip() { printf '  SKIP  %s\n' "$1"; }

main() {
    local full=0
    case "${1:-}" in
        --full) full=1 ;;
        "") ;;
        *) printf 'usage: %s [--full]\n' "$0"; return 2 ;;
    esac

    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi

    printf '=== verify-from-inside.sh ===\n'
    printf 'Repo: %s\n' "$REPO"

    if command -v opencode > /dev/null; then
        pass "opencode $(opencode --version 2>&1)"
    else
        fail "opencode not on PATH"
    fi

    local auth="$HOME/.local/share/opencode/auth.json"
    if [ -f "$auth" ] && grep -q '"deepseek"' "$auth"; then
        pass "auth.json present with deepseek entry"
    else
        fail "auth.json missing or has no deepseek entry" "$auth"
    fi

    [ -n "$DEEPSEEK_API_KEY" ] && pass "DEEPSEEK_API_KEY set (len ${#DEEPSEEK_API_KEY})" || fail "DEEPSEEK_API_KEY empty"
    [ -n "$JEV_API_KEY" ] && pass "JEV_API_KEY set (len ${#JEV_API_KEY})" || fail "JEV_API_KEY empty"

    if [ -f "$REPO/opencode.json" ] && node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));' "$REPO/opencode.json"; then
        pass "opencode.json parses"
        node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); console.log("        model: " + j.model); console.log("        provider: " + Object.keys(j.provider||{}).join(",")); console.log("        mcp servers: " + Object.keys((j.mcp||{}).servers||{}).join(","));' "$REPO/opencode.json"
    else
        fail "opencode.json does not parse"
    fi

    if [ -f /opt/jev-review/dist/server.js ]; then
        pass "jev-review server.js present"
    else
        fail "jev-review server.js missing"
    fi

    if [ "$full" -eq 1 ]; then
        local out rc
        out=$(timeout 120 opencode run --model deepseek/deepseek-flash "Reply with exactly: PONG" 2>&1)
        rc=$?
        if printf '%s' "$out" | grep -q 'PONG'; then
            pass "live round-trip returned PONG (rc=$rc informational)"
        else
            fail "live round-trip did not return PONG"
            printf '%s\n' "$out" | head -5 | while IFS= read -r l; do printf '        %s\n' "$l"; done
        fi
    else
        skip "live round-trip (run with --full; costs ~1e-4 USD)"
    fi

    printf '\nresult: %s\n' "$([ "$FAILS" -eq 0 ] && printf OK || printf FAIL)"
    [ "$FAILS" -eq 0 ]
}

main "$@"
