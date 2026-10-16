#!/usr/bin/env bash
#
# browser-python.sh — resolve a Python with the browser stack (playwright /
# browser-use / selenium) and exec a script with it.
#
# Why: the sandbox venv (/home/node/.venvs/browser) is wiped when the container
# is recreated, but the repo (/workspace) and the HOST venv
# (/home/owner/.venvs/browser) persist. This seam picks whichever exists, so
# ux-smoke.py / browser_bench.py / panels-tour.py keep working across resets.
#
#   ./scripts/browser-python.sh scripts/ux-smoke.py --vision
#   ./scripts/browser-python.sh scripts/browser_bench.py --pick
#   BROWSER_VENV=/path/to/venv ./scripts/browser-python.sh <script> [args...]
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.
#
set -o pipefail

main() {
    local venv="${BROWSER_VENV:-}"
    if [ -z "$venv" ]; then
        local c
        for c in "$HOME/.venvs/browser" /home/owner/.venvs/browser "$HOME/.venvs/ocr"; do
            if [ -x "$c/bin/python" ]; then venv="$c"; break; fi
        done
    fi
    if [ -z "$venv" ] || [ ! -x "$venv/bin/python" ]; then
        printf 'FAIL: no browser venv found\n'
        printf '  set BROWSER_VENV=/path/to/venv, or run: bash scripts/browser-tools-install.sh\n'
        return 2
    fi
    [ $# -ge 1 ] || { printf 'usage: %s <script.py> [args...]\n' "$0"; return 2; }
    printf 'browser-python: using %s\n' "$venv/bin/python" >&2
    exec "$venv/bin/python" "$@"
}

main "$@"
