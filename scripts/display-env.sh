#!/usr/bin/env bash
#
# display-env.sh - make a TTY/login shell on the client expose the local X
# display, so `ssh -Y` (or the managed ForwardX11Trusted block) can forward the
# clipboard. Read-only unless --install.
#
#   ./scripts/display-env.sh --print     # show the detected DISPLAY/XAUTHORITY
#   ./scripts/display-env.sh --install   # idempotent guarded block in ~/.bashrc
#   ./scripts/display-env.sh --self-test # offline, temp rc file
#
# Why: ssh only requests X11 forwarding when the CLIENT has DISPLAY set. A
# TTY login on the MacBook has no DISPLAY even though the XFCE session does
# (systemd --user environment has DISPLAY=:0 and XAUTHORITY). This adds a
# guarded block that runs only for interactive shells and only fills unset
# values, so it never overrides a graphical terminal.
#
# Env: DISPLAY_ENV_RC (default ~/.bashrc), DISPLAY_ENV_FORCE=1 to include in
# self-test. Plain ASCII. No sed. No rm -rf. No set -e. No top-level exit.
# No 2>/dev/null.
#
set -uo pipefail

BEGIN_MARK="# >>> opencode-deepseek-jev display >>>"
END_MARK="# <<< opencode-deepseek-jev display <<<"
RC="${DISPLAY_ENV_RC:-$HOME/.bashrc}"

have() { command -v "$1" >/dev/null; }

detect_display() {
    if [ -n "${DISPLAY:-}" ]; then printf '%s' "$DISPLAY"; return 0; fi
    local s
    for s in /tmp/.X11-unix/X*; do
        [ -S "$s" ] || continue
        printf ':%s' "${s##*X}"
        return 0
    done
    printf ':0'
}

detect_xauthority() {
    if [ -n "${XAUTHORITY:-}" ] && [ -r "${XAUTHORITY}" ]; then printf '%s' "$XAUTHORITY"; return 0; fi
    if have systemctl; then
        local xa
        xa="$(systemctl --user show-environment 2>&1 | awk -F= '$1=="XAUTHORITY"{print $2; exit}')"
        [ -n "$xa" ] && [ -r "$xa" ] && { printf '%s' "$xa"; return 0; }
    fi
    for xa in "/run/lightdm/${USER:-owner}/xauthority" "$HOME/.Xauthority"; do
        [ -r "$xa" ] && { printf '%s' "$xa"; return 0; }
    done
    printf ''
}

block_text() {
    cat <<'EOF'
# >>> opencode-deepseek-jev display >>>
# Guarded: interactive shells only; fills DISPLAY/XAUTHORITY if unset so
# ssh -Y can forward the local X11 clipboard from a TTY.
case $- in
  *i*)
    if [ -z "${DISPLAY:-}" ]; then
      for _s in /tmp/.X11-unix/X*; do
        [ -S "$_s" ] && { export DISPLAY=":${_s##*X}"; break; }
      done
    fi
    if [ -z "${XAUTHORITY:-}" ]; then
      _xa="$(systemctl --user show-environment 2>&1 | awk -F= '$1=="XAUTHORITY"{print $2; exit}')"
      [ -n "$_xa" ] && [ -r "$_xa" ] && export XAUTHORITY="$_xa"
    fi
    unset _s _xa
    ;;
esac
# <<< opencode-deepseek-jev display <<<
EOF
}

write_block() {
    local file="$1" block="$2" tmp="$1.tmp.$$" line replaced=0 skip=0
    : > "$tmp" || return 1
    if [ -f "$file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            if [ "$line" = "$BEGIN_MARK" ]; then
                if [ "$replaced" -eq 0 ]; then printf '%s\n' "$block" >> "$tmp"; replaced=1; fi
                skip=1
                continue
            fi
            if [ "$skip" -eq 1 ]; then
                [ "$line" = "$END_MARK" ] && skip=0
                continue
            fi
            printf '%s\n' "$line" >> "$tmp"
        done < "$file"
    fi
    if [ "$replaced" -eq 0 ]; then
        [ -s "$tmp" ] && printf '\n' >> "$tmp"
        printf '%s\n' "$block" >> "$tmp"
    fi
    if [ -f "$file" ] && cmp -s "$file" "$tmp"; then rm -f "$tmp"; printf 'unchanged %s\n' "$file"; return 0; fi
    if [ -f "$file" ]; then
        cp "$file" "$file.bak.$(date -u +%Y%m%dT%H%M%SZ)" || true
    fi
    mkdir -p "$(dirname "$file")" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$file" && printf 'wrote %s\n' "$file"
}

self_test() {
    local fail=0 w="" out=""
    w="$(mktemp)"
    printf 'alias ll="ls -l"\n' > "$w"
    out="$(DISPLAY_ENV_RC="$w" DISPLAY_ENV_FORCE=1 bash "$0" --install 2>&1)"
    grep -q '^# >>> opencode-deepseek-jev display >>>$' "$w" || { printf 'FAIL install block\n'; fail=1; }
    grep -q 'alias ll="ls -l"' "$w" || { printf 'FAIL clobbered rc\n'; fail=1; }
    DISPLAY_ENV_RC="$w" DISPLAY_ENV_FORCE=1 bash "$0" --install > /dev/null 2>&1
    [ "$(grep -c '^# >>> opencode-deepseek-jev display >>>$' "$w")" -eq 1 ] || { printf 'FAIL not idempotent\n'; fail=1; }
    out="$(DISPLAY=:7 XAUTHORITY=/tmp/x DISPLAY_ENV_FORCE=1 bash "$0" --print 2>&1)"
    printf '%s' "$out" | grep -q 'DISPLAY=:7' || { printf 'FAIL print display\n'; fail=1; }
    rm -f "$w" "$w".bak.*
    if [ "$fail" -eq 0 ]; then printf 'display-env: self-test PASS (install + idempotent + print)\n'; else printf 'display-env: self-test FAIL\n'; fi
    return "$fail"
}

usage() {
    printf 'usage: %s [--print|--install|--self-test]\n' "$0"
}

main() {
    case "${1:-}" in
        --print)
            printf 'export DISPLAY=%s\n' "$(detect_display)"
            local xa
            xa="$(detect_xauthority)"
            [ -n "$xa" ] && printf 'export XAUTHORITY=%s\n' "$xa"
            ;;
        --install)
            if [ "${DISPLAY_ENV_FORCE:-0}" != "1" ] && [ "$(uname -s)" = "Darwin" ]; then
                printf 'skip: macOS uses XQuartz, not ~/.bashrc DISPLAY\n'
                return 0
            fi
            write_block "$RC" "$(block_text)"
            ;;
        --self-test) self_test; return "$?" ;;
        -h | --help) usage; return 0 ;;
        *) usage >&2; return 2 ;;
    esac
}

main "$@"
