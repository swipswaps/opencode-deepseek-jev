#!/usr/bin/env bash
#
# proactive-install.sh — install the user-level proactive-agent timer (no sudo).
# Sibling of sentinel-install.sh / progress-review-install.sh / fts-refresh-install.sh.
#
# Copies systemd/opencode-proactive.{service,timer} into
# ~/.config/systemd/user/ with the repo path baked into ExecStart, then enables
# the timer. Idempotent: re-running refreshes the units.
# Uninstall: ./scripts/proactive-install.sh --uninstall
#
# The timer runs ./scripts/proactive-agent.sh --once every 15 minutes: it turns
# NEW ADVISORY rows into owned tasks (owner `proactive`, idempotent by title),
# writes data/observability/proactive.json and records a PROACTIVE ledger row.
# The first run bootstraps the cursor and creates no tasks from history.
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
    local fail=0 work="" real=""
    real=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    work=$(mktemp -d)
    REPO_OVERRIDE="$real" DEST_OVERRIDE="$work/unit" bash "${BASH_SOURCE[0]}" --write-only > /dev/null 2>&1
    grep -q "ExecStart=$real/scripts/proactive-agent.sh --once" "$work/unit/opencode-proactive.service" \
        || { printf 'FAIL ExecStart baked\n'; fail=1; }
    grep -q "OnCalendar=" "$work/unit/opencode-proactive.timer" \
        || { printf 'FAIL timer calendar\n'; fail=1; }
    grep -q "Nice=10" "$work/unit/opencode-proactive.service" \
        || { printf 'FAIL Nice\n'; fail=1; }
    rm -f "$work/unit/opencode-proactive.service" "$work/unit/opencode-proactive.timer"
    rmdir "$work/unit" "$work"
    if [ "$fail" -eq 0 ]; then printf 'proactive-install: self-test PASS\n'; else printf 'proactive-install: self-test FAIL\n'; fi
    return "$fail"
}

write_units() {
    local repo="$1" dest="$2" src=""
    src="$repo/systemd"
    mkdir -p "$dest"
    python3 - "$src/opencode-proactive.service" "$dest/opencode-proactive.service" "$repo" << 'PYEOF'
import sys
src, dst, repo = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read().replace("__REPO__", repo)
open(dst, "w").write(text)
PYEOF
    cp "$src/opencode-proactive.timer" "$dest/opencode-proactive.timer"
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
            rm -f "$DEST/opencode-proactive.service" "$DEST/opencode-proactive.timer"
            have systemctl && systemctl --user daemon-reload > /dev/null 2>&1 || true
            printf 'proactive-agent timer uninstalled (tasks, cursor and digest kept)\n'
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
    systemctl --user enable --now opencode-proactive.timer 2>&1 || { printf 'FAIL: enable failed\n'; return 1; }
    systemctl --user list-timers opencode-proactive.timer --no-pager 2>&1 | head -n 6
    printf 'digest: data/observability/proactive.json; tasks: python3 scripts/task-id.py list\n'
    return 0
}

main "$@"
