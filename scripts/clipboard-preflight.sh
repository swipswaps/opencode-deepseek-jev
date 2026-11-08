#!/usr/bin/env bash
#
# clipboard-preflight.sh - gate and drive the session clipboard across
# Wayland, X11, and SSH (server-local vs forwarded X11).
#
# Why this exists: "copy/paste works" is not a property of the shell, it is a
# property of the whole path (display server -> clipboard owner -> app). The
# failure that prompted this gate: opencode's paste path probes the clipboard
# via hasClipboardImage/fromClipboard; when the clipboard carried an image
# flavour it tried to decode it, logged ImageDecodeError, and aborted the
# prompt ("Failed to send prompt"). Meanwhile a display-less SSH shell had no
# DISPLAY at all, so xclip could not reach any owner. This script makes that
# path explicit and gates it before a paste is attempted.
#
# Backends: Wayland (wl-copy/wl-paste) is preferred when a Wayland session is
# present; otherwise X11 (xclip, then xsel). For a local X11 session the script
# falls back to DISPLAY=:0 only when an X socket exists and no display was
# inherited. For SSH, a server-local fallback cannot reach the *client*
# clipboard; use ssh -X/-Y (X11 forwarding) so xclip talks to the client's X
# server.
#
#   ./scripts/clipboard-preflight.sh               # gate (default --check)
#   ./scripts/clipboard-preflight.sh --targets     # raw flavours/TARGETS
#   printf '%s' "$text" | ./scripts/clipboard-preflight.sh --set
#   ./scripts/clipboard-preflight.sh --clear-text   # drop an image flavour
#   ./scripts/clipboard-preflight.sh --json         # machine contract
#   ./scripts/clipboard-preflight.sh --self-test    # offline, no display
#
# Exit: 0 usable (text or empty), 3 an image flavour is present (opencode may
# abort the send: run --clear-text), 2 no backend (install wl-clipboard/xclip,
# or reconnect with ssh -X/-Y). --set/--clear-text: 0 on success, 2 no backend.
#
# Test seams: CLIP_FORCE_BACKEND, CLIP_FAKE_TARGETS (offline --check/--json).
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
# References:
#   wl-clipboard(1); xclip(1); ssh(1) X11 forwarding (ForwardX11/ForwardX11Trusted)
#
set -uo pipefail

have() { command -v "$1" >/dev/null; }

# ---- pure logic (unit-tested by --self-test) ------------------------------

targets_has_image() {
    # targets_has_image TARGETS_TEXT -> 0 when any image flavour is offered
    printf '%s\n' "$1" | grep -qi 'image'
}

targets_has_text() {
    # targets_has_text TARGETS_TEXT -> 0 for a text-capable selection
    printf '%s\n' "$1" | grep -qE 'UTF8_STRING|STRING|text/plain|COMPOUND_TEXT|TEXT'
}

choose_backend() {
    # choose_backend SESSION WAYLAND DISPLAY HAS_WL HAS_XCLIP HAS_XSEL
    local session="$1" wl="$2" disp="$3" hwl="$4" hx="$5" hs="$6"
    if [ -n "${CLIP_FORCE_BACKEND:-}" ]; then printf '%s' "$CLIP_FORCE_BACKEND"; return 0; fi
    if [ -n "${CLIP_FAKE_TARGETS:-}" ]; then printf 'fake'; return 0; fi
    if [ "$session" = "wayland" ] && [ -n "$wl" ] && [ "$hwl" = 1 ]; then printf 'wayland'; return 0; fi
    if [ -n "$disp" ] && [ "$hx" = 1 ]; then printf 'xclip'; return 0; fi
    if [ -n "$disp" ] && [ "$hs" = 1 ]; then printf 'xsel'; return 0; fi
    if [ -n "$wl" ] && [ "$hwl" = 1 ]; then printf 'wayland'; return 0; fi
    printf 'none'
}

# ---- environment detection ------------------------------------------------

ensure_display() {
    # A tty/SSH shell inherits no DISPLAY. If a local X socket exists, use it
    # (this is the *server's* clipboard; SSH cross-machine needs -X/-Y).
    if [ -z "${DISPLAY:-}" ] && [ -S /tmp/.X11-unix/X0 ]; then
        DISPLAY=:0
        export DISPLAY
    fi
}

detect() {
    SESSION_TYPE="${XDG_SESSION_TYPE:-${CLIP_FORCE_SESSION:-}}"
    [ -n "${WAYLAND_DISPLAY:-}" ] && SESSION_TYPE="wayland"
    [ -n "${DISPLAY:-}" ] && [ "$SESSION_TYPE" != "wayland" ] && SESSION_TYPE="${SESSION_TYPE:-x11}"
    local hwl=0 hx=0 hs=0
    have wl-copy && have wl-paste && hwl=1
    have xclip && hx=1
    have xsel && hs=1
    BACKEND="$(choose_backend "$SESSION_TYPE" "${WAYLAND_DISPLAY:-}" "${DISPLAY:-}" "$hwl" "$hx" "$hs")"
}

backend_cmd_targets() {
    case "$BACKEND" in
        fake) printf '%s\n' "${CLIP_FAKE_TARGETS:-}" ;;
        wayland) wl-paste --list-types 2>&1 ;;
        xclip) xclip -selection clipboard -o -t TARGETS 2>&1 ;;
        *) return 1 ;;
    esac
}

clip_targets() {
    local out=""
    out="$(backend_cmd_targets)"
    printf '%s' "$out"
}

clip_set() {
    local text="$1"
    case "$BACKEND" in
        fake) return 0 ;;
        wayland) printf '%s' "$text" | wl-copy ;;
        xclip) printf '%s' "$text" | xclip -selection clipboard > /dev/null 2>&1 & ;;
        xsel) printf '%s' "$text" | xsel --clipboard --input ;;
        *) return 1 ;;
    esac
}

ssh_hint() {
    # Over SSH the clipboard owner lives on the *client*; only X11 forwarding
    # connects the two. Prefer untrusted (-X); escalate to trusted (-Y) only
    # when the paste still fails, and codify it with ssh-x11-setup.sh.
    [ -n "${SSH_CONNECTION:-}" ] || return 0
    local setup
    setup="$(dirname "$0")/ssh-x11-setup.sh"
    case "${DISPLAY:-}" in
        '')
            printf 'NOTE: SSH with no DISPLAY: X11 forwarding is off, so xclip cannot reach the client clipboard.\n'
            printf '      reconnect: ssh -X <host>   (still empty? ssh -Y)\n'
            printf '      codify it once: %s --print\n' "$setup"
            ;;
        localhost:* | 127.0.0.1:*)
            if [ "${BACKEND:-}" = "none" ]; then
                printf 'NOTE: X11 forwarding is on but no clipboard backend was found; install xclip on the server.\n'
            fi
            ;;
        *)
            printf 'NOTE: SSH DISPLAY=%s is the SERVER clipboard, not the client.\n' "${DISPLAY:-}"
            printf '      reconnect with X11 forwarding: ssh -X <host> (then -Y if the paste still fails)\n'
            printf '      codify it once: %s --print\n' "$setup"
            ;;
    esac
    return 0
}

usage() {
    printf 'usage: %s [--check|--targets|--set|--clear-text|--json|--self-test|--help]\n' "$0"
    printf '  --set reads the text from stdin. Gate exit: 0 ok, 3 image flavour, 2 no backend.\n'
}

self_test() {
    local fail=0 t=""
    targets_has_image "TARGETS
UTF8_STRING" && { printf 'FAIL image false-positive\n'; fail=1; }
    targets_has_image "TARGETS
image/png" || { printf 'FAIL image miss\n'; fail=1; }
    targets_has_text "TARGETS
UTF8_STRING" || { printf 'FAIL text miss\n'; fail=1; }
    targets_has_text "image/png" && { printf 'FAIL text false-positive\n'; fail=1; }

    t="$(choose_backend wayland wayland-0 "" 1 1 0)"
    [ "$t" = "wayland" ] || { printf 'FAIL choose wayland got=%s\n' "$t"; fail=1; }
    t="$(choose_backend x11 "" ":0" 0 1 0)"
    [ "$t" = "xclip" ] || { printf 'FAIL choose xclip got=%s\n' "$t"; fail=1; }
    t="$(choose_backend x11 "" ":0" 0 0 1)"
    [ "$t" = "xsel" ] || { printf 'FAIL choose xsel got=%s\n' "$t"; fail=1; }
    t="$(choose_backend "" "" "" 0 0 0)"
    [ "$t" = "none" ] || { printf 'FAIL choose none got=%s\n' "$t"; fail=1; }

    # Offline gate: text flavour PASS, image flavour 3.
    local o="" rc=0
    o=$(CLIP_FAKE_TARGETS="TARGETS
UTF8_STRING" bash "${BASH_SOURCE[0]}" --json 2>&1); rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL text gate rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q '"verdict": "PASS"' || { printf 'FAIL text json\n'; fail=1; }
    o=$(CLIP_FAKE_TARGETS="TARGETS
image/png" bash "${BASH_SOURCE[0]}" --json 2>&1); rc=$?
    [ "$rc" -eq 3 ] || { printf 'FAIL image gate rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q '"image": true' || { printf 'FAIL image json\n'; fail=1; }
    o=$(CLIP_FORCE_BACKEND=none CLIP_FAKE_TARGETS="" bash "${BASH_SOURCE[0]}" --json 2>&1); rc=$?
    [ "$rc" -eq 2 ] || { printf 'FAIL no-backend rc=%s\n' "$rc"; fail=1; }

    # Over SSH the hint must name the codified fix, not just "ssh -Y".
    o=$(env -u DISPLAY SSH_CONNECTION="10.0.0.1 1 10.0.0.2 22" CLIP_FORCE_BACKEND=none \
        bash "${BASH_SOURCE[0]}" 2>&1); rc=$?
    printf '%s' "$o" | grep -q 'ssh-x11-setup.sh' || { printf 'FAIL ssh hint missing setup path\n'; fail=1; }

    if [ "$fail" -eq 0 ]; then printf 'clipboard-preflight: self-test PASS (backend + image/text gate)\n'; else printf 'clipboard-preflight: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    local mode="check" text=""
    case "${1:-}" in
        "") ;;
        --check) mode="check" ;;
        --targets) mode="targets" ;;
        --set) mode="set" ;;
        --clear-text) mode="clear" ;;
        --json) mode="json" ;;
        --self-test) self_test; return "$?" ;;
        -h | --help) usage; return 0 ;;
        *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
    esac

    ensure_display
    detect

    if [ "$mode" = "targets" ]; then
        [ "$BACKEND" = "none" ] && { printf 'FAIL: no clipboard backend (install wl-clipboard or xclip; ssh -X/-Y for remote)\n'; return 2; }
        clip_targets
        printf '\n'
        return 0
    fi

    if [ "$mode" = "set" ] || [ "$mode" = "clear" ]; then
        [ "$BACKEND" = "none" ] && { printf 'FAIL: no clipboard backend (install wl-clipboard or xclip; ssh -X/-Y for remote)\n'; return 2; }
        if [ "$mode" = "clear" ]; then text=" "; else text="$(cat)"; fi
        if clip_set "$text"; then
            printf 'clipboard set via %s (text, no image flavour)\n' "$BACKEND"
            return 0
        fi
        printf 'FAIL: %s could not own the clipboard\n' "$BACKEND"
        return 2
    fi

    # check/json
    local targets image=false text_ok=false verdict="PASS" code=0
    if [ "$BACKEND" = "none" ]; then
        verdict="NO_BACKEND"; code=2
    else
        targets="$(clip_targets)"
        if targets_has_image "$targets"; then image=true; fi
        if targets_has_text "$targets"; then text_ok=true; fi
        if [ "$image" = true ]; then verdict="IMAGE_FLAVOUR"; code=3; fi
    fi
    if [ "$mode" = "json" ]; then
        printf '{"backend": "%s", "session": "%s", "display": "%s", "wayland": "%s", "ssh": "%s", "image": %s, "text": %s, "verdict": "%s"}\n' \
            "$BACKEND" "$SESSION_TYPE" "${DISPLAY:-}" "${WAYLAND_DISPLAY:-}" "${SSH_CONNECTION:+yes}" "$image" "$text_ok" "$verdict"
    else
        printf '=== clipboard-preflight ===\n'
        printf 'session: %s  backend: %s  DISPLAY=%s WAYLAND_DISPLAY=%s\n' "${SESSION_TYPE:-unknown}" "$BACKEND" "${DISPLAY:-<unset>}" "${WAYLAND_DISPLAY:-<unset>}"
        printf 'text: %s  image: %s\n' "$text_ok" "$image"
        case "$verdict" in
            NO_BACKEND)
                printf 'FAIL: no clipboard backend. Wayland: install wl-clipboard. X11: install xclip.\n'
                printf '      Over SSH the client clipboard needs X11 forwarding: ssh -Y <host>\n'
                ;;
            IMAGE_FLAVOUR)
                printf 'FAIL: clipboard advertises an image flavour; opencode may fail to decode it and abort the prompt.\n'
                printf '      fix: printf " " | %s --clear-text   (or copy plain text)\n' "$0"
                ;;
            *)
                if [ "$text_ok" = true ]; then printf 'OK: text clipboard usable.\n'; else printf 'OK: backend owns an (empty/unknown) selection.\n'; fi
                ;;
        esac
        ssh_hint
    fi
    return "$code"
}

main "$@"
