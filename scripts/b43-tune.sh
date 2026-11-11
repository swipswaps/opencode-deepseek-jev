#!/usr/bin/env bash
#
# b43-tune.sh - apply / revert the BCM4331/b43 2.4 GHz mitigations.
#
# The BCM4331 + b43 is 2.4 GHz-only and suffers intermittent beacon loss. The
# leading software candidates are Bluetooth coexistence (btcoex=1 while
# Bluetooth is active) and NetworkManager roaming/scanning churn. This script
# applies the two reversible changes together and auto-recovers if the live
# reload does not come back:
#
#   options b43 btcoex=0                       (drop the BT coexistence path)
#   nmcli ... 802-11-wireless.bssid <2.4 BSSID> (pin belkin2 to one 2.4 AP)
#   nmcli ... 802-11-wireless.band bg           (2.4 GHz only)
#   nmcli ... 802-11-wireless.powersave 2       (off, already the case)
#
#   ./scripts/b43-tune.sh --check               # read-only
#   ./scripts/b43-tune.sh --check --json
#   ./scripts/b43-tune.sh --apply               # write config + pin (no reload)
#   ./scripts/b43-tune.sh --apply --reload      # also reload b43 now, auto-recover
#   ./scripts/b43-tune.sh --rollback            # remove config + pin, reload
#   ./scripts/b43-tune.sh --self-test
#
# Reversible: --rollback removes /etc/modprobe.d/99-b43-tune.conf and clears
# the connection pin. The reload path snapshots the old btcoex value and
# restores it if no Wi-Fi comes back within B43TUNE_UP_SEC (default 40 s).
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, printf only, main() wrapper.
#
set -o pipefail

MODPROBE_CONF="${B43TUNE_CONF:-/etc/modprobe.d/99-b43-tune.conf}"
NM_CONN="${B43TUNE_CONN:-belkin2}"
BSSID="${B43TUNE_BSSID:-24:F3:E3:52:1A:06}"
UP_SEC="${B43TUNE_UP_SEC:-40}"
RELOAD=0
JSON=0
SELFTEST="${B43TUNE_SELFTEST:-0}"
IFACE="${B43TUNE_IFACE:-}"
LOG="${B43TUNE_LOG:-$HOME/.local/state/b43-tune.log}"
APPLIED="${B43TUNE_APPLIED:-$HOME/.local/state/b43-tune.applied}"

usage() {
    printf 'usage: %s [--check|--apply|--rollback|--self-test] [--reload] [--json]\n' "$0"
    printf '  --apply   write options b43 btcoex=0 + pin belkin2 to 2.4 GHz + powersave off\n'
    printf '  --reload  also reload b43 now (brief Wi-Fi drop) with auto-recovery\n'
    printf '  --rollback remove the config + pin and reload the previous driver\n'
}

have() { command -v "$1" > /dev/null; }

log() {
    local line=""
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
    printf '%s\n' "$line"
    if [ "$SELFTEST" != "1" ]; then
        mkdir -p "$(dirname "$LOG")" 2>&1 || true
        printf '%s\n' "$line" >> "$LOG" 2>&1 || true
    fi
}

is_root() { [ "$(id -u)" -eq 0 ]; }

as_root() {
    if is_root; then "$@"
    elif have sudo && sudo -n true 2>&1; then sudo -n "$@"
    else return 1
    fi
}

pick_iface() {
    [ -n "$IFACE" ] && return 0
    if have iw; then IFACE="$(iw dev 2>&1 | awk '/^[[:space:]]*Interface /{print $2; exit}')"; fi
    [ -n "$IFACE" ] || IFACE="wlp2s0b1"
}

b43_param() {
    case "$SELFTEST" in 1) case "$1" in btcoex) printf '1';; qos) printf '0';; nohwcrypt) printf '1';; *) printf '0';; esac; return 0;; esac
    cat "/sys/module/b43/parameters/$1" 2>&1
}

bt_state() {
    case "${B43TUNE_FAKE_BT:-}" in active|blocked) printf '%s' "$B43TUNE_FAKE_BT"; return 0;; esac
    have rfkill || { printf 'unknown'; return 0; }
    local raw=""
    raw="$(rfkill list bluetooth 2>&1 | awk '/Soft blocked/{print $3; exit}')"
    case "$raw" in yes) printf 'blocked';; no) printf 'active';; *) printf 'unknown';; esac
}

nm_field() {
    case "${B43TUNE_FAKE_NM:-}" in '' ) : ;; * ) printf '%s' "$B43TUNE_FAKE_NM"; return 0 ;; esac
    have nmcli || { printf ''; return 0; }
    nmcli -g "$2" connection show "$1" 2>&1
}

connected() {
    case "${B43TUNE_FAKE_CONNECTED:-}" in yes) return 0;; no) return 1;; esac
    have nmcli || return 1
    nmcli -t -f DEVICE,TYPE,STATE device 2>&1 | grep -q 'wifi:connected'
}

beacon_loss() {
    case "${B43TUNE_FAKE_BEACON:-}" in '' ) : ;; * ) printf '%s' "$B43TUNE_FAKE_BEACON"; return 0 ;; esac
    have iw || { printf '0'; return 0; }
    iw dev "$IFACE" station dump 2>&1 | awk '/beacon loss/{print $NF; exit}'
}

write_conf() {
    if [ "$SELFTEST" = "1" ]; then
        mkdir -p "$(dirname "$MODPROBE_CONF")" 2>&1 || true
        printf 'options b43 btcoex=0\n' > "$MODPROBE_CONF"
    else
        printf 'options b43 btcoex=0\n' | as_root tee "$MODPROBE_CONF" 1> /dev/null
    fi
    log "wrote $MODPROBE_CONF (options b43 btcoex=0)"
}

remove_conf() {
    if [ -f "$MODPROBE_CONF" ]; then
        if [ "$SELFTEST" = "1" ]; then rm -f "$MODPROBE_CONF"; else as_root rm -f "$MODPROBE_CONF"; fi
        log "removed $MODPROBE_CONF"
    fi
}

apply_nm() {
    if [ "$SELFTEST" = "1" ]; then log "selftest: nmcli pin $NM_CONN bssid=$BSSID band=bg"; return 0; fi
    as_root nmcli connection modify "$NM_CONN" \
        802-11-wireless.bssid "$BSSID" \
        802-11-wireless.band bg \
        802-11-wireless.powersave 2
    log "pinned $NM_CONN to bssid=$BSSID band=bg powersave=2"
}

rollback_nm() {
    if [ "$SELFTEST" = "1" ]; then log "selftest: nmcli unpin $NM_CONN"; return 0; fi
    as_root nmcli connection modify "$NM_CONN" \
        802-11-wireless.bssid "" \
        802-11-wireless.band "" \
        802-11-wireless.powersave 2
    log "unpinned $NM_CONN (kept powersave off)"
}

reload_b43() {
    if [ "$SELFTEST" = "1" ]; then log "selftest: modprobe -r b43; modprobe b43"; return 0; fi
    as_root modprobe -r b43 2>&1 || true
    sleep 1
    as_root modprobe b43 2>&1 || true
}

restart_nm() {
    if [ "$SELFTEST" = "1" ]; then return 0; fi
    as_root systemctl restart NetworkManager 2>&1 || true
}

wait_up() {
    local n="$1" i=0
    while [ "$i" -lt "$n" ]; do
        connected && return 0
        i=$((i + 1)); sleep 1
    done
    return 1
}

do_check() {
    pick_iface
    local btcoex qos nohwcrypt bt bssid band ps conn beacon
    btcoex="$(b43_param btcoex)"; qos="$(b43_param qos)"; nohwcrypt="$(b43_param nohwcrypt)"
    bt="$(bt_state)"; bssid="$(nm_field "$NM_CONN" 802-11-wireless.bssid)"
    band="$(nm_field "$NM_CONN" 802-11-wireless.band)"; ps="$(nm_field "$NM_CONN" 802-11-wireless.powersave)"
    if connected; then conn="yes"; else conn="no"; fi
    beacon="$(beacon_loss)"
    if [ "$JSON" = "1" ]; then
        printf '{"conn":"%s","iface":"%s","btcoex":"%s","qos":"%s","nohwcrypt":"%s","bluetooth":"%s","bssid":"%s","band":"%s","powersave":"%s","connected":"%s","beacon_loss":%s}\n' \
            "$NM_CONN" "$IFACE" "$btcoex" "$qos" "$nohwcrypt" "$bt" "$bssid" "$band" "$ps" "$conn" "$beacon"
        return 0
    fi
    printf 'conn      : %s (%s)\n' "$NM_CONN" "$IFACE"
    printf 'b43       : btcoex=%s qos=%s nohwcrypt=%s\n' "$btcoex" "$qos" "$nohwcrypt"
    printf 'bluetooth : %s\n' "$bt"
    printf 'nm        : bssid=%s band=%s powersave=%s connected=%s\n' "${bssid:-auto}" "${band:-auto}" "$ps" "$conn"
    printf 'beacon-loss (this assoc): %s\n' "$beacon"
    return 0
}

do_apply() {
    pick_iface
    local prev=""
    prev="$(b43_param btcoex)"
    write_conf || { log "FAIL write conf"; return 2; }
    apply_nm || { log "FAIL nm pin"; remove_conf; return 2; }
    if [ "$RELOAD" = "1" ]; then
        log "reloading b43 with btcoex=0 (was $prev)"
        as_root nmcli device disconnect "$IFACE" 2>&1 || true
        reload_b43
        restart_nm
        if wait_up "$UP_SEC"; then
            mkdir -p "$(dirname "$APPLIED")" 2>&1 || true
            printf '%s\n' "$(date +%s)" > "$APPLIED" 2>&1 || true
            log "connected; btcoex=$(b43_param btcoex) bssid=$(nm_field "$NM_CONN" 802-11-wireless.bssid)"
        else
            log "no Wi-Fi after ${UP_SEC}s; rolling back"
            remove_conf
            rollback_nm
            reload_b43
            restart_nm
            wait_up "$UP_SEC" || log "still down after rollback"
        fi
    else
        log "config written; reboot or run --apply --reload to apply"
    fi
    return 0
}

do_rollback() {
    pick_iface
    remove_conf
    rollback_nm
    reload_b43
    restart_nm
    rm -f "$APPLIED" 2>&1 || true
    wait_up "$UP_SEC" || log "not yet connected after rollback"
    log "rollback complete"
    return 0
}

self_test() {
    local tmp fail=0
    tmp="$(mktemp -d)"
    MODPROBE_CONF="$tmp/99-b43-tune.conf"
    B43TUNE_SELFTEST=1
    SELFTEST=1
    write_conf
    [ -f "$MODPROBE_CONF" ] || { printf 'FAIL conf not written\n'; fail=1; }
    grep -q 'btcoex=0' "$MODPROBE_CONF" || { printf 'FAIL conf content\n'; fail=1; }
    apply_nm > "$tmp/step.log" 2>&1
    RELOAD=0 do_apply > "$tmp/step.log" 2>&1
    [ -f "$MODPROBE_CONF" ] || { printf 'FAIL apply missing conf\n'; fail=1; }
    do_rollback > "$tmp/step.log" 2>&1
    [ ! -f "$MODPROBE_CONF" ] || { printf 'FAIL rollback left conf\n'; fail=1; }
    rm -f "$MODPROBE_CONF"
    rmdir "$tmp" 2>&1 || true
    if [ "$fail" -eq 0 ]; then
        printf 'b43-tune: self-test PASS (conf write + apply + rollback)\n'
    else
        printf 'b43-tune: self-test FAIL\n'
    fi
    return "$fail"
}

main() {
    local action="check"
    while [ $# -gt 0 ]; do
        case "$1" in
            --check) action="check"; shift ;;
            --apply) action="apply"; shift ;;
            --rollback) action="rollback"; shift ;;
            --reload) RELOAD=1; shift ;;
            --json) JSON=1; shift ;;
            --self-test) self_test; return "$?" ;;
            -h|--help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 3 ;;
        esac
    done
    case "$action" in
        check) do_check; return "$?" ;;
        apply) do_apply; return "$?" ;;
        rollback) do_rollback; return "$?" ;;
    esac
    usage >&2
    return 3
}

main "$@"
