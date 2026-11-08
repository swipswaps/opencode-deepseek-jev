#!/usr/bin/env bash
#
# web-health.sh - redundant watchdog for the opencode-web access plane.
#
# The start path is already bind-address-proof (caddy publishes on the
# wildcard address), so the remaining failure to recover from is a *change*
# while running: the laptop roams, the LAN IP changes, the TLS SANs go stale,
# or a container dies. This script:
#   1. runs docker/certs-init.sh (idempotent; prints ROTATED only on a SAN
#      gap, e.g. a new DHCP address) and restarts caddy when it rotates;
#   2. probes :4096/:5099 on loopback AND every present client interface
#      (Nebula 10.x, Tailscale 100.x, default LAN);
#   3. if any path is down, runs scripts/web.sh once and re-probes.
#
# Safe for a systemd timer: normally read-only, repairs only when needed.
#
#   ./scripts/web-health.sh [--quiet] [--self-test]
#
# Exit 0 healthy or recovered, 2 still down.
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
set -uo pipefail

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

have() { command -v "$1" >/dev/null; }

http_code() {
    curl -sk -m 12 -o /dev/null -w '%{http_code}' "$1" 2>&1
}

client_ips() {
    local default_if=""
    default_if="$(ip route show default 2>&1 | awk '{print $5; exit}')"
    { ip -brief -4 addr show nebula0 2>&1
      ip -brief -4 addr show tailscale0 2>&1
      if [ -n "$default_if" ]; then ip -brief -4 addr show "$default_if" 2>&1; fi
    } | awk '{for (i=3; i<=NF; i++) {split($i,a,"/"); if (a[1] ~ /^[0-9]+\./) print a[1]}}' | sort -u
}

healthy_on() {
    # healthy_on IP -> 0 when :4096 is 200/401 and :5099 is 200
    local ip="$1" c4 c5
    c4="$(http_code "https://$ip:4096/api/health")"
    c5="$(http_code "https://$ip:5099/api/health")"
    case "$c4" in 200|401) ;; *) return 1 ;; esac
    case "$c5" in 200) ;; *) return 1 ;; esac
    return 0
}

self_test() {
    local fail=0
    grep -q 'docker/certs-init.sh' "${BASH_SOURCE[0]}" || { printf 'FAIL certs-init reference\n'; fail=1; }
    grep -q 'scripts/web.sh' "${BASH_SOURCE[0]}" || { printf 'FAIL web.sh recovery reference\n'; fail=1; }
    grep -q 'client_ips' "${BASH_SOURCE[0]}" || { printf 'FAIL client interface probe\n'; fail=1; }
    if [ "$fail" -eq 0 ]; then printf 'web-health: self-test PASS\n'; else printf 'web-health: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    local QUIET=0
    case "${1:-}" in
        "") ;;
        --quiet) QUIET=1 ;;
        --self-test) self_test; return "$?" ;;
        -h | --help)
            printf 'usage: %s [--quiet|--self-test]\n' "$0"
            return 0
            ;;
        *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
    esac
    log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    if ! have docker || ! have curl; then
        printf 'GATE FAIL: docker and curl are required\n'
        return 2
    fi

    # 1. Keep TLS SANs in step with the current network (stable CA, rotating
    #    server cert). A new DHCP/overlay address rotates and restarts caddy.
    local certout=""
    if [ -x "$REPO/docker/certs-init.sh" ]; then
        certout="$(bash "$REPO/docker/certs-init.sh" 2>&1)"
        case "$certout" in
            *ROTATED*)
                log "web-health: cert SANs rotated for the current network; restarting caddy"
                ( cd "$REPO/docker" && docker compose restart caddy ) || true
                ;;
        esac
    fi

    # 2. Probe loopback + every present client interface.
    local ips ip down=""
    ips="127.0.0.1 $(client_ips | tr '\n' ' ')"
    for ip in $ips; do
        if healthy_on "$ip"; then
            log "web-health: OK https://$ip:4096 (401/200) :5099=200"
        else
            down="$down $ip"
            log "web-health: DOWN https://$ip:4096 or :5099"
        fi
    done
    if [ -z "$down" ]; then
        return 0
    fi

    # 3. One bounded recovery: web.sh waits for IPs, starts compose, verifies.
    log "web-health: unreachable on:$down; running scripts/web.sh"
    mkdir -p /tmp/opencode 2>&1 || true
    bash "$REPO/scripts/web.sh" > /tmp/opencode/web-health-recover.log 2>&1
    local rc=$?
    log "web-health: web.sh rc=$rc (log /tmp/opencode/web-health-recover.log)"

    down=""
    ips="127.0.0.1 $(client_ips | tr '\n' ' ')"
    for ip in $ips; do
        healthy_on "$ip" || down="$down $ip"
    done
    if [ -z "$down" ]; then
        log "web-health: RECOVERED"
        return 0
    fi
    printf 'web-health: STILL DOWN on:%s\n' "$down"
    return 2
}

main "$@"
