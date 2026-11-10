#!/usr/bin/env bash
#
# bluetooth-off.sh - power off the Bluetooth RADIO (not just the service) and
# keep it off across reboots, reversibly.
#
# 2026-11-10: on both ws24 (.24) and fedora (.1) the bluetooth.service is
# already disabled/masked, but the radio (hci0 / tpacpi_bluetooth_sw) is still
# powered ("Soft blocked: no"). b43's btcoex=1 (and iwlwifi's bt_coex_active)
# then still run coexistence against a live Bluetooth radio, which is the
# leading software candidate for the BCM4331 beacon loss. The service being off
# is not enough: the radio must be powered off.
#
#   ./scripts/bluetooth-off.sh --check             # read-only
#   ./scripts/bluetooth-off.sh --check --json
#   ./scripts/bluetooth-off.sh --apply             # rfkill block + persistent unit
#   ./scripts/bluetooth-off.sh --rollback          # rfkill unblock + remove unit
#   ./scripts/bluetooth-off.sh --self-test
#
# --apply writes /etc/systemd/system/bluetooth-off.service (ExecStart=rfkill
# block bluetooth, WantedBy=multi-user.target) so the radio stays off after a
# reboot. --rollback removes it and unblocks the radio. Reversible.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, printf only, main() wrapper.
#
set -o pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UNIT="${BTOFF_UNIT:-/etc/systemd/system/bluetooth-off.service}"
JSON=0
SELFTEST="${BTOFF_SELFTEST:-0}"

usage() {
    printf 'usage: %s [--check|--apply|--rollback|--self-test] [--json]\n' "$0"
}

have() { command -v "$1" > /dev/null; }

log() { printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

is_root() { [ "$(id -u)" -eq 0 ]; }

can_root() { is_root || { have sudo && sudo -n true 2>&1; }; }

as_root() {
    if is_root; then "$@"
    elif have sudo && sudo -n true 2>&1; then sudo -n "$@"
    else return 1
    fi
}

rfkill_cmd() {
    if [ "$SELFTEST" = "1" ]; then log "selftest: rfkill $*"; return 0; fi
    as_root rfkill "$@"
}

systemctl_cmd() {
    if [ "$SELFTEST" = "1" ]; then log "selftest: systemctl $*"; return 0; fi
    as_root systemctl "$@"
}

rfkill_bin() {
    if have rfkill; then command -v rfkill; else printf '/usr/sbin/rfkill'; fi
}

service_active() { systemctl is-active bluetooth 2>&1; }
service_enabled() { systemctl is-enabled bluetooth 2>&1; }
unit_installed() { [ -f "$UNIT" ]; }

rfkill_summary() {
    if [ "$SELFTEST" = "1" ]; then printf 'soft:no hard:no'; return 0; fi
    have rfkill || { printf 'no-rfkill'; return 0; }
    rfkill list bluetooth 2>&1 | awk '/Soft blocked/{s=$3} /Hard blocked/{h=$3} END{printf "soft:%s hard:%s", (s?s:"?"), (h?h:"?")}'
}

btcoex_param() {
    if [ -r /sys/module/b43/parameters/btcoex ]; then cat /sys/module/b43/parameters/btcoex 2>&1
    elif [ -r /sys/module/iwlwifi/parameters/bt_coex_active ]; then cat /sys/module/iwlwifi/parameters/bt_coex_active 2>&1
    else printf 'n/a'; fi
}

write_unit() {
    local rfkill_bin="" tmp=""
    rfkill_bin="$(rfkill_bin)"
    if [ "$SELFTEST" = "1" ]; then
        mkdir -p "$(dirname "$UNIT")" 2>&1 || true
        printf '%s\n' '[Unit]' 'Description=Keep Bluetooth radio off' '' '[Service]' 'Type=oneshot' "ExecStart=$rfkill_bin block bluetooth" '' '[Install]' 'WantedBy=multi-user.target' > "$UNIT"
        return 0
    fi
    tmp="$(mktemp)"
    printf '%s\n' '[Unit]' 'Description=Keep Bluetooth radio off' '' '[Service]' 'Type=oneshot' "ExecStart=$rfkill_bin block bluetooth" '' '[Install]' 'WantedBy=multi-user.target' > "$tmp"
    if as_root install -m 0644 "$tmp" "$UNIT"; then
        log "wrote $UNIT"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    log "FAIL: write $UNIT (needs root)"
    return 2
}

remove_unit() {
    if [ -f "$UNIT" ]; then
        if [ "$SELFTEST" = "1" ]; then rm -f "$UNIT"; else as_root rm -f "$UNIT"; fi
        log "removed $UNIT"
    fi
}

do_check() {
    local sa se ui rf bt
    sa="$(service_active)"; se="$(service_enabled)"
    if unit_installed; then ui="yes"; else ui="no"; fi
    rf="$(rfkill_summary)"; bt="$(btcoex_param)"
    if [ "$JSON" = "1" ]; then
        printf '{"host":"%s","service_active":"%s","service_enabled":"%s","unit_installed":"%s","rfkill":"%s","btcoex":"%s"}\n' \
            "$(hostname 2>&1)" "$sa" "$se" "$ui" "$rf" "$bt"
        return 0
    fi
    printf 'host            : %s\n' "$(hostname 2>&1)"
    printf 'bluetooth.svc   : active=%s enabled=%s\n' "$sa" "$se"
    printf 'bluetooth-off   : unit=%s\n' "$ui"
    printf 'rfkill radio    : %s\n' "$rf"
    printf 'btcoex param    : %s\n' "$bt"
    return 0
}

do_apply() {
    if [ "$SELFTEST" != "1" ] && ! can_root; then
        log 'FAIL: root or passwordless sudo required'
        return 2
    fi
    write_unit || return 2
    if ! rfkill_cmd block bluetooth; then log 'FAIL: rfkill block'; return 2; fi
    systemctl_cmd daemon-reload || true
    systemctl_cmd enable --now bluetooth-off.service || log 'WARN: enable bluetooth-off.service'
    log 'Bluetooth radio powered off and pinned off across reboots'
    return 0
}

do_rollback() {
    systemctl_cmd disable --now bluetooth-off.service 2>&1 || true
    remove_unit
    systemctl_cmd daemon-reload 2>&1 || true
    rfkill_cmd unblock bluetooth 2>&1 || true
    log 'Bluetooth radio unblocked and the pin removed'
    return 0
}

self_test() {
    local tmp fail=0
    tmp="$(mktemp -d)"
    UNIT="$tmp/bluetooth-off.service"
    SELFTEST=1
    write_unit
    [ -f "$UNIT" ] || { printf 'FAIL unit not written\n'; fail=1; }
    grep -q 'block bluetooth' "$UNIT" || { printf 'FAIL unit content\n'; fail=1; }
    do_apply > "$tmp/out.log" 2>&1
    [ -f "$UNIT" ] || { printf 'FAIL apply removed unit\n'; fail=1; }
    do_rollback > "$tmp/out.log" 2>&1
    [ ! -f "$UNIT" ] || { printf 'FAIL rollback left unit\n'; fail=1; }
    rm -f "$UNIT" "$tmp/out.log"
    rmdir "$tmp" 2>&1 || true
    if [ "$fail" -eq 0 ]; then
        printf 'bluetooth-off: self-test PASS (unit + apply + rollback)\n'
    else
        printf 'bluetooth-off: self-test FAIL\n'
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
