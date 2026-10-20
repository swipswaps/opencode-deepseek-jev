#!/usr/bin/env bash
#
# ssh-audit.sh — SSH banner/algorithm audit for one host (jtesta/ssh-audit).
#
# Answers the negotiation branch of a reset: does the server offer weak
# legacy algorithms, is there a client/server mismatch, is the banner
# something unexpected (middlebox)? Banner grab + algorithm lists only;
# no credentials, no auth attempts, no writes.
#
# If ssh-audit is absent, prints SKIP with the exact install line instead
# of installing software unasked.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   printf only, main() wrapper. Target validated (no option injection).
#
set -o pipefail

usage() { printf 'usage: %s HOST [PORT]\n' "$0"; }

valid_host() {
    case "$1" in
        *[!A-Za-z0-9.:-]*) return 1 ;;
    esac
    [ -n "$1" ] && [ "${#1}" -le 253 ]
}

valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

main() {
    if [ $# -lt 1 ] || [ $# -gt 2 ]; then
        usage >&2
        return 2
    fi
    local host="$1" port="${2:-22}"
    valid_host "$host" || { printf 'FAIL: bad host %s\n' "$host"; return 2; }
    valid_port "$port" || { printf 'FAIL: bad port %s\n' "$port"; return 2; }
    if command -v ssh-audit >/dev/null; then
        ssh-audit -T "$host" -p "$port" 2>&1 | head -n 60
        return 0
    fi
    local probe
    probe=$(python3 -c "import ssh_audit; print('present')" 2>&1) || probe=""
    if [ "$probe" = "present" ]; then
        python3 -m ssh_audit -T "$host" -p "$port" 2>&1 | head -n 60
        return 0
    fi
    printf 'SKIP: ssh-audit not installed; rerun after: pip install ssh-audit\n'
    return 0
}

main "$@"
