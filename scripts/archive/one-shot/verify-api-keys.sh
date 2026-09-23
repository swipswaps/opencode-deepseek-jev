#!/usr/bin/env bash
#
# verify-api-keys.sh — confirm the currently configured keys work.
# Read-only. No writes, no restart.
#
set -o pipefail
C="opencode-deepseek-web"
MODEL="deepseek/deepseek-flash"
DATA_DIR="/home/node/.local/share/opencode"
HTTP_URL="http://127.0.0.1:4096"
section() { printf '\n=== %s ===\n' "$1"; }
indent() { local line; while IFS= read -r line; do printf '%s%s\n' '    ' "$line"; done; }
mask() {
    local s="$1"
    if [ ${#s} -le 12 ]; then printf '***'; return 0; fi
    printf '%s...%s' "$(printf '%s' "$s" | cut -c1-8)" "$(printf '%s' "$s" | rev | cut -c1-6 | rev)"
}
main() {
    printf '=== verify-api-keys.sh ===\n'
    printf 'TS: %s\n' "$(date -u +%Y%m%dT%H%M%SZ)"
    section "0. container state"
    local cstate
    cstate=$(docker inspect -f '{{.State.Status}}' "$C" 2>&1)
    printf '  state: %s\n' "$cstate"
    if [ "$cstate" != "running" ]; then
        printf 'GATE FAIL: not running\n'
        return 1
    fi
    section "1. container env (masked)"
    docker exec "$C" sh -c 'env | grep -E "^(DEEPSEEK|JEV)_API_KEY="' 2>&1 | \
        while IFS='=' read -r k v; do printf '  %s=%s\n' "$k" "$(mask "$v")"; done
    section "2. auth.json"
    docker exec "$C" sh -c "ls -la '$DATA_DIR/auth.json' 2>&1 && head -c 200 '$DATA_DIR/auth.json'" | indent
    section "3. HTTP listener"
    local code="" tries=0
    while [ "$tries" -lt 30 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$HTTP_URL/")
        if [ -n "$code" ] && [ "$code" != "000" ]; then break; fi
        tries=$((tries + 1))
        sleep 1
    done
    printf '  http=%s (after %s probe(s))\n' "$code" "$tries"
    section "4. providers"
    docker exec -w /workspace "$C" sh -c 'opencode providers list' 2>&1 | indent
    section "5. DeepSeek one-shot (streaming)"
    local log
    log="/tmp/verify-keys-$(date -u +%Y%m%dT%H%M%SZ).log"
    docker exec -w /workspace "$C" sh -c \
        "opencode run --print-logs --model '$MODEL' 'Reply with exactly: KEYSOK'" \
        2>&1 | tee "$log"
    if grep -q 'KEYSOK' "$log"; then
        printf '\n  PASS DeepSeek key works\n'
    else
        printf '\n  FAIL DeepSeek key — see %s\n' "$log"
    fi
    section "6. JEV MCP status"
    docker exec -w /workspace "$C" sh -c 'opencode mcp list' 2>&1 | indent
    printf '\n  If jev-review is NOT "connected", the JEV key is invalid.\n'
    printf '  Verify at https://console.typesafe.ai/keys\n'
    return 0
}
main "$@"
