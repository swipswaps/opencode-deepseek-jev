#!/usr/bin/env bash
#
# sentinel.sh — periodic threshold monitor for session/model health.
#
# watch.sh shows what is newly wrong; this decides whether it is ACTIONABLE
# and leaves ledger rows a consumer can poll. One sweep is read-only except
# the ledger log and a byte cursor. It is meant to run under a user timer
# (systemd/opencode-sentinel.timer, every 5 min) — see
# ./scripts/sentinel-install.sh — but `--once` works anywhere, including CI.
#
# Thresholds (env, documented defaults):
#   CONTEXT_BUDGET (default 200000) — over/warn bands, shared with
#     session-health.mjs and cost-bottlenecks.sh.
#   SENTINEL_GW_RE  — gateway-failure signature (default below).
#
# TRIP (exit 1 + one ADVISORY row each) only on actionable news:
#   T1 the LATEST session is over budget (prompting it re-sends history)
#   T2 the LATEST session runs a deny-listed model (gateway answers
#      AI_APICallError instead of text)
#   T3 >=1 NEW gateway-failure line in opencode.log since the cursor
#      (AI_APICallError | Free usage exceeded | backend is temporarily
#      unavailable), grouped by modelID.
#   T4 >=1 NEW caddy fetch slower than SENTINEL_SLOW_SEC (default 10) since
#      the access cursor — the "loading takes forever" tripwire. Source is
#      `docker logs` (or SENTINEL_ACCESSLOG file seam); first run
#      initialises silently like every cursor here.
# REPORT-only (exit stays 0): total over/warn/denied counts across recent 40.
# A permanently-red monitor desensitizes (cry-wolf); history is reported,
# only news trips.
#
#   ./scripts/sentinel.sh [--once] [--json] [--no-log]
#   ./scripts/sentinel.sh --self-test   # offline fixture, no docker/net
#
# Env seams: SENTINEL_DB, SENTINEL_APP, SENTINEL_STATE, LEDGER_DB,
# SENTINEL_ACCESSLOG (file instead of `docker logs`), SENTINEL_NODOCKER=1
# (skip T4), SENTINEL_SLOW_SEC (default 10).
# Exit 0 clean-or-report, 1 tripped, 2 usage/resolve error.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1.
# No 2>/dev/null. No subprocess.run. No kill without signal.
#
set -o pipefail

GW_RE='AI_APICallError|Free usage exceeded|backend is temporarily unavailable'

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

log_advisory() {
    # log_advisory VERDICT RESOURCE DETAIL — guarded, never fails the run.
    [ "$DOLOG" -eq 1 ] || return 0
    have python3 || return 0
    SEQ=$((SEQ + 1))
    python3 "$REPO/scripts/ledger.py" record --type ADVISORY \
        --actor sentinel --tool sentinel --resource "$2" \
        --verdict "$1" --detail "$3" --rev "$REV" \
        --source sentinel --key "sentinel-$RUN_TS-$SEQ" \
        > /dev/null 2>&1 || true
    return 0
}

trip() {
    NTRIP=$((NTRIP + 1))
    TRIPMSG="$TRIPMSG$1
"
    log_advisory "FAIL" "$2" "$3"
}

self_test() {
    local fail=0 work=""
    have node || { printf 'FAIL node missing\n'; return 1; }
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    work=$(mktemp -d)
    mkdir -p "$work/state"
    export CONTEXT_BUDGET=1000
    python3 - "$work/fix.db" << 'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute('CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT, model TEXT, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, cost REAL, time_created INTEGER, time_updated INTEGER)')
con.execute('CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)')
con.execute("INSERT INTO session VALUES('s_old','old','{\"id\":\"deepseek-flash\"}',5000,0,0,0,1,2)")
con.execute("INSERT INTO session VALUES('s_new','new','{\"id\":\"opencode/x-free\",\"providerID\":\"opencode\"}',100,0,0,0,3,4)")
con.execute("INSERT INTO part VALUES('p1','m','s_old',1,2,'{\"type\":\"text\",\"text\":\"hi\"}')")
con.commit()
PYEOF
    printf '%s\n' 'ts=1 level=INFO ok' > "$work/app.log"
    local o=""
    o=$(SENTINEL_DB="$work/fix.db" SENTINEL_APP="$work/app.log" SENTINEL_STATE="$work/state" LEDGER_DB="$work/obs.db" bash "${BASH_SOURCE[0]}" --once --no-log 2>&1)
    printf '%s' "$o" | grep -q 'TRIP T2.*s_new' || { printf 'FAIL T2 trips on denied latest\n'; fail=1; }
    # second sweep: same DB still trips T2 (latest unchanged), gateway line fires T3 once
    printf '%s\n' 'timestamp=2026-10-12T15:17:31Z level=ERROR message="stream error" providerID=opencode modelID=muse-spark-1.3-contributor-free error.error="AI_APICallError: The backend is temporarily unavailable. Please retry."' >> "$work/app.log"
    o=$(SENTINEL_DB="$work/fix.db" SENTINEL_APP="$work/app.log" SENTINEL_STATE="$work/state" LEDGER_DB="$work/obs.db" bash "${BASH_SOURCE[0]}" --once --no-log 2>&1)
    printf '%s' "$o" | grep -q 'TRIP T3.*1 new' || { printf 'FAIL T3 trips on new gateway line\n'; fail=1; }
    o=$(SENTINEL_DB="$work/fix.db" SENTINEL_APP="$work/app.log" SENTINEL_STATE="$work/state" LEDGER_DB="$work/obs.db" bash "${BASH_SOURCE[0]}" --once --no-log 2>&1)
    printf '%s' "$o" | grep -q 'TRIP T3' && { printf 'FAIL T3 re-fires after cursor\n'; fail=1; }
    o=$(SENTINEL_DB="$work/fix.db" SENTINEL_APP="$work/app.log" SENTINEL_STATE="$work/state" bash "${BASH_SOURCE[0]}" --json --no-log 2>&1)
    python3 -c 'import json,sys; d=json.load(sys.stdin); assert set(("ts","rev","tripped","trips","counts")) <= set(d), "keys"; assert d["tripped"] is True, "tripped"' <<< "$o" \
        || { printf 'FAIL json contract\n'; fail=1; }
    printf '%s\n' '{"logger":"http.log.access.log0","ts":1791840000,"duration":44.2,"request":{"method":"GET","uri":"/session/s1/message"},"status":200}' '{"logger":"http.log.access.log0","ts":1791840001,"duration":0.2,"request":{"method":"GET","uri":"/api/health"},"status":200}' > "$work/acc.log"
    printf '%s' '0' > "$work/state/sentinel-access.cursor"
    o=$(SENTINEL_DB="$work/fix.db" SENTINEL_APP="$work/app.log" SENTINEL_STATE="$work/state" SENTINEL_ACCESSLOG="$work/acc.log" bash "${BASH_SOURCE[0]}" --once --no-log 2>&1)
    printf '%s' "$o" | grep -q 'TRIP T4 slow-fetch: 1 fetch' || { printf 'FAIL T4 trips on slow fetch\n'; fail=1; }
    printf '%s' "$o" | grep -q 'slowest 44.2s' || { printf 'FAIL T4 slowest reported\n'; fail=1; }
    SENTINEL_DB="$work/fix.db" SENTINEL_APP="$work/app.log" SENTINEL_STATE="$work/state" LEDGER_DB="$work/obs.db" bash "${BASH_SOURCE[0]}" --once > /dev/null 2>&1
    LEDGER_DB="$work/obs.db" python3 "$REPO/scripts/ledger.py" show --grep sentinel 2>&1 | grep -q 'ADVISORY' \
        || { printf 'FAIL ledger advisory logged\n'; fail=1; }
    rm -f "$work/fix.db" "$work/obs.db" "$work/app.log" "$work/acc.log" "$work/state/sentinel.cursor" "$work/state/sentinel-access.cursor"
    rmdir "$work/state" "$work"
    if [ "$fail" -eq 0 ]; then printf 'sentinel: self-test PASS\n'; else printf 'sentinel: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    local JSON=0 SELFTEST=0 DOLOG=1 ONCE=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --once) ONCE=1; shift ;;
            --json) JSON=1; shift ;;
            --no-log) DOLOG=0; shift ;;
            --self-test) SELFTEST=1; shift ;;
            -h | --help)
                printf 'usage: %s [--once] [--json] [--no-log] [--self-test]\n' "$0"
                return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    [ "$ONCE" -eq 1 ] || { printf 'usage: periodic runs go through the systemd timer\n'; return 2; }
    have node || { printf 'GATE FAIL: node required\n'; return 1; }
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 1; }
    local DB="${SENTINEL_DB:-$REPO/data/opencode/opencode.db}"
    local APP="${SENTINEL_APP:-$HOME/.local/share/opencode/log/opencode.log}"
    local STATE="${SENTINEL_STATE:-$REPO/data/observability/.watch}"
    [ -f "$DB" ] || { printf 'FAIL: no database at %s\n' "$DB"; return 1; }
    REV=$(git -C "$REPO" rev-parse --short HEAD 2>&1 || printf 'unknown')
    RUN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    export REV RUN_TS
    SEQ=0
    NTRIP=0
    TRIPMSG=""
    mkdir -p "$STATE"
    local health=""
    health=$(node --experimental-sqlite "$REPO/scripts/session-health.mjs" "$DB" --json 2>&1 || true)
    local summary=""
    summary=$(HEALTH_JSON="$health" APP_LOG="$APP" STATE_DIR="$STATE" python3 - << 'PYEOF'
import json, os, subprocess
raw = os.environ.get("HEALTH_JSON", "")
out = {"trips": [], "counts": {}, "latest": {}}
if "{" not in raw:
    print(json.dumps({"error": "no report"}))
    raise SystemExit
d = json.loads(raw[raw.find("{"):])
risks = d.get("risks") or {}
over, denied = risks.get("over", []), risks.get("denied", [])
out["counts"] = {"over": len(over), "warn": len(risks.get("warn", [])),
                 "denied": len(denied)}
ho = d.get("handoff") or {}
latest_id = ho.get("session")
lat = next((x for x in over + denied if x.get("session") == latest_id), None)
if lat is None and not ho.get("available", True):
    # handoffAdvice unavailable (e.g. older store shape): fall back to the
    # worst risk rather than reporting a clean "(none)".
    lat = (over + denied or [None])[0]
if lat is None:
    lat = {"session": latest_id or "(none)", "level": ho.get("level", "ok"),
           "in_tok": ho.get("in_tok", 0), "ratio": ho.get("ratio", 0),
           "model": "", "model_denied": False}
out["latest"] = {"session": lat.get("session"), "level": lat.get("level"),
                 "model_denied": lat.get("model_denied")}
if lat.get("level") == "over":
    out["trips"].append({"id": "T1", "session": lat.get("session"),
        "msg": "latest session over budget: %s in (%sx)" % (lat.get("in_tok"), lat.get("ratio"))})
if lat.get("model_denied"):
    out["trips"].append({"id": "T2", "session": lat.get("session"),
        "msg": "latest session on deny-listed model (gateway answers AI_APICallError, not text)"})
print(json.dumps(out))
PYEOF
    )
    local trips_json="$summary"
    # T3: gateway-failure lines NEW since the cursor (single bounded tail read;
    # first run initialises at EOF — history is not news).
    local gwcount=0 newseg="" total=0 prev=0 havecur=0
    if [ -f "$APP" ]; then
        total=$(wc -c < "$APP" | tr -d ' ')
        if [ -f "$STATE/sentinel.cursor" ]; then
            havecur=1
            prev=$(tr -d ' ' < "$STATE/sentinel.cursor")
        fi
        [ -n "$prev" ] || prev=0
        [ "$prev" -le "$total" ] || prev=0
        if [ "$havecur" -eq 1 ]; then
            newseg=$(tail -c +"$((prev + 1))" "$APP" 2>&1 | grep -E "$GW_RE" || true)
            gwcount=$(printf '%s' "$newseg" | grep -c . 2>&1 || true)
            case "$gwcount" in ''|*[!0-9]*) gwcount=0 ;; esac
        fi
        printf '%s' "$total" > "$STATE/sentinel.cursor"
    fi
    export GWCOUNT="$gwcount"
    local t1
    t1=$(printf '%s' "$trips_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join("TRIP %s %s: %s" % (t["id"], t["session"], t["msg"]) for t in d.get("trips",[])))' 2>&1 || true)
    while IFS= read -r line; do
        [ -n "$line" ] && trip "$line" "session/sentinel-focus" "guidance issued (see stdout)"
    done <<< "$t1"
    if [ "$gwcount" -gt 0 ]; then
        local models=""
        models=$(printf '%s' "$newseg" | grep -oE 'modelID=[^ ,"]+' | sort -u | tr '\n' ' ')
        trip "TRIP T3 gateway: $gwcount new failure line(s) (models: $models)" "log/opencode.log" "AI_APICallError/Free-usage signatures x$gwcount ($models)"
        if [ "$JSON" -eq 0 ]; then
            printf '%s' "$newseg" | tail -3 | cut -c1-200 | while IFS= read -r line; do
                printf '  %s\n' "$line"
            done
        fi
    fi
    # T4: slow caddy fetches since the access cursor. First run initialises
    # silently; docker missing (or NODOCKER) skips — unless SENTINEL_ACCESSLOG
    # names a fixture file, which is parsed directly and never shells out to
    # docker (this is the self-test path; it must pass in containers that
    # have no docker CLI at all).
    local SLOW_SEC="${SENTINEL_SLOW_SEC:-10}"
    local slow_n=0 slow_max=0 slow_uri=""
    if [ "${SENTINEL_NODOCKER:-0}" -eq 0 ] && { have docker || [ -n "${SENTINEL_ACCESSLOG:-}" ]; } && have python3; then
        local acc_cur="$STATE/sentinel-access.cursor" acc_since="" acc_new=0
        if [ -f "$acc_cur" ]; then
            acc_since=$(tr -d ' ' < "$acc_cur")
        fi
        case "$acc_since" in ''|*[!0-9]*) acc_since="" ;; esac
        local acc_lines="" acc_src="" acc_tmp=""
        if [ -n "${SENTINEL_ACCESSLOG:-}" ]; then
            acc_src="$SENTINEL_ACCESSLOG"
        elif [ -n "$acc_since" ]; then
            acc_tmp=$(mktemp)
            docker logs --since "$acc_since" opencode-caddy > "$acc_tmp" 2>&1 || true
            acc_src="$acc_tmp"
        else
            acc_src=""
        fi
        if [ -z "$acc_src" ]; then
            : # first live run: initialise below, no trip on history
        else
            local slow_out=""
            slow_out=$(python3 - "$SLOW_SEC" "$acc_src" << 'PYEOF'
import json, sys
thresh = float(sys.argv[1])
n, mx, uri = 0, 0.0, ""
try:
    fh = open(sys.argv[2], encoding="utf-8", errors="replace")
except OSError:
    fh = []
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
    if dur >= thresh:
        r = e.get("request", {}) or {}
        n += 1
        if dur > mx:
            mx, uri = dur, str(r.get("method", "?")) + " " + str(r.get("uri", "?"))[:70]
print("%d|%.1f|%s" % (n, mx, uri))
PYEOF
            )
            slow_n=${slow_out%%|*}
            slow_max=$(printf '%s' "$slow_out" | cut -d'|' -f2)
            slow_uri=$(printf '%s' "$slow_out" | cut -d'|' -f3-)
            case "$slow_n" in ''|*[!0-9]*) slow_n=0 ;; esac
        fi
        printf '%s' "$(date +%s)" > "$acc_cur"
        if [ "$slow_n" -gt 0 ]; then
            trip "TRIP T4 slow-fetch: $slow_n fetch(es) >= ${SLOW_SEC}s (slowest ${slow_max}s $slow_uri)" "caddy access log" "slow fetches x$slow_n, slowest ${slow_max}s ($slow_uri)"
        fi
        [ -n "$acc_tmp" ] && rm -f "$acc_tmp"
    fi
    export SLOW_N="$slow_n" SLOW_MAX="$slow_max"
    if [ "$JSON" -eq 1 ]; then
        printf '%s' "$trips_json" | python3 -c 'import json,sys,os; d=json.load(sys.stdin); print(json.dumps({"ts": os.environ.get("RUN_TS",""), "rev": os.environ.get("REV",""), "tripped": bool(d.get("trips")) or int(os.environ.get("SLOW_N","0"))>0, "trips": d.get("trips"), "counts": d.get("counts"), "latest": d.get("latest"), "gw_new": int(os.environ.get("GWCOUNT","0")), "slow": {"threshold_s": float(os.environ.get("SLOW_SEC","10")), "n": int(os.environ.get("SLOW_N","0")), "slowest_s": float(os.environ.get("SLOW_MAX","0") or 0)}}))'
    else
        printf '=== sentinel @ %s ===\n' "$RUN_TS"
        printf '%s' "$trips_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d.get("counts",{}); l=d.get("latest",{}); print("latest: %s [%s] · over=%s warn=%s denied=%s" % (l.get("session"), l.get("level"), c.get("over"), c.get("warn"), c.get("denied")))'
        if [ -n "$TRIPMSG" ]; then
            printf '%s' "$TRIPMSG"
            printf 'guidance: ./scripts/session-guard.sh [--session <id>] for the verdict, or --handoff --session <id> for the full offer (brief+paste steps)\n'
        else
            printf 'clean: no actionable trips (history reported above)\n'
        fi
    fi
    export RUN_TS REV GWCOUNT="$gwcount"
    if [ -n "$TRIPMSG" ]; then return 1; fi
    return 0
}

main "$@"
