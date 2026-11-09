#!/usr/bin/env bash
#
# node-diag.sh - READ-ONLY, verbatim-evidence diagnostic for the MacBook (.1).
#
# Prints the raw error/event/system messages behind each failure class instead
# of a summary, so a finding cannot drift from the log that proves it.
#
#   ./scripts/node-diag.sh                     # all sections, last 24h
#   ./scripts/node-diag.sh --since '3 hours ago'
#   ./scripts/node-diag.sh --section unreachable --section nebula
#   ./scripts/node-diag.sh --list
#   ./scripts/node-diag.sh --self-test         # offline, fixture source
#
# Safe to run over SSH by piping stdin:
#   ssh owner@10.100.0.1 'bash -s -- --section identity' < scripts/node-diag.sh
#
# Read-only: no writes, no restarts, no sudo. Sections: identity, unreachable,
# nebula, mesh, dns, getty, units, coredumps. Override the time window with
# NODE_DIAG_SINCE, or point at a fixture with NODE_DIAG_SOURCE=<file>.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No top-level exit. No 2>/dev/null.
#
set -uo pipefail

SINCE="${NODE_DIAG_SINCE:-24 hours ago}"
BOOT="${NODE_DIAG_BOOT:-0}"
UNTIL="${NODE_DIAG_UNTIL:-}"
SRC="${NODE_DIAG_SOURCE:-}"
SECTIONS=""

have() { command -v "$1" >/dev/null; }
hr() { printf '\n===== %s =====\n' "$1"; }

jrnl() {
    # jrnl [journalctl args] -> raw lines; fixture mode ignores args
    if [ -n "$SRC" ]; then
        cat "$SRC"
    elif have journalctl; then
        if [ -n "$UNTIL" ]; then
            journalctl "$@" --until "$UNTIL"
        else
            journalctl "$@"
        fi
    fi
}

want() {
    [ -z "$SECTIONS" ] && return 0
    case ",$SECTIONS," in
        *",$1,"*) return 0 ;;
    esac
    return 1
}

list_sections() { printf '%s\n' identity unreachable nebula mesh dns getty units coredumps; }

sec_identity() {
    hr identity
    date; hostname 2>&1; uname -sr 2>&1
    printf '\n-- ip -4 addr --\n'; ip -4 -brief addr show 2>&1
    printf '\n-- ip -4 route --\n'; ip -4 route show 2>&1
    printf '\n-- ip rule --\n'; ip rule show 2>&1
    printf '\n-- nmcli device --\n'; nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device 2>&1
    printf '\n-- wifi link / power save --\n'
    iw dev wlp2s0b1 link 2>&1 | head -8
    iw dev wlp2s0b1 get power_save 2>&1
    printf '\n-- default-route + overlay presence --\n'
    ip -4 route show default 2>&1
    ip -4 route show 10.100.0.0/24 2>&1
}

sec_unreachable() {
    hr 'unreachable (verbatim)'
    printf 'matches: network is unreachable / RTNETLINK / no route / deauth / carrier\n'
    jrnl -b "$BOOT" --since "$SINCE" --no-pager 2>&1 \
        | grep -iE 'network is unreachable|RTNETLINK|no route to host|network is down|link is not ready|carrier lost|deauthenticating|CTRL-EVENT-DISCONNECTED|reason=3' \
        | tail -80
}

sec_nebula() {
    hr 'nebula (verbatim + restart churn)'
    printf 'restarts in window (Caught signal): '
    jrnl -b "$BOOT" -u nebula --since "$SINCE" --no-pager 2>&1 | grep -c 'Caught signal'
    printf '\n-- recent lifecycle + errors (not routine handshake timeouts) --\n'
    jrnl -b "$BOOT" -u nebula --since "$SINCE" --no-pager 2>&1 \
        | grep -E 'Nebula interface is active|Caught signal|level=error|Failed to send handshake|Tunnel status|listening on' \
        | tail -60
    printf '\n-- IPv4-listener vs IPv6-remote error count --\n'
    jrnl -b "$BOOT" -u nebula --since "$SINCE" --no-pager 2>&1 | grep -c 'Listener is IPv4, but writing to IPv6 remote'
}

sec_mesh() {
    hr 'mesh-recover / NM dispatcher loop (verbatim)'
    printf '\n-- user timer + service --\n'
    systemctl --user list-timers --all --no-pager 2>&1 | grep -iE 'mesh-recover|NEXT' | head -6
    systemctl --user cat mesh-recover.timer mesh-recover.service 2>&1 | grep -vE '^#' | head -30
    printf '\n-- NM dispatcher hook --\n'
    ls -l /etc/NetworkManager/dispatcher.d/50-mesh-recover 2>&1
    printf '\n-- mesh-recover.path --\n'; cat /etc/mesh-recover.path 2>&1
    printf '\n-- peer mapping in mesh-recover.sh --\n'
    local p=""
    p="$(cat /etc/mesh-recover.path 2>&1)"
    [ -f "$p" ] || p="/home/owner/Documents/d565411ff353dd7f/repo/proxmox-dual-plane-mesh/scripts/mesh-recover.sh"
    grep -nE 'PEER_OVL|PEER_LAN_HINT|10\.100\.0\.[0-9]+\)' "$p" 2>&1 | head -10
    printf '\n-- recover.log (tail 30) --\n'
    tail -n 30 "$HOME/.local/state/mesh-recover/recover.log" 2>&1
    printf '\n-- dispatcher log lines in window --\n'
    jrnl -b "$BOOT" -t mesh-dispatcher --since "$SINCE" --no-pager 2>&1 | tail -20
    printf '\n-- NetworkManager-dispatcher state + activation errors --\n'
    systemctl is-active NetworkManager-dispatcher 2>&1
    jrnl -b "$BOOT" --since "$SINCE" --no-pager 2>&1 | grep -iE 'nm_dispatcher|NetworkManager-dispatcher' | tail -12
}

sec_dns() {
    hr 'dns (verbatim)'
    printf '\n-- tailscale dns status --\n'; tailscale dns status 2>&1 | head -12
    printf '\n-- /etc/resolv.conf --\n'; cat /etc/resolv.conf 2>&1 | head -10
    printf '\n-- resolvectl status --\n'; resolvectl status 2>&1 | head -20
    printf '\n-- tailscale status (health lines) --\n'; tailscale status 2>&1 | grep -iE 'health|dns|warning' | head -6
    printf '\n-- dns errors in window --\n'
    jrnl -b "$BOOT" --since "$SINCE" --no-pager 2>&1 | grep -iE 'could not resolve|name resolution|temporary failure in name|dns.*(fail|error|timeout)' | tail -20
}

sec_getty() {
    hr 'serial-getty storm (verbatim)'
    systemctl is-enabled serial-getty@ttyS0 2>&1
    systemctl status serial-getty@ttyS0 --no-pager 2>&1 | head -8
    printf '\n-- rate in last 5m: '
    jrnl -b "$BOOT" --since '5 min ago' --no-pager 2>&1 | grep -c 'failed to get terminal attributes'
    printf '\n-- last lines --\n'
    jrnl -b "$BOOT" -u serial-getty@ttyS0 --since "$SINCE" --no-pager 2>&1 | tail -12
}

sec_units() {
    hr 'failed units + priority errors (verbatim)'
    printf '\n-- systemctl --failed --\n'; systemctl --failed --no-pager 2>&1 | head -20
    printf '\n-- priority err tail 60 --\n'
    jrnl -b "$BOOT" -p err --since "$SINCE" --no-pager 2>&1 | grep -v 'failed to get terminal attributes' | tail -60
    printf '\n-- accounts-daemon / audit-rules / haveged / tor --\n'
    jrnl -b "$BOOT" -u accounts-daemon -u audit-rules -u haveged -u tor --since "$SINCE" --no-pager 2>&1 | tail -30
}

sec_coredumps() {
    hr 'coredumps + restart counters (verbatim)'
    if have coredumpctl; then coredumpctl list --since "$SINCE" --no-pager 2>&1 | tail -15; else printf 'coredumpctl absent\n'; fi
    printf '\n-- NRestarts --\n'
    for u in nebula tailscaled; do printf '%s: ' "$u"; systemctl show "$u" -p NRestarts --value 2>&1; done
}

self_test() {
    local fail=0 tmp="" out=""
    tmp="$(mktemp)"
    printf '%s\n' \
        'Nov 09 19:57:55 host tailscaled: dial tcp4 1.2.3.4:443: connect: network is unreachable' \
        'Nov 09 19:57:55 host kernel: wlp2s0b1: deauthenticating (Reason: 3=DEAUTH_LEAVING)' \
        'Nov 09 20:08:08 host nebula: level=error msg="Failed to send handshake message" error="Listener is IPv4, but writing to IPv6 remote" vpnIp=10.100.0.24' \
        > "$tmp"
    out="$(NODE_DIAG_SOURCE="$tmp" bash "$0" --section unreachable 2>&1)"
    printf '%s' "$out" | grep -q 'network is unreachable' || { printf 'FAIL unreachable fixture\n'; fail=1; }
    out="$(NODE_DIAG_SOURCE="$tmp" bash "$0" --section nebula 2>&1)"
    printf '%s' "$out" | grep -q 'Listener is IPv4' || { printf 'FAIL nebula fixture\n'; fail=1; }
    out="$(bash "$0" --list 2>&1)"
    printf '%s' "$out" | grep -q 'coredumps' || { printf 'FAIL list\n'; fail=1; }
    bash "$0" --bogus > /dev/null 2>&1
    [ "$?" -eq 2 ] || { printf 'FAIL unknown arg\n'; fail=1; }
    rm -f "$tmp"
    if [ "$fail" -eq 0 ]; then printf 'node-diag: self-test PASS (fixture routing + list + args)\n'; else printf 'node-diag: self-test FAIL\n'; fi
    return "$fail"
}

usage() {
    printf 'usage: %s [--since WHEN] [--until WHEN] [--boot N] [--section NAME]... [--list] [--self-test]\n' "$0"
    printf 'sections: '; list_sections | tr '\n' ' '; printf '\n'
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --since) SINCE="${2:-24 hours ago}"; [ $# -ge 2 ] && shift; shift ;;
            --boot) BOOT="${2:-0}"; [ $# -ge 2 ] && shift; shift ;;
            --until) UNTIL="${2:-}"; [ $# -ge 2 ] && shift; shift ;;
            --section) SECTIONS="${SECTIONS:+$SECTIONS,}${2:-}"; [ $# -ge 2 ] && shift; shift ;;
            --list) list_sections; return 0 ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 2 ;;
        esac
    done

    printf '=== node-diag @ %s  (boot %s since: %s%s) ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BOOT" "$SINCE" "${UNTIL:+ until: $UNTIL}"
    want identity && sec_identity
    want unreachable && sec_unreachable
    want nebula && sec_nebula
    want mesh && sec_mesh
    want dns && sec_dns
    want getty && sec_getty
    want units && sec_units
    want coredumps && sec_coredumps
    printf '\n=== end ===\n'
}

main "$@"
