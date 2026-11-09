#!/usr/bin/env bash
#
# overlay-status.sh - read-only audit of BOTH mesh planes, from either box.
#
# Audits this machine locally, then SSHes to the peer and audits it too, so a
# single command answers "is .24 healthy, is .1 healthy, and can they see each
# other?" without guessing which host you are on.
#
#   ./scripts/overlay-status.sh                 # auto: .24 <-> .1
#   ./scripts/overlay-status.sh --peer owner@10.100.0.1
#   ./scripts/overlay-status.sh --local-only    # this box only
#   ./scripts/overlay-status.sh --self-test     # offline, synthetic blocks
#
# Checks per host: nebula0 address, nebula service, route to the peer, ping to
# the peer, tailscale0 presence, web :5099 health on the server, sshd X11 policy
# on the server, xclip presence. Read-only: no restarts, no writes.
#
# Role is inferred from the local nebula IPv4: 10.100.0.24 = server,
# 10.100.0.1 = lighthouse. Use --peer to override the peer target.
#
# Exit: 0 all core checks PASS (warnings allowed), 2 any FAIL, 3 cannot run.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No top-level exit.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
set -uo pipefail

SERVER_IP="10.100.0.24"
LIGHTHOUSE_IP="10.100.0.1"
SSH_USER="${OVERLAY_SSH_USER:-owner}"
PEER_TARGET="${OVERLAY_PEER:-}"
LOCAL_ONLY="${OVERLAY_LOCAL_ONLY:-0}"
PASS=0
FAIL=0
WARN=0
SSH_ERR=""

have() { command -v "$1" >/dev/null; }
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s :: %s\n' "$1" "$2"; }
warn() { WARN=$((WARN + 1)); printf 'WARN  %s :: %s\n' "$1" "$2"; }

mesh_ip() {
    if [ -n "${OVERLAY_FAKE_LOCAL_IP:-}" ]; then printf '%s' "$OVERLAY_FAKE_LOCAL_IP"; return 0; fi
    if have ip; then
        ip -brief -4 addr show nebula0 2>&1 | awk '{print $3}' | awk -F/ '{print $1; exit}'
    elif have ifconfig; then
        ifconfig nebula0 2>&1 | awk '$1 == "inet" {print $2; exit}'
    fi
}

tailscale_ip() {
    if have ip; then
        ip -brief -4 addr show tailscale0 2>&1 | awk '{print $3}' | awk -F/ '{print $1; exit}'
    elif have ifconfig; then
        ifconfig tailscale0 2>&1 | awk '$1 == "inet" {print $2; exit}'
    fi
}

role_of() {
    case "$1" in
        "$SERVER_IP") printf 'server' ;;
        "$LIGHTHOUSE_IP") printf 'lighthouse' ;;
        *) printf 'node' ;;
    esac
}

peer_of() {
    case "$1" in
        "$SERVER_IP") printf '%s' "$LIGHTHOUSE_IP" ;;
        "$LIGHTHOUSE_IP") printf '%s' "$SERVER_IP" ;;
        *) printf '' ;;
    esac
}

route_ok() {
    # route_ok IP -> 0 when the kernel has a route (not "unreachable")
    [ -n "${OVERLAY_FAKE_ROUTE:-}" ] && { [ "$OVERLAY_FAKE_ROUTE" = "1" ]; return; }
    [ -n "$1" ] || return 1
    have ip || return 0
    ip route get "$1" 2>&1 | grep -q 'unreachable' && return 1
    ip route get "$1" > /dev/null 2>&1
}

ping_ok() {
    [ -n "${OVERLAY_FAKE_PING:-}" ] && { [ "$OVERLAY_FAKE_PING" = "1" ]; return; }
    [ -n "$1" ] || return 1
    have ping || return 0
    ping -c 2 -W 2 "$1" 2>&1 | grep -q '0% packet loss'
}

svc() {
    if have systemctl; then systemctl is-active "$1" 2>&1; else printf 'unknown'; fi
}

web_code() {
    have curl || { printf 'nocurl'; return 0; }
    curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://$1:5099/api/health" 2>&1
}

sshd_x11() {
    grep -hiE '^[[:space:]]*X11Forwarding[[:space:]]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>&1 \
        | awk 'tolower($2) == "yes" || tolower($2) == "no" {print tolower($2); exit}'
}

emit_local_block() {
    # emit_local_block PEER -> KEY=value lines consumed by parse_block
    local peer="$1" rout="0" ping="0" web="n/a" x11=""
    route_ok "$peer" && rout=1
    ping_ok "$peer" && ping=1
    if [ "$(role_of "$(mesh_ip)")" = "server" ]; then web="$(web_code "127.0.0.1")"; fi
    x11="$(sshd_x11)"
    printf 'HOST=%s\n' "$(hostname 2>&1)"
    printf 'OS=%s\n' "$(uname -sr 2>&1)"
    printf 'NEB=%s\n' "$(mesh_ip)"
    printf 'TS=%s\n' "$(tailscale_ip)"
    printf 'NEBULA_SVC=%s\n' "$(svc nebula)"
    printf 'TAILSCALE_SVC=%s\n' "$(svc tailscaled)"
    printf 'ROUTE_OK=%s\n' "$rout"
    printf 'PING_OK=%s\n' "$ping"
    printf 'WEB=%s\n' "$web"
    printf 'SSHD_X11=%s\n' "$x11"
    printf 'XCLIP=%s\n' "$(have xclip && command -v xclip || printf '')"
    printf 'DISPLAY=%s\n' "${DISPLAY:-}"
}

remote_block() {
    # remote_block TARGET MY_IP -> KEY=value lines from the peer (sets SSH_ERR)
    local target="$1" my="$2" errf=""
    errf="$(mktemp)"
    ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new \
        "$target" 'bash -s' "$my" 2>"$errf" <<'EOS'
MY="$1"
WEB="n/a"
if [ "$(ip -brief -4 addr show nebula0 2>&1 | awk '{print $3}' | awk -F/ '{print $1}')" = "10.100.0.24" ]; then
    WEB="$(curl -sk -m 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:5099/api/health" 2>&1)"
fi
printf 'HOST=%s\n' "$(hostname 2>&1)"
printf 'OS=%s\n' "$(uname -sr 2>&1)"
printf 'NEB=%s\n' "$(ip -brief -4 addr show nebula0 2>&1 | awk '{print $3}' | awk -F/ '{print $1}')"
printf 'TS=%s\n' "$(ip -brief -4 addr show tailscale0 2>&1 | awk '{print $3}' | awk -F/ '{print $1}')"
printf 'NEBULA_SVC=%s\n' "$(systemctl is-active nebula 2>&1)"
printf 'TAILSCALE_SVC=%s\n' "$(systemctl is-active tailscaled 2>&1)"
if ip route get "$MY" 2>&1 | grep -q 'unreachable'; then printf 'ROUTE_OK=0\n'; else printf 'ROUTE_OK=1\n'; fi
if ping -c 2 -W 2 "$MY" 2>&1 | grep -q '0% packet loss'; then printf 'PING_OK=1\n'; else printf 'PING_OK=0\n'; fi
printf 'WEB=%s\n' "$WEB"
printf 'SSHD_X11=%s\n' "$(grep -hiE '^[[:space:]]*X11Forwarding[[:space:]]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>&1 | awk 'tolower($2) == "yes" || tolower($2) == "no" {print tolower($2); exit}')"
printf 'XCLIP=%s\n' "$(command -v xclip 2>&1 | head -1)"
printf 'DISPLAY=%s\n' "${DISPLAY:-}"
EOS
    SSH_ERR="$(cat "$errf")"
    rm -f "$errf"
}

parse_block() {
    # stdin -> B_* globals
    local line=""
    B_HOST=""; B_OS=""; B_NEB=""; B_TS=""; B_NEBULA_SVC=""; B_TAILSCALE_SVC=""
    B_ROUTE_OK=""; B_PING_OK=""; B_WEB=""; B_SSHD_X11=""; B_XCLIP=""; B_DISPLAY=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            HOST=*) B_HOST="${line#*=}" ;;
            OS=*) B_OS="${line#*=}" ;;
            NEB=*) B_NEB="${line#*=}" ;;
            TS=*) B_TS="${line#*=}" ;;
            NEBULA_SVC=*) B_NEBULA_SVC="${line#*=}" ;;
            TAILSCALE_SVC=*) B_TAILSCALE_SVC="${line#*=}" ;;
            ROUTE_OK=*) B_ROUTE_OK="${line#*=}" ;;
            PING_OK=*) B_PING_OK="${line#*=}" ;;
            WEB=*) B_WEB="${line#*=}" ;;
            SSHD_X11=*) B_SSHD_X11="${line#*=}" ;;
            XCLIP=*) B_XCLIP="${line#*=}" ;;
            DISPLAY=*) B_DISPLAY="${line#*=}" ;;
        esac
    done
}

audit_block() {
    # audit_block LABEL ROLE -> prints rows, updates PASS/FAIL/WARN
    local label="$1" role="$2"
    printf '\n[%s] %s (%s)  %s\n' "$label" "${B_HOST:-unknown}" "$role" "${B_OS:-?}"
    if [ -n "$B_NEB" ]; then pass "$label nebula0 $B_NEB"; else fail "$label nebula0" "no address"; fi
    if [ "$B_NEBULA_SVC" = "active" ]; then pass "$label nebula service"; else fail "$label nebula service" "${B_NEBULA_SVC:-missing}"; fi
    if [ "$B_ROUTE_OK" = "1" ]; then pass "$label route to peer"; else fail "$label route to peer" "network unreachable"; fi
    if [ "$B_PING_OK" = "1" ]; then pass "$label ping peer"; else fail "$label ping peer" "no reply"; fi
    if [ -n "$B_TS" ]; then pass "$label tailscale0 $B_TS"; else warn "$label tailscale0" "absent (Nebula only)"; fi
    if [ "$B_TAILSCALE_SVC" = "active" ]; then pass "$label tailscaled"; else warn "$label tailscaled" "${B_TAILSCALE_SVC:-missing}"; fi
    if [ "$role" = "server" ]; then
        case "$B_WEB" in
            200) pass "$label web :5099" ;;
            *) fail "$label web :5099" "got ${B_WEB:-000}" ;;
        esac
        case "$B_SSHD_X11" in
            no | NO) fail "$label sshd X11Forwarding" "no" ;;
            *) pass "$label sshd X11Forwarding ${B_SSHD_X11:-default-yes}" ;;
        esac
    fi
    if [ -n "$B_XCLIP" ] && [ "$B_XCLIP" != "" ]; then
        pass "$label xclip $B_XCLIP"
    else
        warn "$label xclip" "not installed"
    fi
}

self_test() {
    local failc=0 out="" rc=0
    out="$(printf 'HOST=a\nOS=Linux\nNEB=10.100.0.24\nTS=100.1.1.1\nNEBULA_SVC=active\nTAILSCALE_SVC=active\nROUTE_OK=1\nPING_OK=1\nWEB=200\nSSHD_X11=yes\nXCLIP=/usr/bin/xclip\nDISPLAY=\n' \
        | { parse_block; audit_block good server; } 2>&1)"
    printf '%s' "$out" | grep -q 'PASS  good web :5099' || { printf 'FAIL selftest good-web\n'; failc=1; }
    printf '%s' "$out" | grep -q 'PASS  good nebula0 10.100.0.24' || { printf 'FAIL selftest good-neb\n'; failc=1; }

    out="$(printf 'HOST=b\nNEB=\nNEBULA_SVC=inactive\nROUTE_OK=0\nPING_OK=0\nWEB=000\nSSHD_X11=no\n' \
        | { parse_block; audit_block bad server; } 2>&1)"
    printf '%s' "$out" | grep -q 'FAIL  bad nebula0' || { printf 'FAIL selftest bad-neb\n'; failc=1; }
    printf '%s' "$out" | grep -q 'FAIL  bad route to peer' || { printf 'FAIL selftest bad-route\n'; failc=1; }
    printf '%s' "$out" | grep -q 'FAIL  bad web :5099' || { printf 'FAIL selftest bad-web\n'; failc=1; }

    [ "$(peer_of "$SERVER_IP")" = "$LIGHTHOUSE_IP" ] || { printf 'FAIL selftest peer .24\n'; failc=1; }
    [ "$(peer_of "$LIGHTHOUSE_IP")" = "$SERVER_IP" ] || { printf 'FAIL selftest peer .1\n'; failc=1; }
    [ "$(role_of "$SERVER_IP")" = server ] || { printf 'FAIL selftest role server\n'; failc=1; }
    [ "$(role_of "$LIGHTHOUSE_IP")" = lighthouse ] || { printf 'FAIL selftest role lh\n'; failc=1; }

    bash "$0" --bogus > /dev/null 2>&1
    [ "$?" -eq 3 ] || { printf 'FAIL selftest unknown arg\n'; failc=1; }

    if [ "$failc" -eq 0 ]; then
        printf 'overlay-status: self-test PASS (parse + audit + role/peer)\n'
    else
        printf 'overlay-status: self-test FAIL\n'
    fi
    return "$failc"
}

usage() {
    printf 'usage: %s [--peer user@host|--local-only|--self-test|--help]\n' "$0"
    printf 'env: OVERLAY_PEER, OVERLAY_SSH_USER, OVERLAY_LOCAL_ONLY\n'
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --peer) PEER_TARGET="${2:-}"; [ $# -ge 2 ] && shift; shift ;;
            --local-only) LOCAL_ONLY=1; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 3 ;;
        esac
    done

    local my peer role
    my="$(mesh_ip)"
    if [ -z "$my" ]; then
        printf 'GATE FAIL: no nebula0 IPv4 (is nebula installed/running here?)\n'
        return 3
    fi
    role="$(role_of "$my")"
    peer="$(peer_of "$my")"
    if [ -z "$PEER_TARGET" ] && [ -n "$peer" ]; then PEER_TARGET="$SSH_USER@$peer"; fi

    printf '=== overlay-status @ %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'this: %s (%s)  peer: %s\n' "$my" "$role" "${PEER_TARGET:-none}"

    local tmp="" peer_ip=""
    tmp="$(mktemp)"
    peer_ip="$(peer_of "$my")"
    if [ -z "$peer_ip" ] && [ -n "$PEER_TARGET" ]; then peer_ip="${PEER_TARGET#*@}"; fi
    emit_local_block "$peer_ip" > "$tmp"
    parse_block < "$tmp"
    audit_block local "$role"

    if [ "$LOCAL_ONLY" = "1" ]; then
        printf '\n(local-only; peer skipped)\n'
    elif [ -z "$PEER_TARGET" ]; then
        warn 'peer' 'not known for this address; pass --peer user@host'
    else
        remote_block "$PEER_TARGET" "$my" > "$tmp"
        parse_block < "$tmp"
        audit_block peer "$(role_of "${PEER_TARGET#*@}")"
        if [ -n "$SSH_ERR" ]; then
            printf 'WARN  ssh stderr :: %s\n' "$(printf '%s' "$SSH_ERR" | head -1)"
            WARN=$((WARN + 1))
        fi
    fi
    rm -f "$tmp"

    printf '\n=== summary: %s pass, %s warn, %s fail ===\n' "$PASS" "$WARN" "$FAIL"
    [ "$FAIL" -eq 0 ] && return 0 || return 2
}

main "$@"
