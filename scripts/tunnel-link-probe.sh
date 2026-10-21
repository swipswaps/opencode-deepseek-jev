#!/usr/bin/env bash
#
# tunnel-link-probe.sh — host-side read-only evidence for TUNNEL-1 LINK (#5).
#
# Why this exists: the hand-off block (`--diagnose` + `--watch 60` + journal
# grep + two pings) looks HUNG because the first step can block on journal
# access and the watch intentionally runs a full minute before the prompt
# returns. This runs the SAME probes with a header before each and a per-step
# timeout, so the terminal shows progress and no step can stall the rest.
#
#   bash scripts/tunnel-link-probe.sh                 # full probe + evidence file
#   bash scripts/tunnel-link-probe.sh --no-net        # unit/journal only
#   bash scripts/tunnel-link-probe.sh --sudo          # journal via `sudo -n` (never prompts)
#   bash scripts/tunnel-link-probe.sh --watch 60      # extra birth watch (opt-in)
#   bash scripts/tunnel-link-probe.sh --json          # one JSON object on stdout
#   bash scripts/tunnel-link-probe.sh --out FILE      # explicit evidence path
#   bash scripts/tunnel-link-probe.sh --self-test     # offline fixtures, no network
#
# Env seams (self-test): PROBE_SYSTEMCTL_FILE, PROBE_JOURNAL_FILE.
# Exit: 0 probe completed (verdict is data), 1 self-test failed, 2 usage.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null. No bare kill.
#
set -o pipefail

UNIT="nebula.service"
PEER="10.100.0.1"
PORT="4242"
SINCE="-15min"
OUT=""
JSON=0
SUDO=0
SKIP_NET=0
WATCH=0
SELFTEST=0
SYS_FILE="${PROBE_SYSTEMCTL_FILE:-}"
JRN_FILE="${PROBE_JOURNAL_FILE:-}"

have() { command -v "$1" >/dev/null 2>&1; }

resolve_repo() {
    local c="$1"
    while [ "$c" != "/" ]; do
        if [ -f "$c/opencode.json" ] && [ -f "$c/docker/Dockerfile" ]; then
            printf '%s' "$c"; return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

limit() {
    local secs="$1"; shift
    if have timeout; then timeout "$secs" "$@"; else "$@"; fi
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

LOG=""
say() {
    printf '%s\n' "$*"
    [ -n "$LOG" ] && printf '%s\n' "$*" >> "$LOG"
    return 0
}
say_err() {
    printf '%s\n' "$*" >&2
    [ -n "$LOG" ] && printf '%s\n' "$*" >> "$LOG"
    return 0
}

read_sysctl() {
    if [ -n "$SYS_FILE" ] && [ -f "$SYS_FILE" ]; then
        cat "$SYS_FILE"
    elif have systemctl; then
        limit 10 systemctl show "$UNIT" -p NRestarts -p MainPID -p ActiveEnterTimestamp \
            -p CPUWeight -p MemoryMax -p StartLimitBurst 2>&1
    else
        printf '%s\n' '(systemctl not available here; host only)'
    fi
}

read_journal() {
    if [ -n "$JRN_FILE" ] && [ -f "$JRN_FILE" ]; then
        cat "$JRN_FILE"
    elif have journalctl; then
        if [ "$SUDO" -eq 1 ]; then
            limit 15 sudo -n journalctl -u "$UNIT" --since "$SINCE" --no-pager -n 400 -o short-iso 2>&1
        else
            limit 15 journalctl -u "$UNIT" --since "$SINCE" --no-pager -n 400 -o short-iso 2>&1
        fi
    else
        printf '%s\n' '(journalctl not available here; host only)'
    fi
}

net_probe() {
    local ipout route pingout loss line s ok=""
    NP_LOSS="?"
    NP_MTU="none"
    if ! have ping; then
        say '  ping: not available here (host only)'
        return 0
    fi
    say '--- overlay address + route ---'
    if have ip; then
        ipout=$(limit 5 ip -brief addr 2>&1)
        printf '%s\n' "$ipout" | grep -E '(^|[[:space:]])10\.100\.' | awk '{print "  " $0}' || say '  no 10.100.x address on this host'
        route=$(limit 5 ip route get "$PEER" 2>&1)
        printf '%s\n' "$route" | awk '{print "  route: " $0}'
    else
        say '  ip: not available here'
    fi
    say "--- overlay ping $PEER (3 x 2s) ---"
    pingout=$(limit 12 ping -c 3 -W 2 "$PEER" 2>&1)
    printf '%s\n' "$pingout" | awk '{print "  " $0}'
    loss=$(printf '%s\n' "$pingout" | awk '/packet loss/{for(i=1;i<=NF;i++) if($i ~ /%/) {gsub(/%/,"",$i); print $i; exit}}')
    # The overlay interface MTU (nebula default 1300) caps the payload: a 1400
    # DF probe fails LOCALLY ("Message too long") and proves nothing about the
    # path. Probe below the route MTU and name that boundary.
    rmtu=$(printf '%s\n' "$route" | awk '{for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); exit}}')
    say "--- MTU probe (DF; route MTU ${rmtu:-unknown}) ---"
    p1=1200
    if [ -n "$rmtu" ] && [ "$rmtu" -gt 1228 ] 2>&1; then p2=$((rmtu - 28)); else p2=1272; fi
    [ "$p2" = "$p1" ] && p2=$((p1 - 1))
    for s in "$p1" "$p2"; do
        if limit 10 ping -M do -s "$s" -c 2 -W 2 "$PEER" >/tmp/tunnel-mtu-$s.out 2>&1; then
            ok="$s"; say "  payload $s: PASS"
        else
            line=$(grep -m1 -E 'Frag needed|Message too long|100% packet loss|Network is unreachable' "/tmp/tunnel-mtu-$s.out" || printf 'no reply')
            say "  payload $s: FAIL ($line)"
        fi
        rm -f "/tmp/tunnel-mtu-$s.out"
    done
    say "  note: 1400/1472 > nebula0 MTU ${rmtu:-1300} fail at sendmsg locally; not path evidence."
    say "--- local UDP listeners :$PORT (peer-side listener is not visible here) ---"
    if have ss; then
        limit 5 ss -lunp 2>&1 | grep ":$PORT" || say "  no local :$PORT listener"
    else
        say '  ss: not available here'
    fi
    NP_LOSS="${loss:-?}"
    NP_MTU="${ok:-none}"
    NP_ROUTE_MTU="${rmtu:-?}"
}

cadence_summary() {
    local f="$1"
    python3 - "$f" <<'PY'
import datetime, re, sys
closes = []
endpoints = {}
try:
    lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
except OSError:
    lines = []
for ln in lines:
    if "Close tunnel received" not in ln:
        continue
    m = re.search(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})", ln)
    t = None
    if m:
        t = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")
    else:
        m = re.search(r"^([A-Z][a-z]{2}) +(\d+) (\d{2}:\d{2}:\d{2})", ln)
        if m:
            t = datetime.datetime.strptime("%s %s %s" % (m.group(1), m.group(2), m.group(3)),
                                           "%b %d %H:%M:%S").replace(year=datetime.date.today().year)
    if t:
        closes.append(t)
    e = re.search(r'udpAddr="([^"]+)"', ln)
    if e:
        endpoints[e.group(1)] = endpoints.get(e.group(1), 0) + 1
closes.sort()
gaps = [(b - a).total_seconds() for a, b in zip(closes, closes[1:])]
if gaps:
    g = sorted(gaps)
    n = len(g)
    med = g[n // 2] if n % 2 else (g[n // 2 - 1] + g[n // 2]) / 2.0
    gap_s = "%d|%.1f|%.1f|%.1f" % (len(closes), med, g[0], g[-1])
else:
    gap_s = "%d|na|na|na" % len(closes)
eps = ", ".join("%s x%d" % (k, v) for k, v in sorted(endpoints.items())) or "none"
print("%s|%s" % (gap_s, eps))
PY
}

classify() {
    local nrest="$1" flaps="$2" lifecycle="$3" loss="$4"
    if [ "${nrest:-?}" != "0" ] && [ "${nrest:-?}" != "?" ]; then
        printf 'restart-churn'
    elif [ "$lifecycle" -gt 0 ]; then
        printf 'restart-churn'
    elif [ "$flaps" -gt 0 ]; then
        printf 'tunnel-flap'
    elif [ "$loss" = "100" ]; then
        printf 'overlay-unreachable'
    else
        printf 'no-evidence-in-window'
    fi
}

probe() {
    local sys jrn nrest flaps lifecycle last loss mtu verdict ts host cad jf closes median
    ts=$(now_utc)
    host=$(hostname 2>&1)
    say "=== tunnel-link-probe @ $ts ==="
    say "host: $host  unit: $UNIT  peer: $PEER  since: $SINCE"

    say '--- unit state (systemctl show; timeout 10s) ---'
    sys=$(read_sysctl)
    printf '%s\n' "$sys" | awk '{print "  " $0}'
    nrest=$(printf '%s\n' "$sys" | awk -F= '/^NRestarts=/{print $2; exit}')

    say '--- journal (timeout 15s; flap count) ---'
    jrn=$(read_journal)
    flaps=$(printf '%s\n' "$jrn" | grep -cE 'Close tunnel received|Taking new handshake|state:dead')
    lifecycle=$(printf '%s\n' "$jrn" | grep -cE "systemd\[[0-9]+\]: *${UNIT%%.*}\.service")
    say "  NRestarts=${nrest:-?}  tunnel-events=$flaps  systemd-lifecycle-lines=$lifecycle"
    jf=$(mktemp) || jf=""
    cad="0|na|na|na|none"
    if [ -n "$jf" ]; then
        printf '%s\n' "$jrn" > "$jf"
        cad=$(cadence_summary "$jf")
        rm -f "$jf"
    fi
    closes=$(printf '%s' "$cad" | cut -d'|' -f1)
    median=$(printf '%s' "$cad" | cut -d'|' -f2)
    say "  teardowns=$closes  median_gap=${median}s  min/max=$(printf '%s' "$cad" | cut -d'|' -f3)-$(printf '%s' "$cad" | cut -d'|' -f4)s"
    say "  udp endpoints: $(printf '%s' "$cad" | cut -d'|' -f5-)"
    last=$(printf '%s\n' "$jrn" | grep -E 'Close tunnel received|Taking new handshake|state:dead' | tail -5)
    if [ -n "$last" ]; then
        say '  last flap lines:'
        printf '%s\n' "$last" | awk '{print "    " $0}'
    fi

    loss="?"
    mtu="none"
    if [ "$SKIP_NET" -eq 1 ]; then
        say '--- network probes skipped (--no-net) ---'
    else
        net_probe
        loss="$NP_LOSS"
        mtu="$NP_MTU"
    fi

    if [ -f "$(dirname "${BASH_SOURCE[0]}")/nebula-restart-trace.py" ]; then
        say '--- process snapshot (read-only; ownership only) ---'
        limit 20 python3 "$(dirname "${BASH_SOURCE[0]}")/nebula-restart-trace.py" 2>&1 | awk '{print "  " $0}'
        say '  note: NRestarts=0 above wins over any "crash-looping" hint in the trace text.'
    fi

    verdict=$(classify "${nrest:-?}" "$flaps" "$lifecycle" "$loss")

    say '--- verdict ---'
    case "$verdict" in
        tunnel-flap)
            say "  TUNNEL FLAP: NRestarts=0 but $flaps teardown/re-handshake event(s). Fix the peer/lighthouse link (#5), not systemd." ;;
        restart-churn)
            say "  RESTART CHURN: NRestarts=${nrest:-?}, $lifecycle systemd lifecycle line(s). Rate-limit/reason the restarts first." ;;
        overlay-unreachable)
            say '  OVERLAY UNREACHABLE: 100% ICMP loss and no flap lines in window. Check nebula membership/routes before the lighthouse.' ;;
        *)
            say '  NO EVIDENCE in this window (no churn, no flap lines, overlay replies). Re-run when T8 trips; keep the window short.' ;;
    esac
    say "  overlay_loss_pct=${loss}  mtu_ok=${mtu}  route_mtu=${NP_ROUTE_MTU:-?}"

    if [ "$WATCH" -gt 0 ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/nebula-restart-trace.py" ]; then
        say "--- birth watch ${WATCH}s (opt-in; read-only) ---"
        limit "$((WATCH + 10))" python3 "$(dirname "${BASH_SOURCE[0]}")/nebula-restart-trace.py" --watch "$WATCH" 2>&1 | awk '{print "  " $0}'
    fi

    JSON_OUT=$(printf '{"ts":"%s","host":"%s","unit":"%s","peer":"%s","nrestarts":"%s","tunnel_events":%s,"teardowns":%s,"median_gap_s":"%s","systemd_lifecycle":%s,"overlay_loss_pct":"%s","mtu_ok":"%s","route_mtu":"%s","verdict":"%s"}' \
        "$ts" "$host" "$UNIT" "$PEER" "${nrest:-?}" "$flaps" "${closes:-0}" "${median:-na}" "$lifecycle" "$loss" "$mtu" "${NP_ROUTE_MTU:-?}" "$verdict")
    return 0
}

self_test() {
    local w rc=0 out
    w=$(mktemp -d) || { say 'FAIL: mktemp'; return 1; }

    printf '%s\n' 'NRestarts=0' 'MainPID=1111684' 'ActiveEnterTimestamp=Sun 2026-10-18 09:00:00 UTC' > "$w/sys_flap"
    printf '%s\n' \
        'Oct 20 21:00:01 node nebula[1111684]: Close tunnel received, tearing down.' \
        'Oct 20 21:00:02 node nebula[1111684]: Taking new handshake' \
        'Oct 20 21:00:03 node nebula[1111684]: tunnelCheck state:dead' \
        'Oct 20 21:05:01 node nebula[1111684]: Close tunnel received, tearing down.' \
        'Oct 20 21:05:02 node nebula[1111684]: Taking new handshake' > "$w/jrn_flap"
    out=$(PROBE_SYSTEMCTL_FILE="$w/sys_flap" PROBE_JOURNAL_FILE="$w/jrn_flap" \
        bash "${BASH_SOURCE[0]}" --no-net --json 2>&1)
    printf '%s' "$out" | grep -q '"tunnel_events":5' || { say "FAIL flap count: $out"; rc=1; }
    printf '%s' "$out" | grep -q '"teardowns":2' || { say "FAIL teardown count: $out"; rc=1; }
    printf '%s' "$out" | grep -q '"median_gap_s":"300.0"' || { say "FAIL cadence median: $out"; rc=1; }
    printf '%s' "$out" | grep -q '"verdict":"tunnel-flap"' || { say "FAIL flap verdict: $out"; rc=1; }

    printf '%s\n' 'NRestarts=3' 'MainPID=222' > "$w/sys_churn"
    printf '%s\n' \
        'Oct 20 21:00:01 node systemd[1]: nebula.service: Scheduled restart job, restart counter is at 3.' \
        'Oct 20 21:00:02 node systemd[1]: nebula.service: Main process exited, code=exited, status=1/FAILURE' > "$w/jrn_churn"
    out=$(PROBE_SYSTEMCTL_FILE="$w/sys_churn" PROBE_JOURNAL_FILE="$w/jrn_churn" \
        bash "${BASH_SOURCE[0]}" --no-net --json 2>&1)
    printf '%s' "$out" | grep -q '"verdict":"restart-churn"' || { say "FAIL churn verdict: $out"; rc=1; }

    printf '%s\n' 'NRestarts=0' 'MainPID=333' > "$w/sys_clean"
    printf '%s\n' 'Oct 20 21:00:01 node nebula[333]: handshake completed' > "$w/jrn_clean"
    out=$(PROBE_SYSTEMCTL_FILE="$w/sys_clean" PROBE_JOURNAL_FILE="$w/jrn_clean" \
        bash "${BASH_SOURCE[0]}" --no-net --json 2>&1)
    printf '%s' "$out" | grep -q '"verdict":"no-evidence-in-window"' || { say "FAIL clean verdict: $out"; rc=1; }

    rm -f "$w/sys_flap" "$w/jrn_flap" "$w/sys_churn" "$w/jrn_churn" "$w/sys_clean" "$w/jrn_clean"
    rmdir "$w" || say "note: temp dir not empty: $w"
    [ "$rc" -eq 0 ] && say 'tunnel-link-probe: self-test PASS'
    return "$rc"
}

main() {
    local repo
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --peer) PEER="$2"; shift 2 ;;
            --port) PORT="$2"; shift 2 ;;
            --since) SINCE="$2"; shift 2 ;;
            --out) OUT="$2"; shift 2 ;;
            --watch) WATCH="$2"; shift 2 ;;
            --systemctl-file) SYS_FILE="$2"; shift 2 ;;
            --journal-file) JRN_FILE="$2"; shift 2 ;;
            --json) JSON=1; shift ;;
            --sudo) SUDO=1; shift ;;
            --no-net) SKIP_NET=1; shift ;;
            --self-test) SELFTEST=1; shift ;;
            -h | --help) printf 'usage: %s [--peer IP] [--port N] [--since SPEC] [--watch SECS] [--out FILE] [--json] [--sudo] [--no-net] [--systemctl-file F] [--journal-file F] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi

    repo=$(resolve_repo "$(dirname "${BASH_SOURCE[0]}")") || repo=$(resolve_repo "$PWD") || repo="$PWD"
    if [ -z "$OUT" ] && [ "$JSON" -eq 0 ]; then
        OUT="$repo/logs/tunnel-link-$(date -u +%Y%m%dT%H%M%SZ).log"
    fi
    if [ -n "$OUT" ]; then
        mkdir -p "$(dirname "$OUT")" || { printf 'FAIL: cannot create %s\n' "$(dirname "$OUT")"; return 2; }
        : > "$OUT" || { printf 'FAIL: cannot write %s\n' "$OUT"; return 2; }
        LOG="$OUT"
    fi

    if [ "$JSON" -eq 1 ]; then
        probe >/dev/null
        printf '%s\n' "$JSON_OUT"
    else
        probe
        say ''
        say "evidence: $OUT"
        say 'Next: paste the verdict + last flap lines into swipswaps/proxmox-dual-plane-mesh#5.'
    fi
    return 0
}

main "$@"
