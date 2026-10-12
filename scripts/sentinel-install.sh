#!/usr/bin/env bash
#
# sentinel-install.sh — install the user-level sentinel timer (no sudo).
#
# Copies systemd/opencode-sentinel.{service,timer} into
# ~/.config/systemd/user/ with the repo path baked into ExecStart, then
# enables the timer. Idempotent: re-running refreshes the units.
# Uninstall: ./scripts/sentinel-install.sh --uninstall
#
# The timer runs ./scripts/sentinel.sh --once every 5 minutes; each sweep
# logs ADVISORY rows to the observability ledger on actionable trips only
# (latest session over budget / deny-listed, new gateway-failure lines).
# Read the rows with: ./scripts/logs.sh --source ledger
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.
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

self_test() {
    # Offline: bake into a temp dir, assert the repo path landed and the
    # timer carries the 5-minute calendar. No systemd touched.
    local fail=0 work="" real=""
    real=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    work=$(mktemp -d)
    REPO_OVERRIDE="$real" DEST_OVERRIDE="$work/unit" bash "${BASH_SOURCE[0]}" --write-only > /dev/null 2>&1
    grep -q "ExecStart=$real/scripts/sentinel.sh --once" "$work/unit/opencode-sentinel.service" \
        || { printf 'FAIL ExecStart baked\n'; fail=1; }
    grep -q "OnCalendar=" "$work/unit/opencode-sentinel.timer" \
        || { printf 'FAIL timer calendar\n'; fail=1; }
    rm -f "$work/unit/opencode-sentinel.service" "$work/unit/opencode-sentinel.timer"
    rmdir "$work/unit" "$work"
    if [ "$fail" -eq 0 ]; then printf 'sentinel-install: self-test PASS\n'; else printf 'sentinel-install: self-test FAIL\n'; fi
    return "$fail"
}

write_units() {
    # write_units REPO DEST — bake + copy. No daemon contact.
    local repo="$1" dest="$2" src=""
    src="$repo/systemd"
    mkdir -p "$dest"
    python3 - "$src/opencode-sentinel.service" "$dest/opencode-sentinel.service" "$repo" << 'PYEOF'
import sys
src, dst, repo = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read().replace("__REPO__", repo)
open(dst, "w").write(text)
PYEOF
    cp "$src/opencode-sentinel.timer" "$dest/opencode-sentinel.timer"
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
    local mode="install" arg="${1:-}"
    case "$arg" in
        "") ;;
        --write-only) write_units "$REPO" "$DEST"; printf 'units written to %s\n' "$DEST"; return 0 ;;
        --uninstall)
            mode="uninstall"
            rm -f "$DEST/opencode-sentinel.service" "$DEST/opencode-sentinel.timer"
            have systemctl && systemctl --user daemon-reload > /dev/null 2>&1 || true
            printf 'sentinel timer uninstalled (ledger rows and cursor kept)\n'
            return 0 ;;
        --self-test) self_test; return "$?" ;;
        -h | --help) printf 'usage: %s [--write-only] [--uninstall] [--self-test]\n' "$0"; return 0 ;;
        *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
    esac
    [ "$mode" = "install" ] || return 0
    write_units "$REPO" "$DEST"
    if ! have systemctl; then
        printf 'units written to %s; no systemctl here — enable manually where systemd runs\n' "$DEST"
        return 0
    fi
    systemctl --user daemon-reload 2>&1 || printf 'WARN: daemon-reload failed (headless session? run: systemctl --user daemon-reload)\n'
    systemctl --user enable --now opencode-sentinel.timer 2>&1 || { printf 'FAIL: enable failed\n'; return 1; }
    systemctl --user list-timers opencode-sentinel.timer --no-pager 2>&1 | head -n 6
    printf 'poll trips with: ./scripts/logs.sh --source ledger\n'
    return 0
}

main "$@"
