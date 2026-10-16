#!/usr/bin/env bash
#
# notify-selfhost.sh — self-host the alert webhook sink and point NOTIFY_WEBHOOK
# at it. No third party (no Slack/Discord URL needed).
#
# Writes a systemd USER unit for scripts/notify-sink.mjs, (host) enables it, then
# sets NOTIFY_WEBHOOK=http://127.0.0.1:PORT/hook via scripts/notify-setup.sh and
# probes it. After this, the sentinel timer pushes trips into the local sink.
#
#   ./scripts/notify-selfhost.sh [--port N] [--write-only] [--self-test]
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

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

main() {
    local REPO PORT=8788 WRITEONLY=0
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    [ -z "$REPO" ] && { printf 'GATE FAIL: cannot resolve repo root\n'; return 2; }
    while [ $# -gt 0 ]; do
        case "$1" in
            --port) PORT="${2:-8788}"; shift 2 ;;
            --write-only) WRITEONLY=1; shift ;;
            --self-test) node "$REPO/scripts/notify-sink.mjs" --self-test; return "$?" ;;
            -h | --help) printf 'usage: %s [--port N] [--write-only] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    have node || { printf 'GATE FAIL: node required (notify-sink.mjs)\n'; return 1; }
    local DEST="$HOME/.config/systemd/user"
    mkdir -p "$DEST" || { printf 'FAIL: cannot create %s\n' "$DEST"; return 1; }
    python3 - "$REPO/systemd/opencode-notify-sink.service" "$DEST/opencode-notify-sink.service" "$REPO" "$PORT" << 'PYEOF'
import sys
src, dst, repo, port = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
t = open(src).read().replace("__REPO__", repo).replace("PORT=8788", "PORT=" + port)
open(dst, "w").write(t)
print("wrote " + dst)
PYEOF
    if [ "$WRITEONLY" -eq 1 ] || ! have systemctl; then
        printf 'unit written; enable on the host: systemctl --user enable --now opencode-notify-sink.service\n'
    else
        systemctl --user daemon-reload || { printf 'FAIL: daemon-reload\n'; return 1; }
        systemctl --user enable --now opencode-notify-sink.service || { printf 'FAIL: enable/start\n'; return 1; }
        sleep 1
        printf 'health: '; curl -s --max-time 5 "http://127.0.0.1:$PORT/health" || printf '(no response)\n'
    fi
    printf 'setting NOTIFY_WEBHOOK -> http://127.0.0.1:%s/hook\n' "$PORT"
    bash "$REPO/scripts/notify-setup.sh" --url "http://127.0.0.1:$PORT/hook" || {
        printf 'WARN: notify-setup probe failed (is the sink running?)\n'; return 1; }
    printf 'done. captured alerts: %s/data/observability/notify-sink.jsonl\n' "$REPO"
    return 0
}

main "$@"
