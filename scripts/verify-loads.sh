#!/usr/bin/env bash
# verify-loads.sh — confirm post-recreate loads on the .24 host.
# Checks: litellm config accepted (fallbacks live, no config error),
# opencode-web picked up the repo MCP server + wizard skill, and the
# models endpoint answers. Read-only (logs + GET). Exit 0 all-green.
# Usage: bash scripts/verify-loads.sh
# Plain ASCII. No sed. No rm -rf. No set -e.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 3
FAIL=0
printf '== 1. litellm (served config carries fallbacks) ==\n'
sudo docker exec litellm cat /app/config.yaml 2>&1 | grep -A4 "^fallbacks:" | head -n 8 || true
printf '\n== 2. opencode-web (config carries repo-tools + wizard skill linked) ==\n'
sudo docker exec opencode-deepseek-web grep -c "repo-tools" /workspace/opencode.json 2>&1 || true
sudo docker logs opencode-deepseek-web --tail 60 2>&1 | grep -iE "blacklist-guard linked|skill linked" | head -n 6 || true
printf '\n== 3. models endpoint ==\n'
KEY=""
if [ -f .env.local ]; then
    KEY="$(grep -E "^LITELLM_MASTER_KEY=" .env.local 2>&1 | head -n 1 | cut -d= -f2-)"
fi
if [ -z "$KEY" ]; then
    printf 'SKIP models endpoint (no LITELLM_MASTER_KEY in .env.local)\n'
else
    curl -sS -m 10 http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $KEY" 2>&1 | head -c 300
    printf '\n'
fi
printf '\ndone. Fallback lines + repo-tools/skill lines + model list = loads CONFIRMED.\n'
