#!/usr/bin/env bash
#
# fts-refresh-install.sh — install the user-level FTS refresh timer (no sudo).
# Sibling of sentinel-install.sh / progress-review-install.sh.
#
# Copies systemd/opencode-fts-refresh.{service,timer} into
# ~/.config/systemd/user/ with the repo path baked into ExecStart, then enables
# the timer. Idempotent: re-running refreshes the units.
# Uninstall: ./scripts/fts-refresh-install.sh --uninstall
#
# Why: the dashboard serves /api/semantic from the on-disk FTS base plus an
# in-memory overlay for new parts. The base is refreshed out-of-band by this
# timer (every 15 min, randomized), so the overlay stays small and search never
# pays a full rebuild on the request path. semantic-search.sh builds to a temp
# file and atomically renames it, so readers never see a partial index.
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
    # Offline: bake into a temp dir, assert the repo path landed and the timer
    # carries a calendar + the low-impact knobs. No systemd touched.
    local fail=0 work="" real=""
    real=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    work=$(mktemp -d)
    REPO_OVERRIDE="$real" DEST_OVERRIDE="$work/unit" bash "${BASH_SOURCE[0]}" --write-only > /dev/null 2>&1
    grep -q "ExecStart=$real/scripts/semantic-search.sh --rebuild" "$work/unit/opencode-fts-refresh.service" \
        || { printf 'FAIL ExecStart baked\n'; fail=1; }
    grep -q "OnCalendar=" "$work/unit/opencode-fts-refresh.timer" \
        || { printf 'FAIL timer calendar\n'; fail=1; }
    grep -q "CPUQuota=50%" "$work/unit/opencode-fts-refresh.service" \
        || { printf 'FAIL CPU quota\n'; fail=1; }
    rm -f "$work/unit/opencode-fts-refresh.service" "$work/unit/opencode-fts-refresh.timer"
    rmdir "$work/unit" "$work"
    if [ "$fail" -eq 0 ]; then printf 'fts-refresh-install: self-test PASS\n'; else printf 'fts-refresh-install: self-test FAIL\n'; fi
    return "$fail"
}

write_units() {
    # write_units REPO DEST — bake + copy. No daemon contact.
    local repo="$1" dest="$2" src=""
    src="$repo/systemd"
    mkdir -p "$dest"
    python3 - "$src/opencode-fts-refresh.service" "$dest/opencode-fts-refresh.service" "$repo" << 'PYEOF'
import sys
src, dst, repo = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read().replace("__REPO__", repo)
open(dst, "w").write(text)
PYEOF
    cp "$src/opencode-fts-refresh.timer" "$dest/opencode-fts-refresh.timer"
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
            rm -f "$DEST/opencode-fts-refresh.service" "$DEST/opencode-fts-refresh.timer"
            have systemctl && systemctl --user daemon-reload > /dev/null 2>&1 || true
            printf 'fts-refresh timer uninstalled (the index file is kept)\n'
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
    systemctl --user enable --now opencode-fts-refresh.timer 2>&1 || { printf 'FAIL: enable failed\n'; return 1; }
    systemctl --user list-timers opencode-fts-refresh.timer --no-pager 2>&1 | head -n 6
    printf 'staleness bound: base <=15 min; new parts are covered by the dashboard overlay.\n'
    printf 'inspect: python3 scripts/semantic-search.sh <query>  (or the dashboard search box)\n'
    return 0
}

main "$@"
