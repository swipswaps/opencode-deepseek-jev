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
#      (Nebula 10.x, Tailscale 100.x, default LAN), with one short settle
#      retry so a caddy restart is not mistaken for a dead plane;
#   3. acts only on a *persisting* failure: a consecutive-failure threshold
#      plus a recovery cooldown. A single transient sample is reported, not
#      repaired. Without this a 2-minute timer self-induces a restart loop
#      (observed 2026-11-08: caddy restarting -> probe 000 -> web.sh re-run).
#   4. when action is due, delegates to the checkpointed, ledger-logged
#      resolver scripts/recover-4096.sh --recover (RULES #74), falling back
#      to scripts/web.sh on an older checkout. The recovery output is kept in
#      logs/ (durable), never only in /tmp (RULES: pasteability).
#
# Safe for a systemd timer: normally read-only; repairs only on a persisting
# failure that survives the threshold and the cooldown.
#
#   ./scripts/web-health.sh [--quiet] [--self-test]
#
# Exit 0 healthy, recovered, or deferred-but-observable; 2 still down after a
# recovery attempt. A deferred check is never reported as healthy.
#
# Tunables (env): WEB_HEALTH_FAIL_THRESHOLD (2), WEB_HEALTH_COOLDOWN_SEC (600),
# WEB_HEALTH_SETTLE_SEC (3), WEB_HEALTH_STATE (state file path),
# WEB_HEALTH_DRY (1 = print the recovery, do not run it).
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
# References:
#   systemd.timer(5): OnUnitInactiveSec measures from the previous FINISH, so
#     a long recovery cannot stack the next tick (OnUnitActiveSec drifts).
#   systemd user units cannot order after system network targets
#     (systemd/systemd#3312); the wait is done by polling here, not by After=.
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
    # http_code URL -> status code or 000. WEB_HEALTH_HTTP_CODE is a generic
    # test seam; WEB_HEALTH_EDGE_CODE / WEB_HEALTH_DASH_CODE override per
    # stratum so the dashboard-only path can be exercised offline.
    case "$1" in
        *:4096*) [ -n "${WEB_HEALTH_EDGE_CODE:-}" ] && { printf '%s' "$WEB_HEALTH_EDGE_CODE"; return 0; } ;;
        *:5099*) [ -n "${WEB_HEALTH_DASH_CODE:-}" ] && { printf '%s' "$WEB_HEALTH_DASH_CODE"; return 0; } ;;
    esac
    if [ -n "${WEB_HEALTH_HTTP_CODE:-}" ]; then
        printf '%s' "$WEB_HEALTH_HTTP_CODE"
        return 0
    fi
    curl -sk -m 12 -o /dev/null -w '%{http_code}' "$1" 2>&1
}

client_ips() {
    local default_if=""
    [ "${WEB_HEALTH_NO_CLIENT_IPS:-0}" = "1" ] && return 0
    have ip || return 0
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

read_state() {
    # read_state -> sets ST_COUNT and ST_LAST_RECOVERY (integers).
    ST_COUNT=0
    ST_LAST_RECOVERY=0
    [ -n "${STATE_FILE:-}" ] && [ -f "$STATE_FILE" ] || return 0
    while IFS='=' read -r k v; do
        case "$k" in
            count) ST_COUNT="${v:-0}" ;;
            last_recovery_epoch) ST_LAST_RECOVERY="${v:-0}" ;;
        esac
    done < "$STATE_FILE"
    case "$ST_COUNT" in '' | *[!0-9]*) ST_COUNT=0 ;; esac
    case "$ST_LAST_RECOVERY" in '' | *[!0-9]*) ST_LAST_RECOVERY=0 ;; esac
    return 0
}

write_state() {
    [ -n "${STATE_FILE:-}" ] || return 0
    mkdir -p "$(dirname "$STATE_FILE")" 2>&1 || return 0
    printf 'count=%s\nlast_recovery_epoch=%s\nlast_ts=%s\n' \
        "$ST_COUNT" "$ST_LAST_RECOVERY" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_FILE"
    return 0
}

decide() {
    # decide COUNT SECONDS_SINCE_LAST_RECOVERY -> prints recover|defer:<why>.
    # Returns 0 when recovery is due, 1 when it must wait. Pure, unit-tested.
    local count="$1" since="$2"
    if [ "$count" -lt "$THRESHOLD" ]; then
        printf 'defer:below-threshold(%s/%s)' "$count" "$THRESHOLD"
        return 1
    fi
    if [ "$since" -lt "$COOLDOWN" ]; then
        printf 'defer:cooldown(%ss/%ss)' "$since" "$COOLDOWN"
        return 1
    fi
    printf 'recover'
    return 0
}

self_test() {
    local fail=0 work="" o="" rc=0
    work=$(mktemp -d)
    export WEB_HEALTH_HTTP_CODE=200 WEB_HEALTH_SKIP_CERTS=1 WEB_HEALTH_SETTLE_SEC=0
    export WEB_HEALTH_NO_CLIENT_IPS=1 WEB_HEALTH_STATE="$work/state"
    export WEB_HEALTH_FAIL_THRESHOLD=2 WEB_HEALTH_COOLDOWN_SEC=999 WEB_HEALTH_DRY=1

    o=$(bash "${BASH_SOURCE[0]}" 2>&1)
    rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL healthy run rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'OK https://127.0.0.1:4096' \
        || { printf 'FAIL healthy run did not report OK\n'; fail=1; }

    export WEB_HEALTH_HTTP_CODE=000
    o=$(bash "${BASH_SOURCE[0]}" 2>&1)
    rc=$?
    [ "$rc" -eq 2 ] || { printf 'FAIL first down run rc=%s (want 2)\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'defer:below-threshold(1/2)' \
        || { printf 'FAIL threshold defer wording\n'; fail=1; }
    [ -f "$WEB_HEALTH_STATE" ] || { printf 'FAIL state not written\n'; fail=1; }

    o=$(bash "${BASH_SOURCE[0]}" 2>&1)
    rc=$?
    [ "$rc" -eq 2 ] || { printf 'FAIL threshold-crossed run rc=%s (want 2)\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'dry: would run' \
        || { printf 'FAIL recovery not attempted at threshold\n'; fail=1; }

    o=$(bash "${BASH_SOURCE[0]}" 2>&1)
    rc=$?
    [ "$rc" -eq 2 ] || { printf 'FAIL cooldown run rc=%s (want 2)\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'defer:cooldown' \
        || { printf 'FAIL cooldown not applied after a recovery\n'; fail=1; }

    export WEB_HEALTH_HTTP_CODE=200
    o=$(bash "${BASH_SOURCE[0]}" 2>&1)
    rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL recovery-clear run rc=%s (want 0)\n' "$rc"; fail=1; }
    grep -q '^count=0$' "$WEB_HEALTH_STATE" \
        || { printf 'FAIL failure counter not cleared on health\n'; fail=1; }

    # dashboard-only: edge healthy, :5099 upstream down -> relaunch (dry here)
    unset WEB_HEALTH_HTTP_CODE
    export WEB_HEALTH_EDGE_CODE=401 WEB_HEALTH_DASH_CODE=000
    o=$(bash "${BASH_SOURCE[0]}" 2>&1)
    printf '%s' "$o" | grep -q 'edge up but dashboard down' \
        || { printf 'FAIL dashboard-only detection\n'; fail=1; }
    printf '%s' "$o" | grep -q 'dry: would relaunch the dashboard' \
        || { printf 'FAIL dashboard-only dry\n'; fail=1; }
    unset WEB_HEALTH_EDGE_CODE WEB_HEALTH_DASH_CODE

    rm -f "$WEB_HEALTH_STATE"
    rmdir "$work"
    if [ "$fail" -eq 0 ]; then
        printf 'web-health: self-test PASS (threshold + cooldown + clear + dashboard-only)\n'
    else
        printf 'web-health: self-test FAIL\n'
    fi
    return "$fail"
}

attempt_recovery() {
    # attempt_recovery -> runs the resolver, keeps its output in logs/.
    local log="" rc=0
    log="$REPO/logs/web-health-recover-$(date -u +%Y%m%dT%H%M%SZ).log"
    if [ "${WEB_HEALTH_DRY:-0}" = "1" ]; then
        printf 'web-health: dry: would run %s (log would be %s)\n' "$RECOVER_CMD" "$log"
        return 0
    fi
    mkdir -p "$REPO/logs" 2>&1 || true
    if [ -x "$REPO/scripts/recover-4096.sh" ]; then
        bash "$REPO/scripts/recover-4096.sh" --recover > "$log" 2>&1
    else
        bash "$REPO/scripts/web.sh" > "$log" 2>&1
    fi
    rc=$?
    printf 'web-health: recovery rc=%s (log %s)\n' "$rc" "$log"
    return "$rc"
}

relaunch_dashboard() {
    # The dashboard is a background child of PID 1 with no supervisor. Replace
    # just that process when only :5099 is down; a full container restart would
    # also drop the opencode session.
    local container="${WEB_HEALTH_CONTAINER:-opencode-deepseek-web}"
    have docker || return 1
    docker exec "$container" sh -c 'for d in /proc/[0-9]*; do c=$(cat "$d/comm" 2>&1) || continue; [ "$c" = node ] || continue; tr "\000" " " < "$d/cmdline" 2>&1 | grep -q dashboard.mjs && kill -TERM "${d#/proc/}"; done' 2>&1 || true
    sleep 1
    docker exec -d "$container" sh -c 'node --no-warnings --experimental-sqlite /workspace/scripts/dashboard.mjs /home/node/.local/share/opencode/opencode.db 5099 0.0.0.0 /workspace/scripts/audit-config.sh >>/tmp/dashboard.log 2>&1' 2>&1 || return 1
    sleep 4
    return 0
}

print_recovery_cmds() {
    printf 'recovery commands:\n'
    printf '  ./scripts/recovery-status.sh                 # one-screen: broken / still working / next\n'
    printf '  ./scripts/recover-4096.sh --recover          # bounded recovery (writes logs/)\n'
    printf '  ./scripts/web.sh                             # rebuild/start the opencode-web access plane\n'
    printf '  docker compose -f docker/docker-compose.yml logs --tail=40 opencode-web caddy\n'
    printf '  ./scripts/web-health.sh                      # re-probe after the fix\n'
}

probe_all() {
    # probe_all IPS -> sets DOWN_IPS (space separated) and logs each result.
    local ips="$1" ip
    DOWN_IPS=""
    for ip in $ips; do
        if healthy_on "$ip"; then
            log "web-health: OK https://$ip:4096 (401/200) :5099=200"
        else
            DOWN_IPS="$DOWN_IPS $ip"
            log "web-health: DOWN https://$ip:4096 or :5099"
        fi
    done
    DOWN_IPS="${DOWN_IPS# }"
    return 0
}

main() {
    local QUIET=0
    RECOVER_CMD="scripts/recover-4096.sh --recover"
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

    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    # Offline seams (self-test / dry run) need neither the network nor docker.
    if [ -z "${WEB_HEALTH_HTTP_CODE:-}" ] && ! have curl; then
        printf 'GATE FAIL: curl is required to probe the access plane\n'
        return 2
    fi
    if [ -z "${WEB_HEALTH_HTTP_CODE:-}" ] && [ "${WEB_HEALTH_DRY:-0}" != "1" ] && ! have docker; then
        printf 'GATE FAIL: docker is required for recovery\n'
        return 2
    fi

    THRESHOLD="${WEB_HEALTH_FAIL_THRESHOLD:-2}"
    COOLDOWN="${WEB_HEALTH_COOLDOWN_SEC:-600}"
    SETTLE="${WEB_HEALTH_SETTLE_SEC:-3}"
    STATE_FILE="${WEB_HEALTH_STATE:-$REPO/data/observability/web-health.state}"
    case "$THRESHOLD" in '' | *[!0-9]*) THRESHOLD=2 ;; esac
    case "$COOLDOWN" in '' | *[!0-9]*) COOLDOWN=600 ;; esac
    case "$SETTLE" in '' | *[!0-9]*) SETTLE=3 ;; esac
    if [ ! -x "$REPO/scripts/recover-4096.sh" ]; then
        RECOVER_CMD="scripts/web.sh"
    fi

    # 1. Keep TLS SANs in step with the current network (stable CA, rotating
    #    server cert). A new DHCP/overlay address rotates and restarts caddy.
    if [ "${WEB_HEALTH_SKIP_CERTS:-0}" != "1" ] && [ -x "$REPO/docker/certs-init.sh" ]; then
        local certout=""
        certout="$(bash "$REPO/docker/certs-init.sh" 2>&1)"
        case "$certout" in
            *ROTATED*)
                log "web-health: cert SANs rotated for the current network; restarting caddy"
                ( cd "$REPO/docker" && docker compose restart caddy ) || true
                ;;
        esac
    fi

    # 2. Probe loopback + every present client interface.
    local ips now since decision
    ips="127.0.0.1 $(client_ips | tr '\n' ' ')"
    probe_all "$ips"
    if [ -z "$DOWN_IPS" ]; then
        read_state
        if [ "$ST_COUNT" -ne 0 ]; then
            ST_COUNT=0
            write_state
        fi
        return 0
    fi

    # Dashboard-only: the edge answers but the :5099 upstream does not. Replace
    # just the unsupervised dashboard child instead of restarting the plane.
    if [ -n "$DOWN_IPS" ]; then
        local e_code="" d_code=""
        e_code="$(http_code "https://127.0.0.1:4096/api/health")"
        d_code="$(http_code "https://127.0.0.1:5099/api/health")"
        if { [ "$e_code" = "200" ] || [ "$e_code" = "401" ]; } && [ "$d_code" != "200" ]; then
            if [ "${WEB_HEALTH_DRY:-0}" = "1" ]; then
                log "web-health: edge up but dashboard down ($d_code); dry: would relaunch the dashboard"
            else
                log "web-health: edge up but dashboard down ($d_code); relaunching the dashboard (no container restart)"
                if relaunch_dashboard; then
                    sleep 2
                    probe_all "$ips"
                    if [ -z "$DOWN_IPS" ]; then
                        log "web-health: RECOVERED (dashboard relaunched)"
                        read_state
                        ST_COUNT=0
                        write_state
                        return 0
                    fi
                else
                    log "web-health: dashboard relaunch failed; falling back to $RECOVER_CMD"
                fi
            fi
        fi
    fi

    # A caddy restart turns both probes into 000 for a moment. One settle
    # retry absorbs that instead of triggering a recovery from one sample.
    if [ "$SETTLE" -gt 0 ]; then
        sleep "$SETTLE"
    fi
    probe_all "$DOWN_IPS"
    if [ -z "$DOWN_IPS" ]; then
        log "web-health: recovered after settle (transient restart absorbed)"
        read_state
        ST_COUNT=0
        write_state
        return 0
    fi

    # 3. Persisting failure: require a consecutive count and a cooldown
    #    before acting. The count is durable so a 2-min timer cannot loop.
    read_state
    ST_COUNT=$((ST_COUNT + 1))
    now=$(date +%s)
    since=$((now - ST_LAST_RECOVERY))
    [ "$since" -lt 0 ] && since=999999
    if decision=$(decide "$ST_COUNT" "$since"); then
        :
    else
        log "web-health: DOWN on:$DOWN_IPS ($decision); no action taken"
        write_state
        return 2
    fi

    log "web-health: unreachable on:$DOWN_IPS; running $RECOVER_CMD"
    attempt_recovery
    ST_LAST_RECOVERY=$now

    # 4. Re-probe; only a clean sweep clears the counter.
    ips="127.0.0.1 $(client_ips | tr '\n' ' ')"
    probe_all "$ips"
    if [ -z "$DOWN_IPS" ]; then
        ST_COUNT=0
        write_state
        log "web-health: RECOVERED"
        return 0
    fi
    write_state
    printf 'web-health: STILL DOWN on:%s\n' "$DOWN_IPS"
    print_recovery_cmds
    return 2
}

main "$@"
