#!/usr/bin/env bash
#
# web-build-restart.sh - build the MUI app and restart the served dashboard
# from the repo root, regardless of the caller's current directory.
#
# This exists because `cd web && npm run build` followed by
# `./scripts/web-restart.sh` fails: the second path is relative to web/. The
# build is the easy half; the restart is what makes the server routes/APIs and
# the new dist visible. One command removes the wrong-cwd failure.
#
#   ./scripts/web-build-restart.sh
#   ./scripts/web-build-restart.sh --dry-run
#   ./scripts/web-build-restart.sh --self-test
#
# Host only (docker/systemctl or the local dashboard process). The build runs
# in web/; the restart runs the canonical scripts/web-restart.sh from the repo
# root. Verification: /app/ 200, /api/rev served==HEAD, /api/usability/tasks
# 200, and the served /app/ asset hash is the built one.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null.
# No subprocess.run. No kill without signal. main() wrapper.
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

have() { command -v "$1" >/dev/null 2>&1; }

self_test() {
    local repo fail=0
    repo=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$repo" ] && { printf 'FAIL repo not found\n'; return 1; }
    [ -f "$repo/web/package.json" ] || { printf 'FAIL web/package.json missing\n'; fail=1; }
    [ -x "$repo/scripts/web-restart.sh" ] || { printf 'FAIL web-restart.sh missing\n'; fail=1; }
    have node || { printf 'FAIL node missing\n'; fail=1; }
    have npm || { printf 'FAIL npm missing\n'; fail=1; }
    bash -n "$repo/scripts/web-restart.sh" || fail=1
    if [ "$fail" -eq 0 ]; then printf 'web-build-restart: self-test PASS\n'; else printf 'web-build-restart: self-test FAIL\n'; fi
    return "$fail"
}

verify() {
    local base="$1" head served code asset dist_asset
    head=$(git -C "$REPO" rev-parse --short HEAD 2>&1 || true)
    code=$(curl -s -o /dev/null -w '%{http_code}' "$base/app/" 2>&1 || true)
    printf '  /app/                     %s\n' "$code"
    [ "$code" = "200" ] || return 1
    served=$(curl -s "$base/api/rev" 2>&1 | python3 -c 'import json,sys; print(json.load(sys.stdin).get("served",""))' 2>&1 || true)
    printf '  /api/rev served=%s head=%s\n' "$served" "$head"
    [ -z "$head" ] || [ "$served" = "$head" ] || return 1
    code=$(curl -s -o /dev/null -w '%{http_code}' "$base/api/usability/tasks" 2>&1 || true)
    printf '  /api/usability/tasks      %s\n' "$code"
    [ "$code" = "200" ] || return 1
    dist_asset=$(python3 - "$REPO/web/dist/index.html" <<'PY'
import re, sys
try:
    h = open(sys.argv[1]).read()
    m = re.search(r'/app/assets/(index-[A-Za-z0-9_-]+\.js)', h)
    print(m.group(1) if m else "")
except Exception:
    print("")
PY
)
    asset=$(curl -s "$base/app/" 2>&1 | python3 -c 'import re,sys; h=sys.stdin.read(); m=re.search(r"/app/assets/(index-[A-Za-z0-9_-]+\.js)",h); print(m.group(1) if m else "")' 2>&1 || true)
    printf '  served asset=%s\n  built asset =%s\n' "$asset" "$dist_asset"
    [ -z "$dist_asset" ] || [ "$asset" = "$dist_asset" ] || return 1
    return 0
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    [ -z "$REPO" ] && { printf 'GATE FAIL: cannot resolve repo root\n'; return 2; }
    local DRY=0 arg="${1:-}"
    case "$arg" in
        --self-test) self_test; return "$?" ;;
        --dry-run) DRY=1 ;;
        -h | --help) printf 'usage: %s [--dry-run] [--self-test]\n' "$0"; return 0 ;;
        "") ;;
        *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
    esac
    have node || { printf 'FAIL: node required\n'; return 1; }
    have npm || { printf 'FAIL: npm required\n'; return 1; }
    [ -f "$REPO/web/package.json" ] || { printf 'FAIL: %s/web/package.json missing\n' "$REPO"; return 1; }
    [ -x "$REPO/scripts/web-restart.sh" ] || { printf 'FAIL: %s/scripts/web-restart.sh missing/not executable\n' "$REPO"; return 1; }
    if [ "$DRY" -eq 1 ]; then
        printf 'DRY RUN\n  cd %s/web && npm run build\n  %s/scripts/web-restart.sh\n' "$REPO" "$REPO"
        return 0
    fi
    printf '=== build (%s/web) ===\n' "$REPO"
    ( cd "$REPO/web" && npm run build ) || { printf 'FAIL: npm run build\n'; return 1; }
    printf '\n=== restart (%s/scripts/web-restart.sh) ===\n' "$REPO"
    ( cd "$REPO" && ./scripts/web-restart.sh ) || { printf 'FAIL: web-restart.sh\n'; return 1; }
    printf '\n=== verify ===\n'
    verify "${WEB_BASE:-http://127.0.0.1:5099}" || { printf 'FAIL: served build is not the built build / server not ready\n'; return 1; }
    printf 'PASS: built, restarted, and served asset matches web/dist\n'
    return 0
}

main "$@"
