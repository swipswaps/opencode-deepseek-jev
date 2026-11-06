#!/usr/bin/env bash
#
# usability-install.sh - install the user-level usability timer (no sudo).
#
# Copies systemd/opencode-usability.{service,timer} into
# ~/.config/systemd/user/ with the repo path baked into ExecStart, then enables
# the timer. Idempotent: re-running refreshes the units.
#
# Default: static layer every 30 minutes (HTTP reachability + WCAG automated
# subset via a11y-audit.mjs). --full: Playwright layer (tasks + CWV + keyboard
# + reflow), falling back to static if Playwright is absent. The timer writes
# usability_run/usability_result rows and data/observability/usability.json.
#
#   ./scripts/usability-install.sh              # static, every 30 min
#   ./scripts/usability-install.sh --full       # browser layer too
#   ./scripts/usability-install.sh --write-only # bake units, no systemctl
#   ./scripts/usability-install.sh --uninstall
#   ./scripts/usability-install.sh --self-test
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.
#
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

have() { command -v "$1" >/dev/null 2>&1; }

write_units() {
    # write_units REPO DEST FULL — bake + copy. No daemon contact.
    local repo="$1" dest="$2" full="$3" src=""
    src="$repo/systemd"
    mkdir -p "$dest"
    python3 - "$src/opencode-usability.service" "$dest/opencode-usability.service" "$repo" "$full" << 'PYEOF'
import sys
src, dst, repo, full = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(src).read().replace("__REPO__", repo)
if full == "1":
    text = text.replace(" --static-only", " --axe")
open(dst, "w").write(text)
PYEOF
    cp "$src/opencode-usability.timer" "$dest/opencode-usability.timer"
}

self_test() {
    local fail=0 work="" real=""
    real=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    work=$(mktemp -d)
    REPO_OVERRIDE="$real" DEST_OVERRIDE="$work/unit" bash "${BASH_SOURCE[0]}" --write-only > /dev/null 2>&1
    grep -q "ExecStart=$real/scripts/usability-suite.py --static-only" "$work/unit/opencode-usability.service" \
        || { printf 'FAIL static ExecStart baked\n'; fail=1; }
    grep -q "OnCalendar=" "$work/unit/opencode-usability.timer" \
        || { printf 'FAIL timer calendar\n'; fail=1; }
    REPO_OVERRIDE="$real" DEST_OVERRIDE="$work/full" bash "${BASH_SOURCE[0]}" --write-only --full > /dev/null 2>&1
    grep -q "ExecStart=$real/scripts/usability-suite.py --axe --base" "$work/full/opencode-usability.service" \
        || { printf 'FAIL full ExecStart baked\n'; fail=1; }
    rm -f "$work/unit/opencode-usability.service" "$work/unit/opencode-usability.timer"
    rm -f "$work/full/opencode-usability.service" "$work/full/opencode-usability.timer"
    rmdir "$work/unit" "$work/full" "$work"
    if [ "$fail" -eq 0 ]; then printf 'usability-install: self-test PASS\n'; else printf 'usability-install: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    if [ -n "${REPO_OVERRIDE:-}" ]; then REPO="$REPO_OVERRIDE"; fi
    local DEST="${DEST_OVERRIDE:-$HOME/.config/systemd/user}"
    local FULL=0 mode="install"
    while [ $# -gt 0 ]; do
        case "$1" in
            --write-only) mode="write" ;;
            --uninstall) mode="uninstall" ;;
            --full) FULL=1 ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) printf 'usage: %s [--write-only] [--full] [--uninstall] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
        shift
    done
    if [ "$mode" = "uninstall" ]; then
        rm -f "$DEST/opencode-usability.service" "$DEST/opencode-usability.timer"
        have systemctl && systemctl --user daemon-reload > /dev/null 2>&1 || true
        printf 'usability timer uninstalled (history kept)\n'
        return 0
    fi
    write_units "$REPO" "$DEST" "$FULL"
    if [ "$mode" = "write" ]; then
        printf 'units written to %s\n' "$DEST"
        return 0
    fi
    if ! have systemctl; then
        printf 'units written to %s; no systemctl here — enable manually where systemd runs\n' "$DEST"
        return 0
    fi
    systemctl --user daemon-reload 2>&1 || printf 'WARN: daemon-reload failed (headless session? run: systemctl --user daemon-reload)\n'
    systemctl --user enable --now opencode-usability.timer 2>&1 || { printf 'FAIL: enable failed\n'; return 1; }
    systemctl --user list-timers opencode-usability.timer --no-pager 2>&1 | head -n 6
    printf 'read history with: ./scripts/usability-suite.py --json\n'
    return 0
}

main "$@"
