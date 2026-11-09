#!/usr/bin/env bash
#
# hotspot-test.sh - phased network-change test for a client that switches to a
# mobile hotspot (the 10.100.0.1 -> phone scenario).
#
# Run this ON THE CLIENT (the roaming box), not on the server.
#
#   ./scripts/hotspot-test.sh --before    # baseline on the current network
#   # switch the client Wi-Fi to the phone hotspot
#   ./scripts/hotspot-test.sh --after     # acceptance after the switch
#   ./scripts/hotspot-test.sh --auto      # before, prompt, after
#   ./scripts/hotspot-test.sh --watch     # re-run on an address change
#   ./scripts/hotspot-test.sh --json      # machine summary (with before/after)
#   ./scripts/hotspot-test.sh --self-test # offline, fake seams
#
# What it proves:
#   - an overlay path (Nebula 10.100.0.24 or Tailscale 100.119.125.16) answers
#     :4096 (200/401) and :5099 (200) after the switch; --require mesh|tailscale
#     pins it, the default "any" accepts a working fallback;
#   - a settle window (default 20s for --after) lets the overlay re-handshake;
#   - the LAN address (192.168.4.24) is a control: reachable before, dropping
#     after a hotspot switch is expected; staying reachable is also fine;
#   - DNS still resolves during the switch;
#   - when client-setup.sh is present, --heal runs and --check reports the path;
#   - when ROAM_SSH_HOST is set, SSH X11 forwarding still yields a DISPLAY;
#   - if this box is the Nebula lighthouse (10.100.0.1) and Nebula dies, it
#     explains that CGNAT removed the inbound UDP anchor (TUNNEL-1).
#
# Env: ROAM_MESH_IP, ROAM_TAILSCALE_IP, ROAM_LAN_IP, ROAM_STATE, ROAM_SSH_HOST,
#      ROAM_SSH_PORT, ROAM_WATCH_SEC, ROAM_REQUIRE, ROAM_SETTLE_SEC,
#      ROAM_LIGHTHOUSE_IP, ROAM_NO_HEAL.
# Seams (self-test): ROAM_FAKE_MESH_4096, ROAM_FAKE_MESH_5099,
#      ROAM_FAKE_TAILSCALE_4096, ROAM_FAKE_TAILSCALE_5099, ROAM_FAKE_LAN_4096,
#      ROAM_FAKE_DNS, ROAM_FAKE_SIG, ROAM_FAKE_LOCAL_NEBULA.
#
# Exit: 0 PASS, 2 FAIL, 3 cannot run.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No top-level exit.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
set -uo pipefail

if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
else
    SELF_DIR="$PWD"
fi
MESH="${ROAM_MESH_IP:-10.100.0.24}"
TAILSCALE="${ROAM_TAILSCALE_IP:-100.119.125.16}"
LAN="${ROAM_LAN_IP:-192.168.4.24}"
STATE="${ROAM_STATE:-$HOME/.local/state/roam-test.state}"
WATCH_SEC="${ROAM_WATCH_SEC:-10}"
REQUIRE="${ROAM_REQUIRE:-any}"
LIGHTHOUSE="${ROAM_LIGHTHOUSE_IP:-10.100.0.1}"
JSON="${ROAM_JSON:-0}"
PASS=0
FAIL=0

have() { command -v "$1" >/dev/null; }
ok() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL  %s :: %s\n' "$1" "$2"; }

fetch() {
    # fetch URL -> three digit code (000 when curl is absent)
    local url="$1" code=""
    if ! have curl; then printf '000'; return 0; fi
    code="$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "$url" 2>&1)"
    case "$code" in
        [0-9][0-9][0-9]) printf '%s' "$code" ;;
        *) printf '000' ;;
    esac
}

mesh_4096() {
    if [ -n "${ROAM_FAKE_MESH_4096:-}" ]; then printf '%s' "$ROAM_FAKE_MESH_4096"; return 0; fi
    fetch "https://$MESH:4096/session"
}
mesh_5099() {
    if [ -n "${ROAM_FAKE_MESH_5099:-}" ]; then printf '%s' "$ROAM_FAKE_MESH_5099"; return 0; fi
    fetch "https://$MESH:5099/api/health"
}
tailscale_5099() {
    if [ -n "${ROAM_FAKE_TAILSCALE_5099:-}" ]; then printf '%s' "$ROAM_FAKE_TAILSCALE_5099"; return 0; fi
    fetch "https://$TAILSCALE:5099/api/health"
}
tailscale_4096() {
    if [ -n "${ROAM_FAKE_TAILSCALE_4096:-}" ]; then printf '%s' "$ROAM_FAKE_TAILSCALE_4096"; return 0; fi
    fetch "https://$TAILSCALE:4096/session"
}
lan_4096() {
    if [ -n "${ROAM_FAKE_LAN_4096:-}" ]; then printf '%s' "$ROAM_FAKE_LAN_4096"; return 0; fi
    fetch "https://$LAN:4096/session"
}

classify_4096() {
    case "$1" in 200 | 401) printf 'PASS' ;; *) printf 'FAIL' ;; esac
}
classify_5099() {
    case "$1" in 200) printf 'PASS' ;; *) printf 'FAIL' ;; esac
}

dns_ok() {
    case "${ROAM_FAKE_DNS:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    if have getent; then
        getent ahostsv4 example.com 2>&1 | grep -q STREAM && return 0
    fi
    if have dscacheutil; then
        dscacheutil -q host -a name example.com 2>&1 | grep -q ip_address && return 0
    fi
    if have nslookup; then
        nslookup example.com 2>&1 | grep -q 'Address' && return 0
    fi
    return 1
}

signature() {
    if [ -n "${ROAM_FAKE_SIG:-}" ]; then printf '%s' "$ROAM_FAKE_SIG"; return 0; fi
    {
        if have ip; then
            ip -brief -4 addr show 2>&1 | awk '{for (i = 3; i <= NF; i++) {split($i, a, "/"); if (a[1] ~ /^[0-9]+\./) print a[1]}}'
        fi
        if have ifconfig; then
            ifconfig 2>&1 | awk '$1 == "inet" {print $2}'
        fi
    } | sort -u | tr '\n' ' '
}

state_path() { printf '%s' "$STATE"; }

state_get() {
    local key="$1" f="$2" line
    [ -f "$f" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key"=*) printf '%s' "${line#*=}"; return 0 ;;
        esac
    done < "$f"
    return 1
}

save_state() {
    # save_state SIG PHASE M4 M5 L4
    local f
    f="$(state_path)"
    mkdir -p "$(dirname "$f")" || return 0
    printf 'SIG=%s\nPHASE=%s\nMESH4096=%s\nMESH5099=%s\nLAN4096=%s\n' "$1" "$2" "$3" "$4" "$5" > "$f"
}

probe_report() {
    # probe_report PHASE -> prints the table; M4 M5 T4 T5 L4 already loaded
    local vm4 vm5 vt4 vt5 vl4 via="none"
    vm4="$(classify_4096 "$M4")"
    vm5="$(classify_5099 "$M5")"
    vt4="$(classify_4096 "$T4")"
    vt5="$(classify_5099 "$T5")"
    vl4="$(classify_4096 "$L4")"
    printf '\n== %s (%s) ==\n' "$1" "$(signature)"
    printf '%-32s %-6s %s\n' TARGET CODE VERDICT
    printf '%-32s %-6s %s\n' "nebula:$MESH:4096" "$M4" "$vm4"
    printf '%-32s %-6s %s\n' "nebula:$MESH:5099" "$M5" "$vm5"
    printf '%-32s %-6s %s\n' "tailscale:$TAILSCALE:4096" "$T4" "$vt4"
    printf '%-32s %-6s %s\n' "tailscale:$TAILSCALE:5099" "$T5" "$vt5"
    printf '%-32s %-6s %s\n' "lan:$LAN:4096 (control)" "$L4" "$vl4"
    printf 'dns: %s\n' "$(dns_ok && printf PASS || printf FAIL)"
    if mesh_ok; then via="nebula"; elif ts_ok; then via="tailscale"; fi
    printf 'overlay path: %s (require=%s)\n' "$via" "$REQUIRE"
    if overlay_ok; then
        ok "overlay reachable via $via"
    else
        case "$REQUIRE" in
            mesh) no "overlay (mesh)" "nebula :4096=$M4 :5099=$M5" ;;
            tailscale) no "overlay (tailscale)" "tailscale :4096=$T4 :5099=$T5" ;;
            *) no "overlay (any)" "nebula :4096=$M4 :5099=$M5; tailscale :4096=$T4 :5099=$T5" ;;
        esac
    fi
    dns_ok || no "dns" "example.com did not resolve"
    return 0
}

probe_codes() {
    M4="$(mesh_4096)"
    M5="$(mesh_5099)"
    T4="$(tailscale_4096)"
    T5="$(tailscale_5099)"
    L4="$(lan_4096)"
}

mesh_ok() { [ "$(classify_4096 "$M4")" = PASS ] && [ "$(classify_5099 "$M5")" = PASS ]; }
ts_ok() { [ "$(classify_4096 "$T4")" = PASS ] && [ "$(classify_5099 "$T5")" = PASS ]; }

overlay_ok() {
    case "$REQUIRE" in
        mesh) mesh_ok ;;
        tailscale) ts_ok ;;
        *) mesh_ok || ts_ok ;;
    esac
}

wait_overlay() {
    # wait_overlay SEC -> retry until the required overlay passes or the
    # deadline; a roam re-handshakes, so an instant probe is too strict.
    local sec="$1" deadline
    if [ "$sec" -le 0 ]; then
        probe_codes
        return 0
    fi
    deadline=$(( $(date +%s) + sec ))
    while :; do
        probe_codes
        overlay_ok && return 0
        [ "$(date +%s)" -ge "$deadline" ] && return 1
        sleep 3
    done
}

local_nebula_ip() {
    if [ -n "${ROAM_FAKE_LOCAL_NEBULA:-}" ]; then printf '%s' "$ROAM_FAKE_LOCAL_NEBULA"; return 0; fi
    if have ip; then
        ip -brief -4 addr show nebula0 2>&1 \
            | awk '{for (i = 3; i <= NF; i++) {split($i, a, "/"); if (a[1] ~ /^[0-9]+\./) {print a[1]; exit}}}'
    elif have ifconfig; then
        ifconfig nebula0 2>&1 | awk '$1 == "inet" {print $2; exit}'
    fi
}

is_lighthouse() { [ "$(local_nebula_ip)" = "$LIGHTHOUSE" ]; }

heal_and_check() {
    [ "${ROAM_NO_HEAL:-0}" = "1" ] && return 0
    [ -f "$SELF_DIR/client-setup.sh" ] || return 0
    printf '\n== client-setup --heal + --check ==\n'
    bash "$SELF_DIR/client-setup.sh" --heal --quiet 2>&1 || printf 'WARN: client-setup --heal returned non-zero\n'
    bash "$SELF_DIR/client-setup.sh" --check 2>&1 || printf 'WARN: client-setup --check returned non-zero\n'
    return 0
}

ssh_x11_probe() {
    [ -n "${ROAM_SSH_HOST:-}" ] || return 0
    printf '\n== ssh X11 forwarding (%s) ==\n' "$ROAM_SSH_HOST"
    local out=""
    out="$(ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new \
        -Y -p "${ROAM_SSH_PORT:-22}" "$ROAM_SSH_HOST" 'printf %s "${DISPLAY:-}"' 2>&1)"
    case "$out" in
        localhost:* | 127.0.0.1:*) ok "ssh X11 forwarding ($out)" ;;
        '') no "ssh X11 forwarding" "empty DISPLAY (forwarding or auth failed)" ;;
        *) printf 'WARN  ssh X11 forwarding :: DISPLAY=%s (expected localhost:N)\n' "$out" ;;
    esac
    return 0
}

emit_json() {
    [ "$JSON" = "1" ] || return 0
    printf '{"phase": "%s", "mesh_4096": "%s", "mesh_5099": "%s", "tailscale_4096": "%s", "tailscale_5099": "%s", "lan_4096": "%s", "require": "%s", "pass": %s, "fail": %s}\n' \
        "$1" "$M4" "$M5" "$T4" "$T5" "$L4" "$REQUIRE" "$PASS" "$FAIL"
}

do_before() {
    PASS=0 FAIL=0
    wait_overlay "${ROAM_SETTLE_SEC:-0}" > /dev/null 2>&1 || true
    probe_report before
    save_state "$(signature)" before "$M4" "$M5" "$L4"
    printf 'baseline saved: %s\n' "$(state_path)"
    emit_json before
    [ "$FAIL" -eq 0 ]
}

do_after() {
    PASS=0 FAIL=0
    local prev_lan="" sig="" settle=""
    settle="${ROAM_SETTLE_SEC:-20}"
    prev_lan="$(state_get LAN4096 "$(state_path)")"
    sig="$(signature)"
    printf 'settling up to %ss for the overlay to re-handshake...\n' "$settle"
    wait_overlay "$settle" > /dev/null 2>&1 || true
    probe_report after
    if [ -n "$prev_lan" ] && [ "$prev_lan" != "000" ]; then
        if [ "$L4" = "000" ]; then
            printf 'ok    LAN control dropped as expected after the hotspot switch\n'
        else
            printf 'note  LAN still reachable (same network or bridged; also acceptable)\n'
        fi
    else
        printf 'note  no usable baseline; run --before first for the LAN control\n'
    fi
    if ! mesh_ok && is_lighthouse; then
        printf 'note  this box is the nebula lighthouse (%s). Behind a hotspot/CGNAT its\n' "$LIGHTHOUSE"
        printf '      inbound UDP anchor is gone, so peers cannot re-handshake. Use Tailscale\n'
        printf '      (client-setup --candidates) or keep the lighthouse on a wired LAN.\n'
    fi
    heal_and_check
    ssh_x11_probe
    emit_json after
    if [ "$FAIL" -eq 0 ]; then
        printf '\nVERDICT: PASS (roam-safe: a required overlay is reachable after the change)\n'
        return 0
    fi
    printf '\nVERDICT: FAIL (%s gap(s)). Check the mesh VPN and the server watchdog.\n' "$FAIL"
    return 2
}

watch_mode() {
    local prev cur
    prev="$(signature)"
    printf 'watching the address set every %ss; baseline: %s\n' "$WATCH_SEC" "$prev"
    printf 'switch the client Wi-Fi/hotspot now (Ctrl-C to stop)\n'
    while :; do
        sleep "$WATCH_SEC"
        cur="$(signature)"
        if [ "$cur" != "$prev" ]; then
            printf '\n[%s] address change: %s -> %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$prev" "$cur"
            prev="$cur"
            do_after || true
        fi
    done
}

self_test() {
    local fail=0 work="" o="" rc=0
    work="$(mktemp -d)"
    export ROAM_STATE="$work/state"
    export ROAM_NO_HEAL=1
    export ROAM_SETTLE_SEC=0
    export ROAM_FAKE_LOCAL_NEBULA=10.100.0.1

    o=$(ROAM_FAKE_SIG="aaa" ROAM_FAKE_MESH_4096=401 ROAM_FAKE_MESH_5099=200 \
        ROAM_FAKE_TAILSCALE_4096=401 ROAM_FAKE_TAILSCALE_5099=200 \
        ROAM_FAKE_LAN_4096=401 ROAM_FAKE_DNS=1 \
        bash "$0" --before 2>&1); rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL before-pass rc=%s\n' "$rc"; fail=1; }
    grep -q '^SIG=aaa$' "$work/state" || { printf 'FAIL state sig\n'; fail=1; }
    grep -q '^LAN4096=401$' "$work/state" || { printf 'FAIL state lan\n'; fail=1; }

    o=$(ROAM_FAKE_SIG="bbb" ROAM_FAKE_MESH_4096=401 ROAM_FAKE_MESH_5099=200 \
        ROAM_FAKE_TAILSCALE_4096=401 ROAM_FAKE_TAILSCALE_5099=200 \
        ROAM_FAKE_LAN_4096=000 ROAM_FAKE_DNS=1 \
        bash "$0" --after 2>&1); rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL after-pass rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'LAN control dropped as expected' || { printf 'FAIL lan control note\n'; fail=1; }

    # Lighthouse on a hotspot: nebula dies, tailscale carries the path.
    o=$(ROAM_FAKE_SIG="ccc" ROAM_FAKE_MESH_4096=000 ROAM_FAKE_MESH_5099=000 \
        ROAM_FAKE_TAILSCALE_4096=401 ROAM_FAKE_TAILSCALE_5099=200 \
        ROAM_FAKE_LAN_4096=000 ROAM_FAKE_DNS=1 \
        bash "$0" --after 2>&1); rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL tailscale-fallback rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'overlay reachable via tailscale' || { printf 'FAIL fallback path\n'; fail=1; }
    printf '%s' "$o" | grep -q 'nebula lighthouse' || { printf 'FAIL lighthouse note\n'; fail=1; }

    o=$(ROAM_FAKE_SIG="ccc" ROAM_FAKE_MESH_4096=000 ROAM_FAKE_MESH_5099=000 \
        ROAM_FAKE_TAILSCALE_4096=401 ROAM_FAKE_TAILSCALE_5099=200 \
        ROAM_FAKE_LAN_4096=000 ROAM_FAKE_DNS=1 \
        bash "$0" --after --require mesh 2>&1); rc=$?
    [ "$rc" -eq 2 ] || { printf 'FAIL require-mesh rc=%s\n' "$rc"; fail=1; }

    o=$(ROAM_FAKE_SIG="ddd" ROAM_FAKE_MESH_4096=000 ROAM_FAKE_MESH_5099=000 \
        ROAM_FAKE_TAILSCALE_4096=000 ROAM_FAKE_TAILSCALE_5099=000 \
        ROAM_FAKE_LAN_4096=000 ROAM_FAKE_DNS=0 \
        bash "$0" --after 2>&1); rc=$?
    [ "$rc" -eq 2 ] || { printf 'FAIL after-down rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'VERDICT: FAIL' || { printf 'FAIL after-down verdict\n'; fail=1; }

    o=$(ROAM_FAKE_MESH_4096=200 ROAM_FAKE_MESH_5099=200 ROAM_FAKE_TAILSCALE_4096=401 \
        ROAM_FAKE_TAILSCALE_5099=200 ROAM_FAKE_LAN_4096=401 ROAM_FAKE_DNS=1 \
        ROAM_FAKE_SIG="eee" bash "$0" --after --json 2>&1); rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL json rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q '"phase": "after"' || { printf 'FAIL json phase\n'; fail=1; }

    bash "$0" --bogus > /dev/null 2>&1
    [ "$?" -eq 3 ] || { printf 'FAIL unknown arg rc\n'; fail=1; }
    bash "$0" --require nope > /dev/null 2>&1
    [ "$?" -eq 3 ] || { printf 'FAIL bad require rc\n'; fail=1; }

    rm -f "$work/state" "$work"/out.txt
    rmdir "$work" 2>&1 || true
    if [ "$fail" -eq 0 ]; then
        printf 'hotspot-test: self-test PASS (before/after + fallback + lighthouse + json)\n'
    else
        printf 'hotspot-test: self-test FAIL\n'
    fi
    return "$fail"
}

usage() {
    printf 'usage: %s [--before|--after|--auto|--watch|--json|--self-test]\n' "$0"
    printf 'flags: --settle SEC --require any|mesh|tailscale --lighthouse-ip IP\n'
    printf 'run on the client; env ROAM_MESH_IP, ROAM_LAN_IP, ROAM_SSH_HOST, ROAM_STATE\n'
}

main() {
    local mode="" arg=""
    while [ $# -gt 0 ]; do
        arg="$1"
        case "$arg" in
            --before) mode="before"; shift ;;
            --after) mode="after"; shift ;;
            --auto) mode="auto"; shift ;;
            --watch) mode="watch"; shift ;;
            --json) JSON=1; shift ;;
            --settle) ROAM_SETTLE_SEC="${2:-}"; [ $# -ge 2 ] && shift; shift ;;
            --require) REQUIRE="${2:-any}"; [ $# -ge 2 ] && shift; shift ;;
            --lighthouse-ip) LIGHTHOUSE="${2:-}"; [ $# -ge 2 ] && shift; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$arg"; usage >&2; return 3 ;;
        esac
    done
    case "$REQUIRE" in
        any | mesh | tailscale) ;;
        *) printf 'FAIL: --require must be any|mesh|tailscale\n'; return 3 ;;
    esac
    case "${ROAM_SETTLE_SEC:-}" in
        '' | *[!0-9]*) ROAM_SETTLE_SEC="" ;;
    esac
    case "$mode" in
        before) do_before; return "$?" ;;
        after) do_after; return "$?" ;;
        auto)
            do_before || { printf 'baseline FAILED; fix the overlay first\n'; return 2; }
            printf '\nSwitch the client to the mobile hotspot now, then press Enter...'
            read -r _ || true
            do_after; return "$?"
            ;;
        watch) watch_mode; return 0 ;;
        '')
            usage
            return 3
            ;;
    esac
}

main "$@"
