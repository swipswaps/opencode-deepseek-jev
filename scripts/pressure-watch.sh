#!/usr/bin/env bash
#
# pressure-watch.sh — one contention-evidence snapshot (observe-only).
#
# Captures PSI (cpu/io/memory), top CPU+memory holders, nebula liveness
# (PID/start/NRestarts), D-state blockers and swap into
# logs/pressure-<utc-ts>.log plus a stdout summary. Exit nonzero only on
# its own failure, never on high pressure: a monitor is not a gate.
#
# Sends no signals, writes nothing outside logs/, touches no other
# project's services. Run twice ~60s apart and diff to separate
# transients (settling PSI) from residents (real hogs).
#
# Usage: ./scripts/pressure-watch.sh
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.
#
# ============================================================================

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=$(resolve_repo "$SCRIPT_DIR")
[ -z "$REPO_DIR" ] && REPO_DIR=$(resolve_repo "$PWD")
if [ -z "$REPO_DIR" ]; then
    printf 'GATE FAIL: cannot resolve repo root\n'
    return 2
fi

main() {
    local ts log
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$REPO_DIR/logs" || return 1
    log="$REPO_DIR/logs/pressure-$ts.log"
    {
        printf '=== pressure-watch %s ===\n' "$ts"
        printf '--- PSI ---\n'
        printf 'cpu: '; cat /proc/pressure/cpu 2>&1 | head -1
        printf 'io: '; cat /proc/pressure/io 2>&1 | head -1
        printf 'memory: '; cat /proc/pressure/memory 2>&1 | head -1
        printf '--- memory/swap ---\n'
        free -m 2>&1 | head -3
        printf '--- top CPU ---\n'
        ps -o pid,pcpu,pmem,etime,comm -e --sort=-%cpu 2>&1 | head -9
        printf '--- top MEM ---\n'
        ps -o pid,pcpu,pmem,etime,comm -e --sort=-%mem 2>&1 | head -9
        printf '--- nebula liveness ---\n'
        ps -o pid,lstart,etime,args -e 2>&1 | grep '[n]ebula' | head -3
        systemctl show nebula -p NRestarts 2>&1 | head -1
        printf '--- D-state blockers ---\n'
        ps -o pid,stat,comm -e 2>&1 | awk '$2 ~ /^D/' | head -8
        printf '(end; blank above means none)\n'
        printf '--- orphans from this repo work (host cleanup, NOT killed here) ---\n'
        ps -o pid,etime,args -e 2>&1 | grep -E '[c]hromium-browser --headless|[d]ashboard.mjs [0-9]{4}' | head -8
        printf '(end)\n'
    } | tee "$log" | head -40
    printf 'archived: %s\n' "$log"
    return 0
}

main "$@"
