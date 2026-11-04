#!/usr/bin/env bash
#
# audit-a1286-network.sh - read-only network forensics for a MacBookPro
# A1286/A1278 (Broadcom BCM4322/BCM4331 Wi-Fi, BCM5764M/BCM57765 Ethernet)
# on Fedora + X11/XFCE. Covers b43, brcmsmac, and the proprietary wl driver.
#
# Symptom this targets: network works at boot, then after logout/login the
# desktop has no network; `ping` says "Network is unreachable"; only a full
# reboot recovers. "Network is unreachable" is a routing/IP failure, not a
# DNS failure, so the collector prioritises link, rfkill, association,
# DHCP/lease, default route, NetworkManager authorization, and the
# Broadcom wl/brcmsmac driver state.
#
# Read-only: no restarts, no nmcli modify/up/down, no modprobe, no sysctl,
# no firewall changes. The only writes are the report and its raw capture.
# Run it while the fault is present. If you already rebooted, run it anyway:
# previous-boot logs are collected and scanned as well.
#
# Usage:
#   ./scripts/audit-a1286-network.sh
#   sudo ./scripts/audit-a1286-network.sh --out /tmp/a1286-broken.txt
#   ./scripts/audit-a1286-network.sh --probe      # adds ping/getent probes
#   sudo ./scripts/audit-a1286-network.sh --watch 90
#
# Options:
#   --probe        also run ping and DNS lookups (default: local checks only)
#   --watch SECS   stream live NM/wpa/logind/iw/dbus events while you reproduce
#   --out FILE     write the combined report here (default /tmp/...txt)
#   -h, --help     show this help
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -uo pipefail

OUT=""
PROBE=0
WATCH=0
WATCH_BASE=""
CAP=""
H=0
M=0
L=0
HIGH_FINDINGS=""
T0_MS=0
J0=""
J1=""

usage() {
    printf '%s\n' \
        'Usage: audit-a1286-network.sh [--probe] [--out FILE]' \
        '' \
        'Read-only audit for A1286/A1278 / Fedora 43 / X11-XFCE network loss after' \
        'logout. Collects live link, rfkill, association, DHCP, route, driver,' \
        'NetworkManager, keyring, logind, DNS, and previous-boot evidence, then' \
        'prints ranked cause candidates followed by the verbatim capture.' \
        '' \
        '  --probe       run ping/getent reachability probes (default: local only)' \
        '  --watch SECS  stream live NM/wpa/logind/iw/dbus events during repro' \
        '  --out FILE    write the combined report to FILE' \
        '  -h, --help    this help'
}

have() { command -v "$1" >/dev/null; }

now_ms() {
    local t="${EPOCHREALTIME:-}"
    if [ -z "$t" ]; then
        printf '%s000' "$(date +%s)"
        return
    fi
    local s="${t%%.*}" us="${t#*.}"
    [ -n "$us" ] || us=0
    printf '%d' "$(( s * 1000 + 10#${us:0:3} ))"
}

progress() {
    local msg="$1" now elapsed line
    now=$(now_ms)
    elapsed=$(( now - T0_MS ))
    line=$(printf 'progress ts=%s elapsed_ms=%s %s' \
        "$(date -u +%H:%M:%S)" "$elapsed" "$msg")
    if [ -t 2 ]; then
        printf '%s\n' "$line" >&2
    elif [ -t 1 ]; then
        printf '%s\n' "$line" >&1
    elif [ -t 0 ]; then
        printf '%s\n' "$line" >/dev/tty
    else
        printf '%s\n' "$line" >&2
    fi
}

tmo() {
    local secs="$1"
    shift
    if have timeout; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

VALS=""
cval() {
    printf '%s\n' "$VALS" | awk -F: -v k="$1" '
        $1 == k { sub(/^[^:]*:/, ""); print; exit }
    '
}

run_heartbeat() {
    local label="$1" out="$2"
    shift 2
    "$@" > "$out" 2>&1 &
    local pid=$! start now
    start=$(now_ms)
    progress "$label started -> $out"
    if have ps; then
        while ps -p "$pid" >/dev/null; do
            sleep 5
            if ps -p "$pid" >/dev/null; then
                now=$(now_ms)
                progress "$label still running ($(( (now - start) / 1000 ))s)"
            fi
        done
    fi
    wait "$pid"
}

watch_mode() {
    local secs="$1" base="$2" p1 p2 p3 p4
    if ! have timeout; then
        printf 'watch skipped: timeout(1) is required\n'
        return 1
    fi
    progress "WATCH ${secs}s: reproduce the logout/login now"
    printf 'Reproduce the failure now; capturing live events for %ss.\n' "$secs"
    timeout "$secs" journalctl -f -o short-iso -u NetworkManager -u wpa_supplicant -u systemd-logind > "$base.watch.journal" 2>&1 &
    p1=$!
    p2=""
    p3=""
    p4=""
    if have nmcli; then
        timeout "$secs" nmcli monitor > "$base.watch.nmcli" 2>&1 &
        p2=$!
    fi
    if have iw; then
        timeout "$secs" iw event -t > "$base.watch.iw" 2>&1 &
        p3=$!
    fi
    if have dbus-monitor; then
        timeout "$secs" dbus-monitor --system "type='signal',sender='org.freedesktop.NetworkManager'" > "$base.watch.dbus" 2>&1 &
        p4=$!
    fi
    if have ps; then
        while ps -p "$p1" >/dev/null; do
            sleep 5
            if ps -p "$p1" >/dev/null; then
                progress "WATCH still running (target ${secs}s)"
            fi
        done
    fi
    wait "$p1"
    [ -z "$p2" ] || wait "$p2"
    [ -z "$p3" ] || wait "$p3"
    [ -z "$p4" ] || wait "$p4"
    progress "WATCH complete; files ${base}.watch.*"
}

sec() {
    progress "collecting $1"
    printf '\n@@@ %s @@@\n' "$1"
}

sec_body() {
    local file="$1" tag="$2"
    awk -v t="@@@ $tag @@@" '
        $0 == t { on = 1; next }
        on && /^@@@ [A-Z0-9]+ @@@$/ { on = 0 }
        on { print }
    ' "$file"
}

oneline() {
    local s="$1"
    s=${s//$'\n'/; }
    printf '%s' "${s:0:600}"
}

hit() {
    local sev="$1" tag="$2" title="$3" ev="$4" nxt="$5"
    case "$sev" in
        HIGH)
            H=$((H + 1))
            HIGH_FINDINGS="${HIGH_FINDINGS}${tag}: ${title}"$'\n'
            ;;
        MED)  M=$((M + 1)) ;;
        LOW)  L=$((L + 1)) ;;
    esac
    printf '\n[%s] %s - %s\n' "$sev" "$tag" "$title"
    [ -n "$ev" ] && printf '  evidence: %s\n' "$(oneline "$ev")"
    [ -n "$nxt" ] && printf '  next:     %s\n' "$nxt"
}

collect() {
    local conn_count=0
    local -a c1s_lines=()
    local name typ uuid dev auto vals
    local perms cauto cpsk ckey cmethod cintf cnever cign cpower cmac cdhcp croute cacrety cauthrety

    sec S0
    printf 'utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'euid=%s user=%s host=%s\n' "$(id -u)" "$(id -un)" "$(uname -n)"
    cat /etc/os-release
    uname -a
    uptime
    cat /sys/class/dmi/id/sys_vendor 2>&1
    cat /sys/class/dmi/id/product_name 2>&1
    cat /sys/class/dmi/id/product_version 2>&1
    cat /sys/class/dmi/id/board_name 2>&1
    printf 'cmdline: '
    cat /proc/cmdline 2>&1

    sec S1
    for c in nmcli ip rfkill iw ethtool journalctl loginctl resolvectl \
             getent ping rpm modinfo lspci timeout awk grep; do
        if have "$c"; then
            printf 'present %s\n' "$c"
        else
            printf 'MISSING %s\n' "$c"
        fi
    done

    sec J0
    printf 'file=%s\n' "$J0"
    if have journalctl; then
        run_heartbeat "journal boot 0 (one full pass)" "$J0" \
            journalctl -b -o short-iso --no-pager
        printf 'lines=%s bytes=%s\n' "$(wc -l < "$J0")" "$(wc -c < "$J0")"
        progress "journal boot 0 captured"
    else
        printf 'journalctl missing\n' > "$J0"
    fi

    sec J1
    printf 'file=%s\n' "$J1"
    if have journalctl; then
        run_heartbeat "journal boot -1 (one full pass)" "$J1" \
            journalctl -b -1 -o short-iso --no-pager
        printf 'lines=%s bytes=%s\n' "$(wc -l < "$J1")" "$(wc -c < "$J1")"
        progress "journal boot -1 captured"
    else
        printf 'journalctl missing\n' > "$J1"
    fi

    sec A0
    if have nmcli; then
        nmcli general status 2>&1
        nmcli general permissions 2>&1
        nmcli networking 2>&1
        nmcli radio all 2>&1
        nmcli -f DEVICE,TYPE,STATE,CONNECTION device status 2>&1
    else
        printf 'nmcli missing\n'
    fi

    sec A1
    ip -4 route show default 2>&1

    sec A2
    ip -6 route show default 2>&1

    sec A3
    ip -4 -o address show scope global 2>&1

    sec A3A
    ip -4 -o address show 2>&1

    sec A4
    ip route show table all 2>&1 | head -n 100

    sec A5
    ip route get 1.1.1.1 2>&1
    ip route get 8.8.8.8 2>&1

    sec A5V
    ip -6 route get 2606:4700:4700::1111 2>&1

    sec A6
    ip -brief link show 2>&1
    ip -details link show 2>&1 | head -n 200

    sec A7
    ip neigh show 2>&1

    sec A8
    for dev in /sys/class/net/*; do
        i=$(basename "$dev")
        [ "$i" = "lo" ] && continue
        printf '\n-- iface %s\n' "$i"
        ethtool "$i" 2>&1 | grep -E 'Link detected|Speed|Duplex|Auto-negotiation|Supported ports'
        ethtool -S "$i" 2>&1 | grep -iE 'error|drop|miss|fail' | head -n 20
    done

    sec A9
    ip rule show 2>&1
    ip -6 route show table all 2>&1 | head -n 100

    sec B0
    rfkill list 2>&1
    for r in /sys/class/rfkill/rfkill*; do
        [ -e "$r/name" ] || continue
        printf '%s name=%s soft=%s hard=%s\n' \
            "$(basename "$r")" "$(cat "$r/name" 2>&1)" \
            "$(cat "$r/soft" 2>&1)" "$(cat "$r/hard" 2>&1)"
    done

    sec B1
    iw dev 2>&1
    for w in /sys/class/net/*/wireless; do
        [ -e "$w" ] || continue
        i=$(basename "$(dirname "$w")")
        printf '\n-- wifi %s\n' "$i"
        iw dev "$i" info 2>&1
        iw dev "$i" link 2>&1
        iw dev "$i" get power_save 2>&1
    done

    sec B2
    lspci -nnk 2>&1 | grep -A4 -Ei 'Network controller|Ethernet controller|Wireless'
    printf '\n-- lsmod\n'
    lsmod 2>&1 | grep -Ei '^(wl|brcmsmac|bcma|b43|ssb|tg3|cfg80211|mac80211|lib80211)'
    for m in wl brcmsmac b43 tg3; do
        printf '\n-- modinfo %s\n' "$m"
        modinfo "$m" 2>&1 | grep -E '^(filename|version|vermagic|srcversion|depends|firmware):'
    done

    sec B3
    rpm -qa 2>&1 | grep -iE 'broadcom|akmod|kmod|linux-firmware|wl' | sort
    printf '\n-- /lib/firmware/brcm\n'
    ls -l /lib/firmware/brcm 2>&1 | head -n 60
    printf '\n-- /lib/firmware/b43\n'
    ls -l /lib/firmware/b43 2>&1 | head -n 30
    printf '\n-- akmods\n'
    ls -la /var/log/akmods.log /var/cache/akmods 2>&1 | head -n 40

    sec B4
    grep -RnsE 'blacklist|options[[:space:]]+(wl|brcmsmac|b43|bcma|tg3)|install[[:space:]]+(wl|brcmsmac|b43|bcma|tg3)' /etc/modprobe.d 2>&1
    cat /etc/modules-load.d/*.conf 2>&1
    grep -E 'GRUB_CMDLINE_LINUX' /etc/default/grub 2>&1

    sec C0
    NetworkManager --print-config 2>&1 | head -n 160
    grep -RnsE 'auth-polkit|dns[[:space:]]*=|wifi\.|powersave|unmanaged|autoconnect|keep|permissions' /etc/NetworkManager 2>&1 | head -n 120
    ls -la /etc/NetworkManager/system-connections 2>&1

    sec C1
    if have nmcli; then
        nmcli -t -f NAME,UUID,TYPE,DEVICE,AUTOCONNECT connection show 2>&1
        while IFS=: read -r name typ uuid dev auto; do
            [ -n "$name" ] || continue
            case "$typ" in
                802-11-wireless|802-3-ethernet|bridge|bond|vlan|team) ;;
                *) continue ;;
            esac
            conn_count=$((conn_count + 1))
            [ "$conn_count" -le 40 ] || break
            vals=$(tmo 6 nmcli -t -f \
                connection.permissions,connection.autoconnect,connection.autoconnect-priority,connection.autoconnect-retries,connection.auth-retries,connection.interface-name,connection.timestamp,connection.read-only,connection.multi-connect,ipv4.method,ipv4.never-default,ipv4.ignore-auto-routes,ipv4.dhcp-timeout,ipv4.route-metric,ipv4.dhcp-client-id,ipv6.method,802-11-wireless.powersave,802-11-wireless-security.key-mgmt,802-11-wireless-security.psk-flags,802-11-wireless.cloned-mac-address,802-3-ethernet.cloned-mac-address \
                connection show "$name" 2>&1)
            VALS="$vals"
            printf '\n-- connection: %s type=%s device=%s autoconnect=%s\n' \
                "$name" "$typ" "$dev" "$auto"
            printf '%s\n' "$vals"
            perms=$(cval connection.permissions)
            cauto=$(cval connection.autoconnect)
            cpsk=$(cval 802-11-wireless-security.psk-flags)
            ckey=$(cval 802-11-wireless-security.key-mgmt)
            cmethod=$(cval ipv4.method)
            cintf=$(cval connection.interface-name)
            cnever=$(cval ipv4.never-default)
            cign=$(cval ipv4.ignore-auto-routes)
            cpower=$(cval 802-11-wireless.powersave)
            cmac=$(cval 802-11-wireless.cloned-mac-address)
            [ -n "$cmac" ] || cmac=$(cval 802-3-ethernet.cloned-mac-address)
            cdhcp=$(cval ipv4.dhcp-timeout)
            croute=$(cval ipv4.route-metric)
            cacrety=$(cval connection.autoconnect-retries)
            cauthrety=$(cval connection.auth-retries)
            case "$typ" in
                802-11-wireless)
                    printf 'mac-address-randomization=%s\n' \
                        "$(tmo 6 nmcli -g 802-11-wireless.mac-address-randomization connection show "$name" 2>&1)"
                    printf 'password-flags=%s\n' \
                        "$(tmo 6 nmcli -g 802-11-wireless-security.password-flags connection show "$name" 2>&1)"
                    printf 'wep-key-flags=%s\n' \
                        "$(tmo 6 nmcli -g 802-11-wireless-security.wep-key-flags connection show "$name" 2>&1)"
                    ;;
            esac
            case "$ckey" in
                *eap*)
                    printf '802-1x.eap=%s\n' "$(tmo 6 nmcli -g 802-1x.eap connection show "$name" 2>&1)"
                    printf '802-1x.phase2-auth=%s\n' "$(tmo 6 nmcli -g 802-1x.phase2-auth connection show "$name" 2>&1)"
                    printf '802-1x.password-flags=%s\n' "$(tmo 6 nmcli -g 802-1x.password-flags connection show "$name" 2>&1)"
                    printf '802-1x.private-key=%s\n' "$(tmo 6 nmcli -g 802-1x.private-key connection show "$name" 2>&1)"
                    printf '802-1x.client-cert=%s\n' "$(tmo 6 nmcli -g 802-1x.client-cert connection show "$name" 2>&1)"
                    printf '802-1x.ca-cert=%s\n' "$(tmo 6 nmcli -g 802-1x.ca-cert connection show "$name" 2>&1)"
                    ;;
            esac
            c1s_lines+=("$name"$'\x1f'"$typ"$'\x1f'"$perms"$'\x1f'"$cauto"$'\x1f'"$cpsk"$'\x1f'"$ckey"$'\x1f'"$cmethod"$'\x1f'"$cintf"$'\x1f'"$cnever"$'\x1f'"$cign"$'\x1f'"$cpower"$'\x1f'"$cmac"$'\x1f'"$cdhcp"$'\x1f'"$croute"$'\x1f'"$cacrety"$'\x1f'"$cauthrety")
        done < <(nmcli -t -f NAME,TYPE,UUID,DEVICE,AUTOCONNECT connection show 2>&1)
    else
        printf 'nmcli missing\n'
    fi

    sec C1S
    printf 'machine format, US=0x1f: name US type US permissions US autoconnect US psk-flags US key-mgmt US method US ifname US never-default US ignore-auto-routes US powersave US cloned-mac US dhcp-timeout US route-metric US autoconnect-retries US auth-retries\n'
    if [ "${#c1s_lines[@]}" -gt 0 ]; then
        printf '%s\n' "${c1s_lines[@]}"
    else
        printf 'no wifi/ethernet/bridge/bond/vlan/team connection profiles found\n'
    fi

    sec C2
    if have nmcli; then
        nmcli -f NAME,UUID,TYPE,DEVICE,STATE,ACTIVE connection show --active 2>&1 | head -n 60
        nmcli -f GENERAL,IP4,IP6,WIFI-PROPERTIES device show 2>&1 | head -n 260
    else
        printf 'nmcli missing\n'
    fi

    sec C3
    loginctl list-sessions --no-legend 2>&1
    for s in $(loginctl list-sessions --no-legend 2>&1 | awk '{print $1}'); do
        printf '\n-- session %s\n' "$s"
        loginctl show-session "$s" -p Id -p User -p Name -p Type -p Class \
            -p Active -p State -p Remote -p Seat -p TTY 2>&1
    done
    loginctl show-user "$TARGET_USER" -p User -p Name -p State -p Linger \
        -p Sessions -p Display 2>&1
    grep -RnsE 'KillUserProcesses|IdleAction|HandleLidSwitch|HandlePowerKey' \
        /etc/systemd/logind.conf /etc/systemd/logind.conf.d 2>&1

    sec C4
    pgrep -a -f 'NetworkManager|wpa_supplicant|iwd|nm-applet|xfce4-session|xfce4-power-manager|gnome-keyring|kwallet|polkit' 2>&1

    sec C5
    if [ -d /etc/NetworkManager/system-connections ]; then
        for f in /etc/NetworkManager/system-connections/*; do
            [ -e "$f" ] || continue
            printf '\n-- keyfile %s\n' "$(basename "$f")"
            grep -E '^(permissions|autoconnect|autoconnect-priority|autoconnect-retries|auth-retries|interface-name|method|never-default|ignore-auto-routes|dhcp-timeout|route-metric|key-mgmt|psk-flags|powersave|cloned-mac-address)=' "$f" 2>&1
        done
    else
        printf 'no /etc/NetworkManager/system-connections\n'
    fi

    sec C6
    for u in NetworkManager wpa_supplicant iwd systemd-resolved; do
        printf '%s is-active=%s is-enabled=%s\n' "$u" \
            "$(systemctl is-active "$u" 2>&1)" \
            "$(systemctl is-enabled "$u" 2>&1)"
    done
    systemctl --failed --no-legend 2>&1

    sec C7
    cat /var/lib/NetworkManager/NetworkManager.state 2>&1
    ls -la /var/lib/NetworkManager 2>&1 | head -n 40
    ls -la /run/NetworkManager 2>&1 | head -n 40
    for l in /var/lib/NetworkManager/*.lease; do
        [ -e "$l" ] || continue
        printf '\n-- lease %s\n' "$l"
        grep -aE '^(ADDRESS|NETMASK|ROUTER|SERVER_ADDRESS|NEXT_SERVER|expire|renew|rebind|interface|ip_address|routers|domain_name_servers)' "$l" 2>&1 | head -n 20
    done

    sec D0
    ls -l /etc/resolv.conf 2>&1
    cat /etc/resolv.conf 2>&1
    systemctl is-active systemd-resolved 2>&1
    systemctl is-enabled systemd-resolved 2>&1
    resolvectl status 2>&1
    resolvectl dns 2>&1
    resolvectl domain 2>&1

    sec D1
    ip route get 1.1.1.1 2>&1
    if [ "$PROBE" -eq 1 ]; then
        timeout 4 ping -c 1 -W 2 1.1.1.1 2>&1
        timeout 6 getent ahostsv4 fedoraproject.org 2>&1
        timeout 6 getent ahostsv6 fedoraproject.org 2>&1
    else
        printf 'probe skipped (use --probe for ping/getent)\n'
    fi

    sec E0
    grep -iE 'kernel:' "$J0" | tail -n 400
    grep -iE 'kernel:' "$J0" | grep -iE 'wl:|brcmsmac|bcma|b43|ssb|tg3|firmware|AER:|PCIe Bus Error|tx timeout|hung task|soft lockup|Oops|BUG:|link is|carrier|rfkill|ieee80211|cfg80211|deauth|reason=|disconnect|reset' | tail -n 200

    sec E1
    grep -iE 'NetworkManager' "$J0" | tail -n 400
    grep -iE 'NetworkManager' "$J0" | grep -iE 'error|warn|auth|permission|polkit|secret|keyring|supplicant|associat|deauth|reason=|dhcp|timeout|unmanaged|unavailable|sleep|suspend|resume|carrier|link|deactivat|activ|session' | tail -n 200

    sec E2
    grep -iE 'wpa_supplicant' "$J0" | tail -n 300
    grep -iE 'wpa_supplicant' "$J0" | grep -iE 'error|fail|timeout|disconnect|deauth|reason=|scan|associat|auth' | tail -n 150
    grep -iE 'iwd' "$J0" | tail -n 100

    sec E3
    grep -iE 'systemd-logind|session opened|session closed|Removed session|New session|logout|login|polkit' "$J0" | tail -n 150

    sec E4
    grep -iE 'PM: suspend|PM: resume|suspend entry|suspend exit|systemd-suspend|Lid Switch|Power Button|power key|hibernate' "$J0" | tail -n 100

    sec E5
    grep -iE 'kernel:' "$J1" | tail -n 250
    grep -iE 'kernel:' "$J1" | grep -iE 'wl:|brcmsmac|bcma|b43|ssb|tg3|firmware|AER:|PCIe Bus Error|tx timeout|hung task|Oops|BUG:|link is|carrier|rfkill|ieee80211|cfg80211|deauth|reason=|disconnect|reset' | tail -n 150

    sec E6
    grep -iE 'NetworkManager' "$J1" | tail -n 250
    grep -iE 'NetworkManager' "$J1" | grep -iE 'error|warn|auth|permission|polkit|secret|keyring|supplicant|associat|deauth|reason=|dhcp|timeout|unmanaged|unavailable|sleep|suspend|resume|carrier|link|deactivat|activ|session' | tail -n 150

    sec E7
    grep -iE 'wpa_supplicant' "$J1" | tail -n 200
    grep -iE 'wpa_supplicant' "$J1" | grep -iE 'error|fail|timeout|disconnect|deauth|reason=|scan|associat|auth' | tail -n 100

    sec E8
    grep -iE 'systemd-logind|session opened|session closed|Removed session|logout|login|polkit' "$J1" | tail -n 100

    sec F0
    for w in /sys/class/net/*/wireless; do
        [ -e "$w" ] || continue
        i=$(basename "$(dirname "$w")")
        printf '\n-- power %s\n' "$i"
        iw dev "$i" get power_save 2>&1
        printf 'power/control=%s\n' "$(cat "/sys/class/net/$i/device/power/control" 2>&1)"
    done
    for p in /sys/module/wl/parameters/*; do
        [ -e "$p" ] || continue
        printf 'wl.%s=%s\n' "$(basename "$p")" "$(cat "$p" 2>&1)"
    done
    grep -RnsE 'wifi\.powersave|powersave' /etc/NetworkManager 2>&1
    systemctl is-active tlp 2>&1
    systemctl is-active powertop 2>&1

    sec F1
    pgrep -a -f 'nm-applet|xfce4-network|xfce4-power-manager|xfce4-session|gnome-keyring' 2>&1
    ls -la "$TARGET_HOME/.config/autostart" 2>&1
    tail -n 80 "$TARGET_HOME/.xsession-errors" 2>&1

    sec F2
    for p in /var/log/Xorg.0.log /var/log/Xorg.1.log \
             "$TARGET_HOME/.local/share/xsession-errors" \
             "$TARGET_HOME/.xsession-errors"; do
        [ -e "$p" ] || continue
        printf '\n-- %s (tail)\n' "$p"
        tail -n 80 "$p" 2>&1
    done
    tmo 20 journalctl _UID="$(id -u "$TARGET_USER" 2>&1)" -b -o short-iso --no-pager 2>&1 \
        | grep -iE 'network|nm-applet|keyring|polkit|xfce4-session|logout|login' \
        | tail -n 120

    sec A10
    if have nft; then
        nft list ruleset 2>&1 | head -n 300
    else
        printf 'nft missing\n'
    fi
    if have firewall-cmd; then
        firewall-cmd --state 2>&1
        firewall-cmd --list-all 2>&1 | head -n 100
        firewall-cmd --list-all-zones 2>&1 | grep -iE 'target|interfaces|services|ports|rich rules' | head -n 120
    else
        printf 'firewall-cmd missing\n'
    fi
    if have iptables; then
        iptables -S 2>&1 | head -n 200
    fi
    if have ip6tables; then
        ip6tables -S 2>&1 | head -n 100
    fi

    sec A11
    ip netns list 2>&1
    if have lsns; then
        lsns -t net 2>&1 | head -n 20
    fi

    sec B5
    for dev in /sys/class/net/*; do
        i=$(basename "$dev")
        [ "$i" = "lo" ] && continue
        p=$(readlink -f "$dev/device" 2>&1)
        [ -d "$p" ] || continue
        bdf=$(basename "$p")
        printf '\n-- %s bdf=%s\n' "$i" "$bdf"
        printf 'driver=%s\n' "$(basename "$(readlink -f "$p/driver" 2>&1)" 2>&1)"
        for f in current_link_speed current_link_width max_link_speed max_link_width \
                 aer_dev_correctable aer_dev_fatal aer_dev_nonfatal \
                 power/runtime_status power/control; do
            [ -e "$p/$f" ] || continue
            printf '%s=%s\n' "$f" "$(cat "$p/$f" 2>&1 | tr '\n' ' ')"
        done
        lspci -vv -s "$bdf" 2>&1 | grep -iE 'LnkCap|LnkSta|ASPM|Correctable|Uncorrectable|DevSta|Kernel driver|Kernel modules' | head -n 40
    done

    sec B6
    for dev in /sys/class/net/*; do
        i=$(basename "$dev")
        [ "$i" = "lo" ] && continue
        printf '\n-- %s\n' "$i"
        ethtool -i "$i" 2>&1 | grep -E 'driver|version|firmware|bus-info'
        ethtool -k "$i" 2>&1 | head -n 40
        ethtool --show-eee "$i" 2>&1 | head -n 10
        ethtool -a "$i" 2>&1 | head -n 10
        ethtool -c "$i" 2>&1 | head -n 20
        ethtool -g "$i" 2>&1 | head -n 20
        ethtool -l "$i" 2>&1 | head -n 20
    done
    for m in brcmsmac b43 bcma tg3; do
        for p in /sys/module/"$m"/parameters/*; do
            [ -e "$p" ] || continue
            printf '%s.%s=%s\n' "$m" "$(basename "$p")" "$(cat "$p" 2>&1)"
        done
    done

    sec B7
    for w in /sys/class/net/*/wireless; do
        [ -e "$w" ] || continue
        i=$(basename "$(dirname "$w")")
        printf '\n-- wifi %s\n' "$i"
        iw dev "$i" station dump 2>&1 | head -n 80
        iw dev "$i" survey dump 2>&1 | head -n 40
        iw dev "$i" scan dump 2>&1 | head -n 80
        iw dev "$i" get txpower 2>&1
        if have wpa_cli; then
            wpa_cli -i "$i" status 2>&1 | head -n 40
            wpa_cli -i "$i" list_networks 2>&1 | head -n 20
            wpa_cli -i "$i" scan_results 2>&1 | head -n 30
        fi
    done
    iw reg get 2>&1
    iw list 2>&1 | head -n 80

    sec B8
    if have nmcli; then
        nmcli -f SSID,BSSID,CHAN,FREQ,RATE,SIGNAL,BARS,SECURITY device wifi list --rescan no 2>&1 | head -n 40
    else
        printf 'nmcli missing\n'
    fi

    sec C8
    ls -la /etc/NetworkManager/dispatcher.d 2>&1
    grep -RnsE 'nmcli|rfkill|ip link|ifconfig|systemctl|wpa_cli|networkctl' /etc/NetworkManager/dispatcher.d 2>&1 | head -n 80
    ls -la /etc/NetworkManager/dispatcher.d/pre-up.d /etc/NetworkManager/dispatcher.d/pre-down.d 2>&1

    sec C9
    ls -la /var/lib/systemd/rfkill 2>&1
    for f in /var/lib/systemd/rfkill/*; do
        [ -e "$f" ] || continue
        printf '%s=%s\n' "$(basename "$f")" "$(cat "$f" 2>&1)"
    done

    sec C10
    for u in NetworkManager wpa_supplicant iwd systemd-resolved systemd-logind; do
        printf '\n-- %s\n' "$u"
        systemctl show "$u" -p ActiveState -p SubState -p Result \
            -p ExecMainStartTimestamp -p ActiveEnterTimestamp -p InvocationID 2>&1
    done
    ps -eo pid,ppid,user,stat,lstart,etime,cmd 2>&1 \
        | grep -iE 'NetworkManager|wpa_supplicant|iwd|gnome-keyring|kwallet|Xorg|xfce4-session|nm-applet|polkit' \
        | grep -v grep

    sec C11
    for u in display-manager lightdm gdm sddm accounts-daemon polkit \
             NetworkManager-dispatcher; do
        printf '\n-- %s\n' "$u"
        systemctl is-active "$u" 2>&1
        systemctl show "$u" -p ActiveState -p SubState -p Result \
            -p ExecMainStartTimestamp -p InvocationID 2>&1
    done
    systemctl cat NetworkManager-dispatcher.service 2>&1 | head -n 40
    printf '\n-- current boot display-manager/accounts lines\n'
    grep -iE 'lightdm|gdm|sddm|accounts-daemon|NetworkManager-dispatcher|org.freedesktop.Accounts' "$J0" \
        | tail -n 150
    printf '\n-- previous boot display-manager/accounts lines\n'
    grep -iE 'lightdm|gdm|sddm|accounts-daemon|NetworkManager-dispatcher|org.freedesktop.Accounts' "$J1" \
        | tail -n 150

    sec D2
    timedatectl 2>&1
    systemctl is-active systemd-timesyncd 2>&1
    systemctl is-active chronyd 2>&1
    if have chronyc; then
        chronyc tracking 2>&1 | head -n 20
    fi
    journalctl --disk-usage 2>&1
    ls -ld /var/log/journal 2>&1
    grep -E '^(Storage|SystemMaxUse|RuntimeMaxUse|MaxRetentionSec)' /etc/systemd/journald.conf 2>&1
    grep -E '^hosts:' /etc/nsswitch.conf 2>&1
    cat /etc/hosts 2>&1

    sec D3
    printf '\n-- resolv.conf ownership/immutability\n'
    ls -l /etc/resolv.conf 2>&1
    lsattr /etc/resolv.conf 2>&1
    stat -c '%a %U:%G %n' /etc/resolv.conf 2>&1
    mount 2>&1 | grep -E ' /etc | / ' | head -n 10
    printf '\n-- tailscale\n'
    if have tailscale; then
        tailscale status 2>&1 | head -n 20
        tailscale debug prefs 2>&1 | head -n 60
    else
        printf 'tailscale missing\n'
    fi

    sec H0
    getenforce 2>&1
    sestatus 2>&1 | head -n 20
    grep -iE 'avc: *denied|selinux.*denied' "$J0" | tail -n 80
    if have ausearch; then
        ausearch -m avc -ts today 2>&1 | tail -n 80
    fi
    ls -ldZ /etc/NetworkManager /etc/NetworkManager/system-connections /var/lib/NetworkManager 2>&1
    ls -laZ "$TARGET_HOME/.local/share/keyrings" 2>&1

    sec H1
    if have coredumpctl; then
        coredumpctl list --no-pager 2>&1 | tail -n 40
        for p in NetworkManager wpa_supplicant gnome-keyring-daemon xfce4-session Xorg \
                 accounts-daemon lightdm polkit; do
            coredumpctl info "$p" --no-pager 2>&1 | head -n 20
        done
    else
        printf 'coredumpctl missing\n'
    fi
    ls -la /var/crash 2>&1
    ls -la /sys/fs/pstore 2>&1
    free -h 2>&1
    df -h / /var /tmp 2>&1
    cat /proc/pressure/memory 2>&1
    grep -iE 'out of memory|oom-kill|killed process' "$J0" | tail -n 40
    systemctl is-active systemd-oomd 2>&1
    grep -i 'systemd-oomd' "$J0" | tail -n 40

    sec H2
    grep -RnsE 'pam_gnome_keyring|pam_kwallet' /etc/pam.d 2>&1 | head -n 60
    ls -la "$TARGET_HOME/.local/share/keyrings" 2>&1
    if have keyctl; then
        keyctl show @s 2>&1 | head -n 20
    fi
    systemctl --user is-active gnome-keyring-daemon 2>&1
    systemctl --user status gnome-keyring-daemon --no-pager 2>&1 | head -n 20

    sec H3
    sysctl net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter \
        net.ipv4.ip_forward net.ipv4.conf.all.arp_filter \
        net.ipv4.conf.all.ignore_routes_with_linkdown \
        net.ipv6.conf.all.disable_ipv6 2>&1
    ip -s -s link show 2>&1 | head -n 120

    sec H4
    cat /proc/sys/kernel/tainted 2>&1
    grep -iE 'taint|module verification|out-of-tree' "$J0" | tail -n 20

    sec H5
    if have sensors; then
        sensors 2>&1 | head -n 50
    else
        printf 'sensors missing\n'
    fi
    for z in /sys/class/thermal/thermal_zone*; do
        [ -e "$z/temp" ] || continue
        printf '%s type=%s temp=%s\n' "$(basename "$z")" \
            "$(cat "$z/type" 2>&1)" "$(cat "$z/temp" 2>&1)"
    done
    grep -iE 'thermal|throttl|temperature|critical temp' "$J0" | tail -n 40

    sec G0
    journalctl --list-boots --no-pager 2>&1 | tail -n 10
    last -n 10 2>&1

    sec G1
    grep -iE 'error|warn|fail|critical|crit|emerg|panic' "$J1" \
        | grep -vE '^[[:space:]]*#[0-9]+ |Stack trace|ELF object|Module [^ ]+ from rpm' \
        | cut -c1-400 | tail -n 100

    sec E9
    for b in -2 -3; do
        progress "historical journal $b (capped at 20s each)"
        printf '\n-- boot %s kernel signatures\n' "$b"
        tmo 20 journalctl -k "$b" -n 1500 -o short-iso --no-pager 2>&1 \
            | grep -iE 'wl:|brcmsmac|bcma|b43|tg3|firmware|AER:|PCIe Bus Error|tx timeout|hung task|Oops|BUG:|rfkill|deauth|reason=|disconnect|reset' \
            | tail -n 80
        printf '\n-- boot %s NetworkManager signatures\n' "$b"
        tmo 20 journalctl -u NetworkManager "$b" -n 1500 -o short-iso --no-pager 2>&1 \
            | grep -iE 'error|warn|auth|permission|polkit|secret|keyring|supplicant|deauth|reason=|dhcp|timeout|deactivat|activ|session' \
            | tail -n 80
    done
}

analyze() {
    local cap="$1"
    local a0 a1 a2 a3 a3a a4 a5 a6 a7 a8 a9 a10 a11 b0 b1 b2 b3 b4 b5 b6 b7 b8 c0 c1 c1s c2 c3 c4 c8 c9 c10 c11 d0 d1 d2 d3 e0 e1 e2 e3 e4 e5 e6 e7 e8 f0 f1 g0 g1 h0 h1 h2 h3 h4
    local default4 default6 default_dev global4 apipa gen state nmdev radio wifiradio
    local rfsoft rfhard net_drv wl_loaded brcm_loaded b43_loaded
    local nm_auth nm_secret nm_dhcp nm_supp nm_sess nm_sleep wpa_err
    local killusers keyring psk_agent user_conn dns_servers resolved_active
    local linkdown linkno wifi_present prev suspend active_conn
    local name perms auto pskflags keymgmt method ifname
    local have_ip=0 have_nm=0 have_iw=0 have_journal=0

    H=0
    M=0
    L=0
    BROKEN=0

    have ip && have_ip=1
    have nmcli && have_nm=1
    have iw && have_iw=1
    have journalctl && have_journal=1

    a0=$(sec_body "$cap" A0)
    a1=$(sec_body "$cap" A1)
    a2=$(sec_body "$cap" A2)
    a3=$(sec_body "$cap" A3)
    a3a=$(sec_body "$cap" A3A)
    a4=$(sec_body "$cap" A4)
    a5=$(sec_body "$cap" A5)
    a6=$(sec_body "$cap" A6)
    a7=$(sec_body "$cap" A7)
    a8=$(sec_body "$cap" A8)
    a9=$(sec_body "$cap" A9)
    a10=$(sec_body "$cap" A10)
    a11=$(sec_body "$cap" A11)
    b0=$(sec_body "$cap" B0)
    b1=$(sec_body "$cap" B1)
    b2=$(sec_body "$cap" B2)
    b3=$(sec_body "$cap" B3)
    b4=$(sec_body "$cap" B4)
    b5=$(sec_body "$cap" B5)
    b6=$(sec_body "$cap" B6)
    b7=$(sec_body "$cap" B7)
    b8=$(sec_body "$cap" B8)
    c0=$(sec_body "$cap" C0)
    c1=$(sec_body "$cap" C1)
    c1s=$(sec_body "$cap" C1S)
    c2=$(sec_body "$cap" C2)
    c3=$(sec_body "$cap" C3)
    c4=$(sec_body "$cap" C4)
    c8=$(sec_body "$cap" C8)
    c9=$(sec_body "$cap" C9)
    c10=$(sec_body "$cap" C10)
    c11=$(sec_body "$cap" C11)
    d0=$(sec_body "$cap" D0)
    d1=$(sec_body "$cap" D1)
    d2=$(sec_body "$cap" D2)
    d3=$(sec_body "$cap" D3)
    e0=$(sec_body "$cap" E0)
    e1=$(sec_body "$cap" E1)
    e2=$(sec_body "$cap" E2)
    e3=$(sec_body "$cap" E3)
    e4=$(sec_body "$cap" E4)
    e5=$(sec_body "$cap" E5)
    e6=$(sec_body "$cap" E6)
    e7=$(sec_body "$cap" E7)
    e8=$(sec_body "$cap" E8)
    f0=$(sec_body "$cap" F0)
    f1=$(sec_body "$cap" F1)
    g0=$(sec_body "$cap" G0)
    g1=$(sec_body "$cap" G1)
    h0=$(sec_body "$cap" H0)
    h1=$(sec_body "$cap" H1)
    h2=$(sec_body "$cap" H2)
    h3=$(sec_body "$cap" H3)
    h4=$(sec_body "$cap" H4)

    printf '=== CAUSE CANDIDATES (ranked by evidence, not by guess) ===\n'
    printf 'host=%s utc=%s\n' "$(uname -n)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    default4=$(printf '%s\n' "$a1" | grep -E '^default via' | head -n 2)
    default6=$(printf '%s\n' "$a2" | grep -E '^default via' | head -n 2)
    default_dev=$(printf '%s\n' "$a1" | awk '/^default via/ { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
    active_conn=$(printf '%s\n' "$a0" | awk -v d="$default_dev" '$1 == d { for (i = 4; i <= NF; i++) printf "%s%s", (i > 4 ? " " : ""), $i; print ""; exit }')
    if [ "$have_ip" -eq 1 ] && [ -z "$default4" ]; then
        if [ -n "$default6" ]; then
            hit HIGH L3 "no IPv4 default route; an IPv6 default route exists" \
                "$default6" \
                "If you test IPv4 (ping 1.1.1.1) this is the direct cause. Check the router/DHCP option for IPv4."
        else
            BROKEN=1
            hit HIGH L3 "no default route at all - this is the kernel reason for 'Network is unreachable'" \
                "ip -4 default: ${a1:-<empty>} / ip -6 default: ${a2:-<empty>}" \
                "This is the direct cause of the ping message. See the ADDR/DHCP/DRIVER findings that explain why the route is absent."
        fi
    fi

    if [ "$have_ip" -eq 1 ] && printf '%s\n' "$a5" | grep -q 'unreachable'; then
        BROKEN=1
        hit HIGH L3 "'ip route get 1.1.1.1' returns unreachable" \
            "$a5" \
            "No route decision exists; fix the route/IP chain before looking at DNS."
    fi

    global4=$(printf '%s\n' "$a3" | grep -E 'inet ')
    apipa=$(printf '%s\n' "$a3a" | grep -E 'inet 169\.254\.' | head -n 3)
    if [ "$have_ip" -eq 1 ] && [ -n "$apipa" ]; then
        BROKEN=1
        hit HIGH DHCP "only APIPA/link-local IPv4 is present (DHCP did not complete)" \
            "$apipa" \
            "Find dhcp4 timeout/lease lines in the NetworkManager log. Check association, cable, and the DHCP server."
    fi
    if [ "$have_ip" -eq 1 ] && [ -z "$global4" ]; then
        if [ -z "$default6" ]; then
            BROKEN=1
            hit HIGH ADDR "no global IPv4 address on any interface" \
                "$(printf '%s\n' "$a3a" | head -n 4)" \
                "The interface has no usable IPv4; the link/association/rfkill/driver findings are the upstream causes."
        else
            hit MED ADDR "no global IPv4 address (IPv6-only path?)" \
                "$(printf '%s\n' "$a3a" | head -n 4)" \
                "IPv4-only tests fail; check whether the router provides IPv4 DHCP."
        fi
    fi

    gen=$(printf '%s\n' "$a0" | awk 'f { print; exit } /^STATE[[:space:]]/ { f = 1 }')
    state=${gen%%[[:space:]]*}
    case "$state" in
        asleep)
            BROKEN=1
            hit HIGH NM "NetworkManager global state is 'asleep'" "$gen" \
                "Suspend/resume or sleep state did not clear; see the suspend and driver findings."
            ;;
        connecting)
            hit MED NM "NetworkManager is stuck in 'connecting'" "$gen" \
                "See association and DHCP findings; check wpa_supplicant log."
            ;;
        disconnected)
            hit MED NM "NetworkManager global state is 'disconnected'" "$gen" \
                "See link and association findings."
            ;;
    esac

    if [ "$(printf '%s\n' "$a0" | grep -m1 -E '^(enabled|disabled)$')" = "disabled" ]; then
        BROKEN=1
        hit HIGH NM "NetworkManager networking is disabled (airplane mode or nmcli networking off)" \
            "nmcli networking: disabled" \
            "This alone explains no route. Check the XFCE panel/airplane-mode key state."
    fi
    radio=$(printf '%s\n' "$a0" | grep -m1 -E '^enabled[[:space:]]+(enabled|disabled)')
    wifiradio=$(printf '%s\n' "$radio" | awk '{print $2}')
    if [ "$wifiradio" = "disabled" ]; then
        BROKEN=1
        hit HIGH RF "Wi-Fi radio is disabled in NetworkManager" "$radio" \
            "Check the hardware/software rfkill state and the XFCE radio toggle."
    fi

    nmdev=$(printf '%s\n' "$a0" | grep -E '^[^[:space:]]+[[:space:]]+(wifi|ethernet)[[:space:]]')
    unmanaged=$(printf '%s\n' "$nmdev" | grep 'unmanaged')
    if [ -n "$unmanaged" ]; then
        if [ -z "$default_dev" ] || printf '%s\n' "$unmanaged" | grep -q "^${default_dev}[[:space:]]"; then
            BROKEN=1
            hit HIGH NM "the default-route device is UNMANAGED by NetworkManager" "$unmanaged" \
                "Check /etc/NetworkManager/conf.d for unmanaged-devices and verify the interface is not owned by another stack."
        else
            hit LOW NM "a non-default network device is UNMANAGED" "$unmanaged" \
                "Only relevant if this interface is the intended path."
        fi
    fi
    unavailable=$(printf '%s\n' "$nmdev" | grep 'unavailable')
    if [ -n "$unavailable" ]; then
        if [ -z "$default_dev" ] || printf '%s\n' "$unavailable" | grep -q "^${default_dev}[[:space:]]"; then
            hit HIGH NM "the default-route device is UNAVAILABLE" "$unavailable" \
                "Usually rfkill, missing firmware, or no kernel driver; cross-check B0/B2/E0."
        else
            hit LOW NM "a non-default network device is UNAVAILABLE" "$unavailable" \
                "Common for an unplugged Ethernet port while Wi-Fi is the active path."
        fi
    fi
    disconnected=$(printf '%s\n' "$nmdev" | grep 'disconnected')
    if [ -n "$disconnected" ]; then
        if [ -z "$default_dev" ] || printf '%s\n' "$disconnected" | grep -q "^${default_dev}[[:space:]]"; then
            hit HIGH WIFI "the default-route device is DISCONNECTED (not associated)" "$disconnected" \
                "See the Wi-Fi association and wpa_supplicant findings."
        else
            hit LOW WIFI "a non-default network device is DISCONNECTED" "$disconnected" \
                "Only relevant if this interface is the intended path."
        fi
    fi
    if printf '%s\n' "$nmdev" | grep -q 'connected (local only)'; then
        BROKEN=1
        hit HIGH DHCP "device is 'connected (local only)' - no routable lease" \
            "$(printf '%s\n' "$nmdev" | grep 'connected (local only)')" \
            "DHCP failed even though L2 is up; inspect dhcp4 log lines and the DHCP server."
    fi

    rfhard=$(printf '%s\n' "$b0" | grep -i 'Hard blocked: yes')
    rfsoft=$(printf '%s\n' "$b0" | grep -i 'Soft blocked: yes')
    if [ -n "$rfhard" ]; then
        BROKEN=1
        hit HIGH RF "hardware rfkill block is active" "$rfhard" \
            "Check the physical switch/keyboard rfkill state; a reboot resetting it fits this cause."
    fi
    if [ -n "$rfsoft" ]; then
        BROKEN=1
        hit HIGH RF "software rfkill block is active" "$rfsoft" \
            "Something set the soft block after login/logout; check XFCE power/radio settings and rfkill unblock history."
    fi

    net_drv=$(printf '%s\n' "$b2" | grep -E 'Kernel driver in use:' | head -n 4)
    if [ -z "$net_drv" ] && printf '%s\n' "$b2" | grep -qiE 'Network controller|Ethernet controller'; then
        BROKEN=1
        hit HIGH DRIVER "no kernel driver is bound to the network controller" \
            "$(printf '%s\n' "$b2" | head -n 8)" \
            "Check lspci/lsmod, the module blacklist, and whether the module failed to load."
    fi
    if printf '%s\n' "$net_drv" | grep -q 'brcmsmac'; then
        hit MED DRIVER "the in-kernel brcmsmac driver is driving the Broadcom Wi-Fi" \
            "$net_drv" \
            "BCM4322/BCM4331 on brcmsmac is frequently unstable, while broadcom-wl is the usual alternative. Confirm with the wl/brcmsmac log signatures before changing anything."
    fi
    if printf '%s\n' "$net_drv" | grep -q 'b43'; then
        hit MED DRIVER "the in-kernel b43 driver is driving the Broadcom Wi-Fi" \
            "$net_drv" \
            "BCM4322/BCM4331 support in b43 is limited; broadcom-wl or brcmsmac are the usual alternatives. Confirm with the log signatures first."
    fi
    wl_loaded=$(printf '%s\n' "$b2" | awk '$1 == "wl" { print $1; exit }')
    brcm_loaded=$(printf '%s\n' "$b2" | awk '$1 == "brcmsmac" { print $1; exit }')
    b43_loaded=$(printf '%s\n' "$b2" | awk '$1 == "b43" { print $1; exit }')
    if [ -n "$wl_loaded" ] && { [ -n "$brcm_loaded" ] || [ -n "$b43_loaded" ]; }; then
        BROKEN=1
        hit HIGH DRIVER "conflicting Broadcom drivers are loaded at the same time (wl and brcmsmac/b43)" \
            "$(printf '%s\n' "$b2" | grep -E '^(wl|brcmsmac|b43)')" \
            "This is a known cause of a card that works at boot and fails after a driver/reload event. Reboot usually restores load order."
    fi
    if { [ -n "$brcm_loaded" ] || [ -n "$b43_loaded" ]; } && printf '%s\n' "$b3" | grep -qiE 'No such file|not found'; then
        hit MED DRIVER "the in-kernel Broadcom driver is loaded but its firmware path is missing" \
            "$(printf '%s\n' "$b3" | grep -iE 'No such file|not found' | head -n 3)" \
            "Install the matching linux-firmware/b43 package or switch to the documented driver for this card."
    fi
    if printf '%s\n' "$b4" | grep -qE 'blacklist[[:space:]]+(wl|brcmsmac|b43)'; then
        hit MED DRIVER "a modprobe blacklist mentions a Broadcom driver" \
            "$(printf '%s\n' "$b4" | grep -E 'blacklist[[:space:]]+(wl|brcmsmac|b43)')" \
            "Confirm this is intentional; a blacklist plus an auto-load can produce an unbound device."
    fi

    nm_auth=$(printf '%s\n' "$e1" | grep -iE 'not authorized|polkit.*(denied|fail)|not permitted to (control|modify|activate|manage)' | head -n 5)
    nm_secret=$(printf '%s\n' "$e1" | grep -iE 'No secrets|secret.*(not|fail|unavailable)|agent-owned|keyring|password.*required|802-11-wireless-security.*(fail|missing)' | head -n 5)
    nm_dhcp=$(printf '%s\n' "$e1" | grep -iE 'dhcp[46]?.*(timeout|fail|no lease|expired|unavailable)|lease.*(fail|expired|not found)|DHCP.*(timeout|failed)' | head -n 5)
    nm_supp=$(printf '%s\n' "$e1" | grep -iE 'supplicant.*(fail|timeout|disconnect)|CTRL-EVENT-DISCONNECTED|associat.*(timeout|fail)|deauth|reason=[0-9]|scan.*(fail|timeout)' | head -n 5)
    nm_sess=$(printf '%s\n' "$e1" | grep -iE 'session.*(closed|removed|logout)|user.*session|deactivat.*(logout|session)' | head -n 5)
    nm_sleep=$(printf '%s\n' "$e1" | grep -iE 'sleep|suspend|resume|wake' | head -n 5)

    [ -n "$nm_auth" ] && hit HIGH POLKIT "NetworkManager authorization/polkit failure" "$nm_auth" \
        "After logout the active logind session may be gone; check C3 and /etc/NetworkManager for auth-polkit."
    [ -n "$nm_secret" ] && hit HIGH KEYRING "NetworkManager cannot obtain the Wi-Fi secret (keyring/agent-owned PSK)" "$nm_secret" \
        "A logout can lock/restart the keyring; a restart re-unlocks it. Check the C1S psk-flags and C4 keyring process."
    [ -n "$nm_dhcp" ] && hit HIGH DHCP "NetworkManager logged a DHCP failure/timeout/lease loss" "$nm_dhcp" \
        "This is the mechanism for missing IP/default route; check the DHCP server and link."
    [ -n "$nm_supp" ] && hit MED WIFI "wpa_supplicant association/authentication failure signatures" "$nm_supp" \
        "Cross-check the E2 wpa_supplicant lines and the driver signatures."
    [ -n "$nm_sess" ] && hit MED SESSION "connection deactivated around a user session/logout event" "$nm_sess" \
        "If the connection is user-scoped (C1S), NetworkManager may hide/deactivate it after logout."
    [ -n "$nm_sleep" ] && hit LOW POWER "NetworkManager saw sleep/suspend/resume/wake" "$nm_sleep" \
        "If the failure follows resume rather than logout, treat this as the trigger."

    wpa_err=$(printf '%s\n' "$e2" | grep -iE 'Authentication.*timed out|CTRL-EVENT-SCAN-FAILED|nl80211.*(fail|error)|deauthenticated|reason=|ASSOC-REJECT|4-way handshake.*fail|association.*timed out' | head -n 6)
    [ -n "$wpa_err" ] && hit HIGH WIFI "wpa_supplicant could not associate/authenticate" "$wpa_err" \
        "The card/driver is not reaching a usable association; see A5/A6 and B2/E0."

    psk_agent=""
    user_conn=""
    if [ "$have_nm" -eq 1 ]; then
        while IFS=$'\x1f' read -r name typ perms auto pskflags keymgmt method ifname cnever cign cpower cmac cdhcp croute cacrety cauthrety; do
            [ -n "$name" ] || continue
            case "$name$typ$perms$auto$pskflags" in
                *"command not found"*|*"Error:"*) continue ;;
            esac
            case "$typ" in
                802-11-wireless|802-3-ethernet) ;;
                *) continue ;;
            esac
            if [ -n "$perms" ]; then
                user_conn="$name"
                hit MED CONN "connection '$name' is user-scoped (connection.permissions=$perms)" \
                    "name=$name type=$typ permissions=$perms autoconnect=$auto" \
                    "NetworkManager treats a user-scoped connection as available only while that user is logged in; this is a known logout failure mode. Compare with the C3 session state."
            fi
            case "$pskflags" in
                1|3|5|7)
                    if [ "$auto" != "no" ]; then
                        psk_agent="$name"
                        if [ "$name" = "$active_conn" ]; then
                            hit HIGH KEYRING "the ACTIVE connection '$name' stores the PSK agent-owned (psk-flags=$pskflags)" \
                                "name=$name type=$typ psk-flags=$pskflags key-mgmt=$keymgmt autoconnect=$auto" \
                                "The active Wi-Fi secret depends on the user keyring; a logout that locks it matches the failure."
                        else
                            hit MED KEYRING "connection '$name' stores the PSK agent-owned (psk-flags=$pskflags)" \
                                "name=$name type=$typ psk-flags=$pskflags key-mgmt=$keymgmt autoconnect=$auto" \
                                "Agent-owned secrets need the user keyring. Only relevant if this profile is the one reconnecting after logout."
                        fi
                    fi
                    ;;
            esac
            if [ "$auto" = "no" ]; then
                hit LOW CONN "connection '$name' has autoconnect=no" \
                    "name=$name type=$typ autoconnect=$auto method=$method" \
                    "After logout it will not come back on its own; confirm whether this is the expected profile."
            fi
        done < <(printf '%s\n' "$c1s")
    fi

    keyring=$(printf '%s\n' "$c4" | grep -iE 'gnome-keyring|kwallet' | head -n 3)
    if [ -n "$psk_agent" ] && [ -z "$keyring" ]; then
        hit HIGH KEYRING "agent-owned PSK is configured but no keyring daemon is visible" \
            "connection=$psk_agent / C4 has no gnome-keyring or kwallet line" \
            "This matches a logout that kills the secret store and leaves NM unable to reconnect until a reboot."
    fi

    killusers=$(printf '%s\n' "$c3" | grep -i 'KillUserProcesses=yes')
    [ -n "$killusers" ] && hit MED LOGIND "logind KillUserProcesses=yes is set" "$killusers" \
        "Logout kills user agents; if the keyring or nm-applet is user-scoped, the connection loses its secret/controller."
    if printf '%s\n' "$c3" | grep -q 'State=closing'; then
        hit MED LOGIND "a logind session is stuck in 'closing' state" \
            "$(printf '%s\n' "$c3" | grep -B2 -A4 'State=closing' | head -n 12)" \
            "A stale session can break polkit authorization for the next login; compare E3/E8."
    fi
    if printf '%s\n' "$c3" | grep -q 'State=' && ! printf '%s\n' "$c3" | grep -q 'State=active'; then
        hit MED LOGIND "no logind session is in State=active" \
            "$(printf '%s\n' "$c3" | grep -E 'Session|Id=|Name=|Type=|Class=|Active=|State=' | head -n 20)" \
            "If the graphical user is logged in, this is abnormal and can block NetworkManager polkit actions."
    fi

    dns_servers=$(printf '%s\n' "$d0" | grep -E '^nameserver ' | head -n 3)
    resolved_active=$(printf '%s\n' "$d0" | grep -m1 -E '^(active|inactive|failed|unknown)$')
    if [ -z "$dns_servers" ] && ! printf '%s\n' "$d0" | grep -q 'DNS Servers:'; then
        hit MED DNS "no DNS servers are visible in /etc/resolv.conf or resolvectl" \
            "$(printf '%s\n' "$d0" | grep -E 'nameserver|DNS Servers|resolv.conf|systemd-resolved' | head -n 8)" \
            "This breaks name resolution, but by itself would not produce 'Network is unreachable'. Fix the L3 findings first."
    fi
    if [ "$resolved_active" = "inactive" ]; then
        hit MED DNS "systemd-resolved is inactive" \
            "systemctl is-active systemd-resolved=inactive" \
            "If /etc/resolv.conf points at 127.0.0.53, name resolution fails; again this is secondary to the missing route."
    fi

    if printf '%s\n' "$f0" | grep -q 'Power save: on'; then
        hit MED POWER "Wi-Fi power save is ON" \
            "$(printf '%s\n' "$f0" | grep -E 'Power save|wl\.|powersave')" \
            "Broadcom wl/brcmsmac are known to stall or disassociate under power save after idle/logout; a reboot clearing it fits this cause."
    fi
    if printf '%s\n' "$c0" | grep -qE 'wifi\.powersave[[:space:]]*=[[:space:]]*3'; then
        hit MED POWER "NetworkManager wifi.powersave=3 (enabled) is configured" \
            "$(printf '%s\n' "$c0" | grep -E 'wifi\.powersave')" \
            "This is consistent with idle/logout-triggered Wi-Fi stalls on Broadcom hardware."
    fi

    suspend=$(printf '%s\n' "$e4" | grep -iE 'PM: suspend|PM: resume|suspend entry|suspend exit|systemd-suspend|Lid Switch|Power Button|hibernate')
    [ -n "$suspend" ] && hit LOW POWER "suspend/resume events exist in this boot" \
        "$(printf '%s\n' "$suspend" | tail -n 4)" \
        "If the failure follows resume instead of logout, use the suspend timestamps in the timeline."

    linkno=$(printf '%s\n' "$a8" | grep -i 'Link detected: no' | head -n 3)
    wifi_present=$(printf '%s\n' "$b1" | grep -c 'phy#')
    if [ -n "$linkno" ]; then
        if [ "$wifi_present" -eq 0 ] && [ "$have_iw" -eq 1 ] && [ "$have_nm" -eq 1 ]; then
            BROKEN=1
            hit HIGH ETH "Ethernet reports no link and no Wi-Fi interface is present" "$linkno" \
                "Check the cable/switch and the tg3 PHY; this alone explains no route."
        else
            hit LOW ETH "Ethernet reports no link (Wi-Fi may still be the active path)" "$linkno" \
                "Only relevant if Ethernet is the intended path."
        fi
    fi
    if printf '%s\n' "$e0" | grep -qiE 'tg3.*(error|fail|reset|Link is Down|firmware)'; then
        hit HIGH ETH "tg3 Ethernet driver logged an error/link-down/reset" \
            "$(printf '%s\n' "$e0" | grep -iE 'tg3.*(error|fail|reset|Link is Down|firmware)' | head -n 5)" \
            "On these MacBooks the Broadcom Ethernet NIC uses tg3; a PHY/driver reset can leave the port dead until reboot."
    fi

    if printf '%s\n' "$e0" | grep -qiE 'firmware.*(fail|error|not found)|Direct firmware load.*failed|brcm.*firmware.*fail'; then
        hit HIGH DRIVER "firmware load failure in the current-boot kernel log" \
            "$(printf '%s\n' "$e0" | grep -iE 'firmware.*(fail|error|not found)|Direct firmware load.*failed|brcm.*firmware.*fail' | head -n 5)" \
            "The driver cannot bring the radio up; check package/firmware path in B3."
    fi
    if printf '%s\n' "$e0" | grep -qiE 'wl: .*(error|fail|fatal|timeout|unknown|assert)|wl_cfg80211.*(error|fail)|wl: module'; then
        hit HIGH DRIVER "Broadcom wl driver logged errors" \
            "$(printf '%s\n' "$e0" | grep -iE 'wl: .*(error|fail|fatal|timeout|unknown|assert)|wl_cfg80211.*(error|fail)|wl: module' | head -n 5)" \
            "The proprietary driver is failing; a reboot reloading it is consistent with the symptom."
    fi
    if printf '%s\n' "$e0" | grep -qiE 'brcmsmac.*(error|fail|fatal|timeout)|bcma.*(error|fail|timeout)|b43.*(error|fail)'; then
        hit HIGH DRIVER "brcmsmac/bcma/b43 logged errors" \
            "$(printf '%s\n' "$e0" | grep -iE 'brcmsmac.*(error|fail|fatal|timeout)|bcma.*(error|fail|timeout)|b43.*(error|fail)' | head -n 5)" \
            "The in-kernel Broadcom path is failing; cross-check B2 and E5."
    fi
    if printf '%s\n' "$e0" | grep -qiE 'AER:.*(error|corrected|uncorrected|fatal)|PCIe Bus Error|Uncorrected error|Corrected error'; then
        hit MED PCIE "real PCIe/AER error lines are present in the kernel log" \
            "$(printf '%s\n' "$e0" | grep -iE 'AER:.*(error|corrected|uncorrected|fatal)|PCIe Bus Error|Uncorrected error|Corrected error' | head -n 5)" \
            "Bus-level errors can take the Wi-Fi/NIC off the bus; a reboot re-trains the link. The _OSC capability list is not an error."
    fi
    if printf '%s\n' "$e0" | grep -qiE 'tx timeout|watchdog|hung task|soft lockup|Oops|BUG:|call trace'; then
        hit HIGH KERNEL "kernel/driver hang or crash signature" \
            "$(printf '%s\n' "$e0" | grep -iE 'tx timeout|watchdog|hung task|soft lockup|Oops|BUG:|call trace' | head -n 5)" \
            "A wedged driver explains why only a reboot recovers the interface."
    fi

    local policy reject aer wpa_state station_bad disp saved oom core pamkey
    local fwloads beacon auth dnsperm dispatcher dm resolv_attr
    policy=$(printf '%s\n' "$a9" | grep -iE 'unreachable|blackhole|prohibit')
    if [ -n "$policy" ]; then
        hit HIGH ROUTE "policy routing contains an unreachable/blackhole/prohibit rule" \
            "$policy" \
            "A rule can discard traffic before the main table; run 'ip rule' and 'ip route show table all' while broken."
    fi
    reject=$(printf '%s\n' "$a10" | grep -iE 'icmp.*unreachable|net-unreachable|network-unreachable|%%REJECT%%|target.*reject')
    if [ -n "$reject" ]; then
        hit HIGH FIREWALL "firewall rules can emit an ICMP unreachable (matches the ping text)" \
            "$reject" \
            "nft/iptables/firewalld REJECT with net-unreachable produces exactly 'Network is unreachable' without a routing fault."
    fi
    aer=$(printf '%s\n' "$b5" | grep -E 'aer_dev_(correctable|fatal|nonfatal)=.*[1-9]')
    if [ -n "$aer" ]; then
        hit HIGH PCIE "PCIe AER error counters are non-zero for the network device" \
            "$aer" \
            "Bus-level errors can take the Wi-Fi/NIC off the bus until reboot re-trains the link; correlate with dmesg AER lines."
    fi
    wpa_state=$(printf '%s\n' "$b7" | grep -i '^wpa_state=' | tail -n 1)
    case "$wpa_state" in
        *DISCONNECTED*|*INACTIVE*|*SCANNING*|*ASSOCIATING*|*AUTHENTICATING*)
            hit HIGH WIFI "wpa_supplicant state is '$wpa_state'" \
                "$(printf '%s\n' "$b7" | grep -E '^(wpa_state|ssid|key_mgmt|address)=' | head -n 6)" \
                "The supplicant has no completed association; compare the station dump and E2 log."
            ;;
    esac
    station_bad=$(printf '%s\n' "$b7" | grep -iE 'beacon loss: [1-9]|tx failed: [1-9]|tx retries: [1-9][0-9][0-9]')
    if [ -n "$station_bad" ]; then
        hit MED WIFI "station dump shows beacon loss / TX failure / high retries" \
            "$station_bad" \
            "This points at RF/driver instability; check B5/E0 and the antenna/regulatory state."
    fi
    if printf '%s\n' "$b7" | grep -q 'country 00'; then
        hit LOW REG "regulatory domain is 00 (world)" \
            "iw reg get: country 00" \
            "This can disable channels after a regulatory update; set the correct country if the AP is on a restricted channel."
    fi
    disp=$(printf '%s\n' "$c8" | grep -iE 'nmcli (networking off|radio wifi off|connection down)|rfkill block|ip link set .* down|systemctl (stop|restart) NetworkManager|wpa_cli terminate')
    if [ -n "$disp" ]; then
        hit HIGH DISPATCH "NetworkManager dispatcher script contains a network-disabling command" \
            "$disp" \
            "Dispatcher scripts run on link/session events; a script here can reproduce the logout trigger exactly."
    fi
    saved=$(printf '%s\n' "$c9" | grep -E '=1$' | grep -iE 'wlan|wifi|phy|bluetooth')
    if [ -n "$saved" ]; then
        hit MED RF "systemd has a saved rfkill soft-block state" \
            "$saved" \
            "systemd-rfkill restores this at boot/login; compare with the live rfkill state in B0."
    fi
    if printf '%s\n' "$d2" | grep -q 'Storage=volatile'; then
        hit MED JOURNAL "journald Storage=volatile: previous-boot evidence is lost at reboot" \
            "$(printf '%s\n' "$d2" | grep -E 'Storage=|/var/log/journal' | head -n 4)" \
            "Enable persistent journald storage before the next repro, otherwise only the current boot can be audited."
    elif printf '%s\n' "$d2" | grep -qi 'No such file.*var/log/journal'; then
        hit MED JOURNAL "no persistent /var/log/journal directory" \
            "$(printf '%s\n' "$d2" | grep -iE 'No such file|/var/log/journal' | head -n 4)" \
            "Same consequence: a reboot destroys the failure-time journal."
    fi
    if printf '%s\n' "$d2" | grep -qi 'System clock synchronized: no'; then
        hit MED TIME "system clock is not synchronized" \
            "$(printf '%s\n' "$d2" | grep -iE 'System clock synchronized|NTP service' | head -n 4)" \
            "Clock skew breaks 802.1X/EAP-TLS certificate validation; check chronyd/timesyncd."
    fi
    avc=$(printf '%s\n' "$h0" | grep -iE 'avc: *denied|selinux.*denied')
    if [ -n "$avc" ]; then
        hit HIGH SELINUX "SELinux AVC denial is present" \
            "$avc" \
            "A denial on NetworkManager, wpa_supplicant, or the keyring can block reconnection; inspect with 'ausearch -m avc -ts recent'."
    fi
    core=$(printf '%s\n' "$h1" | grep -iE 'NetworkManager|wpa_supplicant|gnome-keyring|xfce4-session|Xorg' | grep -iE 'present|coredump|signal')
    if [ -n "$core" ]; then
        hit HIGH CRASH "coredump entry for a network/session process" \
            "$core" \
            "A crash at logout would explain the recovery-on-reboot pattern; inspect 'coredumpctl info <pid>'."
    fi
    oom=$(printf '%s\n' "$h1" | grep -iE 'out of memory|oom-kill|killed process')
    if [ -n "$oom" ]; then
        hit HIGH OOM "OOM killer activity is present" \
            "$oom" \
            "If NetworkManager, wpa_supplicant, or the keyring was killed, the connection cannot recover; check memory pressure."
    fi
    pamkey=$(printf '%s\n' "$h2" | grep -iE 'pam_gnome_keyring|pam_kwallet')
    if [ -n "$psk_agent" ] && [ -z "$pamkey" ]; then
        if [ "$psk_agent" = "$active_conn" ]; then
            hit HIGH KEYRING "the ACTIVE connection needs the keyring but PAM does not unlock it at login" \
                "psk-flags=1 for $psk_agent (active); no pam_gnome_keyring/pam_kwallet in /etc/pam.d" \
                "After logout/login the keyring stays locked, NM cannot fetch the PSK, and only a fresh login/reboot fixes it."
        else
            hit LOW KEYRING "an inactive agent-owned PSK profile exists without PAM keyring unlock" \
                "psk-flags=1 for $psk_agent; no pam_gnome_keyring/pam_kwallet in /etc/pam.d" \
                "Only relevant if this profile reconnects after logout."
        fi
    fi

    fwloads=$(printf '%s\n' "$e0" | grep -c 'b43-phy0: Loading firmware')
    if [ "${fwloads:-0}" -ge 3 ]; then
        hit HIGH DRIVER "b43 reloaded firmware ${fwloads} times in this boot" \
            "$(printf '%s\n' "$e0" | grep 'b43-phy0: Loading firmware' | tail -n 4)" \
            "A b43 firmware reload loop on BCM4331 can wedge the radio; only a module reload/reboot recovers it. Compare with B7 station dump and the previous boot."
    fi
    beacon=$(printf '%s\n%s\n' "$e0" "$e2" | grep -c 'BEACON-LOSS')
    if [ "${beacon:-0}" -ge 5 ]; then
        hit HIGH WIFI "wpa_supplicant logged ${beacon} BEACON-LOSS events" \
            "$(printf '%s\n%s\n' "$e0" "$e2" | grep 'BEACON-LOSS' | tail -n 4)" \
            "The AP link is dropping. On b43 this often precedes a firmware reload and a dead interface."
    fi
    auth=$(printf '%s\n%s\n' "$e2" "$e7" | grep -iE 'Authentication with .* timed out|CTRL-EVENT-SCAN-FAILED|association.* timed out|associat.* timed out')
    if [ -n "$auth" ]; then
        hit HIGH WIFI "b43/wpa_supplicant authentication or scan timeout" "$auth" \
            "The radio cannot complete association/scan; a reboot reloading b43 is consistent with the symptom."
    fi
    dnsperm=$(printf '%s\n' "$e1" | grep -iE 'dns-mgr:.*(Permission denied|g_rename|Failed to rename)')
    if [ -n "$dnsperm" ]; then
        hit HIGH DNS "NetworkManager cannot update /etc/resolv.conf (rename permission denied)" \
            "$dnsperm" \
            "This is a real DNS-update failure, separate from the route loss. Check D3: immutable attribute or a Tailscale-managed resolv.conf."
    fi
    resolv_attr=$(printf '%s\n' "$d3" | grep -E '^[a-zA-Z-]*i[a-zA-Z-]*[[:space:]]+/etc/resolv.conf' | head -n 1)
    if [ -n "$resolv_attr" ]; then
        hit HIGH DNS "/etc/resolv.conf has the immutable attribute" \
            "$resolv_attr" \
            "NetworkManager and Tailscale cannot rewrite it; DNS will go stale. Clear the immutable bit only after deciding who owns resolv.conf."
    fi
    if printf '%s\n' "$d3" | grep -qiE 'Tailscale is stopped|Log in to Tailscale|not running|Logged out' && \
       printf '%s\n' "$d0" | grep -q '100.100.100.100'; then
        hit HIGH DNS "resolv.conf points at Tailscale (100.100.100.100) but Tailscale is not running" \
            "$(printf '%s\n' "$d3" | grep -iE 'Tailscale|100.100.100.100' | head -n 6)" \
            "Name resolution fails after Tailscale stops; this is not the route loss but it will look like 'no network'."
    fi
    dispatcher=$(printf '%s\n' "$e1" | grep -iE 'dispatcher:.*(failed|invalid)|org\.freedesktop\.nm_dispatcher.*(failed|invalid)')
    if [ -n "$dispatcher" ]; then
        hit MED DISPATCH "NetworkManager dispatcher unit failed to activate" \
            "$dispatcher" \
            "Check C11: systemctl cat NetworkManager-dispatcher.service. A broken dispatcher also blocks DNS/route hooks."
    fi
    dm=$(printf '%s\n' "$c11" | grep -iE 'accounts-daemon.*(failed|dumped|ABRT|timed out)|Error getting user list|lightdm.*(error|fail)|gdm.*(error|fail)|sddm.*(error|fail)')
    if [ -n "$dm" ]; then
        hit HIGH SESSION "display-manager/accounts-daemon failure on the logout/login path" \
            "$dm" \
            "This is the 'log out and in failed' evidence: accounts-daemon crashed and the greeter could not fetch the user list. It is separate from the route loss but can leave the session half-initialized."
    fi
    if [ -n "$b43_loaded" ] && printf '%s\n' "$b4" | grep -q 'blacklist.*wl'; then
        hit MED DRIVER "b43 is the active driver while wl/brcmsmac are blacklisted" \
            "$(printf '%s\n' "$b4" | grep -E 'blacklist (wl|brcmsmac|brcmfmac|bcma|ssb)|options b43')" \
            "This is the configured workaround; if b43 keeps reloading firmware, test brcmsmac or broadcom-wl instead of adding more blacklists."
    fi
    if printf '%s\n' "$c0" | grep -q 'wifi.cloned-mac-address=stable-ssid'; then
        hit LOW MAC "wifi.cloned-mac-address=stable-ssid is configured" \
            "$(printf '%s\n' "$c0" | grep 'wifi.cloned-mac-address')" \
            "The MAC changes per SSID; a MAC-bound DHCP reservation or filter can make reconnects fail. Not the route-loss cause by itself."
    fi

    printf '\n'
    if [ "$BROKEN" -eq 1 ]; then
        printf 'VERDICT: the live system has no usable L3 path. The HIGH findings above are the direct cause chain.\n'
    else
        printf 'VERDICT: a live L3 path exists now. The logout failure is intermittent, so re-run this script while broken.\n'
        printf 'If you already rebooted, the PREVIOUS BOOT evidence below holds the failure-time logs.\n'
    fi
    printf 'Summary: %d HIGH, %d MED, %d LOW\n' "$H" "$M" "$L"
    if [ "$H" -eq 0 ] && [ "$M" -eq 0 ]; then
        printf 'No fault signature was found in the captured state.\n'
    fi

    prev=$(printf '%s\n%s\n%s\n' "$e5" "$e6" "$e7" | grep -iE 'firmware|wl:|brcmsmac|bcma|b43|tg3|AER|PCIe|tx timeout|hung task|Oops|BUG:|deauth|reason=|disconnect|not authorized|No secrets|dhcp.*(timeout|fail)|session closed' | tail -n 20)
    if [ -n "$prev" ]; then
        printf '\n=== PREVIOUS BOOT EVIDENCE (the failure before the last reboot) ===\n'
        printf '%s\n' "$prev"
    elif [ "$have_journal" -eq 1 ]; then
        printf '\n=== PREVIOUS BOOT EVIDENCE ===\n'
        printf 'No matching failure signatures were found in the previous boot (or no previous journal exists).\n'
    else
        printf '\n=== PREVIOUS BOOT EVIDENCE ===\n'
        printf 'journalctl is missing; previous-boot logs were not collected.\n'
    fi
}

timeline() {
    local cap="$1"
    printf '\n=== TIMELINE (correlate the last events) ===\n'
    printf '%s\n' '-- NetworkManager state/activation lines'
    sec_body "$cap" E1 | grep -iE 'state change|deactivat|activ|disconnect|associat|dhcp|reason=' | tail -n 12
    printf '%s\n' '-- logind session lines'
    sec_body "$cap" E3 | tail -n 8
    printf '%s\n' '-- wpa_supplicant association lines'
    sec_body "$cap" E2 | grep -iE 'disconnect|deauth|reason=|associat|auth|scan' | tail -n 10
}

main() {
    local arg

    while [ $# -gt 0 ]; do
        arg="$1"
        case "$arg" in
            -h|--help)
                usage
                return 0
                ;;
            --probe)
                PROBE=1
                shift
                ;;
            --watch)
                if [ $# -lt 2 ]; then
                    printf 'error: --watch needs a duration in seconds\n'
                    return 2
                fi
                case "$2" in
                    ''|*[!0-9]*)
                        printf 'error: --watch duration must be an integer\n'
                        return 2
                        ;;
                esac
                WATCH="$2"
                shift 2
                ;;
            --out)
                if [ $# -lt 2 ]; then
                    printf 'error: --out needs a path\n'
                    return 2
                fi
                OUT="$2"
                shift 2
                ;;
            *)
                printf 'error: unknown argument: %s\n' "$arg"
                usage
                return 2
                ;;
        esac
    done

    if [ -z "$OUT" ]; then
        OUT="/tmp/a1286-net-audit-$(date -u +%Y%m%dT%H%M%SZ).txt"
    fi
    CAP="$OUT.raw"
    J0="$CAP.journal-boot0"
    J1="$CAP.journal-boot-1"

    TARGET_USER="${SUDO_USER:-$(id -un)}"
    TARGET_HOME="$HOME"
    if [ -n "${SUDO_USER:-}" ] && have getent; then
        TARGET_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        [ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"
    fi

    T0_MS=$(now_ms)
    if [ "$WATCH" -gt 0 ]; then
        WATCH_BASE="$OUT"
        watch_mode "$WATCH" "$WATCH_BASE"
    fi
    printf 'audit-a1286-network.sh - read-only; collecting...\n'
    printf 'progress lines go to the terminal even while the report is being written.\n'
    if [ "$(id -u)" -ne 0 ]; then
        printf 'note: not root; journal/system-connection visibility may be reduced. Re-run with sudo for the full picture.\n'
    fi
    collect > "$CAP"
    progress "collection complete; writing report"

    {
        printf '=== audit-a1286-network.sh ===\n'
        printf 'read-only diagnostic; no service, link, module, or NetworkManager state was changed.\n'
        printf 'report=%s\n' "$OUT"
        analyze "$CAP"
        timeline "$CAP"
        if [ -n "$WATCH_BASE" ]; then
            printf '\n=== WATCH WINDOW (live events during repro) ===\n'
            for f in "$WATCH_BASE".watch.*; do
                [ -e "$f" ] || continue
                printf '\n-- %s\n' "$f"
                tail -n 150 "$f"
            done
        fi
        printf '\n=== RAW EVIDENCE (verbatim) ===\n'
        cat "$CAP"
        printf '\n=== END a1286-net-audit ===\n'
    } | tee "$OUT"

    printf '\nsaved report: %s\nraw capture: %s\n' "$OUT" "$CAP"
    return 0
}

main "$@"
