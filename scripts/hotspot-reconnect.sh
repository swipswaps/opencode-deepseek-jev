#!/usr/bin/env bash
#
# hotspot-reconnect.sh - detect a lost hotspot/underlay, alert BOTH ends, and
# walk the operator through an interactive reconnect.
#
# Client half - run ON THE CLIENT (the roaming box):
#   ./scripts/hotspot-reconnect.sh --check            # one probe; 0 up, 2 down
#   ./scripts/hotspot-reconnect.sh --watch            # detect, alert, guide
#   ./scripts/hotspot-reconnect.sh --watch --reconnect # also try to rejoin
#   ./scripts/hotspot-reconnect.sh --plan             # show the reconnect order
#   ./scripts/hotspot-reconnect.sh --json             # machine state
#   ./scripts/hotspot-reconnect.sh --self-test        # offline seams
#
# Server half - run ON THE SERVER (ws24):
#   ./scripts/hotspot-reconnect.sh --server --watch
#   -> alerts this server's console when the client overlay disappears/returns.
#
# Two-sided alerting, honestly:
#   - client --watch alerts the local terminal/bell/notify and, when the server
#     is reachable, appends to the server alert log (+ wall). When it is NOT
#     reachable (the usual case) the line is QUEUED and flushed on the next
#     successful contact, so both logs agree afterward.
#   - server --server --watch is the timely server-side half: it watches the
#     client overlay address and alerts locally on loss/return even while the
#     client cannot reach it.
#
# Detection is debounced (FAIL_THRESHOLD consecutive misses) and settled
# (SETTLE_SEC) because a roam legitimately re-handshakes for a few seconds.
# A down client that is still on an underlay (DNS/LAN up, overlay down) is
# reported as "overlay down", not "hotspot lost", so the guidance is right.
#
# Env: ROAM_MESH_IP, ROAM_TAILSCALE_IP, ROAM_LAN_IP, CLIENT_MESH_IP,
#      CLIENT_TAILSCALE_IP, HOTSPOT_SERVER_SSH, HOTSPOT_STATE, HOTSPOT_LOG,
#      HOTSPOT_PENDING, HOTSPOT_WATCH_SEC, HOTSPOT_SETTLE_SEC,
#      HOTSPOT_FAIL_THRESHOLD, HOTSPOT_PROFILE, HOTSPOT_SSID, HOTSPOT_IFACE.
# Seams (self-test): HOTSPOT_FAKE_OVERLAY, HOTSPOT_FAKE_LINK, HOTSPOT_FAKE_DNS,
#      HOTSPOT_FAKE_SSID, HOTSPOT_FAKE_SERVER, HOTSPOT_FAKE_CLIENT,
#      HOTSPOT_FAKE_HAVE_NMCLI, HOTSPOT_FAKE_RECONNECT, HOTSPOT_FAKE_BELL.
#
# Exit: 0 up / ok; 2 down / failed to reconnect; 3 cannot run or unsafe input.
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
CLIENT_MESH="${CLIENT_MESH_IP:-10.100.0.1}"
CLIENT_TAILSCALE="${CLIENT_TAILSCALE_IP:-}"
SERVER_SSH="${HOTSPOT_SERVER_SSH:-}"
STATE="${HOTSPOT_STATE:-$HOME/.local/state/hotspot-reconnect.state}"
LOG="${HOTSPOT_LOG:-$HOME/.local/state/hotspot-alerts.log}"
PENDING="${HOTSPOT_PENDING:-$HOME/.local/state/hotspot-alerts.pending}"
WATCH_SEC="${HOTSPOT_WATCH_SEC:-10}"
SETTLE_SEC="${HOTSPOT_SETTLE_SEC:-20}"
FAIL_THRESHOLD="${HOTSPOT_FAIL_THRESHOLD:-2}"
PROFILE="${HOTSPOT_PROFILE:-}"
SSID="${HOTSPOT_SSID:-}"
IFACE="${HOTSPOT_IFACE:-en0}"
JSON="${HOTSPOT_JSON:-0}"
ALERTS_N="${HOTSPOT_ALERTS_N:-20}"
QUIET="${HOTSPOT_QUIET:-0}"
SILENCE_SEC="${HOTSPOT_SILENCE_SEC:-3600}"
ALERT_COOLDOWN="${HOTSPOT_ALERT_COOLDOWN:-120}"
ALERT_MAX="${HOTSPOT_ALERT_MAX:-4}"
CRITICAL_AFTER="${HOTSPOT_CRITICAL_AFTER:-3}"
ALERT_STATE="${HOTSPOT_ALERT_STATE:-$STATE.alerts}"
QUIET_UNTIL="${HOTSPOT_QUIET_UNTIL:-$HOME/.local/state/hotspot-quiet.until}"
FIX_REQUEST="${HOTSPOT_FIX_REQUEST:-$HOME/.local/state/hotspot-fix.request}"
ACTION_OUT="${HOTSPOT_ACTION_OUT:-$HOME/.local/state/hotspot-action.out}"
NOTIFY_BIN="${HOTSPOT_NOTIFY_BIN:-notify-send}"
ALERT_N=0
MODE=""
ROLE="client"
RECONNECT=0
ASSUME_YES=0
PREV=""
FAILS=0
M4=""
M5=""
T4=""
T5=""
L4=""
DNS=""
SSID_NOW=""
STATE_NOW=""

have() {
    case "$1" in
        nmcli) [ "${HOTSPOT_FAKE_HAVE_NMCLI:-0}" = "1" ] && return 0 ;;
        networksetup) [ "${HOTSPOT_FAKE_HAVE_NETWORKSETUP:-0}" = "1" ] && return 0 ;;
    esac
    command -v "$1" > /dev/null
}

have_notify() {
    if [ "${HOTSPOT_FAKE_NOTIFY:-0}" = "1" ]; then return 0; fi
    command -v "$NOTIFY_BIN" > /dev/null
}

notify_send() {
    if [ "${HOTSPOT_FAKE_NOTIFY:-0}" = "1" ]; then
        printf '%s\n' "$*" >> "${HOTSPOT_NOTIFY_LOG:-/tmp/hotspot-notify.log}"
        printf '%s' "${HOTSPOT_FAKE_NOTIFY_ACTION:-}"
        return 0
    fi
    "$NOTIFY_BIN" "$@"
}

notify_has_actions() {
    [ "${HOTSPOT_FAKE_NOTIFY_ACTIONS:-0}" = "1" ] && return 0
    [ "${HOTSPOT_FAKE_NOTIFY:-0}" = "1" ] && return 1
    "$NOTIFY_BIN" --help 2>&1 | grep -q -e '--action'
}

open_url() {
    if have xdg-open; then
        xdg-open "$1" 2>&1 || true
    elif have open; then
        open "$1" 2>&1 || true
    else
        printf 'open %s\n' "$1"
    fi
}

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { printf '%s\n' "$*"; }
bell() {
    [ "${HOTSPOT_FAKE_BELL:-0}" = "1" ] && return 0
    printf '\a'
}

fetch() {
    local url="$1" code=""
    if ! have curl; then printf '000'; return 0; fi
    code="$(curl -sk -m 8 -o /dev/null -w '%{http_code}' "$url" 2>&1)"
    case "$code" in
        [0-9][0-9][0-9]) printf '%s' "$code" ;;
        *) printf '000' ;;
    esac
}

overlay_seam() {
    case "${HOTSPOT_FAKE_OVERLAY:-}" in
        up) printf 'up' ;;
        down) printf 'down' ;;
        *) printf '' ;;
    esac
}

mesh_4096() {
    case "$(overlay_seam)" in
        up) printf '401' ;;
        down) printf '000' ;;
        *) fetch "https://$MESH:4096/session" ;;
    esac
}
mesh_5099() {
    case "$(overlay_seam)" in
        up) printf '200' ;;
        down) printf '000' ;;
        *) fetch "https://$MESH:5099/api/health" ;;
    esac
}
tailscale_4096() {
    case "$(overlay_seam)" in
        up) printf '401' ;;
        down) printf '000' ;;
        *) fetch "https://$TAILSCALE:4096/session" ;;
    esac
}
tailscale_5099() {
    case "$(overlay_seam)" in
        up) printf '200' ;;
        down) printf '000' ;;
        *) fetch "https://$TAILSCALE:5099/api/health" ;;
    esac
}
lan_4096() {
    case "${HOTSPOT_FAKE_LINK:-}" in
        up) printf '401'; return 0 ;;
        down) printf '000'; return 0 ;;
    esac
    fetch "https://$LAN:4096/session"
}

code_4096() { case "$1" in 200 | 401) printf 'PASS' ;; *) printf 'FAIL' ;; esac; }
code_5099() { case "$1" in 200) printf 'PASS' ;; *) printf 'FAIL' ;; esac; }

dns_ok() {
    case "${HOTSPOT_FAKE_DNS:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    if have getent; then getent ahostsv4 example.com 2>&1 | grep -q STREAM && return 0; fi
    if have dscacheutil; then dscacheutil -q host -a name example.com 2>&1 | grep -q ip_address && return 0; fi
    if have nslookup; then nslookup example.com 2>&1 | grep -q 'Address' && return 0; fi
    return 1
}

default_route() {
    case "${HOTSPOT_FAKE_LINK:-}" in
        up) printf 'up'; return 0 ;;
        down) printf 'down'; return 0 ;;
    esac
    if have ip; then
        if ip route show default 2>&1 | grep -q .; then printf 'up'; else printf 'down'; fi
        return 0
    fi
    if have netstat; then
        if netstat -rn 2>&1 | grep -qE '^default|^0\.0\.0\.0'; then printf 'up'; else printf 'down'; fi
        return 0
    fi
    printf 'unknown'
}

current_ssid() {
    if [ -n "${HOTSPOT_FAKE_SSID:-}" ]; then printf '%s' "$HOTSPOT_FAKE_SSID"; return 0; fi
    if have nmcli; then
        nmcli -t -f ACTIVE,SSID device wifi 2>&1 \
            | awk -F: '$1 == "yes" {print $2; exit}'
        return 0
    fi
    printf ''
}

signature() {
    if [ -n "${HOTSPOT_FAKE_SIG:-}" ]; then printf '%s' "$HOTSPOT_FAKE_SIG"; return 0; fi
    {
        if have ip; then
            ip -brief -4 addr show 2>&1 \
                | awk '{for (i = 3; i <= NF; i++) {split($i, a, "/"); if (a[1] ~ /^[0-9]+\./) print a[1]}}'
        fi
        if have ifconfig; then
            ifconfig 2>&1 | awk '$1 == "inet" {print $2}'
        fi
    } | sort -u | tr '\n' ' '
}

mesh_ok() { [ "$(code_4096 "$M4")" = PASS ] && [ "$(code_5099 "$M5")" = PASS ]; }
ts_ok() { [ "$(code_4096 "$T4")" = PASS ] && [ "$(code_5099 "$T5")" = PASS ]; }
overlay_ok() { mesh_ok || ts_ok; }

assess() {
    M4="$(mesh_4096)"
    M5="$(mesh_5099)"
    T4="$(tailscale_4096)"
    T5="$(tailscale_5099)"
    L4="$(lan_4096)"
    DNS="$(dns_ok && printf 'up' || printf 'down')"
    SSID_NOW="$(current_ssid)"
    if overlay_ok; then
        STATE_NOW="up"
    elif [ "$(default_route)" = "up" ] && [ "$DNS" = "up" ]; then
        # Context-aware inhibition: an underlay that is up+DNS but has a
        # DIFFERENT address signature than the last healthy one means the box
        # roamed to another network. The overlay is expected to be down there,
        # so this is "off-network", not an incident; it does not page.
        if [ -n "$(good_sig)" ] && [ "$(signature)" != "$(good_sig)" ]; then
            STATE_NOW="off-network"
        else
            STATE_NOW="overlay-down"
        fi
    else
        STATE_NOW="hotspot-lost"
    fi
}

via() {
    if mesh_ok; then printf 'nebula'; elif ts_ok; then printf 'tailscale'; else printf 'none'; fi
}

report() {
    printf '\n== state: %s (via %s) ==\n' "$STATE_NOW" "$(via)"
    printf '%-30s %-6s %s\n' TARGET CODE VERDICT
    printf '%-30s %-6s %s\n' "nebula:$MESH:4096" "$M4" "$(code_4096 "$M4")"
    printf '%-30s %-6s %s\n' "nebula:$MESH:5099" "$M5" "$(code_5099 "$M5")"
    printf '%-30s %-6s %s\n' "tailscale:$TAILSCALE:4096" "$T4" "$(code_4096 "$T4")"
    printf '%-30s %-6s %s\n' "tailscale:$TAILSCALE:5099" "$T5" "$(code_5099 "$T5")"
    printf '%-30s %-6s %s\n' "lan:$LAN:4096 (control)" "$L4" "$(code_4096 "$L4")"
    printf 'dns: %s  default-route: %s  ssid: %s\n' "$DNS" "$(default_route)" "${SSID_NOW:-unknown}"
}

state_get() {
    local key="$1" line
    [ -f "$STATE" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$key"=*) printf '%s' "${line#*=}"; return 0 ;;
        esac
    done < "$STATE"
    return 1
}

save_state() {
    mkdir -p "$(dirname "$STATE")" || return 0
    printf 'PREV=%s\nFAILS=%s\nSIG=%s\n' "$1" "$2" "$(signature)" > "$STATE"
}

save_good_sig() {
    mkdir -p "$(dirname "$STATE")" || return 0
    printf '%s\n' "$(signature)" > "$STATE.good"
}

good_sig() {
    if [ -f "$STATE.good" ]; then
        cat "$STATE.good"
    fi
}

log_line() {
    mkdir -p "$(dirname "$LOG")" || return 0
    printf '%s\n' "$*" >> "$LOG"
}

quiet_now() {
    [ "$QUIET" = "1" ] && return 0
    [ -f "$QUIET_UNTIL" ] || return 1
    local until=""
    until="$(cat "$QUIET_UNTIL" 2>&1)"
    case "$until" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "$(date +%s)" -lt "$until" ]
}

do_silence() {
    mkdir -p "$(dirname "$QUIET_UNTIL")" || return 0
    printf '%s\n' "$(( $(date +%s) + SILENCE_SEC ))" > "$QUIET_UNTIL"
    printf 'notifications silenced for %ss (delete %s to re-enable)\n' "$SILENCE_SEC" "$QUIET_UNTIL"
}

alert_budget() {
    local level="$1" now=0 last=0 n=0
    now="$(date +%s)"
    if [ -f "$ALERT_STATE" ]; then
        last="$(awk -F= '/^TS=/{print $2}' "$ALERT_STATE")"
        n="$(awk -F= '/^N=/{print $2}' "$ALERT_STATE")"
    fi
    case "$last" in '' | *[!0-9]*) last=0 ;; esac
    case "$n" in '' | *[!0-9]*) n=0 ;; esac
    if [ "$level" = "OK" ]; then
        n=0
    else
        if [ "$last" -gt 0 ] && [ $((now - last)) -lt "$ALERT_COOLDOWN" ]; then
            ALERT_N="$n"
            return 1
        fi
        n=$((n + 1))
        if [ "$n" -gt "$ALERT_MAX" ]; then
            ALERT_N="$n"
            return 1
        fi
    fi
    mkdir -p "$(dirname "$ALERT_STATE")" || return 0
    printf 'TS=%s\nN=%s\n' "$now" "$n" > "$ALERT_STATE"
    ALERT_N="$n"
    return 0
}

alert_urgency() {
    if [ "${ALERT_N:-1}" -ge "$CRITICAL_AFTER" ]; then
        printf 'critical'
    else
        printf 'normal'
    fi
}

notify_user() {
    local level="$1" msg="$2" urgency="$3" timeout="$4" body=""
    local -a actions=()
    body="$level: $msg"
    if [ "$level" != "OK" ]; then
        body="$body
fix: bash $SELF_DIR/hotspot-reconnect.sh --fix"
    fi
    if notify_has_actions; then
        if [ "$ROLE" = "server" ]; then
            actions=(-A "open=Open dashboard" -A "silence=Silence 1h" -A "dismiss=Dismiss")
        else
            actions=(-A "fix=Reconnect" -A "silence=Silence 1h" -A "dismiss=Dismiss")
        fi
        (
            notify_send -u "$urgency" -t "$timeout" -w "${actions[@]}" \
                --hint=string:x-canonical-private-synchronous:opencode-hotspot \
                "opencode hotspot" "$body" > "$ACTION_OUT" 2>&1
            case "$(cat "$ACTION_OUT" 2>&1)" in
                fix)
                    mkdir -p "$(dirname "$FIX_REQUEST")"
                    printf '%s\n' "$(ts)" > "$FIX_REQUEST"
                    ;;
                open) open_url "https://$MESH:5099" ;;
                silence) do_silence ;;
            esac
        ) &
    else
        notify_send -u "$urgency" -t "$timeout" \
            --hint=string:x-canonical-private-synchronous:opencode-hotspot \
            "opencode hotspot" "$body" 2>&1 || true
    fi
}

note_local() {
    bell
    printf '\n==== INFO [%s] %s ====\n' "$(ts)" "$*"
    log_line "$(ts) INFO $*"
}

alert_local() {
    local level="$1" msg="$2" urgency="" timeout=""
    bell
    printf '\n==== %s [%s] %s ====\n' "$level" "$(ts)" "$msg"
    log_line "$(ts) $level $msg"
    if quiet_now; then
        printf '(notifications silenced; still logged)\n'
        return 0
    fi
    if ! have_notify; then
        printf '(no %s; banner only — fix with: bash %s/hotspot-reconnect.sh --fix)\n' \
            "$NOTIFY_BIN" "$SELF_DIR"
        return 0
    fi
    if ! alert_budget "$level"; then
        printf '(notification throttled; still logged)\n'
        return 0
    fi
    urgency="$(alert_urgency)"
    if [ "$urgency" = "critical" ]; then timeout=0; else timeout=8000; fi
    notify_user "$level" "$msg" "$urgency" "$timeout"
    if [ "$ROLE" = "server" ] && have wall; then
        printf '%s\n' "opencode hotspot: $level: $msg" | wall 2>&1 || true
    fi
}

server_reachable() {
    case "${HOTSPOT_FAKE_SERVER:-}" in
        up) return 0 ;;
        down) return 1 ;;
    esac
    [ -n "$SERVER_SSH" ] || return 1
    have ssh || return 1
    local out=""
    out="$(ssh -o BatchMode=yes -o ConnectTimeout=4 "$SERVER_SSH" true 2>&1)"
    return $?
}

flush_pending() {
    [ -s "$PENDING" ] || return 0
    [ -n "$SERVER_SSH" ] || return 0
    server_reachable || return 0
    printf '+ flush queued alerts to %s\n' "$SERVER_SSH"
    ssh -o BatchMode=yes -o ConnectTimeout=4 "$SERVER_SSH" \
        'cat >> "$HOME/.local/state/hotspot-alerts.log"' < "$PENDING" 2>&1
    : > "$PENDING"
}

alert_server() {
    local level="$1" msg="$2" line=""
    line="$(ts) $level $msg"
    line="${line//\'/}"
    if [ "${HOTSPOT_FAKE_SERVER:-}" = "up" ] && [ -z "$SERVER_SSH" ]; then
        printf 'server alert sent (simulated; set HOTSPOT_SERVER_SSH for real)\n'
        return 0
    fi
    if server_reachable; then
        printf 'server alert sent (log + wall)\n'
        ssh -o BatchMode=yes -o ConnectTimeout=4 "$SERVER_SSH" \
            "printf '%s\n' '$line' >> \$HOME/.local/state/hotspot-alerts.log; command -v wall > /dev/null && printf '%s\n' '$line' | wall" 2>&1 || true
        return 0
    fi
    printf 'server unreachable; queued: %s\n' "$line"
    mkdir -p "$(dirname "$PENDING")" || return 0
    printf '%s\n' "$line" >> "$PENDING"
}

safe_token() {
    case "$1" in
        '' | *[!A-Za-z0-9._:@+/-]*) return 1 ;;
        *) return 0 ;;
    esac
}

plan_actions() {
    printf 'reconnect plan (in order):\n'
    if have nmcli; then
        if [ -n "$PROFILE" ] && safe_token "$PROFILE"; then
            printf '  1. saved profile  : nmcli connection up %s\n' "$PROFILE"
        elif [ -n "$PROFILE" ]; then
            printf '  1. saved profile  : SKIP (%s has unsafe chars; run it manually)\n' "$PROFILE"
        fi
        if [ -n "$SSID" ] && safe_token "$SSID"; then
            printf '  2. join SSID      : nmcli device wifi connect %s\n' "$SSID"
        elif [ -n "$SSID" ]; then
            printf '  2. join SSID      : SKIP (%s has spaces/unsafe chars; join via the GUI)\n' "$SSID"
        fi
        printf '  3. radio on       : nmcli radio wifi on\n'
        printf '  4. networking on  : nmcli networking on\n'
    elif have networksetup; then
        if [ -n "$SSID" ] && safe_token "$SSID" && safe_token "$IFACE"; then
            printf '  1. macOS join     : networksetup -setairportnetwork %s %s\n' "$IFACE" "$SSID"
        else
            printf '  1. macOS join     : SKIP (set HOTSPOT_SSID/HOTSPOT_IFACE, no spaces)\n'
        fi
    else
        printf '  (no nmcli/networksetup here; enable the phone hotspot on the device manually)\n'
    fi
}

run_cmd() {
    local cmd="$1" rc=0
    printf '+ %s\n' "$cmd"
    if [ -n "${HOTSPOT_FAKE_RECONNECT:-}" ]; then
        case "$HOTSPOT_FAKE_RECONNECT" in
            ok) HOTSPOT_FAKE_OVERLAY=up; rc=0 ;;
            *) rc=1 ;;
        esac
    else
        bash -c "$cmd" 2>&1
        rc=$?
    fi
    printf '  rc=%s\n' "$rc"
    return "$rc"
}

wait_overlay() {
    local sec="$1" rc=1 deadline
    deadline=$(( $(date +%s) + sec ))
    while :; do
        assess
        if overlay_ok; then rc=0; break; fi
        [ "$(date +%s)" -ge "$deadline" ] && break
        sleep 3
    done
    if [ "$rc" -ne 0 ]; then
        printf 'overlay still down after %ss settle; last: mesh=%s/%s tailscale=%s/%s\n' \
            "$sec" "$M4" "$M5" "$T4" "$T5"
    fi
    return "$rc"
}

confirm_yes() {
    local prompt="$1" ans=""
    if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
    if [ ! -t 0 ]; then
        say 'not a TTY and --yes not given; refusing to change the network'
        return 1
    fi
    printf '%s Type YES to proceed: ' "$prompt"
    read -r ans || ans=""
    [ "$ans" = "YES" ]
}

interactive_reconnect() {
    local prev_conn="" c=0 label=""
    printf '\n== reconnect guidance ==\n'
    printf 'last address set: %s\n' "$(state_get SIG || printf 'unknown')"
    printf 'current ssid   : %s\n' "${SSID_NOW:-unknown}"
    report
    plan_actions
    if ! confirm_yes 'This may drop the current link and rejoin the hotspot.'; then
        say 'left the network unchanged; fix the phone hotspot, then press Enter in --watch to retry.'
        return 2
    fi
    prev_conn="$(current_ssid)"
    if have nmcli; then
        if [ -n "$PROFILE" ] && safe_token "$PROFILE"; then
            label="saved profile $PROFILE"
            if run_cmd "nmcli connection up $PROFILE"; then
                if wait_overlay "$SETTLE_SEC"; then
                    alert_local OK "reconnected via $label"; after_up; return 0
                fi
            fi
        fi
        if [ -n "$SSID" ] && safe_token "$SSID"; then
            label="SSID $SSID"
            if run_cmd "nmcli device wifi connect $SSID"; then
                if wait_overlay "$SETTLE_SEC"; then
                    alert_local OK "reconnected via $label"; after_up; return 0
                fi
            fi
        fi
        run_cmd 'nmcli radio wifi on' || true
        run_cmd 'nmcli networking on' || true
        if wait_overlay "$SETTLE_SEC"; then
            alert_local OK "reconnected (radio/networking up)"; after_up; return 0
        fi
    elif have networksetup; then
        if [ -n "$SSID" ] && safe_token "$SSID" && safe_token "$IFACE"; then
            if run_cmd "networksetup -setairportnetwork $IFACE $SSID"; then
                if wait_overlay "$SETTLE_SEC"; then
                    alert_local OK "reconnected via $SSID"; after_up; return 0
                fi
            fi
        fi
    fi
    printf '\nreconnect did not restore an overlay. Transparent next checks:\n'
    printf '  nmcli device wifi list            # is the phone hotspot visible?\n'
    printf '  nmcli radio wifi                  # is Wi-Fi enabled?\n'
    printf '  ip route show default             # do we have an underlay route?\n'
    printf '  rfkill list                       # is the radio blocked?\n'
    [ -n "$prev_conn" ] && printf '  nmcli connection up "%s"   # restore the previous network\n' "$prev_conn"
    alert_local ALERT "reconnect failed; manual step needed"
    return 2
}

after_up() {
    if [ "${HOTSPOT_NO_HEAL:-0}" = "1" ]; then :; elif [ -f "$SELF_DIR/client-setup.sh" ]; then
        printf '\n== client-setup --heal (refresh the SSH Host block) ==\n'
        bash "$SELF_DIR/client-setup.sh" --heal --quiet 2>&1 \
            || printf 'WARN: client-setup --heal returned non-zero\n'
    fi
    flush_pending
    printf '\nA TUI survives a roam best over `ssh -t`, not `ssh -Y`:\n'
    printf '  ssh -t %s\n' "${SERVER_SSH:-<user>@<server>}"
}

down_message() {
    case "$STATE_NOW" in
        off-network) printf 'on a different network than the last healthy one; the overlay is expected down there' ;;
        overlay-down) printf 'underlay is up but the overlay (nebula/tailscale) is down' ;;
        *) printf 'hotspot/underlay appears lost (no route and no DNS)' ;;
    esac
}

emit_json() {
    [ "$JSON" = "1" ] || return 0
    printf '{"state": "%s", "via": "%s", "mesh_4096": "%s", "mesh_5099": "%s", "tailscale_4096": "%s", "tailscale_5099": "%s", "lan_4096": "%s", "dns": "%s", "ssid": "%s", "fails": %s}\n' \
        "$STATE_NOW" "$(via)" "$M4" "$M5" "$T4" "$T5" "$L4" "$DNS" "${SSID_NOW:-}" "$FAILS"
}

consume_fix_request() {
    [ -f "$FIX_REQUEST" ] || return 0
    rm -f "$FIX_REQUEST"
    printf '\n== fix requested from the notification ==\n'
    if [ "${STATE_NOW:-}" = "up" ]; then
        printf 'connection is already up; nothing to do\n'
        return 0
    fi
    interactive_reconnect
}

show_alerts() {
    local n="${1:-20}"
    [ -f "$LOG" ] || { printf 'no alert log at %s\n' "$LOG"; return 0; }
    printf 'alert log: %s (%s line(s))\n' "$LOG" "$(wc -l < "$LOG")"
    printf 'ALERT=%s OK=%s\n' "$(grep -c ' ALERT ' "$LOG" || true)" "$(grep -c ' OK ' "$LOG" || true)"
    tail -n "$n" "$LOG"
}

do_fix() {
    assess
    report
    if [ "$STATE_NOW" = "up" ]; then
        printf 'connection is up; nothing to do\n'
        return 0
    fi
    interactive_reconnect
}

client_tick() {
    local prev_saved=""
    prev_saved="$(state_get PREV)"
    FAILS="$(state_get FAILS)"
    case "$FAILS" in
        '' | *[!0-9]*) FAILS=0 ;;
    esac
    [ -n "$prev_saved" ] && PREV="$prev_saved"
    assess
    consume_fix_request || true
    if [ "$STATE_NOW" = "up" ]; then
        if [ -n "$PREV" ] && [ "$PREV" != "up" ]; then
            alert_local OK "connection restored via $(via)"
            flush_pending
        fi
        FAILS=0
        PREV="up"
        save_good_sig
        save_state up 0
        report
        emit_json
        return 0
    fi
    FAILS=$((FAILS + 1))
    if [ "$FAILS" -ge "$FAIL_THRESHOLD" ]; then
        if [ "$PREV" != "$STATE_NOW" ]; then
            case "$STATE_NOW" in
                off-network)
                    note_local "off-network: overlay expected down (alerts inhibited); $(down_message)"
                    ;;
                *)
                    alert_local ALERT "connection lost: $(down_message)"
                    alert_server ALERT "client connection lost: $(down_message)"
                    ;;
            esac
        else
            printf 'still down (%s misses): %s\n' "$FAILS" "$(down_message)"
        fi
    else
        printf 'miss %s/%s (settling): %s\n' "$FAILS" "$FAIL_THRESHOLD" "$(down_message)"
    fi
    PREV="$STATE_NOW"
    save_state "$STATE_NOW" "$FAILS"
    report
    emit_json
    if [ "$RECONNECT" -eq 1 ] && [ "$FAILS" -ge "$FAIL_THRESHOLD" ]; then
        if interactive_reconnect; then
            save_state up 0
            return 0
        fi
    fi
    return 2
}

probe_client() {
    case "${HOTSPOT_FAKE_CLIENT:-}" in
        up) printf 'up'; return 0 ;;
        down) printf 'down'; return 0 ;;
    esac
    local code=""
    code="$(fetch "https://$CLIENT_MESH:5099/api/health")"
    if [ "$code" = "200" ]; then printf 'up'; return 0; fi
    if [ -n "$CLIENT_TAILSCALE" ]; then
        code="$(fetch "https://$CLIENT_TAILSCALE:5099/api/health")"
        if [ "$code" = "200" ]; then printf 'up'; return 0; fi
    fi
    if have ping; then
        if ping -c 1 -W 2 "$CLIENT_MESH" 2>&1 | grep -q 'bytes from'; then printf 'up'; return 0; fi
    fi
    printf 'down'
}

server_tick() {
    local client="" prev=""
    client="$(probe_client)"
    prev="$(state_get PREV)"
    if [ "$client" = "up" ]; then
        if [ -n "$prev" ] && [ "$prev" != "up" ]; then
            alert_local OK "client $CLIENT_MESH is reachable again"
        fi
        save_state up 0
        printf 'client %s: up\n' "$CLIENT_MESH"
        return 0
    fi
    if [ "$prev" != "down" ]; then
        alert_local ALERT "client $CLIENT_MESH disappeared (hotspot/overlay lost?)"
    fi
    save_state down 0
    printf 'client %s: down\n' "$CLIENT_MESH"
    return 2
}

do_check() {
    assess
    report
    emit_json
    if [ "$STATE_NOW" = "up" ]; then return 0; fi
    return 2
}

watch_mode() {
    PREV=""
    FAILS=0
    if [ "$ROLE" = "server" ]; then
        printf 'server watch: client=%s every %ss (Ctrl-C to stop)\n' "$CLIENT_MESH" "$WATCH_SEC"
        trap 'printf "interrupted\n"' INT
        while :; do server_tick || true; sleep "$WATCH_SEC"; done
    fi
    printf 'client watch: every %ss, fail-threshold %s, settle %ss (Ctrl-C to stop)\n' \
        "$WATCH_SEC" "$FAIL_THRESHOLD" "$SETTLE_SEC"
    printf 'waiting for a loss; you will get a bell + banner, then reconnect guidance\n'
    trap 'printf "interrupted\n"' INT
    while :; do client_tick || true; sleep "$WATCH_SEC"; done
}

self_test() {
    local fail=0 work="" o="" rc=0
    work="$(mktemp -d)"
    export HOTSPOT_STATE="$work/state"
    export HOTSPOT_LOG="$work/alerts.log"
    export HOTSPOT_PENDING="$work/pending"
    export HOTSPOT_SETTLE_SEC=0
    export HOTSPOT_FAIL_THRESHOLD=1
    export HOTSPOT_FAKE_BELL=1
    export HOTSPOT_NO_HEAL=1
    export HOTSPOT_ALERT_STATE="$work/alerts.state"
    export HOTSPOT_QUIET_UNTIL="$work/quiet.until"
    export HOTSPOT_FIX_REQUEST="$work/fix.request"
    export HOTSPOT_ACTION_OUT="$work/action.out"
    export HOTSPOT_ALERT_COOLDOWN=999
    export HOTSPOT_ALERT_MAX=4

    o=$(HOTSPOT_FAKE_OVERLAY=up HOTSPOT_FAKE_LINK=up HOTSPOT_FAKE_DNS=1 HOTSPOT_FAKE_SIG=aaa \
        bash "$0" --check 2>&1); rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL check-up rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'state: up' || { printf 'FAIL check-up state\n'; fail=1; }

    o=$(HOTSPOT_FAKE_OVERLAY=down HOTSPOT_FAKE_LINK=down HOTSPOT_FAKE_DNS=0 HOTSPOT_FAKE_SIG=bbb \
        bash "$0" --check 2>&1); rc=$?
    [ "$rc" -eq 2 ] || { printf 'FAIL check-down rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'state: hotspot-lost' || { printf 'FAIL check-down state\n'; fail=1; }

    o=$(HOTSPOT_FAKE_OVERLAY=down HOTSPOT_FAKE_LINK=up HOTSPOT_FAKE_DNS=1 HOTSPOT_FAKE_SIG=ccc \
        bash "$0" --check 2>&1); rc=$?
    [ "$rc" -eq 2 ] || { printf 'FAIL overlay-down rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'state: overlay-down' || { printf 'FAIL overlay-down state\n'; fail=1; }

    : > "$work/state"
    o=$(HOTSPOT_FAKE_OVERLAY=down HOTSPOT_FAKE_LINK=down HOTSPOT_FAKE_DNS=0 \
        HOTSPOT_FAKE_SERVER=down HOTSPOT_FAKE_SIG=ddd \
        bash "$0" --tick 2>&1); rc=$?
    [ "$rc" -eq 2 ] || { printf 'FAIL tick-down rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'connection lost' || { printf 'FAIL tick-down alert\n'; fail=1; }
    printf '%s' "$o" | grep -q 'queued' || { printf 'FAIL queue when server down\n'; fail=1; }
    [ -s "$work/pending" ] || { printf 'FAIL pending file empty\n'; fail=1; }

    : > "$work/state"
    o=$(HOTSPOT_FAKE_OVERLAY=down HOTSPOT_FAKE_LINK=down HOTSPOT_FAKE_DNS=0 \
        HOTSPOT_FAKE_SERVER=up HOTSPOT_FAKE_SIG=eee \
        bash "$0" --tick 2>&1); rc=$?
    printf '%s' "$o" | grep -q 'server alert sent' || { printf 'FAIL server alert sent\n'; fail=1; }

    : > "$work/state"
    o=$(HOTSPOT_FAKE_OVERLAY=down HOTSPOT_FAKE_LINK=down HOTSPOT_FAKE_DNS=0 \
        HOTSPOT_FAKE_CLIENT=down HOTSPOT_FAKE_SIG=fff \
        bash "$0" --server --tick 2>&1); rc=$?
    [ "$rc" -eq 2 ] || { printf 'FAIL server-tick-down rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'disappeared' || { printf 'FAIL server alert text\n'; fail=1; }

    : > "$work/state"
    o=$(HOTSPOT_FAKE_OVERLAY=down HOTSPOT_FAKE_LINK=down HOTSPOT_FAKE_DNS=0 \
        HOTSPOT_FAKE_RECONNECT=ok HOTSPOT_FAKE_HAVE_NMCLI=1 HOTSPOT_PROFILE=PhoneAp \
        HOTSPOT_FAKE_SSID=PhoneAp HOTSPOT_SSID=PhoneAp HOTSPOT_FAKE_SIG=ggg HOTSPOT_FAKE_BELL=1 \
        bash "$0" --tick --reconnect --yes 2>&1); rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL reconnect-ok rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'nmcli connection up PhoneAp' || { printf 'FAIL reconnect plan\n'; fail=1; }
    printf '%s' "$o" | grep -q 'reconnected via' || { printf 'FAIL reconnect result\n'; fail=1; }

    o=$(HOTSPOT_FAKE_HAVE_NMCLI=1 HOTSPOT_PROFILE=PhoneAp HOTSPOT_SSID='Phone AP' \
        bash "$0" --plan 2>&1); rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL plan rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'nmcli connection up PhoneAp' || { printf 'FAIL plan profile\n'; fail=1; }
    printf '%s' "$o" | grep -q 'SKIP' || { printf 'FAIL plan unsafe ssid\n'; fail=1; }

    o=$(HOTSPOT_FAKE_OVERLAY=up HOTSPOT_FAKE_LINK=up HOTSPOT_FAKE_DNS=1 HOTSPOT_FAKE_SIG=hhh \
        bash "$0" --check --json 2>&1); rc=$?
    printf '%s' "$o" | grep -q '"state": "up"' || { printf 'FAIL json state\n'; fail=1; }

    o=$(bash "$0" --bogus 2>&1); rc=$?
    [ "$rc" -eq 3 ] || { printf 'FAIL unknown arg rc\n'; fail=1; }

    : > "$work/state"
    o=$(HOTSPOT_FAKE_OVERLAY=up HOTSPOT_FAKE_LINK=up HOTSPOT_FAKE_DNS=1 HOTSPOT_FAKE_SIG=good1 \
        bash "$0" --tick 2>&1); rc=$?
    : > "$work/state"
    o=$(HOTSPOT_FAKE_OVERLAY=down HOTSPOT_FAKE_LINK=up HOTSPOT_FAKE_DNS=1 HOTSPOT_FAKE_SIG=other2 \
        bash "$0" --tick 2>&1); rc=$?
    [ "$rc" -eq 2 ] || { printf 'FAIL off-network rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'off-network' || { printf 'FAIL off-network state\n'; fail=1; }
    printf '%s' "$o" | grep -q 'overlay expected down' || { printf 'FAIL off-network inhibition\n'; fail=1; }
    rm -f "$work/state.good"

    local nf="$work/notify.log" n=0
    : > "$nf"
    export HOTSPOT_FAKE_NOTIFY=1 HOTSPOT_NOTIFY_LOG="$nf"
    : > "$work/state"
    HOTSPOT_FAKE_OVERLAY=down HOTSPOT_FAKE_LINK=down HOTSPOT_FAKE_DNS=0 HOTSPOT_FAKE_SERVER=down HOTSPOT_FAKE_SIG=iii \
        bash "$0" --tick > /dev/null
    : > "$work/state"
    HOTSPOT_FAKE_OVERLAY=down HOTSPOT_FAKE_LINK=down HOTSPOT_FAKE_DNS=0 HOTSPOT_FAKE_SERVER=down HOTSPOT_FAKE_SIG=jjj \
        bash "$0" --tick > /dev/null
    n="$(grep -c 'opencode hotspot' "$nf")"
    [ "$n" -eq 1 ] || { printf 'FAIL alert cooldown (notify lines=%s)\n' "$n"; fail=1; }

    : > "$nf"
    : > "$work/state"
    : > "$work/alerts.state"
    HOTSPOT_FAKE_OVERLAY=down HOTSPOT_FAKE_LINK=down HOTSPOT_FAKE_DNS=0 HOTSPOT_FAKE_SERVER=down HOTSPOT_QUIET=1 \
        bash "$0" --tick > /dev/null
    [ ! -s "$nf" ] || { printf 'FAIL quiet mode notified\n'; fail=1; }

    o=$(bash "$0" --silence 60 2>&1); rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL silence rc=%s\n' "$rc"; fail=1; }
    [ -s "$work/quiet.until" ] || { printf 'FAIL silence file\n'; fail=1; }

    : > "$work/state"
    printf 'x\n' > "$work/fix.request"
    HOTSPOT_FAKE_OVERLAY=up HOTSPOT_FAKE_LINK=up HOTSPOT_FAKE_DNS=1 HOTSPOT_FAKE_SIG=kkk \
        bash "$0" --tick > /dev/null
    [ ! -f "$work/fix.request" ] || { printf 'FAIL fix request not consumed\n'; fail=1; }
    unset HOTSPOT_FAKE_NOTIFY HOTSPOT_NOTIFY_LOG

    o=$(bash "$0" --alerts 5 2>&1); rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL alerts rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q 'alert log:' || { printf 'FAIL alerts header\n'; fail=1; }
    printf '%s' "$o" | grep -q 'ALERT=' || { printf 'FAIL alerts counts\n'; fail=1; }

    rm -f "$work/state" "$work/alerts.log" "$work/pending"
    rm -f "$work/alerts.state" "$work/quiet.until" "$work/fix.request" "$work/action.out" "$work/notify.log" "$work/state.good"
    rmdir "$work" 2>&1 || true
    if [ "$fail" -eq 0 ]; then
        printf 'hotspot-reconnect: self-test PASS (check + lost + overlay-down + alert + server + reconnect + plan + json + cooldown + quiet + silence + fix)\n'
    else
        printf 'hotspot-reconnect: self-test FAIL\n'
    fi
    return "$fail"
}

usage() {
    printf 'usage: %s [--check|--watch|--tick|--plan|--fix|--alerts [N]|--silence [sec]|--server|--self-test] [--reconnect] [--yes] [--json] [--quiet]\n' "$0"
    printf 'client env: HOTSPOT_SSID, HOTSPOT_PROFILE, HOTSPOT_SERVER_SSH, ROAM_MESH_IP, ROAM_LAN_IP\n'
    printf 'server env: CLIENT_MESH_IP, CLIENT_TAILSCALE_IP\n'
    printf 'alerts: normal urgency + 8s expiry, coalesced, one per HOTSPOT_ALERT_COOLDOWN (120s),\n'
    printf '        capped at HOTSPOT_ALERT_MAX (4), critical only after HOTSPOT_CRITICAL_AFTER (3).\n'
    printf 'buttons: Reconnect (client) / Open dashboard (server) + Silence 1h + Dismiss.\n'
    printf 'run --watch on the client; --server --watch on the server\n'
}

main() {
    local arg=""
    while [ $# -gt 0 ]; do
        arg="$1"
        case "$arg" in
            --check) MODE="check"; shift ;;
            --watch) MODE="watch"; shift ;;
            --tick) MODE="tick"; shift ;;
            --plan) MODE="plan"; shift ;;
            --server) ROLE="server"; shift ;;
            --reconnect) RECONNECT=1; shift ;;
            --yes) ASSUME_YES=1; shift ;;
            --json) JSON=1; shift ;;
            --fix) MODE="fix"; shift ;;
            --alerts)
                shift
                case "${1:-}" in
                    '' | *[!0-9]*) ;;
                    *) ALERTS_N="$1"; shift ;;
                esac
                MODE="alerts"
                ;;
            --quiet) QUIET=1; shift ;;
            --silence)
                shift
                case "${1:-}" in
                    '' | *[!0-9]*) ;;
                    *) SILENCE_SEC="$1"; shift ;;
                esac
                MODE="silence"
                ;;
            --settle) SETTLE_SEC="${2:-}"; [ $# -ge 2 ] && shift; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$arg"; usage >&2; return 3 ;;
        esac
    done
    case "$SETTLE_SEC" in
        '' | *[!0-9]*) SETTLE_SEC=20 ;;
    esac
    case "$FAIL_THRESHOLD" in
        '' | *[!0-9]* | 0) FAIL_THRESHOLD=2 ;;
    esac
    case "$MODE" in
        check) do_check; return "$?" ;;
        plan) plan_actions; return 0 ;;
        fix) do_fix; return "$?" ;;
        alerts) show_alerts "${ALERTS_N:-20}"; return "$?" ;;
        silence) do_silence; return "$?" ;;
        tick)
            if [ "$ROLE" = "server" ]; then server_tick; return "$?"; fi
            client_tick; return "$?" ;;
        watch) watch_mode; return 0 ;;
        '')
            usage; return 3 ;;
    esac
}

main "$@"
