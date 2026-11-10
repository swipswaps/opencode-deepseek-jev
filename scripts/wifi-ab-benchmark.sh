#!/usr/bin/env bash
#
# wifi-ab-benchmark.sh - A/B/A benchmark for the BCM4331/b43 2.4 GHz path.
#
# The user does not need 5 GHz. This measures whether Bluetooth coexistence is
# the beacon-loss trigger without touching the Wi-Fi driver:
#
#   A1: Bluetooth ON   (baseline)
#   B : Bluetooth OFF  (candidate)
#   A2: Bluetooth ON   (control for drift)
#
# Per phase it records beacon-loss delta, tx-failed/rx-drop delta, ping
# loss/latency to the gateway (or --target), signal, and tx/rx bitrate. It then
# prints a verdict. Beacon loss is intermittent, so a short run is only a
# screen: run --duration 300+ for a real A/B, or repeat.
#
#   ./scripts/wifi-ab-benchmark.sh --bt --duration 20
#   ./scripts/wifi-ab-benchmark.sh --bt --duration 20 --target 192.168.4.24 --json
#   ./scripts/wifi-ab-benchmark.sh --self-test
#
# Runs on the client (or via scp to /tmp). It needs rfkill + passwordless sudo
# for the Bluetooth toggle; Wi-Fi is not restarted.
#
# Seams (self-test): WIFAB_FAKE_BT, WIFAB_FAKE_A_BEACON, WIFAB_FAKE_B_BEACON,
#   WIFAB_FAKE_A_AVG, WIFAB_FAKE_B_AVG, WIFAB_FAKE_A_LOSS, WIFAB_FAKE_B_LOSS.
#
# Exit: 0 benchmark completed (inconclusive is still 0); 2 cannot run; 3 usage.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, printf only, main() wrapper.
#
set -o pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DURATION="${WIFAB_DURATION:-20}"
TARGET="${WIFAB_TARGET:-}"
IFACE="${WIFAB_IFACE:-}"
JSON=0
SELFTEST="${WIFAB_SELFTEST:-0}"
PING_COUNT=0
PH_LABEL=""
PH_BT=""
PH_BEACON=0
PH_TXFAIL=0
PH_RXDROP=0
PH_JOURNAL=0
PH_LOSS=0
PH_AVG=0
PH_MAX=0
PH_MDEV=0
PH_SIGNAL="?"
PH_TX="?"
PH_RX="?"

usage() {
    printf 'usage: %s [--bt] [--duration SEC] [--target HOST] [--iface IF] [--json] [--self-test]\n' "$0"
    printf 'default: --bt, duration 20s, target = default gateway\n'
}

have() { command -v "$1" > /dev/null; }

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"
    elif have sudo && sudo -n true 2>&1; then sudo -n "$@"
    else return 1
    fi
}

pick_iface() {
    [ -n "$IFACE" ] && return 0
    if have iw; then IFACE="$(iw dev 2>&1 | awk '/^[[:space:]]*Interface /{print $2; exit}')"; fi
    if [ -z "$IFACE" ] && have nmcli; then
        IFACE="$(nmcli -t -f DEVICE,TYPE,STATE device 2>&1 | awk -F: '$2=="wifi" && $3=="connected"{print $1; exit}')"
    fi
    [ -n "$IFACE" ]
}

bt_present() {
    case "${WIFAB_FAKE_BT:-}" in
        yes|no) return 0 ;;
    esac
    have rfkill || return 1
    rfkill list bluetooth 2>&1 | grep -q 'Bluetooth'
}

bt_state() {
    case "${WIFAB_FAKE_BT:-}" in
        yes) printf 'no'; return 0 ;;
        no) printf 'yes'; return 0 ;;
    esac
    have rfkill || { printf 'unknown'; return 0; }
    rfkill list bluetooth 2>&1 | awk '/Soft blocked/{print $3; exit}'
}

set_bt() {
    local want="$1"
    if [ "$SELFTEST" = "1" ]; then return 0; fi
    case "$want" in
        on) as_root rfkill unblock bluetooth 2>&1 || return 1 ;;
        off) as_root rfkill block bluetooth 2>&1 || return 1 ;;
    esac
}

station_field() {
    local field="$1"
    iw dev "$IFACE" station dump 2>&1 | awk -v f="$field" 'index($0,f){print $NF; exit}'
}

measure() {
    local before_beacon="" before_txfail="" before_rxdrop="" before_journal=""
    local after_beacon="" after_txfail="" after_rxdrop="" after_journal=""
    local ping_out="" loss="" rtt="" min="" avg="" max="" mdev=""
    local link=""
    before_beacon="$(station_field 'beacon loss:')"
    before_txfail="$(station_field 'tx failed:')"
    before_rxdrop="$(station_field 'rx drop misc:')"
    if have journalctl; then before_journal="$(journalctl -u wpa_supplicant -b --no-pager -g 'BEACON-LOSS' -o cat 2>&1 | wc -l | awk '{print $1}')"; fi
    link="$(iw dev "$IFACE" link 2>&1)"
    PH_SIGNAL="$(printf '%s\n' "$link" | awk -F': ' '/signal:/{print $2; exit}')"
    PH_TX="$(printf '%s\n' "$link" | awk -F': ' '/tx bitrate:/{print $2; exit}')"
    PH_RX="$(printf '%s\n' "$link" | awk -F': ' '/rx bitrate:/{print $2; exit}')"
    [ -n "$PH_SIGNAL" ] || PH_SIGNAL="?"
    [ -n "$PH_TX" ] || PH_TX="?"
    [ -n "$PH_RX" ] || PH_RX="?"
    ping_out="$(ping -c "$PING_COUNT" -i 0.5 -W 1 "$TARGET" 2>&1)"
    loss="$(printf '%s\n' "$ping_out" | awk '/packet loss/{for(i=1;i<=NF;i++) if ($i ~ /%$/) {gsub(/%/,"",$i); print $i; exit}}')"
    case "$loss" in ''|*[!0-9.]*) loss=0 ;; esac
    PH_LOSS="$loss"
    rtt="$(printf '%s\n' "$ping_out" | awk -F'= ' '/rtt|round-trip/{print $2; exit}')"
    if [ -n "$rtt" ]; then
        min="$(printf '%s' "$rtt" | awk -F/ '{print $1}')"
        avg="$(printf '%s' "$rtt" | awk -F/ '{print $2}')"
        max="$(printf '%s' "$rtt" | awk -F/ '{print $3}')"
        mdev="$(printf '%s' "$rtt" | awk -F/ '{print $4}' | awk '{print $1}')"
    fi
    PH_AVG="${avg:-0}"; PH_MAX="${max:-0}"; PH_MDEV="${mdev:-0}"
    after_beacon="$(station_field 'beacon loss:')"
    after_txfail="$(station_field 'tx failed:')"
    after_rxdrop="$(station_field 'rx drop misc:')"
    if have journalctl; then after_journal="$(journalctl -u wpa_supplicant -b --no-pager -g 'BEACON-LOSS' -o cat 2>&1 | wc -l | awk '{print $1}')"; fi
    PH_BEACON=$(( ${after_beacon:-0} - ${before_beacon:-0} ))
    PH_TXFAIL=$(( ${after_txfail:-0} - ${before_txfail:-0} ))
    PH_RXDROP=$(( ${after_rxdrop:-0} - ${before_rxdrop:-0} ))
    PH_JOURNAL=$(( ${after_journal:-0} - ${before_journal:-0} ))
    [ "$PH_BEACON" -lt 0 ] && PH_BEACON=0
    [ "$PH_TXFAIL" -lt 0 ] && PH_TXFAIL=0
    [ "$PH_RXDROP" -lt 0 ] && PH_RXDROP=0
    [ "$PH_JOURNAL" -lt 0 ] && PH_JOURNAL=0
}

run_phase() {
    local label="$1" want="$2"
    PH_LABEL="$label"; PH_BT="$want"
    set_bt "$want" || { PH_BEACON=-1; PH_AVG=-1; PH_LOSS=-1; return 0; }
    sleep 2
    measure
}

verdict() {
    local a_beacon a_avg a_loss b_beacon b_avg b_loss
    a_beacon=$(( PH_A_BEACON > PH_C_BEACON ? PH_A_BEACON : PH_C_BEACON ))
    a_avg="$(awk -v x="$PH_A_AVG" -v y="$PH_C_AVG" 'BEGIN{printf "%.2f",(x+y)/2}')"
    a_loss="$(awk -v x="$PH_A_LOSS" -v y="$PH_C_LOSS" 'BEGIN{printf "%.2f",(x+y)/2}')"
    b_beacon="$PH_B_BEACON"; b_avg="$PH_B_AVG"; b_loss="$PH_B_LOSS"
    if [ "$PH_B_LOSS" -lt 0 ]; then
        printf 'INCONCLUSIVE: Bluetooth toggle was not permitted (needs rfkill + sudo).\n'
        return 0
    fi
    if awk -v b="$b_beacon" -v a="$a_beacon" -v bl="$b_loss" -v al="$a_loss" -v ba="$b_avg" -v aa="$a_avg" \
        'BEGIN{exit !((b < a || (a==0 && b==0)) && (bl <= al) && (ba <= aa*1.15))}'; then
        if awk -v b="$b_beacon" -v a="$a_beacon" -v bl="$b_loss" -v al="$a_loss" \
            'BEGIN{exit !(b < a || bl < al)}'; then
            printf 'BT-COEXISTENCE LIKELY: Bluetooth OFF reduced beacon loss/latency. Try options b43 btcoex=0 and/or keep Bluetooth off.\n'
            return 0
        fi
    fi
    printf 'INCONCLUSIVE in %ss: no significant BT effect. Beacon loss is intermittent; run --duration 300+ or test the AP 2.4 GHz radio.\n' "$DURATION"
}

print_phase() {
    printf '%-3s bt=%-5s beacon=%-3s txfail=%-3s rxdrop=%-3s journal=%-3s ping_loss=%-6s avg=%sms max=%sms mdev=%sms signal=%s tx=%s rx=%s\n' \
        "$PH_LABEL" "$PH_BT" "$PH_BEACON" "$PH_TXFAIL" "$PH_RXDROP" "$PH_JOURNAL" \
        "$PH_LOSS" "$PH_AVG" "$PH_MAX" "$PH_MDEV" "$PH_SIGNAL" "$PH_TX" "$PH_RX"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --bt) shift ;;
            --duration) DURATION="${2:-20}"; shift 2 ;;
            --target) TARGET="${2:-}"; shift 2 ;;
            --iface) IFACE="${2:-}"; shift 2 ;;
            --json) JSON=1; shift ;;
            --self-test) SELFTEST=1; shift ;;
            -h|--help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 3 ;;
        esac
    done
    case "$DURATION" in ''|*[!0-9]*) DURATION=20 ;; esac
    PING_COUNT=$(( DURATION * 2 ))
    [ "$PING_COUNT" -gt 0 ] || PING_COUNT=40

    if [ "$SELFTEST" = "1" ]; then
        local fail=0 out=""
        pick_iface || IFACE="wlp2s0b1"
        PH_A_BEACON=10 PH_A_AVG=12.0 PH_A_LOSS=0
        PH_B_BEACON=1  PH_B_AVG=10.0 PH_B_LOSS=0
        PH_C_BEACON=9  PH_C_AVG=12.5 PH_C_LOSS=0
        out="$(verdict)"
        case "$out" in *'BT-COEXISTENCE LIKELY'*) : ;; *) printf 'FAIL self-test: expected BT verdict\n'; fail=1 ;; esac
        PH_B_BEACON=10 PH_B_AVG=12.2 PH_B_LOSS=0
        out="$(verdict)"
        case "$out" in *INCONCLUSIVE*) : ;; *) printf 'FAIL self-test: expected inconclusive\n'; fail=1 ;; esac
        [ "$fail" -eq 0 ] && printf 'wifi-ab-benchmark: self-test PASS (BT improvement + inconclusive)\n'
        [ "$fail" -eq 0 ] || printf 'wifi-ab-benchmark: self-test FAIL\n'
        return "$fail"
    fi

    pick_iface || { printf 'FAIL: no wireless interface\n' >&2; return 2; }
    if [ -z "$TARGET" ] && have ip; then
        TARGET="$(ip route show default 2>&1 | awk '/default via/{print $3; exit}')"
    fi
    [ -n "$TARGET" ] || TARGET="1.1.1.1"
    bt_present || { printf 'FAIL: no Bluetooth/rfkill to A/B\n' >&2; return 2; }
    printf 'wifi-ab-benchmark: iface=%s target=%s duration=%ss (%s pings/phase)\n' "$IFACE" "$TARGET" "$DURATION" "$PING_COUNT"

    run_phase A1 on;  PH_A_BEACON="$PH_BEACON"; PH_A_TXFAIL="$PH_TXFAIL"; PH_A_RXDROP="$PH_RXDROP"; PH_A_JOURNAL="$PH_JOURNAL"; PH_A_LOSS="$PH_LOSS"; PH_A_AVG="$PH_AVG"; PH_A_MAX="$PH_MAX"; PH_A_MDEV="$PH_MDEV"; PH_A_SIGNAL="$PH_SIGNAL"; PH_A_TX="$PH_TX"; PH_A_RX="$PH_RX"; print_phase
    run_phase B off; PH_B_BEACON="$PH_BEACON"; PH_B_TXFAIL="$PH_TXFAIL"; PH_B_RXDROP="$PH_RXDROP"; PH_B_JOURNAL="$PH_JOURNAL"; PH_B_LOSS="$PH_LOSS"; PH_B_AVG="$PH_AVG"; PH_B_MAX="$PH_MAX"; PH_B_MDEV="$PH_MDEV"; PH_B_SIGNAL="$PH_SIGNAL"; PH_B_TX="$PH_TX"; PH_B_RX="$PH_RX"; print_phase
    run_phase A2 on; PH_C_BEACON="$PH_BEACON"; PH_C_TXFAIL="$PH_TXFAIL"; PH_C_RXDROP="$PH_RXDROP"; PH_C_JOURNAL="$PH_JOURNAL"; PH_C_LOSS="$PH_LOSS"; PH_C_AVG="$PH_AVG"; PH_C_MAX="$PH_MAX"; PH_C_MDEV="$PH_MDEV"; PH_C_SIGNAL="$PH_SIGNAL"; PH_C_TX="$PH_TX"; PH_C_RX="$PH_RX"; print_phase

    verdict
    if [ "$JSON" = "1" ]; then
        printf '{"iface":"%s","target":"%s","duration":%s,"phases":[' "$IFACE" "$TARGET" "$DURATION"
        printf '{"label":"A1","bt":"on","beacon":%s,"ping_loss":%s,"avg_ms":%s},' "$PH_A_BEACON" "$PH_A_LOSS" "$PH_A_AVG"
        printf '{"label":"B","bt":"off","beacon":%s,"ping_loss":%s,"avg_ms":%s},' "$PH_B_BEACON" "$PH_B_LOSS" "$PH_B_AVG"
        printf '{"label":"A2","bt":"on","beacon":%s,"ping_loss":%s,"avg_ms":%s}],' "$PH_C_BEACON" "$PH_C_LOSS" "$PH_C_AVG"
        printf '"verdict":"inconclusive-or-bt"}\n'
    fi
    return 0
}

main "$@"
