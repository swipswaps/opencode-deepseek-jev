#!/usr/bin/env bash
#
# chrome-cdp-attach.sh — make a CDP-reachable Chrome whose profile CARRIES
# the user's logins, and forward the debug port so a client in another
# namespace (the sandbox) can attach. Run ON THE HOST.
#
# The hard constraints this encodes (learned from the actual failures):
#   1. Chrome (M136+) REFUSES --remote-debugging-port on the DEFAULT profile:
#      "DevTools remote debugging requires a non-default data directory."
#      -> we always pass an explicit non-default --user-data-dir.
#   2. A fresh /tmp profile is logged OUT, so GitHub settings can't be used.
#      -> with --clone-default we seed the non-default dir from the real
#         profile (~/.config/google-chrome), so cookies survive (same machine,
#         same OS keyring).
#   3. Chrome ignores --remote-debugging-port while an instance already owns
#      the profile ("Opening in existing browser session").
#      -> we SIGTERM a running instance first (typed YES unless --yes).
#
#   bash scripts/chrome-cdp-attach.sh [URL] [--clone-default] [--yes]
#        [--port N] [--fwd N] [--no-forward] [--dry-run]
#
#   profile dir: $CDP_PROFILE, else ~/.cache/chrome-cdp-profile (persistent).
#
# Then, from the sandbox (RULES #62):
#   CDP_HOST=<host-ip> CDP_PORT=<fwd> node scripts/cdp-tab.mjs tabs
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

# probe PORT -> the Chrome "Browser" banner on stdout, empty if not reachable.
probe() { curl -s -m 3 "http://127.0.0.1:$1/json/version" | grep -o '"Browser": *"[^"]*"'; }

chrome_count() {
    if have pgrep; then
        pgrep -c -f 'google-chrome-stable' || true
    else
        printf '0'
    fi
}

default_profile() {
    local c
    for c in "$HOME/.config/google-chrome" "$HOME/.config/chromium" \
             "$HOME/.var/app/com.google.Chrome/config/google-chrome"; do
        [ -d "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

main() {
    local PORT=9222 FWD=9223 URL="about:blank" ASSUME=0 NOFWD=0 DRY=0 CLONE=0
    local PROFILE_DIR="${CDP_PROFILE:-$HOME/.cache/chrome-cdp-profile}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --port) PORT="${2:-9222}"; shift 2 ;;
            --fwd) FWD="${2:-9223}"; shift 2 ;;
            --yes) ASSUME=1; shift ;;
            --clone-default) CLONE=1; shift ;;
            --no-forward) NOFWD=1; shift ;;
            --dry-run) DRY=1; shift ;;
            -h | --help)
                printf 'usage: %s [URL] [--clone-default] [--yes] [--port N] [--fwd N] [--no-forward] [--dry-run]\n' "$0"
                return 0 ;;
            -*) printf 'unknown arg: %s\n' "$1"; return 2 ;;
            *) URL="$1"; shift ;;
        esac
    done

    have google-chrome-stable || { printf 'GATE FAIL: google-chrome-stable not on PATH\n'; return 2; }
    [ "$URL" = "about:blank" ] && [ "$CLONE" -eq 1 ] && URL="https://github.com/settings/personal-access-tokens/new"

    local np banner src
    np=$(chrome_count)
    banner=$(probe "$PORT")
    printf '=== chrome-cdp-attach ===\n'
    printf 'host:     %s\n' "$(hostname)"
    printf 'cwd:      %s\n' "$PWD"
    printf 'chrome:   %s instance(s)\n' "$np"
    printf 'probe %s:  %s\n' "$PORT" "${banner:-closed}"
    printf 'profile:  %s%s\n' "$PROFILE_DIR" "$([ -e "$PROFILE_DIR" ] && printf ' (exists)' || printf ' (new)')"
    printf 'socat:    %s\n' "$(have socat && command -v socat || printf MISSING)"

    if [ "$DRY" -eq 1 ]; then
        printf '\n[dry-run] would: stop %s chrome; %s; launch google-chrome-stable --user-data-dir=%s --remote-debugging-port=%s %s; forward %s -> 127.0.0.1:%s\n' \
            "$np" "$([ "$CLONE" -eq 1 ] && printf 'clone the default profile into it' || printf 'use it as-is')" \
            "$PROFILE_DIR" "$PORT" "$URL" "$FWD" "$PORT"
        return 0
    fi

    if [ -z "$banner" ]; then
        if [ "$np" -gt 0 ] && [ "$ASSUME" -ne 1 ]; then
            printf '\nChrome is running. It must stop to free the profile. Unsaved tabs close.\n'
            printf 'Type YES to continue: '
            local ans=""
            read -r ans
            [ "$ans" = YES ] || { printf 'aborted (no changes)\n'; return 2; }
        fi
        if [ "$np" -gt 0 ]; then
            printf 'stopping chrome (SIGTERM, graceful)...\n'
            pkill -TERM -f 'google-chrome-stable' || true
            local i=0
            while [ "$i" -lt 15 ] && [ "$(chrome_count)" -gt 0 ]; do sleep 1; i=$((i + 1)); done
        fi
        if [ "$CLONE" -eq 1 ] && [ ! -e "$PROFILE_DIR" ]; then
            if src=$(default_profile); then
                printf 'cloning %s -> %s (login cookies carry over)...\n' "$src" "$PROFILE_DIR"
                mkdir -p "$PROFILE_DIR" || return 2
                cp -a "$src/." "$PROFILE_DIR/" || { printf 'GATE FAIL: profile clone failed\n'; return 2; }
                rm -f "$PROFILE_DIR/SingletonLock" "$PROFILE_DIR/SingletonSocket" "$PROFILE_DIR/SingletonCookie"
            else
                printf 'WARN no default profile found to clone; starting logged out\n'
            fi
        fi
        mkdir -p "$PROFILE_DIR" || return 2
        printf 'starting chrome with CDP on a NON-default profile dir (M136 requirement)...\n'
        setsid google-chrome-stable --user-data-dir="$PROFILE_DIR" \
            --remote-debugging-port="$PORT" --remote-allow-origins='*' \
            --no-first-run "$URL" > /tmp/chrome-cdp-attach.log 2>&1 < /dev/null &
        local j=0
        banner=""
        while [ "$j" -lt 30 ]; do
            banner=$(probe "$PORT")
            [ -n "$banner" ] && break
            sleep 1
            j=$((j + 1))
        done
        if [ -z "$banner" ]; then
            printf 'GATE FAIL: CDP not reachable on %s after 30s; log tail:\n' "$PORT"
            tail -n 15 /tmp/chrome-cdp-attach.log
            if grep -q 'non-default data directory' /tmp/chrome-cdp-attach.log; then
                printf 'hint: --user-data-dir was rejected; this build requires a NON-default dir (the script sets one per line above).\n'
            fi
            return 2
        fi
        printf 'CDP bound: %s\n' "$banner"
    else
        printf 'CDP already listening on %s\n' "$PORT"
    fi

    if [ "$NOFWD" -ne 1 ]; then
        if [ -n "$(probe "$FWD")" ]; then
            printf 'forward %s already up\n' "$FWD"
        elif have socat; then
            printf 'forwarding %s -> 127.0.0.1:%s (socat, background)\n' "$FWD" "$PORT"
            setsid socat TCP-LISTEN:"$FWD",fork,reuseaddr TCP:127.0.0.1:"$PORT" \
                > /tmp/chrome-cdp-attach-socat.log 2>&1 < /dev/null &
            sleep 1
            if [ -n "$(probe "$FWD")" ]; then
                printf 'forward up on %s\n' "$FWD"
            else
                printf 'WARN forward not confirmed; socat log tail:\n'
                tail -n 5 /tmp/chrome-cdp-attach-socat.log
            fi
        else
            printf 'WARN socat missing; skip forward (run cdp-tab on this host instead)\n'
        fi
    fi

    printf '\nsandbox attach:\n  CDP_HOST=<host-ip> CDP_PORT=%s node scripts/cdp-tab.mjs tabs\n' "$FWD"
    return 0
}

main "$@"
