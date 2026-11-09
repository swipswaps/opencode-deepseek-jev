#!/usr/bin/env bash
#
# client-setup.sh - one-shot client bootstrap: git clone, run this, and the
# SSH clipboard path + server discovery + a self-heal timer are configured.
#
# It does four things, idempotently:
#   1. finds a reachable server address (mesh -> tailscale -> LAN),
#   2. writes/refreshes the managed ~/.ssh/config Host block (X11 forwarding,
#      trusted trust scoped to that one Host, keepalives) via ssh-x11-setup.sh,
#   3. checks the local X server (XQuartz on macOS) that receives the clipboard,
#   4. installs a self-heal timer (systemd user on Linux, launchd on macOS)
#      that re-discovers the server and repairs the block after a network change.
#
#   git clone https://github.com/swipswaps/opencode-deepseek-jev
#   ./opencode-deepseek-jev/scripts/client-setup.sh
#
#   ./scripts/client-setup.sh --check          # report only, change nothing
#   ./scripts/client-setup.sh --write-only     # write config + units, no launch
#   ./scripts/client-setup.sh --heal           # one repair pass (timer calls this)
#   ./scripts/client-setup.sh --uninstall      # remove block + timer
#   ./scripts/client-setup.sh --discover       # print the chosen server, exit
#   ./scripts/client-setup.sh --self-test      # offline, temp dirs only
#
# Flags: --server HOST, --alias NAME, --user USER, --candidates "a b c",
# --prefer mesh|tailscale|lan, --interval SEC, --untrusted, --no-heal, --quiet,
# --install-deps.
#
# Seams (for self-test/CI): CLIENT_PLATFORM=linux|darwin, CLIENT_SSH_CONFIG,
# CLIENT_UNIT_DIR, CLIENT_LOG, CLIENT_STATE, CLIENT_FAKE_REACHABLE,
# CLIENT_FAKE_NET, CLIENT_NO_LAUNCH, CLIENT_NO_LOG.
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
X11_SETUP="$SELF_DIR/ssh-x11-setup.sh"
DEFAULT_CANDIDATES="10.100.0.24 100.119.125.16 192.168.4.24"
ALIAS_DEFAULT="opencode-jev"
INTERVAL_DEFAULT=300
LABEL="com.opencode.deepseek.jev.client-heal"
have() { command -v "$1" >/dev/null; }

platform() {
    if [ -n "${CLIENT_PLATFORM:-}" ]; then printf '%s' "$CLIENT_PLATFORM"; return; fi
    case "$(uname -s)" in
        Darwin) printf 'darwin' ;;
        *) printf 'linux' ;;
    esac
}

ssh_config() { printf '%s' "${CLIENT_SSH_CONFIG:-$HOME/.ssh/config}"; }

unit_dir() {
    local p="$1"
    if [ -n "${CLIENT_UNIT_DIR:-}" ]; then printf '%s' "$CLIENT_UNIT_DIR"; return; fi
    if [ "$p" = "darwin" ]; then
        printf '%s' "$HOME/Library/LaunchAgents"
    else
        printf '%s' "$HOME/.config/systemd/user"
    fi
}

log_path() { printf '%s' "${CLIENT_LOG:-$HOME/.local/state/opencode-client-heal.log}"; }

state_path() { printf '%s' "${CLIENT_STATE:-$HOME/.local/state/opencode-client-setup.conf}"; }

state_get() {
    # state_get KEY FILE -> value after the first '=' (empty if absent)
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
    local f="$1" cands="$2" alias="$3" trusted="$4" untrusted=0
    [ "$trusted" = "1" ] || untrusted=1
    mkdir -p "$(dirname "$f")" || return 0
    printf 'CANDIDATES=%s\nALIAS=%s\nUNTRUSTED=%s\n' "$cands" "$alias" "$untrusted" > "$f"
}

log() {
    local msg="$1" f
    [ "${CLIENT_NO_LOG:-0}" = "1" ] && return 0
    f="$(log_path)"
    mkdir -p "$(dirname "$f")" || return 0
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$f"
}

say() {
    [ "${QUIET:-0}" = "1" ] && return 0
    printf '%s\n' "$1"
}

valid_host() {
    case "$1" in
        '' | *[!A-Za-z0-9.:-]*) return 1 ;;
    esac
    [ "${#1}" -le 253 ]
}

probe_host() {
    local h="$1" code
    if [ "${CLIENT_FAKE_NET:-0}" = "1" ]; then
        case " ${CLIENT_FAKE_REACHABLE:-} " in
            *" $h "*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    have curl || return 1
    code="$(curl -sk -m 4 -o /dev/null -w '%{http_code}' "https://$h:5099/api/health" 2>&1)"
    [ "$code" = "200" ] && return 0
    code="$(curl -sk -m 4 -o /dev/null -w '%{http_code}' "https://$h:4096/api/health" 2>&1)"
    case "$code" in
        200 | 401) return 0 ;;
    esac
    return 1
}

discover() {
    local h
    for h in $CANDIDATES; do
        if probe_host "$h"; then printf '%s' "$h"; return 0; fi
    done
    return 1
}

prefer_first() {
    # prefer_first NEEDLE "a b c" -> items containing NEEDLE first, order kept
    local needle="$1" list="$2" first="" rest="" h
    for h in $list; do
        case "$h" in
            *"$needle"*) first="$first $h" ;;
            *) rest="$rest $h" ;;
        esac
    done
    set -- $first $rest
    printf '%s' "$*"
}

current_host() {
    managed_field "$1" HostName
}

managed_field() {
    local f="$1" key="$2"
    [ -f "$f" ] || return 1
    grep -A8 '^# >>> opencode-deepseek-jev x11 >>>$' "$f" 2>&1 \
        | awk -v k="$key" '$1==k {print $2; exit}'
}

x_server_state() {
    local p="$1"
    if [ "$p" = "darwin" ]; then
        if [ -d "/Applications/Utilities/XQuartz.app" ] || have xset; then
            if pgrep -x Xquartz > /dev/null 2>&1 || pgrep -x X11.bin > /dev/null 2>&1; then
                printf 'running'; return 0
            fi
            printf 'installed-not-running'; return 0
        fi
        printf 'missing'; return 0
    fi
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then printf 'running'; return 0; fi
    case "${DISPLAY:-}" in
        '') ;;
        localhost:* | 127.0.0.1:*) printf 'forwarded'; return 0 ;;
        *) printf 'running'; return 0 ;;
    esac
    if [ -S /tmp/.X11-unix/X0 ]; then printf 'socket-present'; return 0; fi
    printf 'missing'
}

config_trust() {
    local f="$1"
    [ -f "$f" ] || { printf 'none'; return 0; }
    if grep -q '^# >>> opencode-deepseek-jev x11 >>>$' "$f" 2>&1; then
        if grep -q '^    ForwardX11Trusted yes$' "$f" 2>&1; then
            printf 'trusted'
        else
            printf 'untrusted'
        fi
    else
        printf 'none'
    fi
}

start_x_server() {
    local p="$1"
    [ "$p" = "darwin" ] || return 0
    case "$(x_server_state "$p")" in
        installed-not-running)
            if have open; then
                open -a XQuartz > /dev/null 2>&1 || true
                log "started XQuartz"
            fi
            ;;
        missing)
            log "XQuartz missing; clipboard needs an X server on the client"
            ;;
    esac
    return 0
}

ensure_prereqs() {
    local p="$1" rc=0
    have ssh || { printf 'FAIL: ssh missing; install OpenSSH client\n'; rc=1; }
    have curl || { printf 'FAIL: curl missing; install curl\n'; rc=1; }
    case "$(x_server_state "$p")" in
        missing)
            if [ "$p" = "darwin" ]; then
                printf 'WARN: XQuartz missing (clipboard needs it): brew install --cask xquartz\n'
                if [ "${INSTALL_DEPS:-0}" = "1" ] && have brew; then
                    brew install --cask xquartz || printf 'WARN: brew install xquartz failed\n'
                fi
            else
                printf 'WARN: no DISPLAY/Wayland here; run this on the desktop client that owns the clipboard\n'
            fi
            ;;
    esac
    return "$rc"
}

write_units() {
    local dir="$1" p="$2" interval="$3"
    mkdir -p "$dir" || return 1
    if [ "$p" = "darwin" ]; then
        cat > "$dir/$LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SELF_DIR/client-setup.sh</string>
    <string>--heal</string>
    <string>--quiet</string>
  </array>
  <key>StartInterval</key><integer>$interval</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$(log_path)</string>
  <key>StandardErrorPath</key><string>$(log_path)</string>
</dict>
</plist>
EOF
        return 0
    fi
    cat > "$dir/opencode-client-heal.service" <<EOF
[Unit]
Description=opencode-deepseek-jev client self-heal (SSH/X11/clipboard)
After=default.target

[Service]
Type=oneshot
ExecStart=/bin/bash "$SELF_DIR/client-setup.sh" --heal --quiet
EOF
    cat > "$dir/opencode-client-heal.timer" <<EOF
[Unit]
Description=Run the opencode client self-heal every ${interval}s

[Timer]
OnBootSec=2min
OnUnitInactiveSec=${interval}s
Unit=opencode-client-heal.service

[Install]
WantedBy=timers.target
EOF
    return 0
}

enable_units() {
    local dir="$1" p="$2"
    [ "${CLIENT_NO_LAUNCH:-0}" = "1" ] && return 0
    if [ "$p" = "darwin" ]; then
        have launchctl || return 0
        launchctl bootout "gui/$(id -u)" "$dir/$LABEL.plist" > /dev/null 2>&1 || true
        if ! launchctl bootstrap "gui/$(id -u)" "$dir/$LABEL.plist" > /dev/null 2>&1; then
            launchctl load -w "$dir/$LABEL.plist" > /dev/null 2>&1 || true
        fi
        return 0
    fi
    have systemctl || return 0
    systemctl --user daemon-reload > /dev/null 2>&1 || true
    systemctl --user enable --now opencode-client-heal.timer > /dev/null 2>&1 || \
        printf 'WARN: systemctl --user enable failed; timer written to %s\n' "$dir"
    return 0
}

disable_units() {
    local dir="$1" p="$2"
    if [ "${CLIENT_NO_LAUNCH:-0}" != "1" ]; then
        if [ "$p" = "darwin" ] && have launchctl; then
            launchctl bootout "gui/$(id -u)" "$dir/$LABEL.plist" > /dev/null 2>&1 || true
        elif have systemctl; then
            systemctl --user disable --now opencode-client-heal.timer > /dev/null 2>&1 || true
            systemctl --user daemon-reload > /dev/null 2>&1 || true
        fi
    fi
    rm -f "$dir/$LABEL.plist" "$dir/opencode-client-heal.service" "$dir/opencode-client-heal.timer"
}

write_config() {
    local host="$1" alias="$2" user="$3" trusted="$4" cfg="$5" flag="--trusted"
    [ "$trusted" = "1" ] || flag="--untrusted"
    bash "$X11_SETUP" --write "$cfg" --alias "$alias" --host "$host" --user "$user" "$flag"
}

heal_units_state() {
    local dir="$1" p="$2"
    if [ "$p" = "darwin" ]; then
        if [ -f "$dir/$LABEL.plist" ]; then printf 'installed'; else printf 'absent'; fi
        return 0
    fi
    if [ -f "$dir/opencode-client-heal.timer" ]; then printf 'installed'; else printf 'absent'; fi
}

self_test() {
    local fail=0 work="" out="" rc=0 cfg="" units="" win="" din=""
    work="$(mktemp -d)"
    cfg="$work/config"
    units="$work/units"
    [ "$(prefer_first 192.168.4.24 "10.100.0.24 100.119.125.16 192.168.4.24")" = "192.168.4.24 10.100.0.24 100.119.125.16" ] \
        || { printf 'FAIL prefer_first\n'; fail=1; }
    export CLIENT_FAKE_REACHABLE="10.100.0.24 192.168.4.24"
    export CLIENT_FAKE_NET=1
    export CLIENT_NO_LAUNCH=1
    export CLIENT_NO_LOG=1
    export CLIENT_SSH_CONFIG="$cfg"
    export CLIENT_UNIT_DIR="$units"
    export CLIENT_STATE="$work/state"

    CLIENT_PLATFORM=linux bash "$0" --write-only --alias testalias --user tester \
        --candidates "10.100.0.24 192.168.4.24" > "$work/setup.txt" 2>&1
    [ "$?" -eq 0 ] || { printf 'FAIL linux write-only: %s\n' "$(cat "$work/setup.txt")"; fail=1; }
    grep -q '^Host testalias 10.100.0.24$' "$cfg" || { printf 'FAIL config alias\n'; fail=1; }
    grep -q '^    HostName 10.100.0.24$' "$cfg" || { printf 'FAIL discovery host\n'; fail=1; }
    grep -q '^    ForwardX11Trusted yes$' "$cfg" || { printf 'FAIL trusted line\n'; fail=1; }
    grep -q '^CANDIDATES=10.100.0.24 192.168.4.24$' "$work/state" || { printf 'FAIL state saved\n'; fail=1; }
    [ -f "$units/opencode-client-heal.timer" ] || { printf 'FAIL timer unit\n'; fail=1; }
    grep -q "ExecStart=/bin/bash \"$SELF_DIR/client-setup.sh\" --heal --quiet" "$units/opencode-client-heal.service" \
        || { printf 'FAIL service ExecStart\n'; fail=1; }
    grep -q '^OnUnitInactiveSec=300s$' "$units/opencode-client-heal.timer" || { printf 'FAIL timer interval\n'; fail=1; }

    CLIENT_PLATFORM=darwin CLIENT_UNIT_DIR="$work/darwin" bash "$0" --write-only --alias testalias > "$work/darwin.txt" 2>&1
    [ "$?" -eq 0 ] || { printf 'FAIL darwin write-only\n'; fail=1; }
    grep -q '<key>StartInterval</key><integer>300</integer>' "$work/darwin/$LABEL.plist" \
        || { printf 'FAIL launchd interval\n'; fail=1; }

    CLIENT_FAKE_REACHABLE="10.100.0.24 100.119.125.16 192.168.4.24" \
        CLIENT_SSH_CONFIG="$work/config2" CLIENT_STATE="$work/state2" \
        bash "$0" --write-only --prefer tailscale --alias testalias > /dev/null 2>&1
    grep -q '^    HostName 100.119.125.16$' "$work/config2" \
        || { printf 'FAIL prefer tailscale\n'; fail=1; }

    out="$(CLIENT_FAKE_REACHABLE="192.168.4.24" bash "$0" --discover 2>&1)"
    rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL discover rc=%s\n' "$rc"; fail=1; }
    [ "$out" = "192.168.4.24" ] || { printf 'FAIL discover chose=%s\n' "$out"; fail=1; }

    out="$(CLIENT_FAKE_REACHABLE="" bash "$0" --discover 2>&1)"
    [ "$?" -eq 1 ] || { printf 'FAIL discover-unreachable rc\n'; fail=1; }

    # Heal after a roam: saved candidates are reused, the reachable address
    # changed, and the block is refreshed in place.
    CLIENT_FAKE_REACHABLE="192.168.4.24" bash "$0" --heal --quiet > /dev/null 2>&1
    grep -q '^    HostName 192.168.4.24$' "$cfg" || { printf 'FAIL heal did not refresh host\n'; fail=1; }

    out="$(CLIENT_FAKE_REACHABLE="192.168.4.24" bash "$0" --check 2>&1)"
    printf '%s' "$out" | grep -q 'VERDICT: READY' || { printf 'FAIL check ready\n'; fail=1; }
    printf '%s' "$out" | grep -q 'Host testalias, trusted' || { printf 'FAIL check alias/trust\n'; fail=1; }

    CLIENT_PLATFORM=linux bash "$0" --uninstall > /dev/null 2>&1
    grep -q 'ForwardX11' "$cfg" && { printf 'FAIL uninstall left block\n'; fail=1; }
    [ -f "$units/opencode-client-heal.timer" ] && { printf 'FAIL uninstall left timer\n'; fail=1; }
    [ -f "$work/state" ] && { printf 'FAIL uninstall left state\n'; fail=1; }

    bash "$0" --bogus > /dev/null 2>&1
    [ "$?" -eq 2 ] || { printf 'FAIL unknown arg rc\n'; fail=1; }

    rm -f "$work/config" "$work/config".bak.* "$work/config2" "$work/config2".bak.* \
        "$work/state" "$work/state2" "$work/units"/* "$work/darwin"/* \
        "$work"/*.txt "$work"/*.log
    rmdir "$work/units" "$work/darwin" "$work" 2>&1 || true

    if [ "$fail" -eq 0 ]; then
        printf 'client-setup: self-test PASS (discovery + config + units + heal + uninstall)\n'
    else
        printf 'client-setup: self-test FAIL\n'
    fi
    return "$fail"
}

usage() {
    printf 'usage: %s [--check|--write-only|--heal|--uninstall|--discover|--self-test]\n' "$0"
    printf 'flags: --server HOST --alias NAME --user USER --candidates "a b c"\n'
    printf '       --prefer mesh|tailscale|lan --interval SEC --untrusted --no-heal\n'
    printf '       --quiet --install-deps\n'
}

main() {
    local mode="setup" server="" alias="$ALIAS_DEFAULT" user="${USER:-}" candidates="$DEFAULT_CANDIDATES"
    local interval="$INTERVAL_DEFAULT" trusted=1 no_heal=0 rc=0
    local alias_set=0 user_set=0 trust_set=0 candidates_set=0 prefer="mesh"
    QUIET=0 INSTALL_DEPS=0
    while [ $# -gt 0 ]; do
        case "$1" in
            "") shift ;;
            --check) mode="check"; shift ;;
            --write-only) mode="write"; shift ;;
            --heal) mode="heal"; shift ;;
            --uninstall) mode="uninstall"; shift ;;
            --discover) mode="discover"; shift ;;
            --self-test) self_test; return "$?" ;;
            --server) server="${2:-}"; [ $# -ge 2 ] && shift; shift ;;
            --alias) alias="${2:-}"; alias_set=1; [ $# -ge 2 ] && shift; shift ;;
            --user) user="${2:-}"; user_set=1; [ $# -ge 2 ] && shift; shift ;;
            --candidates) candidates="${2:-}"; candidates_set=1; [ $# -ge 2 ] && shift; shift ;;
            --prefer) prefer="${2:-mesh}"; [ $# -ge 2 ] && shift; shift ;;
            --interval) interval="${2:-}"; [ $# -ge 2 ] && shift; shift ;;
            --untrusted) trusted=0; trust_set=1; shift ;;
            --trusted) trusted=1; trust_set=1; shift ;;
            --no-heal) no_heal=1; shift ;;
            --install-deps) INSTALL_DEPS=1; shift ;;
            --quiet) QUIET=1; shift ;;
            -h | --help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 2 ;;
        esac
    done

    CANDIDATES="$candidates"
    case "$interval" in '' | *[!0-9]*) interval="$INTERVAL_DEFAULT" ;; esac
    if [ -n "$server" ] && ! valid_host "$server"; then
        printf 'FAIL: bad server %s\n' "$server"
        return 2
    fi
    if [ -n "$server" ]; then CANDIDATES="$server"; fi

    local sp=""
    sp="$(state_path)"
    if [ -z "$server" ] && [ "$candidates_set" -eq 0 ] && [ -f "$sp" ]; then
        local saved=""
        saved="$(state_get CANDIDATES "$sp")"
        if [ -n "$saved" ]; then
            candidates="$saved"
            CANDIDATES="$saved"
        fi
    fi

    case "$prefer" in
        mesh | tailscale | lan) ;;
        *) printf 'FAIL: --prefer must be mesh|tailscale|lan\n'; return 2 ;;
    esac
    if [ -z "$server" ] && [ "$prefer" != "mesh" ]; then
        case "$prefer" in
            tailscale) candidates="$(prefer_first 100.119.125.16 "$CANDIDATES")" ;;
            lan) candidates="$(prefer_first 192.168.4.24 "$CANDIDATES")" ;;
        esac
        CANDIDATES="$candidates"
    fi

    local p cfg units
    p="$(platform)"
    cfg="$(ssh_config)"
    units="$(unit_dir "$p")"

    case "$mode" in
        discover)
            local found=""
            found="$(discover)"
            if [ -z "$found" ]; then
                printf 'FAIL: no reachable server among: %s\n' "$CANDIDATES"
                return 1
            fi
            printf '%s\n' "$found"
            return 0
            ;;
        uninstall)
            disable_units "$units" "$p"
            bash "$X11_SETUP" --remove "$cfg"
            rm -f "$sp"
            say "uninstalled client self-heal and removed the SSH block"
            log "uninstall complete"
            return 0
            ;;
        check)
            local ch reached xs ca
            ch="$(current_host "$cfg")"
            ca="$(managed_field "$cfg" Host)"
            reached="$(discover)"
            xs="$(x_server_state "$p")"
            printf 'platform: %s\n' "$p"
            printf 'ssh config: %s\n' "$cfg"
            printf 'configured host: %s (Host %s, %s)\n' "${ch:-<none>}" "${ca:-<none>}" "$(config_trust "$cfg")"
            printf 'reachable now: %s\n' "${reached:-<none>}"
            printf 'x server: %s\n' "$xs"
            printf 'self-heal: %s (%s)\n' "$(heal_units_state "$units" "$p")" "$units"
            [ -n "$reached" ] || { printf 'VERDICT: FAIL (server unreachable)\n'; return 1; }
            printf 'VERDICT: READY (ssh %s)\n' "${ca:-$alias}"
            return 0
            ;;
        heal)
            local target="" ca="" cu="" ct=""
            target="$(discover)"
            if [ -z "$target" ]; then
                log "heal: no reachable server among $CANDIDATES"
                say "heal: server unreachable; will retry"
                return 1
            fi
            ca="$(managed_field "$cfg" Host)"
            cu="$(managed_field "$cfg" User)"
            [ "$alias_set" -eq 0 ] && [ -n "$ca" ] && alias="$ca"
            [ "$user_set" -eq 0 ] && [ -n "$cu" ] && user="$cu"
            if [ "$trust_set" -eq 0 ] && grep -q '^    ForwardX11Trusted yes$' "$cfg" 2>&1; then
                trusted=1
            elif [ "$trust_set" -eq 0 ] && grep -q '^    ForwardX11 ' "$cfg" 2>&1; then
                trusted=0
            elif [ "$trust_set" -eq 0 ]; then
                local su=""
                su="$(state_get UNTRUSTED "$sp")"
                [ "$su" = "1" ] && trusted=0
            fi
            ct="$(current_host "$cfg")"
            if [ "$ct" != "$target" ] || ! grep -q '^    ForwardX11 yes$' "$cfg" 2>&1; then
                write_config "$target" "$alias" "$user" "$trusted" "$cfg" > /dev/null 2>&1 || rc=$?
                log "heal: server $target; ssh block refreshed"
            fi
            start_x_server "$p"
            log "heal: ok server=$target x=$(x_server_state "$p")"
            say "heal: ok (server $target)"
            return "$rc"
            ;;
        write | setup) ;;
    esac

    # setup / write-only
    ensure_prereqs "$p" || rc=1
    local target=""
    if [ -n "$server" ]; then
        target="$server"
        if ! probe_host "$target"; then
            printf 'WARN: %s is not answering yet; writing it anyway (self-heal will refresh)\n' "$target"
        fi
    else
        target="$(discover)"
        if [ -z "$target" ]; then
            target="${candidates%% *}"
            printf 'WARN: no candidate answered; using %s (self-heal will refresh)\n' "$target"
        fi
    fi
    write_config "$target" "$alias" "$user" "$trusted" "$cfg" || rc=$?
    save_state "$sp" "$CANDIDATES" "$alias" "$trusted"
    if [ "$no_heal" -eq 0 ]; then
        write_units "$units" "$p" "$interval" || rc=$?
        if [ "$mode" = "setup" ]; then enable_units "$units" "$p"; fi
    fi
    if [ "$mode" = "setup" ]; then start_x_server "$p"; fi
    log "setup: alias=$alias server=$target config=$cfg units=$units"
    say "server:   $target"
    say "ssh block: $cfg (Host $alias, X11 trusted)"
    if [ "$no_heal" -eq 0 ]; then
        say "self-heal: every ${interval}s via $units"
    else
        say "self-heal: not installed (--no-heal)"
    fi
    say "connect:  ssh $alias"
    return "$rc"
}

main "$@"
