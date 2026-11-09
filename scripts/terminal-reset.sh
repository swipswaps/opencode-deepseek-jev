#!/usr/bin/env bash
#
# terminal-reset.sh - clear leaked SGR mouse reports (the `ESC[<b;x;yM` tail
# shows up as `35;55;16M` spam) and a leftover alt-screen after a crashed or
# aborted TUI, and optionally install a guarded ~/.bashrc hook so the next
# interactive shell self-heals.
#
#   ./scripts/terminal-reset.sh             # full: mouse-off + stty sane + reset
#   ./scripts/terminal-reset.sh --soft      # invisible: mouse-off + alt/cursor
#   ./scripts/terminal-reset.sh --print     # print the shell printf command
#   ./scripts/terminal-reset.sh --install   # idempotent guarded ~/.bashrc block
#   ./scripts/terminal-reset.sh --uninstall # remove that block
#   ./scripts/terminal-reset.sh --self-test # offline, temp rc file
#
# Why: a full-screen TUI turns on any-event mouse tracking (?1003) and SGR
# encoding (?1006). If it aborts mid-session (or the link drops) it may not
# restore them, so the terminal keeps sending motion events and the tty echoes
# them as literal `35;55;16M35;55;16M...`. The fix is to send the matching
# "off" sequences; `stty sane` restores echo/icanon; `reset` reinitialises the
# emulator. The ~/.bashrc hook is silent (invisible escape codes only).
#
# Env: TERMRESET_RC (default ~/.bashrc), TERMRESET_QUIET=1 (no telemetry).
# Exit: 0 ok, 2 usage.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No top-level exit. No 2>/dev/null.
#
set -uo pipefail

BEGIN_MARK="# >>> opencode-deepseek-jev terminal-reset >>>"
END_MARK="# <<< opencode-deepseek-jev terminal-reset <<<"
RC="${TERMRESET_RC:-$HOME/.bashrc}"
QUIET="${TERMRESET_QUIET:-0}"

have() { command -v "$1" > /dev/null; }

soft_emit() {
    printf '\033[?1000l\033[?1002l\033[?1003l\033[?1005l\033[?1006l\033[?1015l\033[?1004l\033[?1049l\033[?25h'
}

print_cmd() {
    cat <<'EOF'
printf '\033[?1000l\033[?1002l\033[?1003l\033[?1005l\033[?1006l\033[?1015l\033[?1004l\033[?1049l\033[?25h'
EOF
}

telemetry() {
    [ "$QUIET" = "1" ] && return 0
    local tty_state="notty"
    [ -t 0 ] && [ -t 1 ] && tty_state="tty"
    printf 'reset: shell=%s %s TERM=%s stty=%s reset=%s\n' \
        "${SHELL:-unknown}" "$tty_state" "${TERM:-unset}" \
        "$(have stty && printf yes || printf no)" \
        "$(have reset && printf yes || have tput && printf tput || printf no)" >&2
}

full_reset() {
    soft_emit
    if [ -t 0 ] && [ -t 1 ]; then
        if have stty; then stty sane 2>&1 || true; fi
        if have reset; then
            reset 2>&1 || true
        elif have tput; then
            tput reset 2>&1 || true
        fi
    fi
}

block_text() {
    cat <<'EOF'
# >>> opencode-deepseek-jev terminal-reset >>>
# Guarded: interactive shells only. Clears leaked SGR mouse reports
# (ESC[<b;x;yM spam) and a leftover alt-screen from a crashed/aborted TUI.
case $- in
  *i*)
    printf '\033[?1000l\033[?1002l\033[?1003l\033[?1005l\033[?1006l\033[?1015l\033[?1004l\033[?1049l\033[?25h'
    ;;
esac
# <<< opencode-deepseek-jev terminal-reset <<<
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

remove_block() {
    local file="$1" tmp="$1.tmp.$$" line skip=0
    [ -f "$file" ] || { printf 'absent %s\n' "$file"; return 0; }
    : > "$tmp" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$BEGIN_MARK" ]; then skip=1; continue; fi
        if [ "$skip" -eq 1 ]; then
            [ "$line" = "$END_MARK" ] && skip=0
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$file"
    if cmp -s "$file" "$tmp"; then rm -f "$tmp"; printf 'unchanged %s\n' "$file"; return 0; fi
    cp "$file" "$file.bak.$(date -u +%Y%m%dT%H%M%SZ)" || true
    mv "$tmp" "$file" && printf 'removed block from %s\n' "$file"
}

self_test() {
    local fail=0 w="" o="" rc=0
    w="$(mktemp)"
    printf 'alias ll="ls -l"\n' > "$w"

    o=$(TERMRESET_RC="$w" TERMRESET_QUIET=1 bash "$0" --install 2>&1); rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL install rc=%s\n' "$rc"; fail=1; }
    grep -q "^$BEGIN_MARK$" "$w" || { printf 'FAIL install block\n'; fail=1; }
    grep -q 'alias ll="ls -l"' "$w" || { printf 'FAIL clobbered rc\n'; fail=1; }

    TERMRESET_RC="$w" TERMRESET_QUIET=1 bash "$0" --install > /dev/null 2>&1
    [ "$(grep -c "^$BEGIN_MARK$" "$w")" -eq 1 ] || { printf 'FAIL not idempotent\n'; fail=1; }

    o=$(bash "$0" --soft 2>&1)
    printf '%s' "$o" | grep -q '?1003l' || { printf 'FAIL soft 1003\n'; fail=1; }
    printf '%s' "$o" | grep -q '?1006l' || { printf 'FAIL soft 1006\n'; fail=1; }
    printf '%s' "$o" | grep -q '?25h' || { printf 'FAIL soft cursor\n'; fail=1; }

    o=$(bash "$0" --print 2>&1)
    printf '%s' "$o" | grep -q "printf '\\\\033\[?1000l" || { printf 'FAIL print cmd\n'; fail=1; }
    printf '%s' "$o" | grep -q '?1003l' || { printf 'FAIL print content\n'; fail=1; }

    TERMRESET_RC="$w" TERMRESET_QUIET=1 bash "$0" --uninstall > /dev/null 2>&1
    grep -q "^$BEGIN_MARK$" "$w" && { printf 'FAIL uninstall left block\n'; fail=1; }
    grep -q 'alias ll="ls -l"' "$w" || { printf 'FAIL uninstall clobbered rc\n'; fail=1; }

    o=$(bash "$0" --bogus 2>&1); rc=$?
    [ "$rc" -eq 2 ] || { printf 'FAIL unknown arg rc=%s\n' "$rc"; fail=1; }

    rm -f "$w" "$w".bak.*
    if [ "$fail" -eq 0 ]; then
        printf 'terminal-reset: self-test PASS (install + idempotent + soft + print + uninstall)\n'
    else
        printf 'terminal-reset: self-test FAIL\n'
    fi
    return "$fail"
}

usage() {
    printf 'usage: %s [--soft|--print|--install|--uninstall|--self-test]\n' "$0"
    printf 'env: TERMRESET_RC (default ~/.bashrc), TERMRESET_QUIET=1\n'
}

main() {
    case "${1:-}" in
        '') telemetry; full_reset ;;
        --soft) soft_emit ;;
        --print) print_cmd ;;
        --install) telemetry; write_block "$RC" "$(block_text)" ;;
        --uninstall) remove_block "$RC" ;;
        --self-test) self_test; return "$?" ;;
        -h | --help) usage; return 0 ;;
        *) usage >&2; return 2 ;;
    esac
}

main "$@"
