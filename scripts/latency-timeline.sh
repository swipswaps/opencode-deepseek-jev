#!/usr/bin/env bash
#
# latency-timeline.sh — Gantt-style timeline of what made a session slow.
#
# Method note (github.com/morluto/rea — "reverse engineer anything with
# agents"): observe behavior, inspect with tools, trace, then report findings
# WITH evidence. The target here is our own request pipeline
# (browser -> caddy :4096 -> single-threaded opencode-web -> sqlite), and the
# tools are the caddy access log (per-fetch duration) plus the part table
# (per-step time_created/time_updated). The chart below is the trace.
#
# What it shows for one session over a trailing window:
#   PARTS  one row per part: step-start/finish markers, reasoning/text/tool
#          bars with durations — the agentic loop cadence made visible.
#   FETCH  slow caddy fetches (>1s) on the same axis — whoever else was
#          waiting while this session burned the single thread.
#
#   ./scripts/latency-timeline.sh --session ses_<id> [--window MIN]
#   ./scripts/latency-timeline.sh --session ses_<id> --json
#   ./scripts/latency-timeline.sh --self-test   # offline fixture
#
# Flags: --width N (default 60), --db PATH (readonly), --access-log FILE
# (default: live `docker logs --since`), --min-fetch SEC (default 1).
# Read-only: never writes any database. No model calls.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
set -o pipefail

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

have() { command -v "$1" >/dev/null 2>&1; }

render() {
    # render DB ACCESSLOG SESSION WINDOWMIN WIDTH MINFETCH JSON(0/1)
    python3 - "$1" "$2" "$3" "$4" "$5" "$6" "$7" << 'PYEOF'
import json, sqlite3, sys, time
dbp, alog, sid, winmin, width, minfetch, as_json = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), float(sys.argv[6]), sys.argv[7] == "1"
now = int(time.time() * 1000)
t0 = now - winmin * 60000
con = sqlite3.connect("file:" + dbp + "?mode=ro", uri=True)
parts = []
for pid, ptype, tc, tu, data in con.execute(
        "SELECT substr(id,1,12), json_extract(data,'$.type'), time_created, time_updated, data"
        " FROM part WHERE session_id=? AND time_created>=? ORDER BY time_created DESC LIMIT 40",
        (sid, t0)):
    try:
        d = json.loads(data or "{}")
    except Exception:
        d = {}
    label = ptype or "?"
    st = d.get("state") or {}
    if ptype == "tool":
        label = "tool:" + str(st.get("tool") or d.get("tool") or "?")[:18]
    elif ptype == "text":
        label = "text:" + str(len(json.dumps(d))) + "B"
    parts.append({"id": pid, "type": ptype, "t0": tc, "t1": tu or tc,
                  "ms": (tu or tc) - tc, "label": label})
parts.reverse()
fetches = []
try:
    with open(alog, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            if not str(e.get("logger", "")).startswith("http.log.access"):
                continue
            dur = float(e.get("duration", 0) or 0)
            if dur < minfetch:
                continue
            ts = float(e.get("ts", 0) or 0) * 1000
            if ts < t0:
                continue
            r = e.get("request", {}) or {}
            fetches.append({"ts": int(ts), "dur": dur,
                            "method": r.get("method", "?"),
                            "uri": str(r.get("uri", "?"))[:60],
                            "status": e.get("status", 0)})
except OSError as ex:
    if as_json:
        print(json.dumps({"error": "access log unreadable: " + str(ex)}))
        raise SystemExit
    print("FAIL: access log unreadable: " + str(ex))
    raise SystemExit(1)
# LAT-2: name the tool span a slow fetch was queued behind. A fetch interval
# [ts-duration, ts] overlapping a long (>=1s) tool part in the same session is
# self-inflicted: the single-threaded server was busy running that tool.
tools = [p for p in parts if p["type"] == "tool" and p["ms"] >= 1000]
for f in fetches:
    lo = f["ts"] - f["dur"] * 1000
    hit = None
    for p in tools:
        if p["t0"] <= f["ts"] and p["t1"] >= lo and (hit is None or p["ms"] > hit["ms"]):
            hit = p
    f["attributed_to"] = None if hit is None else {"id": hit["id"], "label": hit["label"], "ms": hit["ms"]}
if as_json:
    print(json.dumps({"session": sid, "window_min": winmin, "parts": parts,
                      "fetches": fetches,
                      "summary": {"n_parts": len(parts), "n_fetches": len(fetches),
                                  "max_part_ms": max([p["ms"] for p in parts] or [0]),
                                  "max_fetch_s": round(max([f["dur"] for f in fetches] or [0]), 1)}}))
    raise SystemExit
span = (max([p["t1"] for p in parts] + [f["ts"] for f in fetches] or [now])
        - min([p["t0"] for p in parts] + [int(f["ts"] - f["dur"] * 1000) for f in fetches] or [t0]))
span = max(span, 1)
t0 = min([p["t0"] for p in parts] + [int(f["ts"] - f["dur"] * 1000) for f in fetches] or [t0])
def bar(a, b):
    lo = int((a - t0) / span * width)
    hi = int((b - t0) / span * width)
    lo, hi = max(0, lo), min(width - 1, hi)
    return " " * lo + "#" * max(1, hi - lo + 1)
print("=== latency-timeline: %s (last %dm, span %.1fs) ===" % (sid, winmin, span / 1000))
print("PARTS (each row: type, duration, offset)")
for p in parts[-25:]:
    print("%-16s %6.1fs +%5.1fs |%s" % (p["label"][:16], p["ms"] / 1000,
                                        (p["t0"] - t0) / 1000, bar(p["t0"], p["t1"])))
if fetches:
    print("FETCHES >%.0fs (same axis — who waited while the loop burned)" % minfetch)
    for f in fetches[-10:]:
        a = int(f["ts"] - f["dur"] * 1000)
        attr = ""
        if f.get("attributed_to"):
            at = f["attributed_to"]
            attr = " <- %s %.1fs (%s)" % (at["label"], at["ms"] / 1000, at["id"])
        print("%-16s %6.1fs +%5.1fs |%s%s" % ((f["method"] + " " + f["uri"])[:16],
                                              f["dur"], (a - t0) / 1000, bar(a, f["ts"]), attr))
else:
    print("FETCHES: none slower than %.0fs in window" % minfetch)
mp = max([p["ms"] for p in parts] or [0]) / 1000
mf = round(max([f["dur"] for f in fetches] or [0]), 1)
print("read: %d parts, slowest step %.1fs; %d slow fetches, slowest %.1fs" % (len(parts), mp, len(fetches), mf))
PYEOF
}

self_test() {
    local fail=0 work=""
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    work=$(mktemp -d)
    python3 - "$work/fix.db" << 'PYEOF'
import sqlite3, sys, time
con = sqlite3.connect(sys.argv[1])
con.execute('CREATE TABLE session(id TEXT PRIMARY KEY)')
con.execute('CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)')
con.execute("INSERT INTO session VALUES('s1')")
now = int(time.time() * 1000)
con.execute("INSERT INTO part VALUES('p-step','m','s1',?,?,?)", (now - 20000, now - 20000, '{"type":"step-start"}'))
con.execute("INSERT INTO part VALUES('p-tool','m','s1',?,?,?)", (now - 19000, now - 9000, '{"type":"tool","state":{"tool":"bash"}}'))
con.execute("INSERT INTO part VALUES('p-text','m','s1',?,?,?)", (now - 8000, now - 8000, '{"type":"text"}'))
con.commit()
PYEOF
    python3 - "$work/acc.log" << 'PYEOF'
import json, sys, time
e = {"logger": "http.log.access.log0", "ts": time.time() - 5, "duration": 7.5,
     "request": {"method": "GET", "uri": "/session/s1/message"}, "status": 200}
open(sys.argv[1], "w").write(json.dumps(e) + "\n" + "not json\n")
PYEOF
    local o=""
    o=$(bash "${BASH_SOURCE[0]}" --session s1 --db "$work/fix.db" --access-log "$work/acc.log" --window 10 2>&1)
    printf '%s' "$o" | grep -q 'tool:bash' || { printf 'FAIL tool row\n'; fail=1; }
    printf '%s' "$o" | grep -q 'FETCHES' || { printf 'FAIL fetch section\n'; fail=1; }
    printf '%s' "$o" | grep -q 'slowest step 10.0s' || { printf 'FAIL summary\n'; fail=1; }
    printf '%s' "$o" | grep -q '<- tool:bash 10.0s' || { printf 'FAIL LAT-2 attribution missing\n'; fail=1; }
    o=$(bash "${BASH_SOURCE[0]}" --session s1 --db "$work/fix.db" --access-log "$work/acc.log" --window 10 --json 2>&1)
    python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["session"]=="s1", "sid"; assert len(d["parts"])==3, "parts"; assert len(d["fetches"])==1, "fetch"; assert d["summary"]["max_part_ms"]==10000, "max"; a=d["fetches"][0]["attributed_to"]; assert a and a["label"]=="tool:bash" and a["ms"]==10000, "attribution"' <<< "$o" \
        || { printf 'FAIL json contract\n'; fail=1; }
    rm -f "$work/fix.db" "$work/acc.log"
    rmdir "$work"
    if [ "$fail" -eq 0 ]; then printf 'latency-timeline: self-test PASS\n'; else printf 'latency-timeline: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    local SESSION="" WIN=30 WIDTH=60 MINFETCH=1 JSON=0 SELFTEST=0
    local DB="$REPO/data/opencode/opencode.db" ALOG=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) SESSION="${2:-}"; shift 2 ;;
            --session=*) SESSION="${1#--session=}"; shift ;;
            --window) WIN="${2:-30}"; shift 2 ;;
            --window=*) WIN="${1#--window=}"; shift ;;
            --width) WIDTH="${2:-60}"; shift 2 ;;
            --min-fetch) MINFETCH="${2:-1}"; shift 2 ;;
            --json) JSON=1; shift ;;
            --self-test) SELFTEST=1; shift ;;
            --db) DB="${2:-}"; shift 2 ;;
            --db=*) DB="${1#--db=}"; shift ;;
            --access-log) ALOG="${2:-}"; shift 2 ;;
            --access-log=*) ALOG="${1#--access-log=}"; shift ;;
            -h | --help)
                printf 'usage: %s --session ID [--window MIN] [--width N] [--min-fetch SEC] [--json] [--db PATH] [--access-log FILE] [--self-test]\n' "$0"
                return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    [ -n "$SESSION" ] || { printf 'usage: %s --session ID ...\n' "$0"; return 2; }
    [ -f "$DB" ] || { printf 'FAIL: no database at %s\n' "$DB"; return 1; }
    case "$WIN$WIDTH" in ''|*[!0-9]*) printf 'window/width must be integers\n'; return 2 ;; esac
    local logtmp=""
    if [ -z "$ALOG" ]; then
        have docker || { printf 'GATE FAIL: docker required (or pass --access-log FILE)\n'; return 1; }
        logtmp=$(mktemp)
        docker logs --since "${WIN}m" opencode-caddy > "$logtmp" 2>&1 || true
        ALOG="$logtmp"
    fi
    render "$DB" "$ALOG" "$SESSION" "$WIN" "$WIDTH" "$MINFETCH" "$JSON"
    local rc=$?
    [ -n "$logtmp" ] && rm -f "$logtmp"
    return "$rc"
}

main "$@"
