#!/usr/bin/env bash
#
# laya-install.sh — install and run Laya, then wire jev-guard to it.
#
# Laya is the open-weights, Jev-API-compatible System One server (POST
# /v1/systemone). jev-guard honors JEV_BASE_URL, so this gives the guard a
# local, keyed backend without TypeSafe. The server binds the docker bridge
# gateway (not 0.0.0.0) so only the compose network can reach it.
#
#   ./scripts/laya-install.sh                 # venv + systemd user unit + wire
#   ./scripts/laya-install.sh --no-systemd    # background process instead
#   ./scripts/laya-install.sh --port 8000 --device cpu
#   ./scripts/laya-install.sh --gateway 172.28.0.1
#
# Host-only (needs docker + python3-venv). The first start downloads the English
# checkpoint; the probe waits up to 4 minutes. The key is generated here, stored
# in the 0600 unit file, and sent only to Laya (JEV_BASE_API_KEY).
#
# Exit 0 wired, 2 setup/probe failure. Plain ASCII. No sed. No rm -rf.
# No set -e. No 2>/dev/null. printf only.
#
set -o pipefail

PORT=8000
DEVICE=""
GWARG=""
PYARG=""
ALLOW314=0
SYSTEMD=1
PRELOAD=1

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
    local REPO VENV UNIT KEY GW CODE i
    while [ $# -gt 0 ]; do
        case "$1" in
            --port) PORT="${2:-8000}"; shift 2 ;;
            --device) DEVICE="${2:-}"; shift 2 ;;
            --gateway) GWARG="${2:-}"; shift 2 ;;
            --python) PYARG="${2:-}"; shift 2 ;;
            --allow-3.14) ALLOW314=1; shift ;;
            --no-systemd) SYSTEMD=0; shift ;;
            --lazy) PRELOAD=0; shift ;;
            -h | --help) printf 'usage: %s [--port N] [--device cpu|cuda] [--gateway IP] [--python PATH] [--allow-3.14] [--lazy] [--no-systemd]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done

    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then printf 'FAIL: cannot resolve repo root\n'; return 2; fi
    VENV="$HOME/.venvs/laya"
    UNIT="$HOME/.config/systemd/user/laya-serve.service"

    section "preflight"
    printf 'repo:   %s\n' "$REPO"
    printf 'venv:   %s\n' "$VENV"
    printf 'port:   %s\n' "$PORT"
    # Prefer a Python with published torch wheels (3.14 wheels lag); the
    # Laya/torch stack is the constraint, not the venv.
    local PY="$PYARG"
    if [ -z "$PY" ]; then
        for c in python3.12 python3.11 python3.10 python3.13 python3; do
            if have "$c"; then PY="$c"; break; fi
        done
    fi
    [ -n "$PY" ] || { printf 'FAIL: no python3 (need 3.10+)\n'; return 2; }
    local PYVER
    PYVER=$("$PY" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>&1)
    printf 'python: %s (%s)\n' "$PY" "$("$PY" --version 2>&1)"
    if [ -x "$VENV/bin/python" ]; then
        local VENVVER
        VENVVER=$("$VENV/bin/python" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>&1)
        if [ "$VENVVER" != "$PYVER" ]; then
            printf 'recreating venv: %s -> %s\n' "$VENVVER" "$PYVER"
            rm -r "$VENV" || { printf 'FAIL: cannot remove %s\n' "$VENV"; return 2; }
        fi
    fi
    case "$PYVER" in
        3.14)
            if [ "$ALLOW314" -ne 1 ]; then
                printf 'FAIL: Python %s is too new for the Laya/torch stack.\n' "$PYVER"
                printf '  install 3.12:  sudo apt install python3.12 python3.12-venv\n'
                printf '  or with uv:    uv python install 3.12 && %s --python "$(uv python find 3.12)"\n' "$0"
                printf '  override only if torch imports: %s --allow-3.14\n' "$0"
                return 2
            fi
            ;;
    esac
    have docker || { printf 'FAIL: docker missing (run on the host)\n'; return 2; }
    if [ -z "$GWARG" ]; then
        GW=$("$REPO/scripts/laya-wire.sh" --gateways | head -n 1)
        [ -n "$GW" ] || { printf 'FAIL: no docker gateway; is opencode-deepseek-web running?\n'; return 2; }
    else
        GW="$GWARG"
    fi
    printf 'bind:   %s:%s\n' "$GW" "$PORT"

    section "venv + pip install laya[serve]"
    if [ ! -x "$VENV/bin/laya-serve" ]; then
        "$PY" -m venv "$VENV" || { printf 'FAIL: venv; install python3-venv (sudo apt install python3-venv)\n'; return 2; }
        "$VENV/bin/pip" install --upgrade pip > "$REPO/logs/laya-pip.log" 2>&1 || true
        if ! "$VENV/bin/pip" install "laya[serve]" >> "$REPO/logs/laya-pip.log" 2>&1; then
            printf 'FAIL: pip install laya[serve]; tail:\n'
            tail -n 20 "$REPO/logs/laya-pip.log"
            return 2
        fi
    else
        printf 'already installed: %s\n' "$VENV/bin/laya-serve"
    fi
    printf 'laya version: %s\n' "$("$VENV/bin/python" -c 'import laya;print(laya.__version__)' 2>&1 | head -n 1)"

    KEY=$(python3 -c 'import secrets;print(secrets.token_hex(24))')

    section "start"
    if [ "$SYSTEMD" -eq 1 ] && have systemctl; then
        mkdir -p "$(dirname "$UNIT")"
        ( umask 077; cat > "$UNIT" <<UNIT
[Unit]
Description=Laya System One (Jev-compatible) for jev-guard
After=network-online.target
[Service]
Environment=LAYA_HOST=$GW
Environment=LAYA_PORT=$PORT
Environment=LAYA_API_KEY=$KEY
Environment=LAYA_PRELOAD=$PRELOAD
Environment=LAYA_MODELS=english
${DEVICE:+Environment=LAYA_DEVICE=$DEVICE}
ExecStart=$VENV/bin/laya-serve
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target
UNIT
        )
        chmod 600 "$UNIT"
        systemctl --user daemon-reload
        if systemctl --user enable --now laya-serve.service; then
            printf 'systemd user unit: laya-serve.service\n'
        else
            printf 'WARN: systemd --user failed; falling back to a background process\n'
            SYSTEMD=0
        fi
    else
        SYSTEMD=0
    fi
    if [ "$SYSTEMD" -eq 0 ]; then
        LAYA_HOST="$GW" LAYA_PORT="$PORT" LAYA_API_KEY="$KEY" LAYA_PRELOAD="$PRELOAD" LAYA_MODELS=english \
            ${DEVICE:+LAYA_DEVICE="$DEVICE"} \
            nohup "$VENV/bin/laya-serve" > "$REPO/logs/laya-serve.log" 2>&1 &
        printf 'background pid: %s (log %s)\n' "$!" "$REPO/logs/laya-serve.log"
    fi

    section "probe (first start may download the English checkpoint)"
    CODE=000
    for i in $(seq 1 120); do
        CODE=$(curl -s -m 3 -o /dev/null -w '%{http_code}' -X POST "http://$GW:$PORT/v1/systemone" \
            -H "Authorization: Bearer $KEY" -H 'content-type: application/json' \
            -d '{"state":"ping","model":"english","questions":[]}')
        case "$CODE" in 200|400|422) break ;; esac
        if [ $((i % 10)) -eq 0 ]; then printf '  %ss: http=%s\n' "$((i * 2))" "$CODE"; fi
        sleep 2
    done
    printf 'probe: %s\n' "$CODE"
    case "$CODE" in
        200|400|422) ;;
        *)
            printf 'FAIL: Laya did not answer. Evidence:\n'
            if [ "$SYSTEMD" -eq 1 ]; then
                systemctl --user status laya-serve --no-pager -l 2>&1 | head -n 30
                journalctl --user -u laya-serve -n 30 --no-pager 2>&1
            else
                tail -n 30 "$REPO/logs/laya-serve.log"
            fi
            ss -ltnp 2>&1 | grep -E ":$PORT\b" || printf 'nothing listening on :%s\n' "$PORT"
            return 2
            ;;
    esac

    section "wire jev-guard"
    "$REPO/scripts/laya-wire.sh" --url "http://$GW:$PORT" --key "$KEY" --wire || return 2

    section "summary"
    printf 'laya:  http://%s:%s/v1/systemone (key in %s)\n' "$GW" "$PORT" "$UNIT"
    printf 'guard: JEV_BASE_URL=http://%s:%s, JEV_MODEL=english, timeout 2000ms\n' "$GW" "$PORT"
    printf 'next:  ./scripts/test-jev-laya-ab.sh   (A/B against TypeSafe if its key is valid)\n'
    return 0
}

main "$@"
