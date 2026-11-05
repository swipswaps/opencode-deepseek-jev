#!/usr/bin/env bash
# https-selfheal.sh — check and repair the local HTTPS/CA/Caddy path.
#
# Run on the host. It verifies cert SANs, 443/5099, Caddy, the CA download,
# CORS/PNA headers, and dashboard APIs. With --fix it reissues a missing SAN
# cert, recreates caddy, and restarts the dashboard; --watch keeps monitoring.
#
#   ./scripts/https-selfheal.sh --check
#   ./scripts/https-selfheal.sh --fix
#   ./scripts/https-selfheal.sh --fix --watch
#   ./scripts/https-selfheal.sh --open
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CADDY="${CADDY:-opencode-caddy}"
CA="$REPO/docker/certs/ca.crt"
CRT="$REPO/docker/certs/opencode.crt"
BASE="${BASE:-https://10.100.0.24:5099}"
FIX=0
WATCH=0
OPEN=0
JSON=0
INTERVAL="${INTERVAL:-60}"

usage() {
    printf '%s\n' \
        'Usage: https-selfheal.sh [--check|--fix] [--watch] [--open] [--json]' \
        '  --check   monitor only (default)' \
        '  --fix     reissue/reload/restart on failure' \
        '  --watch   monitor until interrupted (INTERVAL=60)' \
        '  --open    xdg-open the live app after a healthy check' \
        '  --json    one JSON object per check'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) FIX=0 ;;
        --fix) FIX=1 ;;
        --watch) WATCH=1 ;;
        --open) OPEN=1 ;;
        --json) JSON=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

log() { printf 'ts=%s level=INFO %s\n' "$(date -u +%H:%M:%S)" "$*"; }

have() { command -v "$1" > /dev/null; }

ips() {
    local out="127.0.0.1" addrs iface a
    for iface in nebula0 tailscale0; do
        addrs="$(ip -brief -4 addr show "$iface" 2>&1)"
        for a in $(printf '%s\n' "$addrs" | awk '{for (i=3; i<=NF; i++) {split($i,b,"/"); if (b[1] ~ /^[0-9]+\./) print b[1]}}'); do
            out="$out $a"
        done
    done
    iface="$(ip route show default 2>&1 | awk '{print $5; exit}')"
    if [ -n "$iface" ]; then
        addrs="$(ip -brief -4 addr show "$iface" 2>&1)"
        for a in $(printf '%s\n' "$addrs" | awk '{for (i=3; i<=NF; i++) {split($i,b,"/"); if (b[1] ~ /^[0-9]+\./) print b[1]}}'); do
            out="$out $a"
        done
    fi
    printf '%s\n' $out | sort -u
}

cert_missing() {
    [ -f "$CRT" ] || return 0
    local sans need ip
    sans="$(openssl x509 -in "$CRT" -noout -ext subjectAltName 2>&1)"
    need="localhost 127.0.0.1 $(ips)"
    for ip in $need; do
        case "$sans" in *"$ip"*) ;; *) return 0 ;; esac
    done
    return 1
}

caddy_running() {
    docker inspect -f '{{.State.Status}}' "$CADDY" 2>&1 | grep -q '^running$'
}

restart_caddy() {
    log "restarting caddy"
    (cd "$REPO/docker" && docker compose up -d --force-recreate caddy)
    sleep 3
}

heal() {
    log "self-heal start"
    if cert_missing; then
        log "reissuing cert for local SANs"
        (cd "$REPO" && ./docker/certs-init.sh)
        restart_caddy
    fi
    if caddy_running; then
        log "reloading caddy"
        (cd "$REPO/docker" && docker compose restart caddy)
        sleep 2
    else
        restart_caddy
    fi
    local code
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$BASE/api/rev" 2>&1)"
    if [ "$code" != "200" ]; then
        log "dashboard API unavailable; restarting dashboard"
        (cd "$REPO" && ./scripts/dashboard-restart.sh)
    fi
    log "self-heal complete"
}

check() {
    local fail=0 code url ip port hdr
    [ -f "$CA" ] || { log "FAIL missing CA $CA"; fail=1; }
    [ -f "$CRT" ] || { log "FAIL missing cert $CRT"; fail=1; }
    if cert_missing; then log "FAIL cert SANs incomplete"; fail=1; else log "PASS cert SANs"; fi
    if caddy_running; then log "PASS caddy running"; else log "FAIL caddy not running"; fail=1; fi
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$BASE/ca.crt" 2>&1)"
    if [ "$code" = "200" ]; then log "PASS CA download"; else log "FAIL CA download HTTP $code"; fail=1; fi
    for ip in $(ips); do
        for port in 443 5099; do
            url="https://$ip:$port/app/"
            code="$(curl -s --cacert "$CA" -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>&1)"
            if [ "$code" = "200" ]; then log "PASS $url"; else log "FAIL $url HTTP $code"; fail=1; fi
        done
    done
    url="$BASE/api/rev"
    code="$(curl -s --cacert "$CA" -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>&1)"
    if [ "$code" = "200" ]; then log "PASS dashboard API"; else log "FAIL dashboard API HTTP $code"; fail=1; fi
    hdr="$(curl -sk -D - -o /dev/null -X OPTIONS -H 'Origin: https://swipswaps.github.io' -H 'Access-Control-Request-Private-Network: true' "$BASE/api/rev" 2>&1)"
    if printf '%s' "$hdr" | grep -qi 'access-control-allow-private-network: true'; then
        log "PASS CORS/PNA preflight"
    else
        log "FAIL CORS/PNA preflight"; fail=1
    fi
    if [ "$JSON" -eq 1 ]; then
        printf '{"ok":%s,"base":"%s","fix":%s}\n' "$([ "$fail" -eq 0 ] && printf true || printf false)" "$BASE" "$FIX"
    fi
    return "$fail"
}

run_once() {
    if check; then
        if [ "$OPEN" -eq 1 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            xdg-open "$BASE/app/" > /dev/null 2>&1 &
        fi
        return 0
    fi
    if [ "$FIX" -eq 1 ]; then
        heal
        check
        return $?
    fi
    return 1
}

if ! have docker; then log "FAIL docker missing (host-only)"; exit 2; fi
if [ "$FIX" -eq 1 ] && ! caddy_running; then heal; fi
if [ "$WATCH" -eq 0 ]; then
    run_once
    exit $?
fi
while :; do
    run_once
    sleep "$INTERVAL"
done
