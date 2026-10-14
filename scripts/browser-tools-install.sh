#!/usr/bin/env bash
#
# browser-tools-install.sh — install browser_use + selenium into a dedicated
# venv. Run in the SANDBOX (where the agent drives from).
#
# Why a script: this Debian image ships NO pip and NO ensurepip, so
# `python3 -m venv` cannot seed pip; we bootstrap it with get-pip.py, then
# install the two browser-automation stacks. Both talk to the ALREADY-OPEN
# browser over CDP (see RULES #62 / scripts/cdp-tab.mjs) — no X11 needed.
#
#   bash scripts/browser-tools-install.sh [--venv DIR] [--with-browsers] [--dry-run]
#
#   --venv DIR        install root (default ~/.venvs/browser)
#   --with-browsers   also run `playwright install chromium` (large, ~150 MB)
#   --dry-run         print the plan only
#
# No model spend. Read-only w.r.t. the repo. Exits 0 ok, 1 failure, 2 usage.
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

GETPIP_URL="https://bootstrap.pypa.io/get-pip.py"

main() {
    local VENV="$HOME/.venvs/browser" WB=0 DRY=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --venv) VENV="${2:-}"; shift 2 ;;
            --with-browsers) WB=1; shift ;;
            --dry-run) DRY=1; shift ;;
            -h | --help)
                printf 'usage: %s [--venv DIR] [--with-browsers] [--dry-run]\n' "$0"
                return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    [ -n "$VENV" ] || { printf 'FAIL: empty --venv\n'; return 2; }
    have python3 || { printf 'FAIL: python3 missing\n'; return 1; }

    printf '=== browser-tools-install ===\n'
    printf 'python: %s\n' "$(python3 --version)"
    printf 'venv:   %s%s\n' "$VENV" "$([ -e "$VENV" ] && printf ' (exists)' || printf ' (new)')"
    printf 'pypi:   http %s\n' "$(curl -s -m 8 -o /dev/null -w '%{http_code}' https://pypi.org/simple/)"

    if [ "$DRY" -eq 1 ]; then
        printf '[dry-run] would: create %s; bootstrap pip via get-pip.py; pip install browser-use selenium%s\n' \
            "$VENV" "$([ "$WB" -eq 1 ] && printf ' + playwright chromium')"
        return 0
    fi

    if [ ! -e "$VENV" ]; then
        # --without-pip: this image strips ensurepip, so `venv` cannot seed it;
        # we bootstrap pip next with get-pip.py instead.
        python3 -m venv --without-pip "$VENV" || { printf 'FAIL: venv creation\n'; return 1; }
    fi
    local PY="$VENV/bin/python"

    if ! "$PY" -m pip --version >/dev/null; then
        printf 'bootstrapping pip via %s\n' "$GETPIP_URL"
        curl -fsSL "$GETPIP_URL" -o /tmp/get-pip.py || { printf 'FAIL: get-pip download\n'; return 1; }
        "$PY" /tmp/get-pip.py || { printf 'FAIL: get-pip run\n'; return 1; }
    fi

    printf 'installing browser-use selenium (a few minutes; wheels only)...\n'
    "$PY" -m pip install --upgrade pip browser-use selenium || { printf 'FAIL: pip install browser-use selenium\n'; return 1; }

    if [ "$WB" -eq 1 ]; then
        printf 'installing playwright chromium (~150 MB)...\n'
        "$PY" -m playwright install chromium || printf 'WARN: playwright chromium install failed\n'
    fi

    printf '\n=== installed versions ===\n'
    "$PY" - <<'PYEOF'
import importlib
for m in ("browser_use", "selenium", "playwright"):
    try:
        mod = importlib.import_module(m)
        print("%-12s %s" % (m, getattr(mod, "__version__", "(installed)")))
    except Exception as e:
        print("%-12s MISSING: %s" % (m, e))
PYEOF

    printf '\nuse it:\n  source %s/bin/activate\n' "$VENV"
    printf '  # drive the host Chrome over CDP (RULES #62), e.g. selenium:\n'
    printf '  #   opts.debugger_address = "192.168.4.24:9223"\n'
    return 0
}

main "$@"
