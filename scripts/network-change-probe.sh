#!/usr/bin/env bash
#
# network-change-probe.sh - prove the access plane survives a network change.
#
# Two questions after roaming (Wi-Fi -> hotspot -> different LAN, tunnel flap):
#   1. does caddy still answer :4096/:5099 on EVERY interface that is up
#      (loopback, Nebula 10.x, Tailscale 100.x, default LAN)?
#   2. does the TLS server cert cover those addresses (SANs), and are the
#      published ports roam-safe (wildcard, not pinned to a vanished IP)?
#
# This is the post-roam acceptance test. Network-change testing workflow:
#   terminal A (server):  ./scripts/network-change-probe.sh --watch
#   terminal B (server):  switch Wi-Fi / unplug / re-join a different LAN
#   -> A prints the IP delta and re-runs the matrix automatically.
#
#   ./scripts/network-change-probe.sh              # one-shot matrix + report
#   ./scripts/network-change-probe.sh --json       # machine contract
#   ./scripts/network-change-probe.sh --watch      # detect changes, re-probe
#   ./scripts/network-change-probe.sh --recover    # run the watchdog on FAIL
#   ./scripts/network-change-probe.sh --self-test  # offline, no docker/net
#
# Flags: --no-docker, --no-certs, --json, --watch, --recover, --self-test.
# Seams: NETPROBE_FAKE_IPS, NETPROBE_FAKE_4096, NETPROBE_FAKE_5099,
# NETPROBE_WATCH_SEC.
#
# Exit: 0 every present interface passes and certs cover them; 1 any gap;
# 2 cannot run (no ip/curl). Report: logs/network-change-<utc>.log.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
# References:
#   https://www.rfc-editor.org/rfc/rfc7235#section-4.1 (401 challenge = alive)
#   ip-address(8); nginx/caddy wildcard-bind behavior is in docker-compose.yml
#
set -uo pipefail

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"
            return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

have() { command -v "$1" >/dev/null; }

# ---- pure logic (unit-tested) --------------------------------------------

classify_4096() {
    case "$1" in
        200 | 401) printf 'PASS' ;;
        *) printf 'FAIL' ;;
    esac
}

classify_5099() {
    case "$1" in
        200) printf 'PASS' ;;
        *) printf 'FAIL' ;;
    esac
}

parse_ipset() {
    # parse_ipset < "ip -brief -4 addr" lines -> one address per line
    awk '{for (i=3; i<=NF; i++) {split($i,a,"/"); if (a[1] ~ /^[0-9]+\./) print a[1]}}' | sort -u
}

classify_bindings() {
    # classify_bindings JSON -> wildcard | pinned:<ips> | unknown
    printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown"); sys.exit(0)
ips = sorted({(b.get("HostIp") or "0.0.0.0") for v in (d or {}).values() for b in (v or [])})
if not ips or ips == ["0.0.0.0"]:
    print("wildcard")
else:
    print("pinned:" + ",".join(ips))
' 2>&1
}

# ---- environment ----------------------------------------------------------

default_if() { ip route show default 2>&1 | awk '{print $5; exit}'; }

present_ips() {
    if [ -n "${NETPROBE_FAKE_IPS:-}" ]; then
        printf '%s\n' "$NETPROBE_FAKE_IPS" | tr ' ' '\n' | sort -u
        return 0
    fi
    have ip || { printf '127.0.0.1\n'; return 0; }
    local dif=""
    dif="$(default_if)"
    { ip -brief -4 addr show nebula0 2>&1
      ip -brief -4 addr show tailscale0 2>&1
      if [ -n "$dif" ]; then ip -brief -4 addr show "$dif" 2>&1; fi
      printf 'lo UNKNOWN 127.0.0.1/8\n'
    } | parse_ipset
}

probe_code() {
    local url="$1" port="$2"
    if [ "$port" = "4096" ] && [ -n "${NETPROBE_FAKE_4096:-}" ]; then printf '%s' "$NETPROBE_FAKE_4096"; return 0; fi
    if [ "$port" = "5099" ] && [ -n "${NETPROBE_FAKE_5099:-}" ]; then printf '%s' "$NETPROBE_FAKE_5099"; return 0; fi
    curl -sk -m 8 -o /dev/null -w '%{http_code}' "$url" 2>&1
}

bind_state() {
    local bj=""
    if [ "$NODOCKER" -eq 1 ] || ! have docker; then printf 'skip'; return 0; fi
    bj="$(docker inspect opencode-caddy --format '{{json .HostConfig.PortBindings}}' 2>&1)"
    classify_bindings "$bj"
}

certs_state() {
    if [ "$NOCERTS" -eq 1 ]; then printf 'skip'; return 0; fi
    if [ ! -x "$REPO/docker/certs-init.sh" ]; then printf 'skip'; return 0; fi
    local out=""
    out="$(bash "$REPO/docker/certs-init.sh" --check 2>&1)"
    case "$out" in
        COVERED:*) printf 'covered: %s' "${out#COVERED: }" ;;
        GAPS:*) printf 'gaps: %s' "${out#GAPS: }" ;;
        *) printf 'unknown: %s' "$out" ;;
    esac
}

run_probe() {
    # run_probe -> prints the matrix, sets FAILS, returns 0/1.
    local ips ip c4 c5 v4 v5 certs bind line
    FAILS=0
    certs="$(certs_state)"
    bind="$(bind_state)"
    case "$certs" in covered:*) ;; skip) ;; *) FAILS=$((FAILS + 1)) ;; esac
    case "$bind" in wildcard | skip) ;; *) FAILS=$((FAILS + 1)) ;; esac
    ips="$(present_ips)"
    [ -z "$ips" ] && { [ "$JSON" -eq 1 ] || printf 'FAIL: no addresses detected\n'; return 1; }
    if [ "$JSON" -eq 0 ]; then
        printf '=== network-change-probe @ %s ===\n' "$ROAM_TS"
        printf 'certs: %s\n' "$certs"
        printf 'host ports: %s\n' "$bind"
        printf '%-16s %-10s %-4s %-10s %-4s\n' INTERFACE :4096 CODE :5099 CODE
    fi
    : > "$TSV"
    for ip in $ips; do
        c4="$(probe_code "https://$ip:4096/api/health" 4096)"
        c5="$(probe_code "https://$ip:5099/api/health" 5099)"
        v4="$(classify_4096 "$c4")"
        v5="$(classify_5099 "$c5")"
        [ "$v4" = PASS ] || FAILS=$((FAILS + 1))
        [ "$v5" = PASS ] || FAILS=$((FAILS + 1))
        [ "$JSON" -eq 1 ] || printf '%-16s %-10s %-4s %-10s %-4s\n' "$ip" "$c4" "$v4" "$c5" "$v5"
        printf '%s\t%s\t%s\t%s\t%s\n' "$ip" "$c4" "$v4" "$c5" "$v5" >> "$TSV"
    done
    if [ "$FAILS" -eq 0 ]; then
        [ "$JSON" -eq 1 ] || printf 'VERDICT: PASS (every present interface reachable; roam-safe)\n'
        return 0
    fi
    [ "$JSON" -eq 1 ] || printf 'VERDICT: FAIL (%s gap(s)); remediation: ./scripts/web-health.sh --quiet\n' "$FAILS"
    return 1
}

emit_json() {
    python3 - "$ROAM_TS" "$TSV" <<'PY'
import json, sys
ts, path = sys.argv[1], sys.argv[2]
rows = []
for line in open(path, encoding='utf-8', errors='replace'):
    p = line.rstrip('\n').split('\t')
    if len(p) != 5:
        continue
    ip, c4, v4, c5, v5 = p
    rows.append({'ip': ip, 'code_4096': c4, 'v4096': v4, 'code_5099': c5, 'v5099': v5})
print(json.dumps({'ts': ts, 'passed': all(r['v4096'] == 'PASS' and r['v5099'] == 'PASS' for r in rows), 'results': rows}))
PY
}

watch_mode() {
    local sec prev cur
    sec="${NETPROBE_WATCH_SEC:-10}"
    case "$sec" in '' | *[!0-9]*) sec=10 ;; esac
    prev="$(present_ips | tr '\n' ' ')"
    printf 'watching for network changes every %ss; baseline: %s\n' "$sec" "$prev"
    printf 'change Wi-Fi/LAN now (Ctrl-C to stop)\n'
    while :; do
        sleep "$sec"
        cur="$(present_ips | tr '\n' ' ')"
        if [ "$cur" != "$prev" ]; then
            printf '\n[%s] interface change: %s -> %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$prev" "$cur"
            prev="$cur"
            run_probe
        fi
    done
}

usage() {
    printf 'usage: %s [--json|--watch|--recover|--no-docker|--no-certs|--self-test|--help]\n' "$0"
}

self_test() {
    local fail=0 t=""
    [ "$(classify_4096 401)" = PASS ] || { printf 'FAIL classify 401\n'; fail=1; }
    [ "$(classify_4096 000)" = FAIL ] || { printf 'FAIL classify 000\n'; fail=1; }
    [ "$(classify_5099 200)" = PASS ] || { printf 'FAIL classify 5099 200\n'; fail=1; }
    [ "$(classify_5099 502)" = FAIL ] || { printf 'FAIL classify 5099 502\n'; fail=1; }
    t="$(printf 'nebula0 UP 10.100.0.24/24\nwlP2p0 UP 192.168.4.24/24\n' | parse_ipset | tr '\n' ' ')"
    [ "$t" = "10.100.0.24 192.168.4.24 " ] || { printf 'FAIL parse_ipset got=%s\n' "$t"; fail=1; }
    [ "$(classify_bindings '{"4096/tcp":[{"HostIp":"","HostPort":"4096"}]}')" = wildcard ] \
        || { printf 'FAIL bindings wildcard\n'; fail=1; }
    case "$(classify_bindings '{"4096/tcp":[{"HostIp":"10.1.2.3","HostPort":"4096"}]}')" in
        pinned:*) ;;
        *) printf 'FAIL bindings pinned\n'; fail=1 ;;
    esac

    local o="" rc=0
    o=$(NETPROBE_NO_REPORT=1 NETPROBE_FAKE_IPS="127.0.0.1 10.100.0.24" NETPROBE_FAKE_4096=401 NETPROBE_FAKE_5099=200 \
        bash "${BASH_SOURCE[0]}" --json --no-docker --no-certs 2>&1); rc=$?
    [ "$rc" -eq 0 ] || { printf 'FAIL offline matrix rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q '"passed": true' || { printf 'FAIL offline json pass\n'; fail=1; }
    o=$(NETPROBE_NO_REPORT=1 NETPROBE_FAKE_IPS="127.0.0.1" NETPROBE_FAKE_4096=000 NETPROBE_FAKE_5099=000 \
        bash "${BASH_SOURCE[0]}" --json --no-docker --no-certs 2>&1); rc=$?
    [ "$rc" -eq 1 ] || { printf 'FAIL offline matrix fail rc=%s\n' "$rc"; fail=1; }
    printf '%s' "$o" | grep -q '"passed": false' || { printf 'FAIL offline json fail\n'; fail=1; }

    if [ "$fail" -eq 0 ]; then printf 'network-change-probe: self-test PASS (matrix + certs/bind seams)\n'; else printf 'network-change-probe: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then printf 'GATE FAIL: cannot resolve repo root\n'; return 2; fi
    JSON=0 NODOCKER=0 NOCERTS=0 RECOVER=0 WATCH=0 SELFTEST=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) JSON=1; shift ;;
            --no-docker) NODOCKER=1; shift ;;
            --no-certs) NOCERTS=1; shift ;;
            --recover) RECOVER=1; shift ;;
            --watch) WATCH=1; shift ;;
            --self-test) SELFTEST=1; shift ;;
            -h | --help) usage; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    if ! have curl; then printf 'GATE FAIL: curl required\n'; return 2; fi
    ROAM_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$REPO/logs" 2>&1 || true
    TSV="$(mktemp)"
    REPORT="$REPO/logs/network-change-$ROAM_TS.log"

    if [ "$WATCH" -eq 1 ]; then
        watch_mode | tee "$REPORT"
        rm -f "$TSV"
        return 0
    fi

    local out="" rc=0
    out="$(run_probe)"; rc=$?
    if [ "$JSON" -eq 0 ]; then
        printf '%s\n' "$out"
    fi
    if [ "${NETPROBE_NO_REPORT:-0}" != "1" ]; then
        printf '%s\n' "$out" > "$REPORT"
        [ "$JSON" -eq 1 ] || printf 'report: %s\n' "$REPORT"
    fi
    if [ "$JSON" -eq 1 ]; then emit_json; fi
    if [ "$rc" -ne 0 ] && [ "$RECOVER" -eq 1 ]; then
        printf 'recovering via web-health.sh ...\n'
        bash "$REPO/scripts/web-health.sh" --quiet
        out="$(run_probe)"; rc=$?
        printf '%s\n' "$out"
        if [ "$JSON" -eq 1 ]; then emit_json; fi
    fi
    rm -f "$TSV"
    return "$rc"
}

main "$@"
