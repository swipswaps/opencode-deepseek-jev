#!/usr/bin/env bash
#
# diag-opencode-web.sh - read-only diagnosis of the opencode-web access plane.
#
# What it answers
# ---------------
# "opencode-web is not running" is usually a *reachability* claim, not a
# process claim. This script measures each hop instead of guessing:
#
#   docker container state  ->  upstream :4096/:5099 inside the container
#   ->  proxy (caddy) state ->  published host ports -> host/LAN/Tailscale probe
#
# It also records the startup failures that are adjacent to the web plane
# (failed user units, the deepseek-harness restart loop) and delegates the
# chat-store audit to scripts/diag-opencode-store.py.
#
# Contract
# --------
# * Read-only: never starts, stops, restarts, recreates or removes anything.
# * Writes exactly one report under logs/ (the telemetry you asked for).
# * Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null. No subprocess.run.
#
# Usage
# -----
#   bash scripts/diag-opencode-web.sh [--help]
#
# Exit: 0 end-to-end reachable, 2 upstream down, 3 upstream up but unreachable
#       through the proxy, 4 could not determine.
#
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$REPO/logs"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$LOG_DIR/diag-opencode-web-$TS.log"
DOCKER="docker"
WEB_CT=opencode-deepseek-web
CADDY_CT=opencode-caddy
WEB_4096="http://127.0.0.1:4096/api/health"
WEB_5099="http://127.0.0.1:5099/api/health"
HOST_4096="https://127.0.0.1:4096/api/health"
HOST_5099="https://127.0.0.1:5099/api/health"

section() { printf '\n== %s ==\n' "$1"; }
info() { printf '  %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; }
ok() { printf '  OK    %s\n' "$1"; }

have() { command -v "$1" >/dev/null; }

http_code() {
    # http_code URL [insecure] -> status code or 000
    if [ "${2:-}" = "insecure" ]; then
        curl -sk -m 5 -o /dev/null -w '%{http_code}' "$1" 2>&1
    else
        curl -s -m 5 -o /dev/null -w '%{http_code}' "$1" 2>&1
    fi
}

usage() {
    printf 'usage: %s [--help]\n\n' "$0"
    printf 'Read-only diagnosis of why opencode-web is unreachable.\n'
    printf 'Writes one report to logs/diag-opencode-web-<utc>.log.\n'
}

main() {
    local rc=0
    local upstream_ok=0 caddy_ok=0 host_ok=0

    case "${1:-}" in
        "") ;;
        *)
            printf 'unknown arg: %s (try --help)\n' "$1"
            return 2
            ;;
    esac

    if ! have docker; then
        printf 'GATE FAIL: docker not found\n'
        return 4
    fi
    if ! have curl; then
        printf 'GATE FAIL: curl not found\n'
        return 4
    fi
    mkdir -p "$LOG_DIR"

    printf '=== diag-opencode-web @ %s ===\n' "$TS"
    printf 'repo: %s\n' "$REPO"

    section "1. container state"
    $DOCKER ps -a --filter "name=$WEB_CT" --filter "name=$CADDY_CT" \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>&1
    local web_status caddy_status
    web_status="$($DOCKER inspect -f '{{.State.Status}}' "$WEB_CT" 2>&1)"
    caddy_status="$($DOCKER inspect -f '{{.State.Status}}' "$CADDY_CT" 2>&1)"
    info "opencode-web: $web_status"
    info "caddy (only host-port publisher): $caddy_status"

    if [ "$web_status" = "running" ]; then
        ok "opencode-web process is running (the claim 'not running' is about reachability)"
    else
        bad "opencode-web container is not running"
        rc=2
    fi
    if [ "$caddy_status" = "running" ]; then
        caddy_ok=1
        ok "caddy is running"
    else
        bad "caddy is not running (no host port 4096/5099 can be served)"
        rc=3
    fi

    section "2. upstream health inside the container (bypasses proxy)"
    if [ "$web_status" = "running" ]; then
        local c4096 c5099
        c4096="$($DOCKER exec "$WEB_CT" curl -s -m 5 -o /dev/null -w '%{http_code}' "$WEB_4096" 2>&1)"
        c5099="$($DOCKER exec "$WEB_CT" curl -s -m 5 -o /dev/null -w '%{http_code}' "$WEB_5099" 2>&1)"
        info "web  :4096 -> $c4096 (401 = up and auth-gated, expected)"
        info "dash :5099 -> $c5099 (200 = up)"
        if [ "$c4096" = "401" ] || [ "$c4096" = "200" ]; then
            upstream_ok=1
            ok "opencode server is listening on :4096"
        else
            bad "opencode server is not answering on :4096"
            rc=2
        fi
        if [ "$c5099" = "200" ]; then
            ok "observability dashboard is listening on :5099"
        else
            warn "dashboard is not answering on :5099"
        fi
    else
        warn "skipped: container not running"
    fi

    section "3. proxy failure evidence"
    local caddy_err caddy_exit caddy_started caddy_finished
    caddy_err="$($DOCKER inspect -f '{{.State.Error}}' "$CADDY_CT" 2>&1)"
    caddy_exit="$($DOCKER inspect -f '{{.State.ExitCode}}' "$CADDY_CT" 2>&1)"
    caddy_started="$($DOCKER inspect -f '{{.State.StartedAt}}' "$CADDY_CT" 2>&1)"
    caddy_finished="$($DOCKER inspect -f '{{.State.FinishedAt}}' "$CADDY_CT" 2>&1)"
    info "exit=$caddy_exit started=$caddy_started finished=$caddy_finished"
    if [ -n "$caddy_err" ] && [ "$caddy_err" != "<no value>" ]; then
        bad "caddy state error: $caddy_err"
    else
        info "no recorded caddy state error"
    fi

    local bind_evidence
    bind_evidence="$($DOCKER logs --tail 400 "$CADDY_CT" 2>&1 | grep -iE 'failed to bind|EADDRNOTAVAIL|cannot assign requested address' | tail -n 5)"
    if [ -n "$bind_evidence" ]; then
        bad "host-port bind failure in caddy log:"
        printf '%s\n' "$bind_evidence" | while IFS= read -r line; do printf '        %s\n' "$line"; done
    else
        info "no host-port bind failure in the last 400 caddy log lines"
    fi

    section "4. declared bind IPs vs addresses actually present on the host"
    local bind_json distinct_ips ip present missing=0
    bind_json="$($DOCKER inspect -f '{{json .HostConfig.PortBindings}}' "$CADDY_CT" 2>&1)"
    distinct_ips="$(printf '%s' "$bind_json" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
ips=sorted({b.get("HostIp","") for v in (d or {}).values() for b in (v or []) if b.get("HostIp")})
print("\n".join(ips))
' 2>&1)"
    if [ -z "$distinct_ips" ]; then
        warn "could not read caddy PortBindings (container may be absent)"
    else
        for ip in $distinct_ips; do
            if ip -o addr show | grep -qF " $ip/"; then present=1; else present=0; missing=$((missing + 1)); fi
            info "$ip -> $([ "$present" = 1 ] && printf PRESENT || printf MISSING)"
        done
        if [ "$missing" -gt 0 ]; then
            bad "$missing declared bind IP(s) absent: Docker cannot publish those ports (EADDRNOTAVAIL)"
        else
            ok "every declared bind IP is present now; a caddy restart would likely succeed"
        fi
    fi

    section "5. published host ports and listeners"
    local host4096 host5099
    host4096="$(http_code "$HOST_4096" insecure)"
    host5099="$(http_code "$HOST_5099" insecure)"
    info "host https://127.0.0.1:4096 -> $host4096"
    info "host https://127.0.0.1:5099 -> $host5099"
    local listeners
    listeners="$(ss -ltn 2>&1 | grep -E ':(4096|5099)[[:space:]]' || true)"
    if [ -z "$listeners" ]; then
        bad "no host listener on 4096/5099"
    else
        printf '%s\n' "$listeners" | while IFS= read -r line; do printf '        %s\n' "$line"; done
    fi
    if [ "$host4096" != "000" ]; then
        host_ok=1
        ok "opencode-web is reachable from the host"
    else
        bad "opencode-web is NOT reachable from the host"
    fi

    section "6. adjacent startup failures (system and user units)"
    local failed_user failed_sys
    failed_user="$(systemctl --user --failed --no-pager 2>&1 | grep -iE 'opencode|deepseek|harness|caddy|web' || true)"
    failed_sys="$(systemctl --failed --no-pager 2>&1 | grep -iE 'opencode|deepseek|harness|caddy|web' || true)"
    if [ -n "$failed_user" ]; then printf '  user units:\n%s\n' "$failed_user"; else info "no failed user units matching opencode/web"; fi
    if [ -n "$failed_sys" ]; then printf '  system units:\n%s\n' "$failed_sys"; else info "no failed system units matching opencode/web"; fi

    local h_exec h_active h_opt
    h_exec="$(systemctl --user show -p ExecStart --value deepseek-harness.service 2>&1)"
    h_active="$(systemctl --user is-active deepseek-harness.service 2>&1)"
    h_opt="$(journalctl --user -u deepseek-harness.service -n 60 --no-pager 2>&1 | grep -m1 "unknown option" || true)"
    if printf '%s' "$h_exec" | grep -q -- '--no-window'; then
        bad "deepseek-harness ExecStart still passes --no-window; 'dsh web' accepts --no-open"
    elif [ "$h_active" != "active" ]; then
        bad "deepseek-harness is $h_active (last error: ${h_opt:-none in last 60 lines})"
    else
        ok "deepseek-harness active with a valid flag"
    fi

    section "7. chat-store telemetry (read-only)"
    python3 "$REPO/scripts/diag-opencode-store.py" --db "$REPO/data/opencode/opencode.db" 2>&1
    local store_rc=$?
    info "store helper exit: $store_rc (3 = readable with stuck/errored tool parts)"

    section "8. verdict"
    if [ "$web_status" != "running" ] || [ "$upstream_ok" != 1 ]; then
        bad "UPSTREAM_DOWN: opencode server itself is not serving; fix the container first"
        rc=2
    elif [ "$caddy_ok" != 1 ]; then
        bad "PROXY_DOWN: opencode-web is healthy on the compose network, but caddy - the only publisher of 4096/5099 - is not running"
        rc=3
    elif [ "$host_ok" != 1 ]; then
        bad "PROXY_UNREACHABLE: caddy runs but host probes fail; check published ports/bind IPs"
        rc=3
    else
        ok "REACHABLE: opencode-web is served end-to-end"
        rc=0
    fi

    section "9. suggested remediation (NOT executed by this read-only script)"
    printf '%s\n' \
        "  # a) recover the proxy now that the bind IPs may be present:" \
        "  ( cd \"$REPO/docker\" && docker compose up -d caddy )" \
        "  # b) verify:" \
        "  curl -sk https://127.0.0.1:4096/api/health" \
        "  # c) prevent recurrence: make caddy start after the tunnel IP exists" \
        "  #    (systemd After/Requires=tailscaled.service) or stop publishing the" \
        "  #    volatile Tailscale IP in docker-compose.yml and reach it via the tunnel." \
        "  # d) fix the harness loop:" \
        "  #    replace '--no-window' with '--no-open' in" \
        "  #    ~/.config/systemd/user/deepseek-harness.service" \
        "  #    then: systemctl --user daemon-reload && systemctl --user restart deepseek-harness.service"

    printf '\nreport: %s\n' "$REPORT"
    return "$rc"
}

# The only write is the report; display and log are the same stream.
case "${1:-}" in
    -h | --help) usage ;;
    *) main "$@" 2>&1 | tee "$REPORT" ;;
esac
