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
#   T5 a NON-latest session runs a deny-listed model and was active since
#      the last sweep (T2 covers the latest only) — the $2.04 v4-pro history.
#   T6 a NON-latest session is over budget and was active since the last
#      sweep (T1 covers the latest only) — prompting it re-sends history.
#   T7 a tool in a recent session has been `running` longer than
#      session-health's run_ms (a stalled tool the single-threaded server is
#      blocked on — S0) and started since the last sweep. Cursor-bounded like
#      T3/T5/T6: the first sweep initialises silently, so an archival "running"
#      part (e.g. a 12-day-old entry) is history, not news.
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
    # log_advisory VERDICT RESOURCE DETAIL [KEY] — guarded, never fails the run.
    # KEY defaults to a fresh per-run key. Pass a STABLE per-incident key so a
    # recurring condition collapses to ONE ledger row via UNIQUE(source,key)
    # instead of one ADVISORY per sweep (the 589-row slow-/provider cry-wolf,
    # which desensitizes the watchdog).
    [ "$DOLOG" -eq 1 ] || return 0
    have python3 || return 0
    SEQ=$((SEQ + 1))
    local key="${4:-sentinel-$RUN_TS-$SEQ}"
    python3 "$REPO/scripts/ledger.py" record --type ADVISORY \
        --actor sentinel --tool sentinel --resource "$2" \
        --verdict "$1" --detail "$3" --rev "$REV" \
        --source sentinel --key "$key" \
        > /dev/null 2>&1 || true
    return 0
}

trip() {
    NTRIP=$((NTRIP + 1))
    TRIPMSG="$TRIPMSG$1
"
    log_advisory "FAIL" "$2" "$3" "$4"
}

emit_digest() {
    # emit_digest SID DB — best-effort DB-only digest written next to the trip,
    # so the operator (or a consumer) can hand off WITHOUT replaying the
    # transcript into a model. Never fails the sweep.
    local sid="$1" dbf="$2"
    [ -n "$sid" ] && [ -f "$REPO/scripts/session-digest.sh" ] || return 0
    have python3 || return 0
    mkdir -p "$DIGEST_DIR" || return 0
    bash "$REPO/scripts/session-digest.sh" "$sid" --db "$dbf" > "$DIGEST_DIR/$sid.md" 2>&1 || true
    return 0
}

self_test() {
    local fail=0 work="" n1 n2
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
con.execute("INSERT INTO session VALUES('s_old','old','{\"id\":\"deepseek-v4-pro\",\"providerID\":\"deepseek\"}',5000,0,0,0,1,2)")
con.execute("INSERT INTO session VALUES('s_new','new','{\"id\":\"opencode/x-free\",\"providerID\":\"opencode\"}',100,0,0,0,3,4)")
con.execute("INSERT INTO session VALUES('s_over','over','{\"id\":\"deepseek-flash\",\"providerID\":\"deepseek\"}',5000,0,0,0,2,2)")
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
    # T5/T6: s_old is deny-listed AND over budget; s_over is over budget but
    # ALLOW-listed. Both are NOT latest. Stamp them active 60s ago with a
    # cursor 600s old (relative offsets — immune to clock). First sweep trips
    # T5 only for s_old and T6 for both; second sweep is silent (cursor
    # advanced past the activity). s_over isolates T6 from T5.
    t5_now=$(date +%s)
    python3 - "$work/fix.db" "$(( (t5_now - 60) * 1000 ))" "$(( (t5_now - 180) * 1000 ))" << 'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("UPDATE session SET time_updated=? WHERE id IN ('s_old','s_over')", (int(sys.argv[2]),))
# T7 stall fixture: a tool in `running` for 180s (> session-health run_ms of
# 120s) that began 180s ago, i.e. AFTER the 600s-old sweep cursor. time_created
# stays 0 so s_new remains the latest session and T2 still fires.
con.execute("INSERT OR REPLACE INTO session VALUES('s_stall','stall','{\"id\":\"deepseek-flash\",\"providerID\":\"deepseek\"}',10,0,0,0,0,?)", (int(sys.argv[3]),))
con.execute("INSERT OR REPLACE INTO part VALUES('p_stall','m','s_stall',?,?,'{\"type\":\"tool\",\"tool\":\"bash\",\"state\":{\"status\":\"running\",\"input\":{\"command\":\"sleep 999\"}}}')", (int(sys.argv[3]), int(sys.argv[3])))
con.commit()
PYEOF
    printf '%s' "$((t5_now - 600))" > "$work/state/sentinel-t5.cursor"
    o=$(SENTINEL_DB="$work/fix.db" SENTINEL_APP="$work/app.log" SENTINEL_STATE="$work/state" bash "${BASH_SOURCE[0]}" --once --no-log 2>&1)
    printf '%s' "$o" | grep -q 'TRIP T5 denied-model: s_old' || { printf 'FAIL T5 trips on denied non-latest active session\n'; fail=1; }
    printf '%s' "$o" | grep -q 'TRIP T6 over-budget: s_old' || { printf 'FAIL T6 trips on over-budget non-latest active session\n'; fail=1; }
    printf '%s' "$o" | grep -q 'TRIP T6 over-budget: s_over' || { printf 'FAIL T6 trips on over-budget ALLOW-listed non-latest session\n'; fail=1; }
    printf '%s' "$o" | grep -q 'TRIP T5.*s_over' && { printf 'FAIL T5 fired on an allow-listed session\n'; fail=1; }
    printf '%s' "$o" | grep -q 'TRIP T7 stall: s_stall bash running' || { printf 'FAIL T7 trips on a stall that began since the cursor\n'; fail=1; }
    o=$(SENTINEL_DB="$work/fix.db" SENTINEL_APP="$work/app.log" SENTINEL_STATE="$work/state" bash "${BASH_SOURCE[0]}" --once --no-log 2>&1)
    printf '%s' "$o" | grep -q 'TRIP T5' && { printf 'FAIL T5 re-fires after cursor\n'; fail=1; }
    printf '%s' "$o" | grep -q 'TRIP T6' && { printf 'FAIL T6 re-fires after cursor\n'; fail=1; }
    printf '%s' "$o" | grep -q 'TRIP T7' && { printf 'FAIL T7 re-fires after cursor\n'; fail=1; }
    printf '%s' "$((t5_now - 600))" > "$work/state/sentinel-t5.cursor"
    SENTINEL_DB="$work/fix.db" SENTINEL_APP="$work/app.log" SENTINEL_STATE="$work/state" SENTINEL_DIGEST_DIR="$work/digests" LEDGER_DB="$work/obs.db" bash "${BASH_SOURCE[0]}" --once > /dev/null 2>&1
    LEDGER_DB="$work/obs.db" python3 "$REPO/scripts/ledger.py" show --grep sentinel 2>&1 | grep -q 'ADVISORY' \
        || { printf 'FAIL ledger advisory logged\n'; fail=1; }
    [ -f "$work/digests/s_old.md" ] || { printf 'FAIL digest emitted for tripped session\n'; fail=1; }
    # Stable per-incident keys: re-running the SAME trips must NOT add rows
    # (UNIQUE(source,key) ignores them) — the cry-wolf fix.
    n1=$(LEDGER_DB="$work/obs.db" python3 "$REPO/scripts/ledger.py" show --grep sentinel 2>&1 | grep -c 'ADVISORY')
    printf '%s' "$((t5_now - 600))" > "$work/state/sentinel-t5.cursor"
    SENTINEL_DB="$work/fix.db" SENTINEL_APP="$work/app.log" SENTINEL_STATE="$work/state" SENTINEL_DIGEST_DIR="$work/digests" LEDGER_DB="$work/obs.db" bash "${BASH_SOURCE[0]}" --once > /dev/null 2>&1
    n2=$(LEDGER_DB="$work/obs.db" python3 "$REPO/scripts/ledger.py" show --grep sentinel 2>&1 | grep -c 'ADVISORY')
    [ "$n1" = "$n2" ] && [ "$n1" -gt 0 ] || { printf 'FAIL ledger not idempotent (n1=%s n2=%s)\n' "$n1" "$n2"; fail=1; }
    rm -f "$work/digests/"*.md "$work/fix.db" "$work/obs.db" "$work/app.log" "$work/acc.log" "$work/state/sentinel.cursor" "$work/state/sentinel-access.cursor" "$work/state/sentinel-t5.cursor"
    rmdir "$work/digests" "$work/state" "$work"
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
    local DIGEST_DIR="${SENTINEL_DIGEST_DIR:-$REPO/data/observability/digests}"
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
out["denied"] = [{"session": x.get("session"), "model": x.get("model"),
                  "updated_at": x.get("updated_at")} for x in denied]
out["over"] = [{"session": x.get("session"), "model": x.get("model"),
                "updated_at": x.get("updated_at"), "in_tok": x.get("in_tok"),
                "ratio": x.get("ratio")} for x in over]
out["stalls"] = [{"session": f.get("session"), "tool": f.get("tool"),
                  "started_at": f.get("started_at"), "age_s": f.get("age_s")}
                 for f in d.get("findings", []) if f.get("kind") == "running_tool"]
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
    local t1 tk=""
    t1=$(printf '%s' "$trips_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join("TRIP %s %s: %s" % (t["id"], t["session"], t["msg"]) for t in d.get("trips",[])))' 2>&1 || true)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # Stable key per (trip-id, session): a latest session that STAYS over
        # budget / deny-listed logs ONE advisory, not one per sweep.
        tk=$(printf '%s' "$line" | awk '{gsub(/:$/,"",$3); print $2"_"$3}')
        trip "$line" "session/sentinel-focus" "guidance issued (see stdout)" "sentinel-$tk"
    done <<< "$t1"
    if [ "$gwcount" -gt 0 ]; then
        local models=""
        models=$(printf '%s' "$newseg" | grep -oE 'modelID=[^ ,"]+' | sort -u | tr '\n' ' ')
        trip "TRIP T3 gateway: $gwcount new failure line(s) (models: $models)" "log/opencode.log" "AI_APICallError/Free-usage signatures x$gwcount ($models)" "sentinel-t3-$models"
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
            trip "TRIP T4 slow-fetch: $slow_n fetch(es) >= ${SLOW_SEC}s (slowest ${slow_max}s $slow_uri)" "caddy access log" "slow fetches x$slow_n, slowest ${slow_max}s ($slow_uri)" "sentinel-t4-$slow_uri"
        fi
        [ -n "$acc_tmp" ] && rm -f "$acc_tmp"
    fi
    # T5/T6: sessions OTHER than latest that are still risky and were active
    # since last sweep. T2/T1 cover only the LATEST session, so a
    # background/forked session burning on a deny-listed model (the $2.04
    # v4-pro history) or re-sending an over-budget history stays invisible.
    # Cursor-bounded like T3: first run initialises silently, no trip on
    # history. Advisory only — trips never stop sessions; the guidance names
    # the handoff. T5 = deny-listed; T6 = over budget.
    local t5_cur="$STATE/sentinel-t5.cursor" t5_since=""
    if [ -f "$t5_cur" ]; then
        t5_since=$(tr -d ' ' < "$t5_cur")
    fi
    case "$t5_since" in ''|*[!0-9]*) t5_since="" ;; esac
    local t5_n=0 t6_n=0 t7_n=0 t5_hits=""
    if [ -n "$t5_since" ]; then
        # Data travels by env (a heredoc owns stdin — the pipe would lose it).
        t5_hits=$(TRIPS_JSON="$trips_json" SENTINEL_T5_SINCE="$t5_since" python3 - << 'PYEOF' 2>&1
import json, os, sys
from datetime import datetime
try:
    d = json.loads(os.environ.get("TRIPS_JSON", "") or "{}")
except Exception:
    print("")
    raise SystemExit
since = int(os.environ.get("SENTINEL_T5_SINCE", "0") or 0)
latest = (d.get("latest") or {}).get("session") or ""
def active(x):
    sid = x.get("session") or ""
    if not sid or sid == latest:
        return None
    try:
        upd = datetime.fromisoformat((x.get("updated_at") or "").replace("Z", "+00:00")).timestamp()
    except Exception:
        return None
    return sid if upd > since else None
out = []
for x in d.get("denied") or []:
    sid = active(x)
    if sid:
        out.append("T5|%s|%s" % (sid, x.get("model") or "?"))
for x in d.get("over") or []:
    sid = active(x)
    if sid:
        out.append("T6|%s|%s|%s" % (sid, x.get("ratio"), x.get("in_tok")))
# T7: a running tool whose start is NEW since the sweep cursor. A stall that
# predates the cursor was already news on an earlier sweep (or is the silent
# first-run init), so re-tripping it every 5 min would desensitize.
for x in d.get("stalls") or []:
    sid = x.get("session") or ""
    try:
        st = datetime.fromisoformat((x.get("started_at") or "").replace("Z", "+00:00")).timestamp()
    except Exception:
        continue
    if sid and st > since:
        out.append("T7|%s|%s|%s" % (sid, x.get("tool") or "?", x.get("age_s") or 0))
print("\n".join(out))
PYEOF
) || true
        while IFS='|' read -r tag sid a b; do
            [ -n "$tag" ] || continue
            case "$tag" in
                T5) t5_n=$((t5_n + 1)); emit_digest "$sid" "$DB"
                    trip "TRIP T5 denied-model: $sid on $a active since last sweep" "session/$sid" "deny-listed model still burning; stop prompting, hand off (./scripts/handoff-brief.sh $sid)" "sentinel-T5-$sid" ;;
                T6) t6_n=$((t6_n + 1)); emit_digest "$sid" "$DB"
                    trip "TRIP T6 over-budget: $sid (${a}x, $b in) active since last sweep" "session/$sid" "non-latest session over budget still being prompted; stop, hand off (./scripts/handoff-brief.sh $sid)" "sentinel-T6-$sid" ;;
                T7) t7_n=$((t7_n + 1)); emit_digest "$sid" "$DB"
                    trip "TRIP T7 stall: $sid $a running ${b}s active since last sweep" "session/$sid" "tool stuck in running (session-health S0); the single-threaded server is blocked on it; inspect, then hand off if it must be abandoned (./scripts/handoff-brief.sh $sid)" "sentinel-T7-$sid" ;;
            esac
        done <<< "$t5_hits"
    fi
    printf '%s' "$(date +%s)" > "$t5_cur"
    export T5_N="$t5_n" T6_N="$t6_n" T7_N="$t7_n"
    export SLOW_N="$slow_n" SLOW_MAX="$slow_max"
    if [ "$JSON" -eq 1 ]; then
        printf '%s' "$trips_json" | python3 -c 'import json,sys,os; d=json.load(sys.stdin); print(json.dumps({"ts": os.environ.get("RUN_TS",""), "rev": os.environ.get("REV",""), "tripped": bool(d.get("trips")) or int(os.environ.get("SLOW_N","0"))>0 or int(os.environ.get("T5_N","0"))>0 or int(os.environ.get("T6_N","0"))>0 or int(os.environ.get("T7_N","0"))>0, "trips": d.get("trips"), "counts": d.get("counts"), "latest": d.get("latest"), "gw_new": int(os.environ.get("GWCOUNT","0")), "denied_active": int(os.environ.get("T5_N","0")), "over_active": int(os.environ.get("T6_N","0")), "stall_active": int(os.environ.get("T7_N","0")), "slow": {"threshold_s": float(os.environ.get("SLOW_SEC","10")), "n": int(os.environ.get("SLOW_N","0")), "slowest_s": float(os.environ.get("SLOW_MAX","0") or 0)}}))'
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
