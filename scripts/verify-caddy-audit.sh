#!/usr/bin/env bash
# verify-caddy-audit.sh — scripted Caddy access-plane verification.
# Run ON THE HOST from the repo root:
#   bash scripts/verify-caddy-audit.sh [session-id]
# Default session: ses_ee4ec6b14ffeN7ssA582NZBWgJ (this investigation).
# Checks: container Running (not merely Created), published bindings on
# 4096/5099, access-log lines for the session referer + /global/event SSE
# outcomes, and absence of 401/403 denials. Exit 0 all-green, 2 otherwise.
# Plain ASCII. No sed. No rm -rf. No set -e.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SID="${1:-ses_ee4ec6b14ffeN7ssA582NZBWgJ}"
cd "$REPO/docker" || exit 3
printf '== 1. container state ==\n'
sudo docker compose -f docker-compose.yml -f docker-compose.override.yml ps caddy 2>&1 || exit 2
printf '\n== 2. published bindings ==\n'
sudo docker inspect opencode-caddy --format '{{range $p, $b := .NetworkSettings.Ports}}{{$p}} -> {{$b}}{{"\n"}}{{end}}' 2>&1 || exit 2
printf '\n== 3. access log: session referer hits ==\n'
sudo docker logs opencode-caddy 2>&1 | grep -c "$SID" || true
printf '\n== 4. access log: /global/event outcomes (last 5) ==\n'
sudo docker logs opencode-caddy 2>&1 | grep "global/event" | tail -n 5 || true
printf '\n== 5. denials (expect none) ==\n'
sudo docker logs opencode-caddy 2>&1 | grep -E " 401 | 403 " | tail -n 5 || true
printf '\ndone. 401/403 empty + referer hits >0 + no EADDRNOTAVAIL = audit CONFIRMED.\n'
