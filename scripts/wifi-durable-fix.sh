#!/usr/bin/env bash
#
# wifi-durable-fix.sh - replace the reverse-engineered b43 driver with the
# vendor Broadcom `wl` driver (akmod-wl/kmod-wl), reversibly, with an automatic
# boot-time rollback if Wi-Fi does not come back.
#
# Why: the 2026-11-10 incident proved the BCM4331 client loses beacons on
# 2.4 GHz with b43 (2.4-GHz-only, 100+ BEACON-LOSS events in hours). Powersave
# was already off. The durable fix is the vendor driver, which supports 5 GHz
# and is far more stable. It is a system change, so every step is undoable.
#
#   ./scripts/wifi-durable-fix.sh --check          # read-only diagnosis
#   ./scripts/wifi-durable-fix.sh --check --json
#   ./scripts/wifi-durable-fix.sh --plan           # exact steps
#   ./scripts/wifi-durable-fix.sh --apply --yes    # install + arm rollback
#   ./scripts/wifi-durable-fix.sh --rollback --yes # back to b43 now
#   ./scripts/wifi-durable-fix.sh --status
#   ./scripts/wifi-durable-fix.sh --install-guard  # unit only (root)
#   ./scripts/wifi-durable-fix.sh --self-test      # offline, temp root
#
# Safety model:
#   1. Before changing anything, write /var/lib/wifi-durable/state with
#      phase=awaiting-reboot, prev_driver=..., and the rollback commands.
#   2. Install akmod-wl/kmod-wl, blacklist b43/bcma/ssb, rebuild initramfs.
#   3. Enable wifi-durable-guard.service. On boot it waits, then either marks
#      phase=ok (wl loaded + a Wi-Fi connection is active) or runs --rollback
#      automatically (blacklist removed, b43 restored, NetworkManager
#      restarted, optional reboot).
#   4. --rollback is idempotent and available at any time.
#
# The proprietary `wl` driver cannot be switched safely without dropping the
# link, so --apply schedules a reboot (WIFIDF_REBOOT_DELAY, default 20s).
# Run it detached from the notification button so the SSH/agent session can
# disappear without killing the operation.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, printf only, main() wrapper.
#
set -o pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT="${WIFIDF_ROOT:-/}"
STATE_DIR="${WIFIDF_STATE_DIR:-$ROOT/var/lib/wifi-durable}"
STATE="$STATE_DIR/state"
LOG="${WIFIDF_LOG:-$ROOT/var/log/wifi-durable.log}"
BLACKLIST="${WIFIDF_BLACKLIST:-$ROOT/etc/modprobe.d/99-wifi-durable-b43.conf}"
MODLOAD="${WIFIDF_MODLOAD:-$ROOT/etc/modules-load.d/wifi-durable-wl.conf}"
DRACUT_CONF="${WIFIDF_DRACUT_CONF:-$ROOT/etc/dracut.conf.d/99-wifi-durable.conf}"
GUARD_BIN="${WIFIDF_GUARD_BIN:-$ROOT/usr/local/sbin/wifi-durable-fix.sh}"
UNIT="${WIFIDF_UNIT:-$ROOT/etc/systemd/system/wifi-durable-guard.service}"
REBOOT_DELAY="${WIFIDF_REBOOT_DELAY:-20}"
GUARD_WAIT="${WIFIDF_GUARD_WAIT:-600}"
NM_CONNECTION="${WIFIDF_NM_CONNECTION:-belkin2}"
NM_ZONE="${WIFIDF_NM_ZONE:-trusted}"
NO_REBOOT="${WIFIDF_NO_REBOOT:-0}"
PURGE=0
JSON=0
ASSUME_YES=0
SELFTEST="${WIFIDF_SELFTEST:-0}"

usage() {
    printf 'usage: %s [--check|--plan|--apply|--rollback|--status|--install-guard|--guard-check|--self-test]\n' "$0"
    printf '          [--json] [--yes] [--no-reboot] [--purge] [--reboot]\n'
    printf '  --apply     install akmod-wl/kmod-wl + blacklist b43 + arm auto-rollback\n'
    printf '  --rollback  restore b43 (idempotent; --purge also removes the packages)\n'
    printf '  --recover-now stop/disable the boot guard, restore b43, no reboot\n'
    printf '  --check     read-only: distro, kernel, driver, RPMFusion, wl availability\n'
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

die() { printf 'ERROR: %s\n' "$*" >&2; return 2; }

state_get() {
    [ -f "$STATE" ] || return 0
    awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }' "$STATE"
}

state_set() {
    local k="$1" v="$2" tmp="$STATE.tmp.$$"
    mkdir -p "$STATE_DIR" 2>&1 || true
    {
        if [ -f "$STATE" ]; then grep -v "^$k=" "$STATE"; fi
        printf '%s=%s\n' "$k" "$v"
    } > "$tmp"
    mv "$tmp" "$STATE"
}

driver_now() {
    case "${WIFIDF_FAKE_DRIVER:-}" in
        '' ) : ;;
        * ) printf '%s' "$WIFIDF_FAKE_DRIVER"; return 0 ;;
    esac
    local iface driver
    iface="$(iw dev 2>&1 | awk '/^[[:space:]]*Interface /{print $2; exit}')"
    if [ -n "$iface" ] && have readlink; then
        driver="$(basename "$(readlink -f "/sys/class/net/$iface/device/driver" 2>&1)")"
        case "$driver" in *'No such'*|*'not found'*) driver="" ;; esac
        [ -n "$driver" ] && { printf '%s' "$driver"; return 0; }
    fi
    if have lspci; then
        driver="$(lspci -k 2>&1 | awk '/Network controller|Wireless/{f=1} f && /Kernel driver in use:/{print $NF; exit}')"
        [ -n "$driver" ] && { printf '%s' "$driver"; return 0; }
    fi
    printf 'unknown'
}

distro_id() {
    case "${WIFIDF_FAKE_DISTRO:-}" in
        '' ) : ;;
        * ) printf '%s' "$WIFIDF_FAKE_DISTRO"; return 0 ;;
    esac
    awk -F= '/^ID=/{gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>&1
}

kernel_rel() {
    case "${WIFIDF_FAKE_KERNEL:-}" in
        '' ) uname -r ;;
        * ) printf '%s' "$WIFIDF_FAKE_KERNEL" ;;
    esac
}

rpmfusion_enabled() {
    case "${WIFIDF_FAKE_RPMFUSION:-}" in
        yes|1|true) return 0 ;;
        no|0|false) return 1 ;;
    esac
    have dnf || return 1
    timeout 20 dnf repolist --enabled 2>&1 | grep -qi 'rpmfusion'
}

wl_available() {
    case "${WIFIDF_FAKE_WL_AVAILABLE:-}" in
        yes|1|true) return 0 ;;
        no|0|false) return 1 ;;
    esac
    have dnf || return 1
    timeout 60 dnf list --available akmod-wl 2>&1 | grep -q 'akmod-wl'
}

wl_loaded() {
    case "${WIFIDF_FAKE_LSMOD:-}" in
        wl) return 0 ;;
        b43) return 1 ;;
    esac
    have lsmod || return 1
    lsmod 2>&1 | grep -q '^wl '
}

nm_wifi_connected() {
    case "${WIFIDF_FAKE_NM:-}" in
        connected) return 0 ;;
        disconnected) return 1 ;;
    esac
    have nmcli || return 1
    nmcli -t -f DEVICE,TYPE,STATE device 2>&1 | grep -q 'wifi:connected'
}

is_root() {
    [ "${WIFIDF_FAKE_ROOT:-0}" = "1" ] && return 0
    [ "$(id -u)" -eq 0 ]
}

as_root() {
    if is_root; then
        "$@"
    elif have sudo && sudo -n true 2>&1; then
        sudo -n "$@"
    else
        return 1
    fi
}

cmd() {
    if [ "$SELFTEST" = "1" ]; then log "selftest: $*"; return 0; fi
    "$@"
}

active_wifi_iface() {
    case "${WIFIDF_FAKE_IFACE:-}" in
        '' ) : ;;
        * ) printf '%s' "$WIFIDF_FAKE_IFACE"; return 0 ;;
    esac
    have nmcli || return 1
    nmcli -t -f DEVICE,TYPE,STATE device 2>&1 | awk -F: '$2 == "wifi" && $3 == "connected" { print $1; exit }'
}

# The wl driver creates a NEW interface name. firewalld zone bindings are
# per-interface, so the old zone does not follow it; everything (SSH, ICMP,
# Tailscale, Nebula) can be dropped while ARP still works. Set the NM
# connection zone (applies to the new interface) and add the live interface.
prepare_zone() {
    local prev="default"
    if [ "$SELFTEST" != "1" ] && have nmcli; then
        prev="$(nmcli -g connection.zone connection show "$NM_CONNECTION" 2>&1)"
        case "$prev" in ''|*'not found'*|*'Error'*) prev="default" ;; esac
    fi
    state_set prev_zone "$prev"
    state_set nm_connection "$NM_CONNECTION"
    state_set nm_zone "$NM_ZONE"
    log "setting $NM_CONNECTION connection.zone=$NM_ZONE (was $prev)"
    cmd as_root nmcli connection modify "$NM_CONNECTION" connection.zone "$NM_ZONE" 2>&1 || true
}

restore_zone() {
    local pz=""
    pz="$(state_get prev_zone)"
    [ -n "$pz" ] || return 0
    log "restoring $NM_CONNECTION connection.zone=$pz"
    cmd as_root nmcli connection modify "$NM_CONNECTION" connection.zone "$pz" 2>&1 || true
}

ensure_zone_runtime() {
    local iface=""
    iface="$(active_wifi_iface)"
    [ -n "$iface" ] || return 0
    if have firewall-cmd; then
        cmd as_root firewall-cmd --zone="$NM_ZONE" --change-interface="$iface" 2>&1 || true
        cmd as_root firewall-cmd --permanent --zone="$NM_ZONE" --add-interface="$iface" 2>&1 || true
        cmd as_root firewall-cmd --reload 2>&1 || true
    fi
}

guard_l3_ok() {
    case "${WIFIDF_FAKE_L3:-}" in
        ok) return 0 ;;
        fail) return 1 ;;
    esac
    local target=""
    target="${WIFIDF_GUARD_PING:-}"
    if [ -z "$target" ] && have ip; then
        target="$(ip route show default 2>&1 | awk '/default via/{print $3; exit}')"
    fi
    [ -n "$target" ] || return 1
    have ping || return 1
    ping -c 1 -W 2 "$target" 2>&1 | grep -q 'bytes from'
}

install_rpmfusion() {
    local rel=""
    rel="$(rpm -E %fedora 2>&1)"
    case "$rel" in ''|*[!0-9]*) die "cannot determine Fedora release"; return 2 ;; esac
    log "enabling RPMFusion free + nonfree for Fedora $rel"
    cmd as_root dnf -y install \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$rel.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$rel.noarch.rpm" \
        || return 1
}

install_wl() {
    if [ "${WIFIDF_SKIP_KMOD:-0}" = "1" ]; then
        log "WIFIDF_SKIP_KMOD=1: using the already-built akmod-wl module (no kmod-wl transaction)"
        cmd as_root dnf -y install akmod-wl
        return $?
    fi
    log "installing akmod-wl + kmod-wl (kmod may be unavailable for this kernel)"
    if cmd as_root dnf -y install akmod-wl kmod-wl; then return 0; fi
    log "kmod-wl unavailable; installing akmod-wl only (builds on next boot)"
    cmd as_root dnf -y install akmod-wl
}

write_blacklist() {
    mkdir -p "$(dirname "$BLACKLIST")" 2>&1 || return 1
    {
        printf '%s\n' '# Managed by wifi-durable-fix.sh. Remove this file or run --rollback to restore b43.'
        printf '%s\n' 'blacklist b43'
        printf '%s\n' 'blacklist b43legacy'
        printf '%s\n' 'blacklist bcma'
        printf '%s\n' 'blacklist ssb'
        printf '%s\n' 'blacklist brcmsmac'
        printf '%s\n' 'install b43 /bin/false'
        printf '%s\n' 'install b43legacy /bin/false'
        printf '%s\n' 'install bcma /bin/false'
        printf '%s\n' 'install ssb /bin/false'
        printf '%s\n' 'install brcmsmac /bin/false'
    } > "$BLACKLIST"
    log "wrote $BLACKLIST (blacklist + hard install block)"
}

# The 2026-11-10 failure: b43 still loaded even with `blacklist b43`, so wl
# never bound. Force wl into the initramfs and omit the conflicting drivers.
write_boot_config() {
    mkdir -p "$(dirname "$MODLOAD")" "$(dirname "$DRACUT_CONF")" 2>&1 || return 1
    printf '%s\n' 'wl' > "$MODLOAD"
    {
        printf '%s\n' 'force_drivers+=" wl "'
        printf '%s\n' 'omit_drivers+=" b43 b43legacy bcma ssb brcmsmac "'
    } > "$DRACUT_CONF"
    log "wrote $MODLOAD and $DRACUT_CONF"
}

remove_boot_config() {
    local f=""
    for f in "$BLACKLIST" "$MODLOAD" "$DRACUT_CONF"; do
        if [ -f "$f" ]; then rm -f "$f"; log "removed $f"; fi
    done
}

remove_blacklist() {
    if [ -f "$BLACKLIST" ]; then
        rm -f "$BLACKLIST"
        log "removed $BLACKLIST"
    fi
}

run_dracut() {
    log "rebuilding initramfs (dracut -f)"
    if have dracut; then cmd as_root dracut -f; else log "dracut absent; skipping"; fi
}

install_guard() {
    local tmp=""
    if [ "$SELFTEST" != "1" ]; then
        cmd as_root mkdir -p "$(dirname "$GUARD_BIN")" "$(dirname "$UNIT")" 2>&1 || return 1
        cmd as_root install -m 0755 "$0" "$GUARD_BIN" || return 1
    else
        mkdir -p "$(dirname "$GUARD_BIN")" "$(dirname "$UNIT")" 2>&1 || return 1
        printf 'selftest guard\n' > "$GUARD_BIN"
        chmod 0755 "$GUARD_BIN" 2>&1 || true
    fi
    tmp="$(mktemp)"
    {
        printf '%s\n' '[Unit]'
        printf '%s\n' 'Description=Wi-Fi durable-fix rollback guard (b43 -> wl)'
        printf '%s\n' 'After=NetworkManager.service'
        printf '%s\n' 'Wants=NetworkManager.service'
        printf '%s\n' ''
        printf '%s\n' '[Service]'
        printf '%s\n' 'Type=oneshot'
        printf '%s\n' "ExecStart=$GUARD_BIN --guard-check"
        printf '%s\n' ''
        printf '%s\n' '[Install]'
        printf '%s\n' 'WantedBy=multi-user.target'
    } > "$tmp"
    if [ "$SELFTEST" != "1" ]; then
        cmd as_root install -m 0644 "$tmp" "$UNIT" || { rm -f "$tmp"; return 1; }
    else
        cp "$tmp" "$UNIT"
    fi
    rm -f "$tmp"
    log "wrote $UNIT"
    if [ "$SELFTEST" != "1" ]; then
        cmd as_root systemctl daemon-reload || return 1
        cmd as_root systemctl enable wifi-durable-guard.service || return 1
    fi
    return 0
}

notify() {
    local msg="$1"
    log "notify: $msg"
    [ "$SELFTEST" = "1" ] && return 0
    if have notify-send; then
        local uid dbus disp
        uid="$(id -u)"
        dbus="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$uid/bus}"
        disp="${DISPLAY:-:0}"
        DBUS_SESSION_BUS_ADDRESS="$dbus" DISPLAY="$disp" \
            notify-send -u normal -t 15000 "opencode wifi durable fix" "$msg" 2>&1 || true
    fi
}

schedule_reboot() {
    if [ "$NO_REBOOT" = "1" ] || [ "$SELFTEST" = "1" ]; then
        log "reboot skipped (--no-reboot or self-test)"
        return 0
    fi
    log "scheduling reboot in ${REBOOT_DELAY}s"
    (
        sleep "$REBOOT_DELAY"
        if is_root; then systemctl reboot; else sudo -n systemctl reboot; fi
    ) &
}

do_check() {
    local dr distro kern rpmf wla phase actionable="no" known_bad="no"
    dr="$(driver_now)"
    distro="$(distro_id)"
    kern="$(kernel_rel)"
    if rpmfusion_enabled; then rpmf="yes"; else rpmf="no"; fi
    if wl_available; then wla="yes"; else wla="no"; fi
    phase="$(state_get phase)"
    [ -z "$phase" ] && phase="none"
    case "${WIFIDF_FAKE_KNOWN_BAD:-}" in
        yes) known_bad="yes" ;;
        no) known_bad="no" ;;
        *) if have lspci && lspci -nn 2>&1 | grep -qi '14e4:4331'; then known_bad="yes"; fi ;;
    esac
    case "$dr" in
        wl) actionable="no" ;;
        b43|bcma|unknown) [ "$rpmf" = "yes" ] && [ "$wla" = "yes" ] && actionable="yes" ;;
    esac
    [ "$known_bad" = "yes" ] && actionable="no"
    if [ "$known_bad" = "yes" ]; then
        printf 'note         : wl loads but does not scan/associate on BCM4331 + Fedora 43 (unmaintained STA driver); use a USB WiFi/Ethernet adapter\n'
    fi
    if [ "$JSON" = "1" ]; then
        printf '{"distro":"%s","kernel":"%s","driver":"%s","rpmfusion":"%s","wl_available":"%s","phase":"%s","known_bad":"%s","actionable":"%s"}\n' \
            "$distro" "$kern" "$dr" "$rpmf" "$wla" "$phase" "$known_bad" "$actionable"
        return 0
    fi
    printf 'distro       : %s\n' "$distro"
    printf 'kernel       : %s\n' "$kern"
    printf 'driver now   : %s\n' "$dr"
    printf 'RPMFusion    : %s\n' "$rpmf"
    printf 'akmod-wl     : %s\n' "$wla"
    printf 'phase        : %s\n' "$phase"
    printf 'known_bad    : %s\n' "$known_bad"
    printf 'actionable   : %s\n' "$actionable"
    case "$dr" in
        wl) printf 'note         : already on the vendor wl driver; use --rollback to revert\n' ;;
        b43) printf 'note         : b43 is the reverse-engineered driver; wl adds 5 GHz + stability\n' ;;
    esac
    return 0
}

do_plan() {
    printf 'plan (all steps reversible; state: %s):\n' "$STATE"
    printf '  1. write %s (phase=awaiting-reboot, prev_driver)\n' "$STATE"
    printf '  2. enable RPMFusion free+nonfree if missing\n'
    printf '  3. install akmod-wl + kmod-wl (akmod-only fallback)\n'
    printf '  4. write %s (blacklist b43/b43legacy/bcma/ssb/brcmsmac)\n' "$BLACKLIST"
    printf '  5. dracut -f\n'
    printf '  6. install + enable %s\n' "$UNIT"
    printf '  7. reboot in %ss (WIFIDF_REBOOT_DELAY)\n' "$REBOOT_DELAY"
    printf '  8. on boot: guard waits up to %ss for the akmod build + wl + Layer 3; else --rollback + reboot\n' "$GUARD_WAIT"
    printf 'rollback now : %s --rollback --yes\n' "$0"
}

do_apply() {
    if [ "$SELFTEST" != "1" ] && ! is_root; then
        if have sudo && sudo -n true 2>&1; then
            log "re-executing with sudo -n"
            exec sudo -n env \
                WIFIDF_SKIP_KMOD="${WIFIDF_SKIP_KMOD:-0}" \
                WIFIDF_REBOOT_DELAY="$REBOOT_DELAY" \
                WIFIDF_GUARD_WAIT="$GUARD_WAIT" \
                WIFIDF_NM_CONNECTION="$NM_CONNECTION" \
                WIFIDF_NM_ZONE="$NM_ZONE" \
                WIFIDF_FORCE="${WIFIDF_FORCE:-0}" \
                "$0" --apply --yes
        fi
        die "root is required (run with sudo or configure passwordless sudo)"
        return 2
    fi
    if [ "${WIFIDF_FORCE:-0}" != "1" ] && [ "$SELFTEST" != "1" ]; then
        if [ "${WIFIDF_FAKE_KNOWN_BAD:-}" = "yes" ] || { have lspci && lspci -nn 2>&1 | grep -qi '14e4:4331'; }; then
            log "REFUSING: wl loads but cannot scan/associate on BCM4331 + Fedora 43 (unmaintained STA driver)."
            log "Use a USB WiFi adapter with an in-kernel driver or USB/Thunderbolt Ethernet. Override with WIFIDF_FORCE=1."
            notify "wl is not viable on this BCM4331. b43 remains active. Use a USB WiFi/Ethernet adapter."
            return 2
        fi
    fi
    if [ "$ASSUME_YES" != "1" ] && [ "$SELFTEST" != "1" ]; then
        printf 'This will install the vendor wl driver and REBOOT in %ss.\n' "$REBOOT_DELAY"
        printf 'Type YES to continue: '
        local ans=""
        read -r ans
        [ "$ans" = "YES" ] || { printf 'aborted\n'; return 0; }
    fi
    state_set phase installing
    state_set prev_driver "$(driver_now)"
    state_set created "$(date +%s)"
    if ! rpmfusion_enabled; then
        if ! install_rpmfusion; then
            log "RPMFusion enable failed; rolling back"
            do_rollback --auto >> "$LOG" 2>&1
            return 2
        fi
    fi
    if ! install_wl; then
        log "driver install failed; rolling back"
        do_rollback --auto >> "$LOG" 2>&1
        return 2
    fi
    prepare_zone || log "WARN: could not set the NM connection zone"
    if ! write_blacklist; then
        log "blacklist write failed; rolling back"
        do_rollback --auto >> "$LOG" 2>&1
        return 2
    fi
    if ! write_boot_config; then
        log "boot config write failed; rolling back"
        do_rollback --auto >> "$LOG" 2>&1
        return 2
    fi
    run_dracut || log "WARN: dracut failed; rollback guard still armed"
    if ! install_guard; then
        log "guard install failed; rolling back"
        do_rollback --auto >> "$LOG" 2>&1
        return 2
    fi
    state_set phase awaiting-reboot
    notify "wl installed. Reboot in ${REBOOT_DELAY}s. If Wi-Fi fails, b43 is restored automatically. Rollback: $0 --rollback --yes"
    schedule_reboot
    log "apply complete; awaiting reboot"
    return 0
}

do_rollback() {
    local auto="${1:-}"
    if [ "$SELFTEST" != "1" ] && ! is_root; then
        if have sudo && sudo -n true 2>&1; then
            if [ "$PURGE" = "1" ]; then exec sudo -n "$0" --rollback --yes --purge; fi
            exec sudo -n "$0" --rollback --yes
        fi
        die "root is required for rollback"
        return 2
    fi
    log "rollback: restoring b43${auto:+ ($auto)}"
    restore_zone
    remove_boot_config
    if have modprobe; then
        cmd as_root modprobe -r wl 2>&1 || true
        cmd as_root modprobe b43 2>&1 || true
    fi
    run_dracut || true
    if have systemctl; then cmd as_root systemctl restart NetworkManager 2>&1 || true; fi
    if [ "$PURGE" = "1" ]; then
        log "purging akmod-wl/kmod-wl/broadcom-wl"
        cmd as_root dnf -y remove akmod-wl kmod-wl broadcom-wl 2>&1 || true
    fi
    state_set phase rolled-back
    state_set rolled_back_at "$(date +%s)"
    notify "Wi-Fi rolled back to b43. NetworkManager restarted."
    if [ "$REBOOT" = "1" ] && [ "$SELFTEST" != "1" ]; then
        log "rollback reboot requested"
        cmd as_root systemctl reboot 2>&1 || true
    fi
    return 0
}

do_recover() {
    if [ "$SELFTEST" != "1" ] && ! is_root; then
        if have sudo && sudo -n true 2>&1; then
            exec sudo -n "$0" --recover-now
        fi
        die "root is required for --recover-now"
        return 2
    fi
    log "recover-now: stopping/disabling the guard, then restoring b43 (no reboot)"
    cmd as_root systemctl stop wifi-durable-guard.service 2>&1 || true
    cmd as_root systemctl disable wifi-durable-guard.service 2>&1 || true
    do_rollback
}

do_guard_check() {
    local phase="" i=0
    phase="$(state_get phase)"
    if [ "$phase" != "awaiting-reboot" ]; then
        log "guard: phase=$phase; nothing to do"
        return 0
    fi
    log "guard: awaiting Wi-Fi on wl; waiting up to ${GUARD_WAIT}s"
    local zone_fixed=0 wl_tried=0
    while :; do
        if ! wl_loaded && [ "$wl_tried" = "0" ]; then
            cmd as_root modprobe wl 2>&1 || true
            wl_tried=1
        fi
        if wl_loaded && nm_wifi_connected; then
            if [ "$zone_fixed" = "0" ]; then
                ensure_zone_runtime
                zone_fixed=1
            fi
            if guard_l3_ok; then
                state_set phase ok
            state_set ok_at "$(date +%s)"
                log "guard: wl loaded, Wi-Fi connected, and Layer 3 reachable; durable fix succeeded"
                notify "Wi-Fi durable fix succeeded: vendor wl driver is connected and routing traffic."
                return 0
            fi
            log "guard: wl+NM connected but Layer 3 is not reachable yet; waiting"
        fi
        [ "$i" -ge "$GUARD_WAIT" ] && break
        i=$((i + 5))
        sleep 5
    done
    log "guard: no stable Wi-Fi on wl after ${GUARD_WAIT}s; rolling back to b43"
    notify "Wi-Fi did not come back on wl; rolling back to b43 automatically."
    REBOOT=1 do_rollback auto
    return 0
}

do_status() {
    printf 'state file : %s\n' "$STATE"
    if [ -f "$STATE" ]; then awk '{print "  " $0}' "$STATE"; else printf '  (none)\n'; fi
    printf 'blacklist  : %s\n' "$BLACKLIST"
    [ -f "$BLACKLIST" ] && printf '  present\n' || printf '  absent\n'
    printf 'guard unit : %s\n' "$UNIT"
    [ -f "$UNIT" ] && printf '  present\n' || printf '  absent\n'
    printf 'driver now : %s\n' "$(driver_now)"
    return 0
}

self_test() {
    local tmp fail=0 STEPLOG=""
    tmp="$(mktemp -d)"
    STEPLOG="$tmp/step.log"
    ROOT="$tmp"
    STATE_DIR="$tmp/var/lib/wifi-durable"
    STATE="$STATE_DIR/state"
    LOG="$tmp/var/log/wifi-durable.log"
    BLACKLIST="$tmp/etc/modprobe.d/99-wifi-durable-b43.conf"
    MODLOAD="$tmp/etc/modules-load.d/wifi-durable-wl.conf"
    DRACUT_CONF="$tmp/etc/dracut.conf.d/99-wifi-durable.conf"
    GUARD_BIN="$tmp/usr/local/sbin/wifi-durable-fix.sh"
    UNIT="$tmp/etc/systemd/system/wifi-durable-guard.service"
    SELFTEST=1
    NO_REBOOT=1
    export WIFIDF_FAKE_ROOT=1 WIFIDF_FAKE_DRIVER=b43 WIFIDF_FAKE_RPMFUSION=yes
    export WIFIDF_FAKE_WL_AVAILABLE=yes WIFIDF_FAKE_DISTRO=fedora WIFIDF_FAKE_KERNEL=test
    export WIFIDF_FAKE_IFACE=wlp2s0 WIFIDF_FAKE_L3=fail

    state_set phase pending
    [ "$(state_get phase)" = "pending" ] || { printf 'FAIL state round-trip\n'; fail=1; }

    do_apply --yes > "$STEPLOG" 2>&1
    [ -f "$BLACKLIST" ] || { printf 'FAIL blacklist missing\n'; fail=1; }
    [ "$(state_get phase)" = "awaiting-reboot" ] || { printf 'FAIL apply phase=%s\n' "$(state_get phase)"; fail=1; }
    [ -f "$UNIT" ] || { printf 'FAIL guard unit missing\n'; fail=1; }
    [ -f "$MODLOAD" ] || { printf 'FAIL modules-load missing\n'; fail=1; }
    [ -f "$DRACUT_CONF" ] || { printf 'FAIL dracut conf missing\n'; fail=1; }

    export WIFIDF_FAKE_LSMOD=b43 WIFIDF_FAKE_NM=disconnected
    GUARD_WAIT=0 do_guard_check > "$STEPLOG" 2>&1
    [ "$(state_get phase)" = "rolled-back" ] || { printf 'FAIL auto-rollback phase=%s\n' "$(state_get phase)"; fail=1; }
    [ ! -f "$BLACKLIST" ] || { printf 'FAIL rollback left blacklist\n'; fail=1; }

    export WIFIDF_FAKE_LSMOD=wl WIFIDF_FAKE_NM=connected WIFIDF_FAKE_L3=ok
    do_apply --yes > "$STEPLOG" 2>&1
    GUARD_WAIT=0 do_guard_check > "$STEPLOG" 2>&1
    [ "$(state_get phase)" = "ok" ] || { printf 'FAIL guard success phase=%s\n' "$(state_get phase)"; fail=1; }

    PURGE=0 do_rollback > "$STEPLOG" 2>&1
    [ "$(state_get phase)" = "rolled-back" ] || { printf 'FAIL manual rollback\n'; fail=1; }

    rm -f "$STATE" "$LOG" "$BLACKLIST" "$MODLOAD" "$DRACUT_CONF" "$UNIT" "$GUARD_BIN" "$STEPLOG"
    for d in "$STATE_DIR" "$tmp/var/lib" "$tmp/var/log" "$tmp/var" \
        "$tmp/etc/modprobe.d" "$tmp/etc/modules-load.d" "$tmp/etc/dracut.conf.d" \
        "$tmp/etc/systemd/system" "$tmp/etc/systemd" "$tmp/etc" \
        "$tmp/usr/local/sbin" "$tmp/usr/local" "$tmp/usr" "$tmp"; do
        [ -d "$d" ] && rmdir "$d" 2>&1
    done
    if [ "$fail" -eq 0 ]; then
        printf 'wifi-durable-fix: self-test PASS (state + apply + guard rollback + guard success + manual rollback)\n'
    else
        printf 'wifi-durable-fix: self-test FAIL\n'
    fi
    return "$fail"
}

main() {
    local action="check"
    REBOOT=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --check) action="check"; shift ;;
            --plan) action="plan"; shift ;;
            --apply) action="apply"; shift ;;
            --rollback) action="rollback"; shift ;;
            --status) action="status"; shift ;;
            --install-guard) action="install-guard"; shift ;;
            --guard-check) action="guard-check"; shift ;;
            --recover-now) action="recover-now"; shift ;;
            --self-test) self_test; return "$?" ;;
            --json) JSON=1; shift ;;
            --yes) ASSUME_YES=1; shift ;;
            --no-reboot) NO_REBOOT=1; shift ;;
            --reboot) REBOOT=1; shift ;;
            --purge) PURGE=1; shift ;;
            -h|--help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 3 ;;
        esac
    done
    case "$action" in
        check) do_check; return "$?" ;;
        plan) do_plan; return 0 ;;
        apply) do_apply "$@"; return "$?" ;;
        rollback) do_rollback; return "$?" ;;
        status) do_status; return 0 ;;
        install-guard) install_guard; return "$?" ;;
        guard-check) do_guard_check; return "$?" ;;
        recover-now) do_recover; return "$?" ;;
    esac
    usage >&2
    return 3
}

main "$@"
