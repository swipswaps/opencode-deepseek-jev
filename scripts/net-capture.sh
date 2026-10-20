#!/usr/bin/env bash
#
# net-capture.sh — bounded packet capture for reset forensics (tcpdump + mtr).
#
# Captures `host REMOTE and tcp port PORT` for SECONDS (default 30) with a
# 10 MB rotate cap into logs/, after an mtr --report baseline. Reproduce
# the failure while it runs, then Ctrl+C. Analyze with net-rst.sh.
# Needs CAP_NET_RAW (root): without it, prints SKIP, not PASS.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   printf only, main() wrapper. Fixed filter template only — no
#   user-supplied bpf, no broad captures, captures never leave logs/.
#
set -o pipefail

usage() { printf 'usage: %s HOST [PORT] [SECONDS]\n' "$0"; }

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
    if [ $# -lt 1 ] || [ $# -gt 3 ]; then
        usage >&2
        return 2
    fi
    local host="$1" port="${2:-22}" secs="${3:-30}"
    valid_host "$host" || { printf 'FAIL: bad host %s\n' "$host"; return 2; }
    valid_port "$port" || { printf 'FAIL: bad port %s\n' "$port"; return 2; }
    case "$secs" in
        ''|*[!0-9]*) printf 'FAIL: bad seconds %s\n' "$secs"; return 2 ;;
    esac
    if [ "$secs" -lt 5 ] || [ "$secs" -gt 600 ]; then
        printf 'FAIL: seconds must be 5..600 (got %s)\n' "$secs"
        return 2
    fi
    command -v tcpdump >/dev/null || { printf 'FAIL: tcpdump not installed\n'; return 2; }
    if [ "$(id -u)" -ne 0 ]; then
        printf 'SKIP: capture needs root (CAP_NET_RAW); rerun under sudo\n'
        return 0
    fi
    local repo ts cap
    repo="$(cd "$(dirname "$0")/.." && pwd)"
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$repo/logs"
    cap="$repo/logs/netcap-${host//[^A-Za-z0-9.-]/_}-${port}-${ts}.pcap"
    if command -v mtr >/dev/null; then
        printf '--- mtr baseline (10 cycles) ---\n'
        mtr --report --report-cycles 10 --timeout 30 "$host" 2>&1 | head -n 15 || true
    else
        printf '--- mtr absent; skipping baseline ---\n'
    fi
    printf '--- sar interface snapshot (overload context) ---\n'
    if command -v sar >/dev/null; then
        sar -n DEV 1 3 2>&1 | tail -n 8 || true
    else
        printf 'sar absent\n'
    fi
    printf '--- capturing %ss to %s ---\n' "$secs" "$cap"
    printf 'reproduce the failure now, then Ctrl+C (auto-stops at %ss)\n' "$secs"
    timeout "$secs" tcpdump -i any -nn -s 0 -C 10 -w "$cap" "host $host and tcp port $port" 2>&1
    printf '--- done: %s ---\n' "$cap"
    printf 'next: ./scripts/net-rst.sh %s\n' "$cap"
    return 0
}

main "$@"
