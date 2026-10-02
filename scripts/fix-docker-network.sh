#!/usr/bin/env bash
#
# fix-docker-network.sh — recover host->docker port forwarding (RUN WITH SUDO).
#
# Symptom: every docker-mapped port (4096/5099/4000/5001) unreachable from
# the host while containers run fine and in-container loopback works.
# Cause: host firewall/NAT path to docker bridges broken; only a daemon
# restart rebuilds it. No repo code can fix this (verified 2026-10-02).
#
#   sudo ./scripts/fix-docker-network.sh
#
# Kills and restarts ALL containers (agent runs included) — savepoint
# first. Requires typing YES. Idempotent: exits 0 immediately when all
# ports already answer.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.
#
# ============================================================================

set -o pipefail

PORTS="4096 5099 4000 5001"

probe() {
    local ok=0 p code
    for p in $PORTS; do
        code=$(curl -s --max-time 6 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p/" 2>&1) || code="000"
        if [ "$code" = "000" ]; then
            printf 'DOWN: 127.0.0.1:%s\n' "$p"
            ok=1
        else
            printf 'up: 127.0.0.1:%s (%s)\n' "$p" "$code"
        fi
    done
    return "$ok"
}

main() {
    printf '=== fix-docker-network.sh ===\n'
    if [ "$(id -u)" -ne 0 ]; then
        printf 'FAIL: run with sudo (firewall + daemon need root)\n'
        return 1
    fi
    if probe; then
        printf 'PASS: all mapped ports answer — nothing to fix\n'
        return 0
    fi
    printf '\nWARNING: this restarts the docker daemon. ALL containers stop\n'
    printf 'and restart (running agent turns die). Savepoint first.\n'
    printf 'Type YES to proceed: '
    read -r answer
    if [ "$answer" != "YES" ]; then
        printf 'aborted (no changes made)\n'
        return 2
    fi
    if ! systemctl restart docker; then
        printf 'FAIL: systemctl restart docker failed\n'
        return 1
    fi
    printf 'daemon restarted; waiting 30s for containers...\n'
    sleep 30
    docker ps --format '{{.Names}} {{.Status}}'
    if probe; then
        printf 'PASS: port path recovered\n'
        return 0
    fi
    printf 'FAIL: ports still unreachable — reboot the host next\n'
    return 1
}

main "$@"
