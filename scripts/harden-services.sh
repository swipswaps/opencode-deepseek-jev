#!/usr/bin/env bash
#
# harden-services.sh — bound the crash-looping / oversubscribing services.
#
# From durable-pi ("checkpointed/supervised jobs"): a service that crash-loops
# must be rate-limited and CPU/memory-capped, and supervised with a bounded
# restart, or it starves the box (the ws24 lockup: deepseek-harness restart
# counter 46, >100% CPU). This PRINTS the exact systemd drop-ins + commands;
# --apply writes them (host only, needs systemctl + the daemon).
#
#   ./scripts/harden-services.sh                # print the plan (default)
#   ./scripts/harden-services.sh --apply        # write drop-ins, reload, restart
#   ./scripts/harden-services.sh --self-test    # offline, no systemd
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

UNIT="deepseek-harness.service"
DROPDIR="$HOME/.config/systemd/user/$UNIT.d"
DROPIN="$DROPDIR/override.conf"

dropin_text() {
    printf '%s\n' \
        '[Service]' \
        '# Rate-limit the crash loop (was restart counter 46): stop hammering.' \
        'Restart=on-failure' \
        'RestartSec=5' \
        'StartLimitIntervalSec=60' \
        'StartLimitBurst=3' \
        '# Bound CPU/memory so it cannot oversubscribe the 8-core box.' \
        'CPUQuota=25%' \
        'MemoryMax=1G' \
        'IOWeight=50'
}

plan() {
    printf '=== harden-services: %s ===\n' "$UNIT"
    printf 'drop-in: %s\n\n' "$DROPIN"
    dropin_text
    printf '\n--- commands (run on the host) ---\n'
    printf 'mkdir -p %s\n' "$DROPDIR"
    printf 'cat > %s <<EOF\n' "$DROPIN"
    dropin_text
    printf 'EOF\n'
    printf 'systemctl --user daemon-reload\n'
    printf 'systemctl --user restart %s\n' "$UNIT"
    printf 'systemctl --user show %s -p CPUQuotaPerSecUSec -p MemoryMax -p StartLimitBurst\n' "$UNIT"
    printf '\n# container (opencode-web): cap cpus in docker/docker-compose.yml\n'
    printf '#   services.opencode-web.cpus: "2.0"\n'
    printf '#   services.opencode-web.mem_limit: 4g\n'
    printf '\n# do NOT run TUI + :4096 web + dsh + Chrome-heavy at once on 8 cores\n'
}

self_test() {
    local fail=0 t
    t=$(dropin_text)
    printf '%s' "$t" | grep -q 'CPUQuota=25%' || { printf 'FAIL cpuquota\n'; fail=1; }
    printf '%s' "$t" | grep -q 'StartLimitBurst=3' || { printf 'FAIL startlimit\n'; fail=1; }
    printf '%s' "$t" | grep -q '^\[Service\]' || { printf 'FAIL unit header\n'; fail=1; }
    printf '%s' "$t" | grep -qE 'Restart=on-failure' || { printf 'FAIL restart\n'; fail=1; }
    if [ "$fail" -eq 0 ]; then printf 'harden-services: self-test PASS\n'; else printf 'harden-services: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    local APPLY=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --apply) APPLY=1; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) printf 'usage: %s [--apply] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$APPLY" -eq 0 ]; then
        plan
        return 0
    fi
    have systemctl || { printf 'FAIL: systemctl not available (run on the host)\n'; return 1; }
    mkdir -p "$DROPDIR" || { printf 'FAIL: cannot create %s\n' "$DROPDIR"; return 1; }
    dropin_text > "$DROPIN" || { printf 'FAIL: cannot write %s\n' "$DROPIN"; return 1; }
    printf 'wrote %s\n' "$DROPIN"
    systemctl --user daemon-reload && systemctl --user restart "$UNIT" || {
        printf 'WARN: reload/restart failed; is the user unit installed?\n'; return 1; }
    printf 'applied + restarted %s\n' "$UNIT"
    return 0
}

main "$@"
