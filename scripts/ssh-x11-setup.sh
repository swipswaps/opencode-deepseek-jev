#!/usr/bin/env bash
#
# ssh-x11-setup.sh - codify clipboard-over-SSH (X11 forwarding) instead of
# typing `ssh -Y` by hand after every network change.
#
# Decision this encodes: keep `ForwardX11 yes` for the normal case and add
# `ForwardX11Trusted yes` (what `-Y` does) scoped to ONE Host block. Untrusted
# X11 forwarding is safer but some clipboard owners/managers refuse untrusted
# clients, which is why a bare `ssh -X` can still fail to paste. Trusting a
# single mesh Host is the smallest change that makes the clipboard reliable,
# and a Host block makes a reconnect after roaming deterministic.
#
#   ./scripts/ssh-x11-setup.sh --print            # show the Host block
#   ./scripts/ssh-x11-setup.sh --check            # inspect sshd + this session
#   ./scripts/ssh-x11-setup.sh --write [FILE]     # idempotent; default ~/.ssh/config
#   ./scripts/ssh-x11-setup.sh --remove [FILE]    # drop the managed block
#   ./scripts/ssh-x11-setup.sh --self-test        # offline, temp files only
#
# Flags: --alias NAME, --host HOST, --user USER, --untrusted (omit the trusted
# line). These let client-setup.sh drive this writer on any client.
#
# No python3 required: the managed-region edit is pure bash, so it runs on a
# fresh client (including macOS bash 3.2) with no extra tooling.
#
# Exit: 0 ok/clean, 1 check found a gap, 2 cannot run.
#
# Plain ASCII. No sed. No set -e. No top-level exit. No rm -rf. No 2>/dev/null.
#
# References:
#   ssh_config(5) ForwardX11 / ForwardX11Trusted; sshd_config(5) X11Forwarding;
#   https://www.openssh.com/manual.html
#
set -uo pipefail

DEFAULT_ALIAS="opencode-jev"
DEFAULT_HOST="10.100.0.24"
BEGIN_MARK="# >>> opencode-deepseek-jev x11 >>>"
END_MARK="# <<< opencode-deepseek-jev x11 <<<"

have() { command -v "$1" >/dev/null; }

valid_value() {
    case "$1" in
        '' | *[!A-Za-z0-9._:@-]*) return 1 ;;
    esac
    [ "${#1}" -le 253 ]
}

block_text() {
    # block_text ALIAS HOST USER TRUSTED
    # Match BOTH the alias and the literal host, so `ssh 10.100.0.24` gets the
    # trusted forwarding too (not just `ssh opencode-jev`).
    local alias="$1" host="$2" user="$3" trusted="${4:-1}" match="$1"
    if [ "$host" != "$alias" ]; then match="$alias $host"; fi
    printf '%s\n' "$BEGIN_MARK"
    printf 'Host %s\n' "$match"
    printf '    HostName %s\n' "$host"
    if [ -n "$user" ]; then
        printf '    User %s\n' "$user"
    fi
    printf '    ForwardX11 yes\n'
    if [ "$trusted" = "1" ]; then
        printf '    ForwardX11Trusted yes\n'
    fi
    printf '    ServerAliveInterval 15\n'
    printf '    ServerAliveCountMax 3\n'
    printf '    ConnectTimeout 10\n'
    printf '%s\n' "$END_MARK"
}

# Replace-or-append the managed region. Pure bash so it is byte-exact and
# idempotent without python3; a second identical run reports "unchanged".
write_block() {
    local file="$1" block="$2" tmp="$1.tmp.$$"
    local line replaced=0 skip=0
    : > "$tmp" || return 1
    if [ -f "$file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            if [ "$line" = "$BEGIN_MARK" ]; then
                if [ "$replaced" -eq 0 ]; then
                    printf '%s\n' "$block" >> "$tmp"
                    replaced=1
                fi
                skip=1
                continue
            fi
            if [ "$skip" -eq 1 ]; then
                if [ "$line" = "$END_MARK" ]; then skip=0; fi
                continue
            fi
            printf '%s\n' "$line" >> "$tmp"
        done < "$file"
    fi
    if [ "$replaced" -eq 0 ]; then
        if [ -s "$tmp" ]; then printf '\n' >> "$tmp"; fi
        printf '%s\n' "$block" >> "$tmp"
    fi
    if [ -f "$file" ] && cmp -s "$file" "$tmp"; then
        rm -f "$tmp"
        printf 'unchanged %s\n' "$file"
        return 0
    fi
    if [ -f "$file" ]; then
        local backup="$file.bak.$(date -u +%Y%m%dT%H%M%SZ)"
        if cp "$file" "$backup"; then printf 'backup %s\n' "$backup"; fi
    fi
    mkdir -p "$(dirname "$file")" || { rm -f "$tmp"; return 1; }
    if mv "$tmp" "$file"; then
        printf 'wrote %s\n' "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

remove_block() {
    local file="$1" tmp="$1.tmp.$$"
    local line skip=0 found=0
    [ -f "$file" ] || { printf 'no %s\n' "$file"; return 0; }
    : > "$tmp" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$BEGIN_MARK" ]; then
            found=1
            skip=1
            continue
        fi
        if [ "$skip" -eq 1 ]; then
            if [ "$line" = "$END_MARK" ]; then skip=0; fi
            continue
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$file"
    if [ "$found" -eq 0 ]; then
        rm -f "$tmp"
        printf 'no managed block in %s\n' "$file"
        return 0
    fi
    local backup="$file.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    if cp "$file" "$backup"; then printf 'backup %s\n' "$backup"; fi
    if mv "$tmp" "$file"; then
        printf 'removed managed block from %s\n' "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

check_server() {
    local files="" out="" verdict=0
    for files in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$files" ] || continue
        out="$out$(grep -iE '^[[:space:]]*X11Forwarding[[:space:]]+' "$files" 2>&1)"
    done
    if [ -z "$out" ]; then
        printf 'sshd: X11Forwarding not set explicitly (OpenSSH default is yes)\n'
    else
        printf 'sshd:\n%s\n' "$out"
        if printf '%s' "$out" | grep -qiE 'X11Forwarding[[:space:]]+no'; then
            printf 'GAP: sshd denies X11 forwarding; set X11Forwarding yes and reload sshd\n'
            verdict=1
        fi
    fi
    if [ -n "${SSH_CONNECTION:-}" ]; then
        case "${DISPLAY:-}" in
            '') printf 'session: SSH without DISPLAY (no X11 forwarding on this connection)\n' ;;
            localhost:* | 127.0.0.1:*) printf 'session: SSH with X11 forwarding (DISPLAY=%s)\n' "$DISPLAY" ;;
            *) printf 'session: SSH with server-local DISPLAY=%s (not the client clipboard)\n' "$DISPLAY" ;;
        esac
    else
        printf 'session: not SSH (run --check on the server to inspect sshd)\n'
    fi
    if have xclip; then printf 'backend: xclip present\n'; else printf 'backend: xclip missing (install xclip)\n'; fi
    return "$verdict"
}

self_test() {
    local fail=0 b="" tmp="" first="" second="" out="" n=0
    b="$(block_text myalias 10.100.0.24 alice 1)"
    printf '%s' "$b" | grep -q '^Host myalias 10.100.0.24$' || { printf 'FAIL alias\n'; fail=1; }
    printf '%s' "$b" | grep -q '^    ForwardX11 yes$' || { printf 'FAIL ForwardX11\n'; fail=1; }
    printf '%s' "$b" | grep -q '^    ForwardX11Trusted yes$' || { printf 'FAIL trusted\n'; fail=1; }
    printf '%s' "$b" | grep -q '^    HostName 10.100.0.24$' || { printf 'FAIL hostname\n'; fail=1; }
    b="$(block_text myalias 10.100.0.24 "" 1)"
    printf '%s' "$b" | grep -q '^    User ' && { printf 'FAIL empty user emitted\n'; fail=1; }
    b="$(block_text myalias 10.100.0.24 alice 0)"
    printf '%s' "$b" | grep -q 'ForwardX11Trusted' && { printf 'FAIL untrusted still trusted\n'; fail=1; }

    tmp="$(mktemp)"
    printf 'Host keepme\n    HostName 192.0.2.1\n' > "$tmp"
    write_block "$tmp" "$(block_text myalias 10.100.0.24 alice 1)" >/dev/null
    first="$(cat "$tmp")"
    write_block "$tmp" "$(block_text myalias 10.100.0.24 alice 1)" >/dev/null
    second="$(cat "$tmp")"
    [ "$first" = "$second" ] || { printf 'FAIL not idempotent\n'; fail=1; }
    n="$(printf '%s\n' "$second" | grep -c '^# >>> opencode-deepseek-jev x11 >>>$')"
    [ "$n" -eq 1 ] || { printf 'FAIL begin markers=%s\n' "$n"; fail=1; }
    printf '%s' "$second" | grep -q '^Host keepme$' || { printf 'FAIL clobbered existing host\n'; fail=1; }
    printf '%s' "$second" | grep -q '^Host myalias 10.100.0.24$' || { printf 'FAIL appended block\n'; fail=1; }
    remove_block "$tmp" >/dev/null
    out="$(cat "$tmp")"
    printf '%s' "$out" | grep -q 'ForwardX11' && { printf 'FAIL remove left block\n'; fail=1; }
    printf '%s' "$out" | grep -q '^Host keepme$' || { printf 'FAIL remove clobbered host\n'; fail=1; }
    rm -f "$tmp" "$tmp".bak.*
    if [ "$fail" -eq 0 ]; then
        printf 'ssh-x11-setup: self-test PASS (block shape + idempotent managed region)\n'
    else
        printf 'ssh-x11-setup: self-test FAIL\n'
    fi
    return "$fail"
}

usage() {
    printf 'usage: %s [--print|--check|--write [FILE]|--remove [FILE]|--self-test]\n' "$0"
    printf 'flags: --alias NAME --host HOST --user USER --untrusted\n'
    printf '  --print        emit the managed ~/.ssh/config Host block (safe everywhere)\n'
    printf '  --check        inspect sshd X11 policy + the current SSH/DISPLAY\n'
    printf '  --write FILE   write/refresh the block idempotently (default ~/.ssh/config)\n'
    printf '  --remove FILE  drop the managed block (existing unrelated hosts kept)\n'
}

main() {
    local mode="print" file="" alias="$DEFAULT_ALIAS" host="$DEFAULT_HOST" user="${USER:-}" trusted=1
    local rc=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --print) mode="print"; shift ;;
            --check) mode="check"; shift ;;
            --write)
                mode="write"
                if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
                    file="$2"
                    shift
                else
                    file="$HOME/.ssh/config"
                fi
                shift
                ;;
            --remove)
                mode="remove"
                if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then
                    file="$2"
                    shift
                else
                    file="$HOME/.ssh/config"
                fi
                shift
                ;;
            --alias) alias="${2:-}"; [ $# -ge 2 ] && shift; shift ;;
            --host) host="${2:-}"; [ $# -ge 2 ] && shift; shift ;;
            --user) user="${2:-}"; [ $# -ge 2 ] && shift; shift ;;
            --trusted) trusted=1; shift ;;
            --untrusted) trusted=0; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) usage; return 0 ;;
            "") shift ;;
            *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 2 ;;
        esac
    done

    valid_value "$alias" || { printf 'FAIL: bad alias %s\n' "$alias"; return 2; }
    valid_value "$host" || { printf 'FAIL: bad host %s\n' "$host"; return 2; }
    if [ -n "$user" ]; then
        valid_value "$user" || { printf 'FAIL: bad user %s\n' "$user"; return 2; }
    fi

    case "$mode" in
        print)
            printf '# add to the CLIENT ~/.ssh/config (or run: %s --write)\n' "$0"
            block_text "$alias" "$host" "$user" "$trusted"
            ;;
        check) check_server || rc=$? ;;
        write)
            write_block "$file" "$(block_text "$alias" "$host" "$user" "$trusted")" || rc=2
            printf 'next: ssh %s   (works on the same LAN and across a network change)\n' "$alias"
            ;;
        remove) remove_block "$file" || rc=2 ;;
    esac
    return "$rc"
}

main "$@"
