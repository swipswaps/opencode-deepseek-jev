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
# The block uses the stable Nebula address (10.100.0.24) so the same alias
# works on the same LAN and on a different network; only the underlying path
# changes, not the command.
#
#   ./scripts/ssh-x11-setup.sh --print            # show the Host block
#   ./scripts/ssh-x11-setup.sh --check            # inspect sshd + this session
#   ./scripts/ssh-x11-setup.sh --write [FILE]     # idempotent; default ~/.ssh/config
#   ./scripts/ssh-x11-setup.sh --self-test        # offline, temp files only
#
# Run --write on the CLIENT (the box you type `ssh` from). --check is useful on
# the server. --print is safe everywhere and is what you paste on a client that
# has no checkout.
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
    # host / alias / user: no whitespace, no shell metacharacters
    case "$1" in
        '' | *[!A-Za-z0-9._:@-]*) return 1 ;;
    esac
    [ "${#1}" -le 253 ]
}

block_text() {
    # block_text ALIAS HOST USER
    printf '%s\n' "$BEGIN_MARK"
    printf 'Host %s\n' "$1"
    printf '    HostName %s\n' "$2"
    if [ -n "$3" ]; then
        printf '    User %s\n' "$3"
    fi
    printf '    ForwardX11 yes\n'
    printf '    ForwardX11Trusted yes\n'
    printf '    ServerAliveInterval 15\n'
    printf '    ServerAliveCountMax 3\n'
    printf '    ConnectTimeout 10\n'
    printf '%s\n' "$END_MARK"
}

# Replace-or-append the managed region. Pure python3 so the edit is byte-exact
# and idempotent: a second run with the same block prints "unchanged".
write_block() {
    local file="$1" block="$2"
    python3 - "$file" "$block" "$BEGIN_MARK" "$END_MARK" <<'PY'
import os, sys, time

path, block, begin, end = sys.argv[1:5]
try:
    with open(path, encoding="utf-8") as fh:
        old = fh.read()
except FileNotFoundError:
    old = ""

out = []
inside = False
replaced = False
for line in old.splitlines(keepends=True):
    if line.strip() == begin:
        inside = True
        if not replaced:
            out.append(block + "\n")
            replaced = True
        continue
    if inside:
        if line.strip() == end:
            inside = False
        continue
    out.append(line)

if not replaced:
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    if out:
        out.append("\n")
    out.append(block + "\n")

new = "".join(out)
if new == old:
    print("unchanged " + path)
    sys.exit(0)

os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
if old:
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    backup = path + ".bak." + stamp
    with open(backup, "w", encoding="utf-8") as fh:
        fh.write(old)
    print("backup " + backup)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(new)
print("wrote " + path)
PY
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
            '' ) printf 'session: SSH without DISPLAY (no X11 forwarding on this connection)\n' ;;
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
    local fail=0 b="" tmp="" first="" second="" out="" n_begin=0 n_end=0
    b="$(block_text myalias 10.100.0.24 alice)"
    printf '%s' "$b" | grep -q '^Host myalias$' || { printf 'FAIL alias\n'; fail=1; }
    printf '%s' "$b" | grep -q '^    ForwardX11 yes$' || { printf 'FAIL ForwardX11\n'; fail=1; }
    printf '%s' "$b" | grep -q '^    ForwardX11Trusted yes$' || { printf 'FAIL trusted\n'; fail=1; }
    printf '%s' "$b" | grep -q '^    HostName 10.100.0.24$' || { printf 'FAIL hostname\n'; fail=1; }
    b="$(block_text nohost 10.100.0.24 "")"
    printf '%s' "$b" | grep -q '^    User ' && { printf 'FAIL empty user emitted\n'; fail=1; }

    tmp="$(mktemp)"
    write_block "$tmp" "$(block_text myalias 10.100.0.24 alice)" >/dev/null
    first="$(cat "$tmp")"
    write_block "$tmp" "$(block_text myalias 10.100.0.24 alice)" >/dev/null
    second="$(cat "$tmp")"
    [ "$first" = "$second" ] || { printf 'FAIL not idempotent\n'; fail=1; }
    n_begin="$(printf '%s\n' "$second" | grep -c '^# >>> opencode-deepseek-jev x11 >>>$')"
    n_end="$(printf '%s\n' "$second" | grep -c '^# <<< opencode-deepseek-jev x11 <<<$')"
    [ "$n_begin" -eq 1 ] || { printf 'FAIL begin markers=%s\n' "$n_begin"; fail=1; }
    [ "$n_end" -eq 1 ] || { printf 'FAIL end markers=%s\n' "$n_end"; fail=1; }

    printf 'Host keepme\n    HostName 192.0.2.1\n' > "$tmp"
    write_block "$tmp" "$(block_text myalias 10.100.0.24 alice)" >/dev/null
    printf 'Host keepme\n    HostName 192.0.2.1\n' > "$tmp"
    write_block "$tmp" "$(block_text myalias 10.100.0.24 alice)" >/dev/null
    out="$(cat "$tmp")"
    printf '%s' "$out" | grep -q '^Host keepme$' || { printf 'FAIL clobbered existing host\n'; fail=1; }
    printf '%s' "$out" | grep -q '^Host myalias$' || { printf 'FAIL appended block\n'; fail=1; }
    rm -f "$tmp"

    if [ "$fail" -eq 0 ]; then
        printf 'ssh-x11-setup: self-test PASS (block shape + idempotent managed region)\n'
    else
        printf 'ssh-x11-setup: self-test FAIL\n'
    fi
    return "$fail"
}

usage() {
    printf 'usage: %s [--print|--check|--write [FILE]|--self-test|--help]\n' "$0"
    printf '  --print        emit the managed ~/.ssh/config Host block (safe everywhere)\n'
    printf '  --check        inspect sshd X11 policy + the current SSH/DISPLAY\n'
    printf '  --write FILE   write/refresh the block idempotently (default ~/.ssh/config)\n'
}

main() {
    local mode="print" file="" alias="$DEFAULT_ALIAS" host="$DEFAULT_HOST" user="${USER:-}" rc=0
    case "${1:-}" in
        --print) mode="print" ;;
        --check) mode="check" ;;
        --write)
            mode="write"
            file="${2:-$HOME/.ssh/config}"
            ;;
        --self-test) self_test; return "$?" ;;
        -h | --help) usage; return 0 ;;
        "") ;;
        *) printf 'unknown arg: %s\n' "$1"; usage >&2; return 2 ;;
    esac

    valid_value "$alias" || { printf 'FAIL: bad alias %s\n' "$alias"; return 2; }
    valid_value "$host" || { printf 'FAIL: bad host %s\n' "$host"; return 2; }
    if [ -n "$user" ]; then
        valid_value "$user" || { printf 'FAIL: bad user %s\n' "$user"; return 2; }
    fi

    case "$mode" in
        print)
            printf '# add to the CLIENT ~/.ssh/config (or run: %s --write)\n' "$0"
            block_text "$alias" "$host" "$user"
            ;;
        check)
            check_server || rc=$?
            ;;
        write)
            check_server || rc=$?
            printf '\n'
            write_block "$file" "$(block_text "$alias" "$host" "$user")"
            printf 'next: ssh %s   (works on the same LAN and across a network change)\n' "$alias"
            ;;
    esac
    return "$rc"
}

main "$@"
