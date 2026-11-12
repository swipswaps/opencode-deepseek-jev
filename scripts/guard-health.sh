#!/usr/bin/env bash
#
# guard-health.sh — fail-closed health check for the blacklist guard (P0, #4).
#
# A missing/dangling/stale guard is indistinguishable from "no matches": the
# guard is silently absent. This checks the plugin file, the prose (assistant
# output) hook, the irreversible rule, strict mode, the guard self-test, the
# global link, and that the loaded plugin is not older than the file (a stale
# in-memory guard needs an opencode-web restart).
#
#   ./scripts/guard-health.sh            # --check
#   ./scripts/guard-health.sh --self-test
#
# Exit: 0 healthy, 2 FAIL.
# Constraints: no sed, no 2>/dev/null, no set -e, no rm -rf,
#   no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

REPO=""
FAIL=0
STATE=""

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

pass() { printf '  PASS %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }

self_test() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then printf 'FAIL: cannot resolve repo\n'; return 2; fi
    REPO="$REPO"; FAIL=0
    STATE="$REPO/logs"; mkdir -p "$STATE"
    plugin_check
    printf 'guard-health: self-test %s\n' "$([ "$FAIL" -eq 0 ] && printf PASS || printf FAIL)"
    [ "$FAIL" -eq 0 ] && return 0 || return 2
}

plugin_check() {
    local plugin="$REPO/.opencode/plugins/blacklist-guard.js"
    if [ -f "$plugin" ]; then pass "plugin present"; else fail "plugin missing: $plugin"; fi
    if grep -q 'experimental.text.complete' "$plugin"; then pass "assistant-output hook present"; else fail "assistant-output hook missing"; fi
    if grep -q 'name: "irreversible"' "$plugin"; then pass "irreversible rule present"; else fail "irreversible rule missing"; fi
    if grep -q 'strict' "$plugin"; then pass "strict mode present"; else fail "strict mode missing"; fi
    if [ -x "$REPO/scripts/blacklist-guard-self-test.mjs" ] || [ -f "$REPO/scripts/blacklist-guard-self-test.mjs" ]; then
        if node "$REPO/scripts/blacklist-guard-self-test.mjs" > "$STATE/guard-health-selftest" 2>&1; then
            pass "guard self-test"
        else
            fail "guard self-test ($(tail -1 "$STATE/guard-health-selftest"))"
        fi
    else
        fail "guard self-test missing"
    fi
}

main() {
    local selftest=0
    [ "${1:-}" = "--self-test" ] && selftest=1
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'FAIL: cannot resolve repo\n'
        return 2
    fi
    STATE="$REPO/logs"; mkdir -p "$STATE"
    printf '=== guard-health ===\n'
    plugin_check
    if [ "$selftest" -eq 0 ]; then
        if [ -x "$REPO/scripts/install-global-guard.sh" ]; then
            if "$REPO/scripts/install-global-guard.sh" --check > "$STATE/guard-health-link" 2>&1; then
                pass "global guard link"
            else
                fail "global guard link ($(tail -1 "$STATE/guard-health-link"))"
            fi
        else
            fail "install-global-guard.sh missing"
        fi
        local plugin="$REPO/.opencode/plugins/blacklist-guard.js"
        local log="$REPO/data/observability/guard.log"
        local loaded="" loaded_sha=""
        if [ -f "$log" ]; then
            loaded_sha=$(grep '"verdict":"loaded"' "$log" 2>&1 | tail -1 | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get("sha") or "")
except Exception:
    print("")' 2>&1)
            loaded=$(grep '"verdict":"loaded"' "$log" 2>&1 | tail -1 | python3 -c 'import json,sys,datetime
try:
    d=json.load(sys.stdin); print(int(datetime.datetime.fromisoformat(d["ts"].replace("Z","+00:00")).timestamp()))
except Exception:
    print("")' 2>&1)
        fi
        local file_sha=""
        file_sha=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$plugin" 2>&1)
        if [ -z "$loaded" ]; then
            fail "no loaded heartbeat in guard.log (restart opencode-web)"
        elif [ -z "$loaded_sha" ]; then
            fail "loaded heartbeat has no content hash; restart opencode-web to record it"
        elif [ "$loaded_sha" != "$file_sha" ]; then
            fail "loaded plugin hash differs from file (restart opencode-web to load it)"
        else
            pass "loaded instance is current (content hash)"
        fi
    fi
    printf 'guard-health: %s\n' "$([ "$FAIL" -eq 0 ] && printf PASS || printf 'FAIL (%s)' "$FAIL")"
    [ "$FAIL" -eq 0 ] && return 0 || return 2
}

main "$@"
