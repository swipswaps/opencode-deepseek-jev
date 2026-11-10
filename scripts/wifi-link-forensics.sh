#!/usr/bin/env bash
#
# wifi-link-forensics.sh - prove WHY a Wi-Fi link stalls, from the logs on
# BOTH ends, then apply the safe fixes.
#
# The 2026-11-10 incident: an `ssh -Y 100.119.125.16` session from the
# Fedora 43 MacBook (10.100.0.1) to ws24 (10.100.0.24) kept freezing. The
# operator suspected Wi-Fi powersave. It was NOT powersave on the client
# (already off): wpa_supplicant logged CTRL-EVENT-BEACON-LOSS dozens of
# times per hour on a 2.4 GHz-only b43/BCM4331 radio, the Nebula lighthouse
# handshake timed out in lock-step, and Tailscale flapped between the LAN,
# Nebula, and DERP paths. This script turns that into reproducible evidence.
#
#   ./scripts/wifi-link-forensics.sh                 # local verdict
#   ./scripts/wifi-link-forensics.sh --peer owner@100.70.43.78
#   ./scripts/wifi-link-forensics.sh --since 24 --json
#   ./scripts/wifi-link-forensics.sh --fix           # powersave off + persist
#   ./scripts/wifi-link-forensics.sh --fix --dry-run # print, change nothing
#   ./scripts/wifi-link-forensics.sh --self-test     # offline, fake seams
#
# Where: the local run inspects this host; --peer re-runs THIS script on the
# other machine over SSH (stdin, no install needed). Run it on the server and
# point --peer at the client: that is "logs from both machines".
#
# Seams (self-test): WIFIFX_PS, WIFIFX_SSID, WIFIFX_BSSID, WIFIFX_FREQ,
#   WIFIFX_SIGNAL, WIFIFX_DRIVER, WIFIFX_5G, WIFIFX_BEACON, WIFIFX_DEAUTH,
#   WIFIFX_FWLOAD, WIFIFX_DNSFAIL, WIFIFX_PATHFLAP, WIFIFX_NMDEACT, WIFIFX_IFACE.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
# Exit: 0 corroborated-healthy; 2 a link-layer cause is proven; 3 cannot run.
#
set -o pipefail

SINCE_HOURS="${WIFIFX_SINCE_HOURS:-24}"
IFACE="${WIFIFX_IFACE:-${WIFI_IFACE:-}}"
PEER="${WIFI_PEER:-}"
JSON=0
FIX=0
DRY=0
SELF=0
VERDICTS=""
REASONS=""
DRIVER=""
SSID=""
BSSID=""
FREQ=""
SIGNAL=""
PS=""
BAND=""
HAS_5G=""
NM_PS=""
BEACON=0
DEAUTH=0
FWLOAD=0
DNSFAIL=0
PATHFLAP=0
NMDEACT=0

usage() {
    printf 'usage: %s [--since HOURS] [--iface IF] [--peer USER@HOST] [--json]\n' "$0"
    printf '          [--fix [--dry-run]] [--self-test]\n'
    printf 'local:  inspect this host.  --peer: re-run this script over SSH there.\n'
    printf 'exit:   0 healthy, 2 link-layer cause proven, 3 cannot run.\n'
}

have() { command -v "$1" > /dev/null; }

add_verdict() { VERDICTS="${VERDICTS}${VERDICTS:+,}$1"; }
add_reason() { REASONS="${REASONS}${REASONS:+; }$1"; }

pick_iface() {
    [ -n "$IFACE" ] && return 0
    if have iw; then
        IFACE="$(iw dev 2>&1 | awk '/^[[:space:]]*Interface /{print $2; exit}')"
    fi
    if [ -z "$IFACE" ] && have nmcli; then
        IFACE="$(nmcli -t -f DEVICE,TYPE,STATE dev status 2>&1 | awk -F: '$2=="wifi" && $3=="connected"{print $1; exit}')"
    fi
    [ -n "$IFACE" ]
}

collect_iface() {
    if ! pick_iface; then
        add_verdict no-wifi
        add_reason "no wireless interface found"
        return 0
    fi
    DRIVER="${WIFIFX_DRIVER:-}"
    if [ -z "$DRIVER" ] && have readlink; then
        DRIVER="$(basename "$(readlink -f "/sys/class/net/$IFACE/device/driver" 2>&1)" 2>&1)"
    fi
    case "$DRIVER" in *'No such'*|*'not found'*) DRIVER="" ;; esac
    if [ -z "$DRIVER" ] && have lspci; then
        DRIVER="$(lspci -k 2>&1 | awk '/Network controller|Wireless/{f=1} f && /Kernel driver in use:/{print $NF; exit}')"
    fi
    [ -n "$DRIVER" ] || DRIVER="unknown"

    if [ -n "${WIFIFX_SSID:-}" ]; then
        SSID="$WIFIFX_SSID"; BSSID="${WIFIFX_BSSID:-?}"
        FREQ="${WIFIFX_FREQ:-0}"; SIGNAL="${WIFIFX_SIGNAL:-?}"
    elif have iw; then
        local link=""
        link="$(iw dev "$IFACE" link 2>&1)"
        SSID="$(printf '%s\n' "$link" | awk -F': ' '/^[[:space:]]*SSID:/{print $2; exit}')"
        BSSID="$(printf '%s\n' "$link" | awk '/Connected to/{print $3; exit}')"
        FREQ="$(printf '%s\n' "$link" | awk -F': ' '/freq:/{gsub(/[^0-9.]/,"",$2); split($2,a,"."); print a[1]; exit}')"
        SIGNAL="$(printf '%s\n' "$link" | awk -F': ' '/signal:/{print $2; exit}')"
    fi
    case "$FREQ" in ''|*[!0-9]*) FREQ=0 ;; esac
    if [ "$FREQ" -ge 5000 ]; then BAND="5GHz"; else BAND="2.4GHz"; fi

    PS="${WIFIFX_PS:-}"
    if [ -z "$PS" ] && have iw; then
        PS="$(iw dev "$IFACE" get power_save 2>&1 | awk -F': ' '{print $2; exit}')"
    fi
    [ -n "$PS" ] || PS="unknown"

    HAS_5G="${WIFIFX_5G:-}"
    if [ -z "$HAS_5G" ] && have iw; then
        local phy=""
        phy="$(iw dev "$IFACE" info 2>&1 | awk '/wiphy/{print $2; exit}')"
        if [ -n "$phy" ]; then
            HAS_5G="$(iw phy "phy$phy" info 2>&1 | awk '
                /\* [0-9.]+ MHz/ { f=$2+0; if (f>=5000) found=1 }
                END { print (found?"yes":"no") }')"
        fi
    fi
    [ -n "$HAS_5G" ] || HAS_5G="unknown"

    NM_PS=""
    if have nmcli && [ -n "$SSID" ]; then
        NM_PS="$(nmcli -e no -g 802-11-wireless.powersave connection show "$SSID" 2>&1)"
    fi
}

count_journal() {
    # `-g` filters in journalctl itself, so only matching lines cross the pipe;
    # a plain grep over the full journal blocks for minutes on a busy host.
    local unit="$1" pat="$2"
    have journalctl || { printf '0'; return 0; }
    if [ -n "$unit" ]; then
        journalctl -u "$unit" --since "-${SINCE_HOURS} hours" --no-pager -q -n 5000 \
            -g "$pat" -o cat 2>&1 | wc -l | awk '{print $1}'
    else
        journalctl -k --since "-${SINCE_HOURS} hours" --no-pager -q -n 5000 \
            -g "$pat" -o cat 2>&1 | wc -l | awk '{print $1}'
    fi
}

collect_counts() {
    BEACON="${WIFIFX_BEACON:-}"
    [ -n "$BEACON" ] || BEACON="$(count_journal wpa_supplicant 'BEACON-LOSS')"
    DEAUTH="${WIFIFX_DEAUTH:-}"
    [ -n "$DEAUTH" ] || DEAUTH="$(count_journal '' 'deauthenticat|authentication with .* timed out')"
    FWLOAD="${WIFIFX_FWLOAD:-}"
    [ -n "$FWLOAD" ] || FWLOAD="$(count_journal '' 'Loading firmware|Loaded firmware|firmware.*(reset|reload)')"
    DNSFAIL="${WIFIFX_DNSFAIL:-}"
    [ -n "$DNSFAIL" ] || DNSFAIL="$(count_journal NetworkManager 'could not commit DNS changes')"
    PATHFLAP="${WIFIFX_PATHFLAP:-}"
    [ -n "$PATHFLAP" ] || PATHFLAP="$(count_journal tailscaled 'now using|endpoints changed')"
    NMDEACT="${WIFIFX_NMDEACT:-}"
    [ -n "$NMDEACT" ] || NMDEACT="$(count_journal NetworkManager 'state change: activated -> (deactivating|disconnected)')"
    local v
    for v in BEACON DEAUTH FWLOAD DNSFAIL PATHFLAP NMDEACT; do
        eval "case \"\$$v\" in ''|*[!0-9]*) $v=0 ;; esac"
    done
}

classify() {
    case "$PS" in on|enable) add_verdict powersave-on; add_reason "Wi-Fi powersave is ON ($PS)" ;; esac
    if [ "$BEACON" -gt 0 ]; then
        add_verdict beacon-loss
        add_reason "wpa_supplicant BEACON-LOSS x$BEACON in ${SINCE_HOURS}h on $IFACE ($BAND, $SIGNAL)"
    fi
    if [ "$DEAUTH" -gt 0 ]; then
        add_reason "deauth/timeout x$DEAUTH and firmware reload x$FWLOAD"
    fi
    case "$DRIVER" in b43|bcma*) add_verdict driver-b43; add_reason "reverse-engineered b43 driver on Broadcom $IFACE" ;; esac
    if [ "$BAND" = "2.4GHz" ] && [ "$HAS_5G" = "no" ]; then
        add_verdict 2.4-only
        add_reason "radio advertises no 5GHz channel (b43 restriction), so it cannot escape crowded 2.4GHz"
    fi
    if [ "$PATHFLAP" -gt 0 ]; then
        add_verdict path-flap
        add_reason "Tailscale path changed x$PATHFLAP in ${SINCE_HOURS}h (LAN/Nebula/DERP churn)"
    fi
    if [ "$DNSFAIL" -gt 0 ]; then
        add_verdict dns-commit-failure
        add_reason "NetworkManager could not replace /etc/resolv.conf x$DNSFAIL (DNS stale after reconnect)"
    fi
    [ -n "$VERDICTS" ] || { add_verdict stable; add_reason "no beacon loss, powersave off, no path churn"; }
}

report() {
    printf '== wifi-link-forensics (%sh window) ==\n' "$SINCE_HOURS"
    printf 'host    : %s\n' "$(hostname 2>&1)"
    printf 'iface   : %s (driver=%s)\n' "${IFACE:-none}" "$DRIVER"
    printf 'link    : ssid=%s bssid=%s freq=%s band=%s signal=%s\n' \
        "${SSID:-?}" "${BSSID:-?}" "${FREQ:-0}" "${BAND:-?}" "${SIGNAL:-?}"
    printf 'radio   : 5GHz-capable=%s powersave=%s nm-powersave=%s\n' \
        "$HAS_5G" "$PS" "${NM_PS:-n/a}"
    printf 'counts  : beacon-loss=%s deauth=%s fw-reload=%s nm-deactivate=%s\n' \
        "$BEACON" "$DEAUTH" "$FWLOAD" "$NMDEACT"
    printf 'overlay : tailscale-path-changes=%s  dns-commit-failures=%s\n' "$PATHFLAP" "$DNSFAIL"
    printf 'verdict : %s\n' "$VERDICTS"
    printf 'why     : %s\n' "$REASONS"
}

json_escape() { printf '%s' "$1" | tr -d '"\\'; }

emit_json() {
    printf '{"host":"%s","iface":"%s","driver":"%s","ssid":"%s","band":"%s","signal":"%s",' \
        "$(json_escape "$(hostname 2>&1)")" "$(json_escape "$IFACE")" "$(json_escape "$DRIVER")" \
        "$(json_escape "$SSID")" "$(json_escape "$BAND")" "$(json_escape "$SIGNAL")"
    printf '"five_ghz":"%s","powersave":"%s","beacon_loss":%s,"deauth":%s,"fw_reload":%s,' \
        "$HAS_5G" "$PS" "$BEACON" "$DEAUTH" "$FWLOAD"
    printf '"nm_deactivate":%s,"path_flap":%s,"dns_fail":%s,"verdicts":"%s","since_hours":%s}\n' \
        "$NMDEACT" "$PATHFLAP" "$DNSFAIL" "$VERDICTS" "$SINCE_HOURS"
}

recommend() {
    printf '\n-- fixes (safe first) --\n'
    printf '1. disable powersave now    : iw dev %s set power_save off\n' "${IFACE:-IFACE}"
    printf '   persist via NetworkManager: printf "[connection]\\nwifi.powersave = 2\\n" | sudo tee /etc/NetworkManager/conf.d/99-wifi-powersave-off.conf && sudo systemctl reload NetworkManager\n'
    case "$DRIVER" in b43|bcma*)
        printf '2. replace b43 (5GHz+stability): enable RPMFusion, then sudo dnf install akmod-wl kmod-wl; blacklist b43 bcma; reboot\n'
        printf '   or bypass Wi-Fi entirely       : use wired/USB-Ethernet on enp1s0f0\n'
        ;;
    esac
    if [ "$DNSFAIL" -gt 0 ]; then
        printf '3. DNS commit failure       : ensure /etc is writable and /etc/resolv.conf is not immutable; or point NM at systemd-resolved\n'
    fi
    if [ -n "$PEER" ]; then
        printf '4. re-run on the peer       : %s --peer %s --since %s\n' "$0" "$PEER" "$SINCE_HOURS"
    fi
}

apply_fix() {
    pick_iface || { printf 'FAIL: no wireless interface\n'; return 3; }
    local s=""
    if [ "$(id -u)" -eq 0 ]; then s=""; elif have sudo && sudo -n true 2>&1; then s="sudo"; fi
    if [ "$DRY" -eq 1 ]; then
        printf '+ %s iw dev %s set power_save off\n' "${s:-sudo}" "$IFACE"
        printf '+ %s sh -c persist wifi.powersave=2 to /etc/NetworkManager/conf.d/99-wifi-powersave-off.conf\n' "${s:-sudo}"
        printf '+ %s systemctl reload NetworkManager\n' "${s:-sudo}"
        return 0
    fi
    if [ -z "$s" ] && [ "$(id -u)" -ne 0 ]; then
        printf 'SKIP: need root or passwordless sudo; run these yourself:\n'
        printf '  iw dev %s set power_save off\n' "$IFACE"
        printf '  printf "%%s\\n" "[connection]" "wifi.powersave = 2" | sudo tee /etc/NetworkManager/conf.d/99-wifi-powersave-off.conf\n'
        printf '  sudo systemctl reload NetworkManager\n'
        return 3
    fi
    printf '+ iw dev %s set power_save off\n' "$IFACE"
    $s iw dev "$IFACE" set power_save off 2>&1 || printf 'WARN: iw set failed (driver may ignore it)\n'
    printf '+ persist wifi.powersave = 2\n'
    printf '%s\n' '[connection]' 'wifi.powersave = 2' | $s tee /etc/NetworkManager/conf.d/99-wifi-powersave-off.conf > /dev/null 2>&1 \
        || printf 'WARN: could not write NM drop-in\n'
    $s systemctl reload NetworkManager 2>&1 || printf 'WARN: NetworkManager reload failed\n'
    printf 'done. powersave now: %s\n' "$(iw dev "$IFACE" get power_save 2>&1)"
    return 0
}

self_test() {
    local out="" rc=0
    export WIFIFX_IFACE=wlp2s0b1 WIFIFX_DRIVER=b43 WIFIFX_SSID=belkin2
    export WIFIFX_BSSID=24:f3:e3:52:1a:06 WIFIFX_FREQ=2462 WIFIFX_SIGNAL=-38.00
    export WIFIFX_PS=on WIFIFX_5G=no WIFIFX_BEACON=95 WIFIFX_DEAUTH=6
    export WIFIFX_FWLOAD=8 WIFIFX_DNSFAIL=2 WIFIFX_PATHFLAP=11 WIFIFX_NMDEACT=1
    collect_iface; collect_counts; classify
    case "$VERDICTS" in
        *beacon-loss*) : ;;
        *) printf 'FAIL self-test: expected beacon-loss verdict, got %s\n' "$VERDICTS"; rc=1 ;;
    esac
    case "$VERDICTS" in
        *powersave-on*) : ;;
        *) printf 'FAIL self-test: expected powersave-on verdict, got %s\n' "$VERDICTS"; rc=1 ;;
    esac
    case "$VERDICTS" in
        *2.4-only*) : ;;
        *) printf 'FAIL self-test: expected 2.4-only verdict, got %s\n' "$VERDICTS"; rc=1 ;;
    esac
    out="$(emit_json)"
    if have python3; then
        printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' || { printf 'FAIL self-test: JSON invalid\n'; rc=1; }
    fi
    DRY=1; FIX=1
    out="$(apply_fix 2>&1)"
    case "$out" in
        *'power_save off'*) : ;;
        *) printf 'FAIL self-test: dry-run did not print power_save\n'; rc=1 ;;
    esac
    if [ "$rc" -eq 0 ]; then
        printf 'wifi-link-forensics: self-test PASS (beacon-loss + powersave + 2.4-only + json + fix-dry-run)\n'
    else
        printf 'wifi-link-forensics: self-test FAIL\n'
    fi
    return "$rc"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --since) SINCE_HOURS="${2:-24}"; shift 2 ;;
            --iface) IFACE="${2:-}"; shift 2 ;;
            --peer) PEER="${2:-}"; shift 2 ;;
            --json) JSON=1; shift ;;
            --fix) FIX=1; shift ;;
            --dry-run) DRY=1; shift ;;
            --self-test) SELF=1; shift ;;
            -h|--help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 3 ;;
        esac
    done
    case "$SINCE_HOURS" in ''|*[!0-9]*) SINCE_HOURS=24 ;; esac

    if [ "$SELF" -eq 1 ]; then self_test; return "$?"; fi

    if [ -n "$PEER" ]; then
        have ssh || { printf 'FAIL: ssh not installed\n'; return 3; }
        local args="--since $SINCE_HOURS"
        [ -n "${IFACE:-}" ] && args="$args --iface $IFACE"
        [ "$JSON" -eq 1 ] && args="$args --json"
        [ "$FIX" -eq 1 ] && args="$args --fix"
        [ "$DRY" -eq 1 ] && args="$args --dry-run"
        printf '== peer %s ==\n' "$PEER"
        # shellcheck disable=SC2029
        ssh -o BatchMode=yes -o ConnectTimeout=8 "$PEER" "bash -s -- $args" < "$0"
        return "$?"
    fi

    collect_iface
    collect_counts
    classify
    if [ "$JSON" -eq 1 ]; then emit_json; else report; recommend; fi
    if [ "$FIX" -eq 1 ]; then
        apply_fix || return 3
    fi
    case ",$VERDICTS," in
        *,stable,*) return 0 ;;
        *) return 2 ;;
    esac
}

main "$@"
