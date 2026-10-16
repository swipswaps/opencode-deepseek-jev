#!/usr/bin/env bash
#
# host-path-probe.sh — break down the :5099/:4096 hop to localize "long delays".
#
# The "loading forever" complaint is rarely the app. This measures the phases a
# request pays (dns -> connect -> tls -> ttfb -> total) against the host URL and
# the loopback, repeatedly, and names the dominant phase. Run ON THE HOST.
#
#   ./scripts/host-path-probe.sh [--url URL] [--n N]
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

probe() {
    # probe URL -> "dns conn tls ttfb total"
    curl -sk -o /dev/null --max-time 30 \
        -w '%{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}' \
        "$1"
}

main() {
    local URL="https://127.0.0.1:5099/" N=5
    while [ $# -gt 0 ]; do
        case "$1" in
            --url) URL="${2:-}"; shift 2 ;;
            --n) N="${2:-5}"; shift 2 ;;
            -h | --help) printf 'usage: %s [--url URL] [--n N]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    have curl || { printf 'GATE FAIL: curl required\n'; return 2; }
    printf '=== host-path-probe: %s (n=%s) ===\n' "$URL" "$N"
    local i line dns conn tls ttfb total
    local sumtls=0 sumttfb=0 sumtotal=0 sumconn=0
    for i in $(seq 1 "$N"); do
        line=$(probe "$URL")
        set -- $line
        dns=$1; conn=$2; tls=$3; ttfb=$4; total=$5
        printf '  dns=%s conn=%s tls=%s ttfb=%s total=%s\n' "$dns" "$conn" "$tls" "$ttfb" "$total"
        sumconn=$(python3 -c "print($sumconn + $conn)")
        sumtls=$(python3 -c "print($sumtls + $tls)")
        sumttfb=$(python3 -c "print($sumttfb + $ttfb)")
        sumtotal=$(python3 -c "print($sumtotal + $total)")
    done
    python3 - "$N" "$sumconn" "$sumtls" "$sumttfb" "$sumtotal" << 'PYEOF'
import sys
n, conn, tls, ttfb, total = (float(x) for x in sys.argv[1:6])
conn /= n; tls /= n; ttfb /= n; total /= n
print("--- averages (s) ---")
print("  connect %.3f  tls %.3f  ttfb %.3f  total %.3f" % (conn, tls, ttfb, total))
# ttfb includes connect+tls; tls overhead = tls - conn; server think = ttfb - tls
tls_overhead = max(0.0, tls - conn)
server = max(0.0, ttfb - tls)
print("--- verdict ---")
if tls_overhead >= 0.08 and tls_overhead >= server and tls_overhead >= conn:
    print("  TLS-DOMINATED (tls overhead %.2fs of %.2fs total): caddy handshake cost. Check CPU"
          " contention on the caddy container/host, enable HTTP/2 keep-alive, and do not pay a new"
          " TLS handshake per request." % (tls_overhead, total))
elif server >= 0.3 and server >= tls_overhead:
    print("  SERVER-DOMINATED (ttfb-after-tls %.2fs of %.2fs): the upstream took the time - check the"
          " single-threaded opencode-web container and its slow endpoints (web-logs.sh, sentinel T4)." % (server, total))
elif total < 0.08:
    print("  FAST (%.2fs): the hop is not the bottleneck; look at app load / payloads." % total)
else:
    print("  MODERATE (total %.2fs; tls %.2f, server %.2f, connect %.2f): no single dominant phase."
          % (total, tls_overhead, server, conn))
PYEOF
    printf '\ncompare container-direct (on the host or in the container):\n'
    printf "  curl -s -o /dev/null -w '%%{time_total}\\n' http://127.0.0.1:5099/   # expect 0.01-0.03s\n"
}

main "$@"
