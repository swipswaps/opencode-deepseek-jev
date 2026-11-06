#!/usr/bin/env bash
#
# usability-guide.sh - optional facilitator guide: open each task page, then
# run the guided session (timer, success/failure, difficulty, note, SUS).
#
# Uses the best available opener:
#   xdg-open (desktop) > cdp-tab.mjs (already-open browser) > Playwright
#   (headed Chromium) > Selenium (Chrome) > print the URL.
#
#   ./scripts/usability-guide.sh                 # auto opener
#   ./scripts/usability-guide.sh --opener xdg
#   ./scripts/usability-guide.sh --opener playwright
#   ./scripts/usability-guide.sh --opener selenium
#   ./scripts/usability-guide.sh --opener cdp
#   ./scripts/usability-guide.sh --base https://10.100.0.24:5099
#   ./scripts/usability-guide.sh --self-test
#
# The in-app equivalent is /usability (no browser driver needed). This wrapper
# is for a facilitator running on the host with a browser available.
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
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    python3 "$repo/scripts/usability-guided.py" --self-test || fail=1
    python3 "$repo/scripts/usability-guided.py" --tasks > /dev/null || fail=1
    if [ "$fail" -eq 0 ]; then printf 'usability-guide: self-test PASS\n'; else printf 'usability-guide: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    local repo base opener
    repo=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$repo" ] && repo=$(resolve_repo "$PWD")
    [ -z "$repo" ] && { printf 'GATE FAIL: cannot resolve repo root\n'; return 2; }
    base="${USABILITY_BASE:-http://127.0.0.1:5099}"
    opener="auto"
    while [ $# -gt 0 ]; do
        case "$1" in
            --opener) shift; opener="${1:-auto}" ;;
            --opener=*) opener="${1#--opener=}" ;;
            --base) shift; base="${1:-$base}" ;;
            --base=*) base="${1#--base=}" ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) printf 'usage: %s [--opener auto|xdg|playwright|selenium|cdp|print] [--base URL] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
        shift
    done
    printf 'guided usability test\n'
    printf '  base:   %s\n' "$base"
    printf '  opener: %s\n' "$opener"
    printf '  tasks:  7 (pulse, search, graph, signals, runbooks, models, docs)\n'
    printf '  in-app: %s/usability\n\n' "${base%/}"
    if ! have python3; then
        printf 'FAIL: python3 required\n'; return 2
    fi
    exec python3 "$repo/scripts/usability-guided.py" --guide --opener "$opener" --base "$base" --participant "${USABILITY_PARTICIPANT:-anonymous}"
}

main "$@"
