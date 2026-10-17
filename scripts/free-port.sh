#!/usr/bin/env bash
#
# free-port.sh — find / test a free TCP port (scripted, never assume a port).
#
# Port conflicts recur (the chat DB alone has 18x "already in use" / 10x "port
# conflict"); deploy.sh already picks a free scratch port inline. This is the
# shared helper so every publisher (grafana-up, deploy, the dashboard) discovers
# a port instead of assuming one. Loopback only (127.0.0.1).
#
#   ./scripts/free-port.sh [START] [TRIES]   # print the first free port >= START (3000, 50)
#   ./scripts/free-port.sh --check PORT      # exit 0 if free, 1 if busy
#   ./scripts/free-port.sh --owner PORT      # best-effort: who holds it
#   ./scripts/free-port.sh --self-test
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null.
#
set -o pipefail

py() { python3 "$@"; }

find_free() {
    py - "$1" "$2" << 'PYEOF'
import socket, sys
start, tries = int(sys.argv[1]), int(sys.argv[2])
for p in range(start, start + tries):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", p)); print(p); sys.exit(0)
    except OSError:
        pass
    finally:
        s.close()
sys.exit(1)
PYEOF
}

check_free() {
    py - "$1" << 'PYEOF'
import socket, sys
p = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.bind(("127.0.0.1", p)); print("free"); sys.exit(0)
except OSError:
    print("busy"); sys.exit(1)
finally:
    s.close()
PYEOF
}

owner() {
    local out=""
    if command -v ss >/dev/null 2>&1; then
        out=$(ss -ltnp "sport = :$1" 2>&1 | tail -n +2 | head -3)
    elif command -v lsof >/dev/null 2>&1; then
        out=$(lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>&1 | head -5)
    else
        printf '(no ss/lsof; cannot name the holder)\n'; return 0
    fi
    printf '%s\n' "$out"
    case "$out" in
        *'users:'*) : ;;
        *) printf '(no PID shown: the holder is likely another user/root — ss needs privilege; try: sudo ss -ltnp %s)\n' "'sport = :$1'" ;;
    esac
}

self_test() {
    local fail=0 p
    p=$(find_free 3000 50)
    case "$p" in ''|*[!0-9]*) printf 'FAIL: no free port found\n'; return 1 ;; esac
    check_free "$p" >/dev/null || { printf 'FAIL: found port %s reported busy\n' "$p"; fail=1; }
    if check_free 1 >/dev/null; then :; else
        # port 1 is almost always busy (or unbound-able); accepted either way
        :
    fi
    printf 'free-port: self-test %s (picked %s)\n' "$([ "$fail" -eq 0 ] && printf PASS || printf FAIL)" "$p"
    return "$fail"
}

main() {
    case "${1:-}" in
        --self-test) self_test; return "$?" ;;
        --check) [ -n "${2:-}" ] || { printf 'usage: %s --check PORT\n' "$0"; return 2; }; check_free "$2"; return "$?" ;;
        --owner) [ -n "${2:-}" ] || { printf 'usage: %s --owner PORT\n' "$0"; return 2; }; owner "$2"; return 0 ;;
        -h | --help) printf 'usage: %s [START] [TRIES] | --check PORT | --owner PORT | --self-test\n' "$0"; return 0 ;;
        "") find_free 3000 50; return "$?" ;;
        *) find_free "${1:-3000}" "${2:-50}"; return "$?" ;;
    esac
}

main "$@"
