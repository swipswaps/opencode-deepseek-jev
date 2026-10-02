#!/usr/bin/env bash
#
# route-via-proxy.sh — switch the live agent route to LiteLLM :4000 (OPT-IN).
#
# Effect: opencode.json deepseek provider baseURL becomes the local proxy
# (retries + cost headers per call) instead of api.deepseek.com direct.
# The proxy must be healthy (:4000 answers) and LITELLM_MASTER_KEY set.
# Budget note: max_budget stays decorative without DATABASE_URL — this
# switch buys retries/observability, NOT enforcement.
#
#   ./scripts/route-via-proxy.sh [--revert]
#
# Backs up opencode.json before touching it; --revert restores the newest
# backup and restarts. Requires typing YES. Never prints secrets.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.
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

main() {
    printf '=== route-via-proxy.sh ===\n'
    if [ "${1:-}" = "--revert" ]; then
        local bak
        bak=$(ls -t "$REPO_DIR"/opencode.json.bak.* 2>&1 | head -1)
        if [ -z "$bak" ] || [ ! -f "$bak" ]; then
            printf 'FAIL: no backup found (*.bak.*)\n'
            return 1
        fi
        cp "$bak" "$REPO_DIR/opencode.json" || return 1
        printf 'restored %s\n' "$(basename "$bak")"
        (cd "$REPO_DIR/docker" && docker compose restart opencode-web)
        printf 'reverted; verify with: curl -s 127.0.0.1:5099/api/rev\n'
        return 0
    fi
    if ! curl -s --max-time 8 http://127.0.0.1:4000/health -o /dev/null; then
        printf 'FAIL: proxy :4000 not answering — fix it first (see TODO G4)\n'
        return 1
    fi
    if ! grep -q '^LITELLM_MASTER_KEY=.\+' "$REPO_DIR/.env.local" 2>&1; then
        printf 'FAIL: LITELLM_MASTER_KEY missing/empty in .env.local\n'
        return 1
    fi
    printf 'will switch: deepseek baseURL api.deepseek.com -> 127.0.0.1:4000/v1\n'
    printf 'will switch: apiKey {env:DEEPSEEK_API_KEY} -> {env:LITELLM_MASTER_KEY}\n'
    printf 'model id stays deepseek-flash (proxy model_name).\n'
    printf 'Type YES to apply (backup taken first): '
    read -r answer
    if [ "$answer" != "YES" ]; then
        printf 'aborted (no changes made)\n'
        return 2
    fi
    local stamp bak
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    bak="$REPO_DIR/opencode.json.bak.$stamp"
    cp "$REPO_DIR/opencode.json" "$bak" || return 1
    if ! python3 - "$REPO_DIR/opencode.json" <<'PYEOF'; then
import json, sys
p = sys.argv[1]
c = json.load(open(p))
o = c["provider"]["deepseek"]["options"]
o["baseURL"] = "http://127.0.0.1:4000/v1"
o["apiKey"] = "{env:LITELLM_MASTER_KEY}"
json.dump(c, open(p, "w"), indent=2)
print("provider switched")
PYEOF
        printf 'FAIL: edit failed, restoring backup\n'
        cp "$bak" "$REPO_DIR/opencode.json"
        return 1
    fi
    (cd "$REPO_DIR/docker" && docker compose restart opencode-web)
    printf 'applied (backup: %s). Verify: new TUI turn routes via proxy\n' "$(basename "$bak")"
    printf '(watch x-litellm headers; revert anytime with --revert)\n'
    return 0
}

main "$@"
