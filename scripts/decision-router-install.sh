#!/usr/bin/env bash
#
# decision-router-install.sh — run the Laya/SubQ System One router and point
# jev-guard at it.
#
# Laya (local, free) and SubQ (remote, paid) share POST /v1/systemone.
# decision-router.py chooses by measured reliability + cost, fails over, and
# records every attempt in data/observability/observability.db. jev-guard has
# one JEV_BASE_URL, so it points here instead of directly at Laya.
#
#   ./scripts/decision-router-install.sh              # install + wire guard
#   ./scripts/decision-router-install.sh --no-wire    # install only
#   ./scripts/decision-router-install.sh --uninstall
#   ./scripts/decision-router-install.sh --self-test
#
# Host-only. The unit binds the docker bridge gateway (not 0.0.0.0). Keys come
# from the Laya unit and .env.local; the router env file is 0600.
#
# Exit 0 installed/wired, 2 setup/probe failure.
#
set -o pipefail

PORT=8010
GWARG=""
WIRE=1
ACTION="install"

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

have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n=== %s ===\n' "$1"; }

main() {
    local REPO ENVDIR ENVF UNIT PY GW LKEY SKEY CODE i
    while [ $# -gt 0 ]; do
        case "$1" in
            --port) PORT="${2:-8010}"; shift 2 ;;
            --gateway) GWARG="${2:-}"; shift 2 ;;
            --no-wire) WIRE=0; shift ;;
            --uninstall) ACTION="uninstall"; shift ;;
            --self-test) ACTION="self-test"; shift ;;
            -h | --help) printf 'usage: %s [--port N] [--gateway IP] [--no-wire] [--uninstall] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done

    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then printf 'FAIL: cannot resolve repo root\n'; return 2; fi

    if [ "$ACTION" = "self-test" ]; then
        python3 "$REPO/scripts/decision-router.py" --self-test
        return "$?"
    fi

    ENVDIR="$HOME/.config/decision-router"
    ENVF="$ENVDIR/env"
    UNIT="$HOME/.config/systemd/user/decision-router.service"

    if [ "$ACTION" = "uninstall" ]; then
        systemctl --user disable --now decision-router.service 2>&1 || true
        rm -f "$UNIT" "$ENVF"
        systemctl --user daemon-reload 2>&1 || true
        printf 'uninstalled decision-router.service (Laya untouched)\n'
        return 0
    fi

    section "preflight"
    printf 'repo: %s\n' "$REPO"
    have docker || { printf 'FAIL: docker missing (run on the host)\n'; return 2; }
    have systemctl || { printf 'FAIL: systemd missing\n'; return 2; }
    PY=$(command -v python3)
    [ -n "$PY" ] || { printf 'FAIL: python3 missing\n'; return 2; }
    if [ -z "$GWARG" ]; then
        GW=$("$REPO/scripts/laya-wire.sh" --gateways | head -n 1)
        [ -n "$GW" ] || { printf 'FAIL: no docker gateway; is opencode-deepseek-web running?\n'; return 2; }
    else
        GW="$GWARG"
    fi
    printf 'bind: %s:%s\n' "$GW" "$PORT"

    section "keys"
    LKEY=$(awk -F= '/^Environment=LAYA_API_KEY=/{print $3; exit}' "$HOME/.config/systemd/user/laya-serve.service" 2>&1)
    if [ -z "$LKEY" ]; then
        printf 'WARN: no LAYA_API_KEY in laya-serve.service (keyless Laya?)\n'
    else
        printf 'LAYA_API_KEY: present (len %s)\n' "${#LKEY}"
    fi
    SKEY=$(awk -F= '$1=="SUBQ_API_KEY"{print substr($0, index($0,"=")+1); exit}' "$REPO/.env.local" 2>&1)
    if [ -z "$SKEY" ]; then
        printf 'WARN: SUBQ_API_KEY missing; the paid fallback will 401\n'
    else
        printf 'SUBQ_API_KEY: present (len %s)\n' "${#SKEY}"
    fi

    section "unit + env"
    mkdir -p "$ENVDIR" "$HOME/.config/systemd/user"
    ( umask 077; cat > "$ENVF" <<ENV
LAYA_URL=http://$GW:8000/v1/systemone
LAYA_API_KEY=$LKEY
SUBQ_API_KEY=$SKEY
ENV
    )
    chmod 600 "$ENVF"
    ( umask 077; cat > "$UNIT" <<UNIT
[Unit]
Description=Decision router (Laya/SubQ System One)
After=network-online.target
[Service]
EnvironmentFile=$ENVF
ExecStart=$PY $REPO/scripts/decision-router.py --serve --host $GW --port $PORT
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target
UNIT
    )
    chmod 600 "$UNIT"
    systemctl --user daemon-reload
    systemctl --user enable --now decision-router.service || {
        printf 'FAIL: unit did not start; evidence:\n'
        systemctl --user status decision-router --no-pager -l 2>&1 | head -n 30
        journalctl --user -u decision-router -n 30 --no-pager 2>&1
        return 2
    }

    section "health"
    CODE=000
    for i in $(seq 1 20); do
        CODE=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://$GW:$PORT/healthz")
        [ "$CODE" = "200" ] && break
        sleep 1
    done
    printf 'healthz: %s\n' "$CODE"
    [ "$CODE" = "200" ] || {
        printf 'FAIL: router did not answer; evidence:\n'
        systemctl --user status decision-router --no-pager -l 2>&1 | head -n 30
        journalctl --user -u decision-router -n 30 --no-pager 2>&1
        return 2
    }
    curl -s "http://$GW:$PORT/healthz" | python3 -m json.tool 2>&1 | head -n 40

    if [ "$WIRE" -eq 1 ]; then
        section "wire jev-guard at the router"
        "$REPO/scripts/laya-wire.sh" --url "http://$GW:$PORT" --timeout 4000 --wire || return 2
    fi
    section "summary"
    printf 'router: http://%s:%s/v1/systemone\n' "$GW" "$PORT"
    printf 'order:  Laya (free) -> SubQ (paid fallback); Jev disabled\n'
    printf 'stats:  curl -s http://%s:%s/stats\n' "$GW" "$PORT"
    printf 'db:     %s\n' "$REPO/data/observability/observability.db"
    return 0
}

main "$@"
