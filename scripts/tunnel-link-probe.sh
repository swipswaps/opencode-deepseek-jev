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
# It also answers "reload or endpoint flip?": per-teardown udpAddr sequence +
# alternation, per-endpoint gaps, DNS samples for the lighthouse name, the
# lighthouse/static_map config lines, systemd reload timers and container
# RestartCount. It re-samples the unit at the end, because NRestarts counts
# ONLY automatic restarts: an explicit `systemctl restart` resets it to 0, so a
# MainPID change during the run is the smoking gun. Verdicts: restart-churn,
# external-restart, dns-flip, endpoint-rotation, tunnel-flap,
# journal-unreadable, overlay-unreachable, no-evidence-in-window. Read-only.
#
#   bash scripts/tunnel-link-probe.sh                 # full probe + evidence file
#   bash scripts/tunnel-link-probe.sh --no-net        # unit/journal only
#   bash scripts/tunnel-link-probe.sh --sudo          # journal/config/who-restarted via `sudo -n`
#   bash scripts/tunnel-link-probe.sh --lighthouse lighthouse-01 --config /etc/nebula/config.yml
#   bash scripts/tunnel-link-probe.sh --container nebula   # container RestartCount/StartedAt
#   bash scripts/tunnel-link-probe.sh --watch 60      # extra birth watch (opt-in)
#   bash scripts/tunnel-link-probe.sh --json          # one JSON object on stdout
#   bash scripts/tunnel-link-probe.sh --out FILE      # explicit evidence path
#   bash scripts/tunnel-link-probe.sh --self-test     # offline fixtures, no network
#
# Env seams (self-test): PROBE_SYSTEMCTL_FILE, PROBE_SYSTEMCTL_FILE2, PROBE_JOURNAL_FILE.
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
SYS_FILE2="${PROBE_SYSTEMCTL_FILE2:-}"
JRN_FILE="${PROBE_JOURNAL_FILE:-}"
LIGHTHOUSE="${PROBE_LIGHTHOUSE:-lighthouse-01}"
CONFIG="${PROBE_NEBULA_CONFIG:-/etc/nebula/config.yml}"
CONTAINER="${PROBE_CONTAINER:-}"
DP_FLIP=0
DP_DISTINCT=0
DP_ADDRS=""
CP_ENDPOINTS=""
RP_TIMERS=0
RP_CONTAINER=""
RP_RESTARTS="?"
RP_STARTED=""

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

read_sysctl2() {
    if [ -n "$SYS_FILE2" ] && [ -f "$SYS_FILE2" ]; then
        cat "$SYS_FILE2"
    else
        read_sysctl
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

dns_probe() {
    local i out addrs first="" seen=""
    DP_FLIP=0
    DP_DISTINCT=0
    DP_ADDRS=""
    if [ -n "$SYS_FILE$JRN_FILE" ]; then
        DP_ADDRS='(fixture)'
        return 0
    fi
    if ! have getent; then
        say "  getent: not available here (host only)"
        return 0
    fi
    say "--- DNS for $LIGHTHOUSE (3 samples, 2s apart; timeout 5s) ---"
    for i in 1 2 3; do
        out=$(limit 5 getent ahosts "$LIGHTHOUSE" 2>&1)
        addrs=$(printf '%s\n' "$out" | awk 'NF > 0 {print $1}' | sort -u | awk 'NR > 1 {printf ","} {printf "%s", $0}')
        say "  sample $i: ${addrs:-<none>}"
        if [ -n "$addrs" ]; then
            [ -z "$first" ] && first="$addrs"
            [ "$addrs" != "$first" ] && DP_FLIP=1
            case ",$seen," in
                *",$addrs,"*) ;;
                *) seen="${seen:+$seen,}$addrs" ;;
            esac
        fi
        [ "$i" -lt 3 ] && sleep 2
    done
    DP_DISTINCT=$(printf '%s\n' "$seen" | tr ',' '\n' | awk 'NF > 0' | sort -u | wc -l)
    DP_ADDRS="${seen:-none}"
    if [ -z "$seen" ]; then
        say "  note: '$LIGHTHOUSE' did not resolve here (run on the peer; DNS may be host-only)"
    elif [ "$DP_DISTINCT" -gt 1 ]; then
        say "  note: $DP_DISTINCT distinct address(es) across samples -> DNS is a candidate for endpoint flips."
    fi
    return 0
}

config_probe() {
    local out
    CP_ENDPOINTS=""
    if [ -n "$SYS_FILE$JRN_FILE" ]; then
        CP_ENDPOINTS='(fixture)'
        return 0
    fi
    say "--- nebula config ($CONFIG): lighthouse/static_map (read-only) ---"
    if [ -r "$CONFIG" ]; then
        out=$(limit 5 cat "$CONFIG")
    elif [ "$SUDO" -eq 1 ] && have sudo; then
        out=$(limit 10 sudo -n cat "$CONFIG" 2>&1)
        printf '%s' "$out" | grep -qE '^(sudo:|cat:)' && out=""
    else
        out=""
    fi
    if [ -z "$out" ]; then
        say "  not readable here (run on the peer, or pass --config FILE; try --sudo)"
        CP_ENDPOINTS="unavailable"
        return 0
    fi
    printf '%s\n' "$out" | grep -nE '^[[:space:]]*(lighthouse|host|static_map|interval|dns|relay|addrs|port):' | head -40 | awk '{print "  " $0}'
    printf '%s\n' "$out" | grep -qE '^[[:space:]]*(lighthouse|host|static_map):' || say '  no lighthouse/static_map/host lines found (different schema?)'
    CP_ENDPOINTS=$(printf '%s\n' "$out" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]+)?' | sort -u | awk 'NR > 1 {printf ","} {printf "%s", $0}')
    [ -n "$CP_ENDPOINTS" ] || CP_ENDPOINTS="none"
    say "  config ip[:port] tokens: $CP_ENDPOINTS"
    say '  note: two advertised lighthouse addresses are normal for a dual-plane mesh; what matters is whether they alternate per teardown.'
    return 0
}

reload_probe() {
    local out rt prop name
    RP_TIMERS=0
    RP_CONTAINER=""
    RP_RESTARTS="?"
    RP_STARTED=""
    if [ -n "$SYS_FILE$JRN_FILE" ]; then
        return 0
    fi
    say '--- reload/restart cadence (read-only) ---'
    if have systemctl; then
        prop=$(limit 10 systemctl show "$UNIT" -p ActiveEnterTimestamp -p ExecMainStartTimestamp -p ExecMainPID -p FragmentPath 2>&1)
        printf '%s\n' "$prop" | awk 'NF > 0 {print "  " $0}'
        say '  note: NRestarts counts AUTOMATIC restarts only; an explicit `systemctl restart` resets it to 0.'
        out=$(limit 10 systemctl list-timers --all --no-pager 2>&1 | head -25)
        RP_TIMERS=$(printf '%s\n' "$out" | grep -c '\.timer')
        printf '%s\n' "$out" | awk 'NF > 0 {print "  timer: " $0}'
    else
        say '  systemctl: not available here'
    fi
    if [ "$SUDO" -eq 1 ] && have sudo; then
        say '  who-restarted probes (sudo -n; read-only):'
        out=$(limit 15 sudo -n journalctl --since "$SINCE" _COMM=sudo --no-pager -n 100 -o short-iso 2>&1 | grep -iE 'nebula|systemctl restart' | tail -10)
        if [ -n "$out" ]; then
            printf '%s\n' "$out" | awk '{print "    sudo> " $0}'
        else
            say '    no sudo-logged nebula/restart command in window'
        fi
        out=$(limit 15 sudo -n journalctl --since "$SINCE" -g 'restart nebula|restart .*nebula' --no-pager -n 50 -o short-iso 2>&1 | grep -viE '^-- |journalctl' | tail -10)
        if [ -n "$out" ]; then
            printf '%s\n' "$out" | awk '{print "    match> " $0}'
        else
            say '    no journal line names a restart command in window'
        fi
        out=$(limit 10 ps -eo pid,ppid,etimes,args --no-headers 2>&1 | grep -E 'restart nebula|sleep (1[0-9][0-9])' | grep -v grep | head -10)
        if [ -n "$out" ]; then
            printf '%s\n' "$out" | awk '{print "    proc> " $0}'
        else
            say '    no visible restart loop process'
        fi
        out=$(limit 10 crontab -l 2>&1 | grep -vE '^[[:space:]]*(#|$)' | head -10)
        [ -n "$out" ] && printf '%s\n' "$out" | awk '{print "    cron(user)> " $0}'
        out=$(limit 10 sudo -n crontab -l 2>&1 | grep -vE '^[[:space:]]*(#|$)' | head -10)
        [ -n "$out" ] && printf '%s\n' "$out" | awk '{print "    cron(root)> " $0}'
    fi
    name="$CONTAINER"
    if [ -z "$name" ]; then
        for rt in podman docker; do
            have "$rt" || continue
            name=$(limit 8 "$rt" ps --format '{{.Names}}' 2>&1 | grep -i nebula | head -1)
            [ -n "$name" ] && { RP_CONTAINER="$rt"; break; }
        done
    else
        for rt in podman docker; do
            have "$rt" && { RP_CONTAINER="$rt"; break; }
        done
    fi
    if [ -n "$name" ] && [ -n "$RP_CONTAINER" ]; then
        out=$(limit 10 "$RP_CONTAINER" inspect -f '{{.RestartCount}}|{{.State.StartedAt}}|{{.State.Status}}' "$name" 2>&1)
        say "  container $name ($RP_CONTAINER): $out"
        RP_RESTARTS=$(printf '%s' "$out" | cut -d'|' -f1)
        RP_STARTED=$(printf '%s' "$out" | cut -d'|' -f2)
    else
        say '  container: none detected (pass --container NAME if nebula is containerised)'
    fi
    return 0
}

cadence_summary() {
    local f="$1"
    python3 - "$f" <<'PY'
import datetime, re, sys
times = []
seq_times = []
labels = {}
legend = []
cur = None
try:
    lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
except OSError:
    lines = []
for ln in lines:
    e = re.search(r'udpAddr="([^"]+)"', ln)
    if e:
        cur = e.group(1)
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
    ep = cur or "?"
    if ep not in labels:
        labels[ep] = "E%d" % (len(labels) + 1)
        legend.append(ep)
    if t:
        times.append(t)
        seq_times.append((labels[ep], t))
    else:
        seq_times.append((labels[ep], None))

def median(vals):
    if not vals:
        return None
    vals = sorted(vals)
    n = len(vals)
    return vals[n // 2] if n % 2 else (vals[n // 2 - 1] + vals[n // 2]) / 2.0

gaps = [(b - a).total_seconds() for a, b in zip(times, times[1:])]
med = median(gaps)
gmin = min(gaps) if gaps else None
gmax = max(gaps) if gaps else None
seq = [lab for lab, _ in seq_times]
diffs = sum(1 for a, b in zip(seq, seq[1:]) if a != b)
alt = int(round(100.0 * diffs / (len(seq) - 1))) if len(seq) > 1 else 0

eps = ", ".join("%s=%s x%d" % (labels[k], k, seq.count(labels[k])) for k in legend) or "none"
perep = []
for k in legend:
    vt = [t for lab, t in seq_times if lab == labels[k] and t is not None]
    ed = [(b - a).total_seconds() for a, b in zip(vt, vt[1:])]
    em = median(ed)
    perep.append("%s med=%s n=%d" % (labels[k], "na" if em is None else ("%.0f" % em), len(vt)))
print("%d|%s|%s|%s|%d|%d|%s|%s|%s" % (
    len(times),
    "na" if med is None else "%.1f" % med,
    "na" if gmin is None else "%.1f" % gmin,
    "na" if gmax is None else "%.1f" % gmax,
    len(legend), alt, eps, " ".join(seq) or "none", "; ".join(perep) or "none"))
PY
}

classify() {
    local nrest="$1" flaps="$2" lifecycle="$3" loss="$4" neps="$5" alt="$6" dnsflip="$7"
    local restarted="$8" jrnerr="$9"
    case "$nrest" in '' | '?') nrest=0 ;; esac
    case "$neps" in '' | '?') neps=0 ;; esac
    case "$alt" in '' | '?') alt=0 ;; esac
    case "$flaps" in '' | '?') flaps=0 ;; esac
    case "$lifecycle" in '' | '?') lifecycle=0 ;; esac
    case "$jrnerr" in '' | '?') jrnerr=0 ;; esac
    if [ "$nrest" != "0" ] || [ "$lifecycle" -gt 0 ]; then
        printf 'restart-churn'
    elif [ "$restarted" = "1" ]; then
        printf 'external-restart'
    elif [ "$dnsflip" = "1" ]; then
        printf 'dns-flip'
    elif [ "$flaps" -gt 0 ] && [ "$neps" -ge 2 ] && [ "$alt" -ge 75 ]; then
        printf 'endpoint-rotation'
    elif [ "$flaps" -gt 0 ]; then
        printf 'tunnel-flap'
    elif [ "$jrnerr" -gt 0 ]; then
        printf 'journal-unreadable'
    elif [ "$loss" = "100" ]; then
        printf 'overlay-unreachable'
    else
        printf 'no-evidence-in-window'
    fi
}

probe() {
    local sys sys2 jrn nrest flaps lifecycle last loss mtu verdict ts host cad jf closes median
    local gmin gmax neps alt eps seq perep dnsflip jrnerr pid1 pid2 aer1 aer2 nrest2 restarted
    local meddisp mindisp maxdisp
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
    jrnerr=$(printf '%s\n' "$jrn" | grep -cE 'You are currently not seeing messages|No journal files were found|Access denied|Failed to (open|seek) journal|not seeing messages from other users')
    if [ "$jrnerr" -gt 0 ]; then
        say '  journal NOT readable/complete (flap counts below are NOT evidence); re-run with --sudo'
    fi
    flaps=$(printf '%s\n' "$jrn" | grep -cE 'Close tunnel received|Taking new handshake|state:dead')
    lifecycle=$(printf '%s\n' "$jrn" | grep -cE "systemd\[[0-9]+\]: *${UNIT%%.*}\.service")
    say "  NRestarts=${nrest:-?}  tunnel-events=$flaps  systemd-lifecycle-lines=$lifecycle"
    jf=$(mktemp) || jf=""
    cad="0|na|na|na|0|0|none|none|none"
    if [ -n "$jf" ]; then
        printf '%s\n' "$jrn" > "$jf"
        cad=$(cadence_summary "$jf")
        rm -f "$jf"
    fi
    IFS='|' read -r closes median gmin gmax neps alt eps seq perep <<< "$cad"
    meddisp="$median"; [ "$meddisp" != "na" ] && meddisp="${meddisp}s"
    mindisp="$gmin"; [ "$mindisp" != "na" ] && mindisp="${mindisp}s"
    maxdisp="$gmax"; [ "$maxdisp" != "na" ] && maxdisp="${maxdisp}s"
    say "  teardowns=${closes:-0}  median_gap=${meddisp:-na}  min/max=${mindisp:-na}-${maxdisp:-na}"
    say "  udp endpoints per teardown: ${eps:-none}"
    say "  endpoint sequence: ${seq:-none}  (adjacent switches ${alt:-0}%)"
    say "  per-endpoint gaps: ${perep:-none}"
    dns_probe
    dnsflip="$DP_FLIP"
    config_probe
    reload_probe
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
        say '  note: parent=systemd is normal for auto- AND explicit restarts; the final PID delta below decides which.'
    fi
    # First unit sample was taken before the journal/DNS/reload/network probes;
    # sample again at the very END so a restart during ANY of them is caught.
    # Explicit `systemctl restart` resets NRestarts to 0, so a PID change here
    # is the only in-band evidence.
    pid1=$(printf '%s\n' "$sys" | awk -F= '/^MainPID=/{print $2; exit}')
    aer1=$(printf '%s\n' "$sys" | awk -F= '/^ActiveEnterTimestamp=/{print $2; exit}')
    sys2=$(read_sysctl2)
    pid2=$(printf '%s\n' "$sys2" | awk -F= '/^MainPID=/{print $2; exit}')
    aer2=$(printf '%s\n' "$sys2" | awk -F= '/^ActiveEnterTimestamp=/{print $2; exit}')
    nrest2=$(printf '%s\n' "$sys2" | awk -F= '/^NRestarts=/{print $2; exit}')
    restarted=0
    { [ -n "$pid1" ] && [ -n "$pid2" ] && [ "$pid1" != "$pid2" ]; } && restarted=1
    [ -n "$aer1" ] && [ -n "$aer2" ] && [ "$aer1" != "$aer2" ] && restarted=1
    if [ "$restarted" -eq 1 ]; then
        say "  RESTART DURING PROBE: MainPID ${pid1:-?} -> ${pid2:-?}; ActiveEnter ${aer1:-?} -> ${aer2:-?}; NRestarts now ${nrest2:-?}"
        say '  note: that is an EXTERNAL (explicit) restart; NRestarts=0 would not show it. Check the caller before blaming the tunnel.'
    fi

    verdict=$(classify "${nrest2:-${nrest:-?}}" "$flaps" "$lifecycle" "$loss" "${neps:-0}" "${alt:-0}" "${dnsflip:-0}" "${restarted:-0}" "${jrnerr:-0}")

    say '--- verdict ---'
    case "$verdict" in
        external-restart)
            say "  EXTERNAL RESTART: MainPID ${pid1:-?} -> ${pid2:-?} during the probe with NRestarts=${nrest2:-${nrest:-?}}."
            say "  Explicit restarts reset NRestarts, so this is a restart loop, not a tunnel/lighthouse reload. Name the caller (sudo/cron/timer output above) and stop it; teardowns follow the restarts." ;;
        journal-unreadable)
            say '  JOURNAL UNREADABLE: counts are NOT evidence. Re-run with --sudo so lifecycle/flap data is real before judging the overlay.' ;;
        endpoint-rotation)
            say "  ENDPOINT ROTATION: ${flaps} tunnel event(s) alternate across ${neps} udp endpoint(s) (${alt}% adjacent switches) with NRestarts=${nrest:-?} and ${RP_TIMERS:-0} reload timer(s)."
            say "  That is the lighthouse endpoint list/round-robin in play, not a systemd reload; fix endpoint selection/keepalive in #5." ;;
        dns-flip)
            say "  DNS FLIP: $LIGHTHOUSE returned different addresses within the sample window (${DP_DISTINCT} distinct)."
            say "  Pin static_map (or fix split-horizon DNS) before blaming the tunnel; see the config block above." ;;
        tunnel-flap)
            say "  TUNNEL FLAP: NRestarts=0 but $flaps teardown/re-handshake event(s); endpoints=${eps:-none}."
            say "  A single stable endpoint keeps this a link/UDP problem (#5), not systemd and not DNS." ;;
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

    JSON_OUT=$(printf '{"ts":"%s","host":"%s","unit":"%s","peer":"%s","lighthouse":"%s","nrestarts":"%s","tunnel_events":%s,"teardowns":%s,"median_gap_s":"%s","systemd_lifecycle":%s,"endpoint_count":%s,"endpoint_alternation_pct":%s,"endpoint_sequence":"%s","per_endpoint_gaps":"%s","dns_distinct":%s,"dns_flip":%s,"config_endpoints":"%s","reload_timers":%s,"container":"%s","container_restarts":"%s","container_started_at":"%s","restarted_during_probe":%s,"nrestarts_after":"%s","mainpid_first":"%s","mainpid_last":"%s","active_enter_first":"%s","active_enter_last":"%s","journal_readable":%s,"overlay_loss_pct":"%s","mtu_ok":"%s","route_mtu":"%s","verdict":"%s"}' \
        "$ts" "$host" "$UNIT" "$PEER" "$LIGHTHOUSE" "${nrest:-?}" "$flaps" "${closes:-0}" "${median:-na}" "$lifecycle" "${neps:-0}" "${alt:-0}" "${seq:-none}" "${perep:-none}" "${DP_DISTINCT:-0}" "${dnsflip:-0}" "${CP_ENDPOINTS:-none}" "${RP_TIMERS:-0}" "${RP_CONTAINER:-none}" "${RP_RESTARTS:-?}" "${RP_STARTED:-}" "${restarted:-0}" "${nrest2:-${nrest:-?}}" "${pid1:-?}" "${pid2:-?}" "${aer1:-}" "${aer2:-}" "$([ "${jrnerr:-0}" -eq 0 ] && printf 1 || printf 0)" "$loss" "$mtu" "${NP_ROUTE_MTU:-?}" "$verdict")
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

    printf '%s\n' 'NRestarts=0' 'MainPID=444' > "$w/sys_rot"
    printf '%s\n' \
        'Oct 20 22:00:00 node nebula[444]: handshake completed udpAddr="192.168.4.45:4242" vpnIp=10.100.0.1' \
        'Oct 20 22:00:01 node nebula[444]: Close tunnel received, tearing down. vpnIp=10.100.0.1' \
        'Oct 20 22:02:10 node nebula[444]: handshake completed udpAddr="100.70.43.78:4242" vpnIp=10.100.0.1' \
        'Oct 20 22:02:11 node nebula[444]: Close tunnel received, tearing down. vpnIp=10.100.0.1' \
        'Oct 20 22:04:20 node nebula[444]: handshake completed udpAddr="192.168.4.45:4242" vpnIp=10.100.0.1' \
        'Oct 20 22:04:21 node nebula[444]: Close tunnel received, tearing down. vpnIp=10.100.0.1' \
        'Oct 20 22:06:30 node nebula[444]: handshake completed udpAddr="100.70.43.78:4242" vpnIp=10.100.0.1' \
        'Oct 20 22:06:31 node nebula[444]: Close tunnel received, tearing down. vpnIp=10.100.0.1' > "$w/jrn_rot"
    out=$(PROBE_SYSTEMCTL_FILE="$w/sys_rot" PROBE_JOURNAL_FILE="$w/jrn_rot" \
        bash "${BASH_SOURCE[0]}" --no-net --json 2>&1)
    printf '%s' "$out" | grep -q '"endpoint_count":2' || { say "FAIL endpoint count: $out"; rc=1; }
    printf '%s' "$out" | grep -q '"endpoint_alternation_pct":100' || { say "FAIL endpoint alternation: $out"; rc=1; }
    printf '%s' "$out" | grep -q '"verdict":"endpoint-rotation"' || { say "FAIL rotation verdict: $out"; rc=1; }

    printf '%s\n' 'NRestarts=0' 'MainPID=555' 'ActiveEnterTimestamp=Wed 2026-10-21 10:36:57 EDT' > "$w/sys_ext1"
    printf '%s\n' 'NRestarts=0' 'MainPID=666' 'ActiveEnterTimestamp=Wed 2026-10-21 10:39:07 EDT' > "$w/sys_ext2"
    printf '%s\n' 'Oct 20 22:10:00 node nebula[555]: handshake completed' > "$w/jrn_ext"
    out=$(PROBE_SYSTEMCTL_FILE="$w/sys_ext1" PROBE_SYSTEMCTL_FILE2="$w/sys_ext2" \
        PROBE_JOURNAL_FILE="$w/jrn_ext" bash "${BASH_SOURCE[0]}" --no-net --json 2>&1)
    printf '%s' "$out" | grep -q '"restarted_during_probe":1' || { say "FAIL restart-delta detect: $out"; rc=1; }
    printf '%s' "$out" | grep -q '"verdict":"external-restart"' || { say "FAIL external-restart verdict: $out"; rc=1; }

    printf '%s\n' 'NRestarts=0' 'MainPID=777' > "$w/sys_unread"
    printf '%s\n' 'Hint: You are currently not seeing messages from other users and the system.' > "$w/jrn_unread"
    out=$(PROBE_SYSTEMCTL_FILE="$w/sys_unread" PROBE_JOURNAL_FILE="$w/jrn_unread" \
        bash "${BASH_SOURCE[0]}" --no-net --json 2>&1)
    printf '%s' "$out" | grep -q '"journal_readable":0' || { say "FAIL journal-readable flag: $out"; rc=1; }
    printf '%s' "$out" | grep -q '"verdict":"journal-unreadable"' || { say "FAIL journal-unreadable verdict: $out"; rc=1; }

    printf '%s\n' 'NRestarts=0' 'MainPID=333' > "$w/sys_clean"
    printf '%s\n' 'Oct 20 21:00:01 node nebula[333]: handshake completed' > "$w/jrn_clean"
    out=$(PROBE_SYSTEMCTL_FILE="$w/sys_clean" PROBE_JOURNAL_FILE="$w/jrn_clean" \
        bash "${BASH_SOURCE[0]}" --no-net --json 2>&1)
    printf '%s' "$out" | grep -q '"verdict":"no-evidence-in-window"' || { say "FAIL clean verdict: $out"; rc=1; }

    rm -f "$w/sys_flap" "$w/jrn_flap" "$w/sys_churn" "$w/jrn_churn" "$w/sys_clean" "$w/jrn_clean" "$w/sys_rot" "$w/jrn_rot" \
        "$w/sys_ext1" "$w/sys_ext2" "$w/jrn_ext" "$w/sys_unread" "$w/jrn_unread"
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
            --systemctl-file2) SYS_FILE2="$2"; shift 2 ;;
            --journal-file) JRN_FILE="$2"; shift 2 ;;
            --lighthouse) LIGHTHOUSE="$2"; shift 2 ;;
            --config) CONFIG="$2"; shift 2 ;;
            --container) CONTAINER="$2"; shift 2 ;;
            --json) JSON=1; shift ;;
            --sudo) SUDO=1; shift ;;
            --no-net) SKIP_NET=1; shift ;;
            --self-test) SELFTEST=1; shift ;;
            -h | --help) printf 'usage: %s [--peer IP] [--port N] [--since SPEC] [--watch SECS] [--lighthouse NAME] [--config FILE] [--container NAME] [--out FILE] [--json] [--sudo] [--no-net] [--systemctl-file F] [--systemctl-file2 F] [--journal-file F] [--self-test]\n' "$0"; return 0 ;;
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
