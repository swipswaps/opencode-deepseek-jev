#!/usr/bin/env bash
#
# recovery-status.sh - one screen answering: what is broken, what still works,
# what the system is doing about it, and what to do next.
#
# Read-only. It merges the durable signals the recovery tools already write:
#   - data/observability/last-gate.json   (gate pass/fail)
#   - data/observability/pulse.json       (narrative health)
#   - data/observability/observability.db (ADVISORY/FAIL ledger)
#   - $HOME/.local/state/hotspot-reconnect.state (+ inhibit/silence files)
#
#   ./scripts/recovery-status.sh              # human
#   ./scripts/recovery-status.sh --json       # machine
#   ./scripts/recovery-status.sh --write      # cache for the dashboard /api/recovery
#   ./scripts/recovery-status.sh --self-test  # offline fixture
#
# "unknown" is a first-class state: missing/stale evidence never renders healthy.
# Exit 0 healthy, 2 degraded, 3 cannot run.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No top-level exit. No 2>/dev/null.
#
set -uo pipefail

if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
else
    SELF_DIR="$PWD"
fi

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

REPO=$(resolve_repo "$SELF_DIR")
[ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
[ -z "$REPO" ] && REPO=""

MODE="human"
OUT=""
build() {
    local root="$1"
    python3 - "$root" "${HOME:-/root}" << 'PYEOF'
import json, os, sqlite3, sys, time

root, home = sys.argv[1], sys.argv[2]
obs = os.path.join(root, "data", "observability")

def read_json(name):
    try:
        with open(os.path.join(obs, name), encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None

def parse_state(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if "=" in line:
                    k, v = line.split("=", 1)
                    out[k] = v
    except Exception:
        return None
    return out

def active_until(path):
    try:
        with open(path, encoding="utf-8") as fh:
            v = fh.read().strip()
        n = int(v)
        return n if n > int(time.time()) else None
    except Exception:
        return None

gate = read_json("last-gate.json") or {}
pulse = read_json("pulse.json") or {}

state_path = os.environ.get("HOTSPOT_STATE") or os.path.join(home, ".local", "state", "hotspot-reconnect.state")
if not os.path.isfile(state_path):
    alt = os.path.join(obs, "hotspot-reconnect.state")
    if os.path.isfile(alt):
        state_path = alt
hot = parse_state(state_path)
inhibit = active_until(os.environ.get("HOTSPOT_INHIBIT") or os.path.join(home, ".local", "state", "hotspot-inhibit.until"))
quiet = active_until(os.environ.get("HOTSPOT_QUIET_UNTIL") or os.path.join(home, ".local", "state", "hotspot-quiet.until"))

subs = []
actions = []

# Gate / sentinel
if gate:
    failed = int(gate.get("failed") or 0)
    passed = int(gate.get("passed") or 0)
    st = "fail" if failed > 0 else "pass"
    subs.append({"name": "gate", "state": st,
                 "detail": "%s pass / %s fail @ %s" % (passed, failed, gate.get("ts", "?"))})
    if failed > 0:
        actions.append("./scripts/harness.sh   # re-run the gate and fix the failing check")
else:
    subs.append({"name": "gate", "state": "unknown", "detail": "no last-gate.json"})

# Pulse narrative
if pulse:
    hv = (pulse.get("headline") or "").strip()
    subs.append({"name": "pulse", "state": "attention" if hv.lower().startswith("attention") else "ok",
                 "detail": hv or "no headline"})
else:
    subs.append({"name": "pulse", "state": "unknown", "detail": "no pulse.json (run ./scripts/pulse.py)"})

# Hotspot overlay
if hot is None:
    subs.append({"name": "overlay", "state": "unknown", "detail": "no hotspot state (not this host / watcher idle)"})
else:
    prev = (hot.get("PREV") or "").strip()
    fails = hot.get("FAILS", "?")
    st = {"up": "ok", "off-network": "expected", "overlay-down": "fail",
          "hotspot-lost": "fail", "down": "fail"}.get(prev, "unknown")
    subs.append({"name": "overlay", "state": st,
                 "detail": "%s (misses=%s)" % (prev or "unknown", fails)})
    if st == "fail":
        actions.append("./scripts/hotspot-reconnect.sh --fix   # guided reconnect (preview first)")

# Shared inhibition / silence
if inhibit or quiet:
    until = max([x for x in (inhibit, quiet) if x])
    subs.append({"name": "alerts", "state": "silenced",
                 "detail": "suppressed until %s (%s)" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(until)),
                                                          "inhibit" if inhibit else "quiet")})
    actions.append("./scripts/hotspot-reconnect.sh --clear-inhibit   # re-enable overlay alerts")
else:
    subs.append({"name": "alerts", "state": "ok", "detail": "not suppressed"})

# Ledger advisories
fail_n = 0
last_ts = ""
db = os.path.join(obs, "observability.db")
if os.path.isfile(db):
    try:
        cutoff = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 86400))
        con = sqlite3.connect("file:" + db + "?mode=ro", uri=True)
        row = con.execute("SELECT COUNT(*), MAX(ts) FROM ledger WHERE type='ADVISORY' AND verdict='FAIL' AND ts >= ?", (cutoff,)).fetchone()
        fail_n = int(row[0] or 0)
        last_ts = row[1] or ""
    except Exception:
        pass
subs.append({"name": "ledger", "state": "attention" if fail_n > 0 else "ok",
             "detail": "%s FAIL advisory row(s) in 24h%s" % (fail_n, (", latest " + str(last_ts)) if last_ts else "")})

# Cache-hit SLO: DeepSeek prefix caching is the biggest cost lever. The ratio is
# cache_read / (cache_read + input) over recent sessions; below the SLO means the
# prompt prefix is churning (unstable tools/state/compaction) and cost is rising.
def find_ocdb(root_dir, home_dir):
    for p in (os.environ.get("OPENCODE_DB"),
              os.path.join(root_dir, "data", "opencode", "opencode.db"),
              os.path.join(home_dir, ".local", "share", "opencode", "opencode.db")):
        if p and os.path.isfile(p):
            return p
    return ""

try:
    slo = float(os.environ.get("RECOVERY_CACHE_HIT_SLO", "0.5") or 0.5)
except ValueError:
    slo = 0.5
ocdb = find_ocdb(root, home)
cache_ratio = None
cache_n = 0
if ocdb:
    try:
        con2 = sqlite3.connect("file:" + ocdb + "?mode=ro", uri=True)
        cutoff_ms = int((time.time() - 86400) * 1000)
        rows = con2.execute(
            "SELECT tokens_input, tokens_cache_read, time_updated FROM session "
            "ORDER BY rowid DESC LIMIT 500").fetchall()
        rows = [r for r in rows if int(r[2] or 0) >= cutoff_ms]
        tin = sum(int(r[0] or 0) for r in rows)
        tcr = sum(int(r[1] or 0) for r in rows)
        cache_n = len(rows)
        if tin + tcr > 0:
            cache_ratio = tcr / float(tin + tcr)
    except Exception:
        pass
if cache_ratio is None:
    subs.append({"name": "cache", "state": "unknown", "detail": "no cache data (store missing or empty)"})
else:
    cst = "ok" if cache_ratio >= slo else "attention"
    subs.append({"name": "cache", "state": cst,
                 "detail": "%.1f%% cache hit over %s session(s) in 24h (SLO %.0f%%)" % (cache_ratio * 100, cache_n, slo * 100)})
    if cst == "attention":
        actions.append("cache-hit below SLO: keep the prompt prefix stable and prune stale tool output before compaction")

states = [s["state"] for s in subs]
if "fail" in states or "attention" in states:
    overall = "degraded"
elif all(s == "unknown" for s in states):
    overall = "unknown"
else:
    overall = "healthy"

if not actions:
    actions.append("no action required")

print(json.dumps({
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "overall": overall,
    "subsystems": subs,
    "actions": actions,
    "source": "recovery-status.sh",
}, indent=2))
PYEOF
}

render_human() {
    python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("recovery: cannot parse status")
    sys.exit(2)
print("recovery: %s @ %s" % (d.get("overall", "?"), d.get("ts", "?")))
for s in d.get("subsystems", []):
    print("  %-8s %-10s %s" % (s.get("name", "?"), s.get("state", "?"), s.get("detail", "")))
acts = d.get("actions") or []
if acts:
    print("next:")
    for a in acts:
        print("  " + a)'
}

self_test() {
    local fail=0 w="" out=""
    w=$(mktemp -d)
    mkdir -p "$w/data/observability"
    printf '%s\n' '{"ts":"20260101T000000Z","passed":4,"failed":0}' > "$w/data/observability/last-gate.json"
    printf '%s\n' '{"headline":"ok: all quiet"}' > "$w/data/observability/pulse.json"
    printf 'PREV=up\nFAILS=0\nSIG=a\nGOOD_SIG=a\n' > "$w/hotspot.state"
    out=$(HOTSPOT_STATE="$w/hotspot.state" build "$w")
    printf '%s' "$out" | grep -q '"overall": "healthy"' || { printf 'FAIL healthy\n'; fail=1; }
    printf '%s' "$out" | grep -q '"name": "overlay"' || { printf 'FAIL overlay row\n'; fail=1; }

    printf 'PREV=off-network\nFAILS=1\nSIG=b\nGOOD_SIG=a\n' > "$w/hotspot.state"
    out=$(HOTSPOT_STATE="$w/hotspot.state" build "$w")
    printf '%s' "$out" | grep -q '"state": "expected"' || { printf 'FAIL expected roam\n'; fail=1; }

    printf '%s\n' '{"ts":"20260101T000000Z","passed":3,"failed":1}' > "$w/data/observability/last-gate.json"
    out=$(HOTSPOT_STATE="$w/hotspot.state" build "$w")
    printf '%s' "$out" | grep -q '"overall": "degraded"' || { printf 'FAIL degraded\n'; fail=1; }
    printf '%s' "$out" | grep -q 'harness.sh' || { printf 'FAIL gate action\n'; fail=1; }

    # cache-hit SLO: high cache_read/input is ok; a churning prefix is attention
    python3 - "$w/opencode.db" << 'PY'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE session(id TEXT PRIMARY KEY, tokens_input INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, time_updated INTEGER)")
c.execute("INSERT INTO session VALUES('s1', 100, 900, 0, ?)", (int(time.time() * 1000),))
c.commit()
PY
    out=$(OPENCODE_DB="$w/opencode.db" HOTSPOT_STATE="$w/hotspot.state" build "$w")
    printf '%s' "$out" | grep -A2 '"name": "cache"' | grep -q '"state": "ok"' \
        || { printf 'FAIL cache ok\n'; fail=1; }
    python3 - "$w/opencode.db" << 'PY'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT INTO session VALUES('s2', 9000, 100, 0, ?)", (int(time.time() * 1000),))
c.commit()
PY
    out=$(OPENCODE_DB="$w/opencode.db" HOTSPOT_STATE="$w/hotspot.state" build "$w")
    printf '%s' "$out" | grep -A2 '"name": "cache"' | grep -q '"state": "attention"' \
        || { printf 'FAIL cache attention\n'; fail=1; }
    rm -f "$w/opencode.db"

    rm -f "$w/data/observability/last-gate.json" "$w/data/observability/pulse.json" "$w/hotspot.state"
    rmdir "$w/data/observability" "$w/data" "$w" 2>&1 || true
    if [ "$fail" -eq 0 ]; then
        printf 'recovery-status: self-test PASS (healthy + expected-roam + degraded + cache-slo)\n'
    else
        printf 'recovery-status: self-test FAIL\n'
    fi
    return "$fail"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) MODE="json"; shift ;;
            --write) MODE="write"; shift ;;
            --out) OUT="${2:-}"; shift 2 ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) printf 'usage: %s [--json] [--write] [--out PATH] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 3 ;;
        esac
    done
    if [ -z "$REPO" ]; then
        printf 'FAIL: cannot resolve repo root\n'
        return 3
    fi
    case "$MODE" in
        json) build "$REPO" ;;
        write)
            [ -n "$OUT" ] || OUT="$REPO/data/observability/recovery.json"
            build "$REPO" > "$OUT" || { printf 'FAIL: cannot write %s\n' "$OUT"; return 1; }
            printf 'wrote %s\n' "$OUT"
            ;;
        human) build "$REPO" | render_human ;;
    esac
    return 0
}

main "$@"
