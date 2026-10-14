#!/usr/bin/env bash
#
# chrome-cdp-attach.sh — make the USER'S Chrome CDP-reachable on the user's
# OWN profile (logins persist) and forward the debug port so a client in
# another namespace (the sandbox) can attach. Run ON THE HOST.
#
# Why not chrome-cdp-up.sh: that starts an ISOLATED profile under
# /tmp/chrome-cdp (logged out) — fine for our own :5099/:4096 pages, wrong
# for GitHub settings, which need the signed-in session. Chrome also IGNORES
# --remote-debugging-port when an instance already owns the profile
# ("Opening in existing browser session"), so the running instance must be
# restarted WITH the flag, on the DEFAULT profile.
#
#   bash scripts/chrome-cdp-attach.sh [URL] [--port N] [--fwd N] [--yes] [--no-forward] [--dry-run]
#
# Restarting Chrome closes unsaved tabs; it asks for a typed YES unless
# --yes is given. The socat forward is idempotent and never auto-deleted.
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

main() {
    local PORT=9222 FWD=9223 URL="" ASSUME=0 NOFWD=0 DRY=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --port) PORT="${2:-9222}"; shift 2 ;;
            --fwd) FWD="${2:-9223}"; shift 2 ;;
            --yes) ASSUME=1; shift ;;
            --no-forward) NOFWD=1; shift ;;
            --dry-run) DRY=1; shift ;;
            -h | --help)
                printf 'usage: %s [URL] [--port N] [--fwd N] [--yes] [--no-forward] [--dry-run]\n' "$0"
                return 0 ;;
            -*) printf 'unknown arg: %s\n' "$1"; return 2 ;;
            *) URL="$1"; shift ;;
        esac
    done
    [ -n "$URL" ] || URL="about:blank"

    have google-chrome-stable || { printf 'GATE FAIL: google-chrome-stable not on PATH\n'; return 2; }

    local np banner
    np=$(chrome_count)
    banner=$(probe "$PORT")
    printf '=== chrome-cdp-attach ===\n'
    printf 'host:    %s\n' "$(hostname)"
    printf 'cwd:     %s\n' "$PWD"
    printf 'chrome:  %s instance(s)\n' "$np"
    printf 'probe %s: %s\n' "$PORT" "${banner:-closed}"
    printf 'socat:   %s\n' "$(have socat && command -v socat || printf MISSING)"

    if [ "$DRY" -eq 1 ]; then
        printf '\n[dry-run] would: restart %s chrome on the default profile with --remote-debugging-port=%s; forward %s -> 127.0.0.1:%s; open %s\n' \
            "$np" "$PORT" "$FWD" "$PORT" "$URL"
        return 0
    fi

    if [ -n "$banner" ]; then
        printf 'CDP already listening on %s\n' "$PORT"
    else
        if [ "$np" -gt 0 ] && [ "$ASSUME" -ne 1 ]; then
            printf '\nChrome is running WITHOUT the debug port. Restarting closes unsaved tabs.\n'
            printf 'Type YES to restart Chrome with CDP on the default profile: '
            local ans=""
            read -r ans
            [ "$ans" = YES ] || { printf 'aborted (no changes)\n'; return 2; }
        fi
        if [ "$np" -gt 0 ]; then
            printf 'stopping chrome (SIGTERM, graceful)...\n'
            pkill -TERM -f 'google-chrome-stable' || true
            local i=0
            while [ "$i" -lt 15 ] && [ "$(chrome_count)" -gt 0 ]; do
                sleep 1
                i=$((i + 1))
            done
        fi
        printf 'starting chrome with CDP on the default profile...\n'
        setsid google-chrome-stable --remote-debugging-port="$PORT" \
            --remote-allow-origins='*' "$URL" > /tmp/chrome-cdp-attach.log 2>&1 < /dev/null &
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
            return 2
        fi
        printf 'CDP bound: %s\n' "$banner"
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
