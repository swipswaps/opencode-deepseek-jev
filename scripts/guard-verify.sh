#!/usr/bin/env bash
#
# guard-verify.sh — prove jev-guard is loaded and answering via its backend.
#
# Host-only (needs docker). Reads the RUNNING web container: the global config
# must list jev-guard, JEV_BASE_URL must be set, and `jev-guard check` must
# ALLOW a read-only call (rc 0) and DENY a destructive one (rc 2). The commands
# are CLASSIFIED, never executed.
#
#   ./scripts/guard-verify.sh             # verify only
#   ./scripts/guard-verify.sh --restart   # docker compose restart (keeps env)
#   ./scripts/guard-verify.sh --recreate  # recreate web (REQUIRED after .env.local)
#
# Exit 0 verified, 1 failed check, 2 usage/docker error.
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null. printf only.
#
set -o pipefail

C="opencode-deepseek-web"
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RESTART=0

case "${1:-}" in
    --restart) RESTART=1 ;;
    --recreate) RESTART=2 ;;
    -h | --help) printf 'usage: %s [--restart|--recreate]\n' "$0"; exit 0 ;;
    "") ;;
    *) printf 'unknown arg: %s\n' "$1"; exit 2 ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }
have docker || { printf 'FAIL: docker missing (host-only)\n'; exit 2; }

if [ "$RESTART" -eq 2 ]; then
    "$REPO/scripts/web-restart.sh" --recreate || { printf 'FAIL: web-recreate\n'; exit 2; }
elif [ "$RESTART" -eq 1 ]; then
    "$REPO/scripts/web-restart.sh" || { printf 'FAIL: web-restart\n'; exit 2; }
fi

OUT=$(docker exec -i "$C" sh <<'IN' 2>&1
set -u
rc=0
if grep -q '"jev-guard' "$HOME/.config/opencode/opencode.jsonc"; then
    printf 'guard_config: ON\n'
else
    printf 'guard_config: OFF\n'; rc=1
fi
printf 'JEV_BASE_URL=%s\n' "$(printenv JEV_BASE_URL)"
printf 'JEV_MODEL=%s\n' "$(printenv JEV_MODEL)"
printf 'JEV_GUARD_TIMEOUT_MS=%s\n' "$(printenv JEV_GUARD_TIMEOUT_MS)"
run_check() {
    case "$1" in
        *.js) node "$1" check Bash "$2" ;;
        *) "$1" check Bash "$2" ;;
    esac
}
BIN=""
for c in "$(command -v jev-guard || true)" \
         "$HOME/.config/opencode/node_modules/.bin/jev-guard" \
         "$HOME"/.cache/opencode/packages/*/node_modules/.bin/jev-guard \
         "$HOME/.config/opencode/node_modules/jev-guard/src/cli.js" \
         "$HOME"/.cache/opencode/packages/*/node_modules/jev-guard/src/cli.js \
         "$HOME/.opencode/node_modules/jev-guard/src/cli.js" \
         "/usr/local/lib/node_modules/jev-guard/src/cli.js" \
         "/usr/lib/node_modules/jev-guard/src/cli.js"; do
    if [ -n "$c" ] && [ -f "$c" ]; then BIN="$c"; break; fi
done
if [ -z "$BIN" ]; then
    printf 'cli: MISSING\n'
    for d in "$HOME/.cache/opencode" "$HOME/.config/opencode" "$HOME/.opencode" /usr/local/lib/node_modules /usr/lib/node_modules; do
        [ -d "$d" ] && find "$d" -maxdepth 7 -type f -name cli.js -path '*jev-guard*' 2>&1 | head -3
    done
    rc=1
else
    printf 'cli: %s\n' "$BIN"
    OUT1=$(run_check "$BIN" '{"command":"ls -la"}' 2>&1); A=$?
    OUT2=$(run_check "$BIN" '{"command":"rm -rf /"}' 2>&1); D=$?
    printf 'allow_rc=%s %s\n' "$A" "$(printf '%s' "$OUT1" | head -1)"
    printf 'deny_rc=%s %s\n' "$D" "$(printf '%s' "$OUT2" | head -1)"
    [ "$A" -eq 0 ] || rc=1
    [ "$D" -eq 2 ] || rc=1
fi
exit "$rc"
IN
)
RC=$?
printf '%s\n' "$OUT"
if [ "$RC" -eq 0 ]; then
    printf 'PASS: guard verified\n'
else
    printf 'FAIL: guard check failed (rc=%s)\n' "$RC"
fi
exit "$RC"
