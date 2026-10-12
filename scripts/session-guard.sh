#!/usr/bin/env bash
#
# session-guard.sh — the 4-step over-budget / denied-model guidance as code.
#
# Reads session-health.mjs --json (read-only over opencode.db) and prints the
# numbered recovery for the focus session:
#   1. pause this session (every turn re-sends the whole context)
#   2. open a fresh session (read HANDOFF.md first)
#   3. carry a brief, not the history (./scripts/handoff-brief.sh <id>);
#      never --fork/--continue (copies the context back)
#   4. use an allow-listed model (opencode-go/*, deepseek/flash, gemini-flash);
#      never opencode/*-free (deny-listed, gateway-metered: the provider
#      answers AI_APICallError "backend temporarily unavailable" instead of
#      text, which the web UI renders as its backend banner).
#
# On the verdict wording, read this before renaming it: FAIL does NOT mean
# broken, unrecoverable, or anyone's fault. It means ACTIONABLE NOW — the
# session cannot continue efficiently, and the prescription IS the handoff.
# The word exists for the watchdog, which only understands binary signals
# (exit 1 trips, exit 0 does not). The human lines around it say the rest:
# routine handoff due, work intact, offer below.
#
# Focus default: first over-budget session, else first deny-listed session,
# else the latest handoff session. Findings are logged as ADVISORY rows to the
# observability ledger (LEDGER_DB seam) so a watchdog can poll them.
#
#   ./scripts/session-guard.sh [--session ID] [--db PATH]
#   ./scripts/session-guard.sh --handoff --session ID [--out FILE]
#       runs the whole chain (risks -> brief -> leak check -> ledger) and
#       prints the paste-ready handoff offer. This is the "do it for me".
#   ./scripts/session-guard.sh --json [--no-log] [--session ID]
#   ./scripts/session-guard.sh --self-test   # offline fixture, no docker/net
#
# Exit 0 when the focus is clean (or the handoff offer was delivered),
# 1 when it is over budget or deny-listed (actionable), 2 on
# usage/resolve errors. A SKIP is never reported clean.
# Secrets by name only, never by value.
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

log_advisory() {
    # log_advisory VERDICT RESOURCE DETAIL — guarded, never fails the run.
    [ "$DOLOG" -eq 1 ] || return 0
    have python3 || return 0
    SEQ=$((SEQ + 1))
    python3 "$REPO/scripts/ledger.py" record --type ADVISORY \
        --actor session-guard --tool session-guard --resource "$2" \
        --verdict "$1" --detail "$3" --rev "$REV" \
        --source session-guard --key "guard-$RUN_TS-$SEQ" \
        > /dev/null 2>&1 || true
    return 0
}

self_test() {
    local fail=0 work=""
    have node || { printf 'FAIL node missing\n'; return 1; }
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    export CONTEXT_BUDGET=1000
    work=$(mktemp -d)
    CONTEXT_BUDGET=1000 python3 - "$work/fix.db" << 'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute('CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT, model TEXT, tokens_input INTEGER, cost REAL, time_created INTEGER, time_updated INTEGER)')
con.execute('CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)')
con.execute("INSERT INTO session VALUES('s_over','over','{\"id\":\"deepseek-flash\"}',5000,0.07,3,4)")
con.execute("INSERT INTO session VALUES('s_denied','denied','{\"id\":\"opencode/x-free\",\"providerID\":\"opencode\"}',100,0,2,5)")
con.execute("INSERT INTO session VALUES('s_ok','ok','{\"id\":\"deepseek-flash\"}',100,0,0,1)")
con.execute("INSERT INTO part VALUES('p1','m','s_over',3,4,'{\"type\":\"text\",\"text\":\"hi\"}')")
con.commit()
PYEOF
    local o=""
    o=$(CONTEXT_BUDGET=1000 LEDGER_DB="$work/obs.db" bash "${BASH_SOURCE[0]}" --no-log --db "$work/fix.db" --session s_over 2>&1)
    printf '%s' "$o" | grep -q '1\. pause s_over' || { printf 'FAIL step 1 names session\n'; fail=1; }
    printf '%s' "$o" | grep -q 'never --fork/--continue' || { printf 'FAIL no-fork rule\n'; fail=1; }
    printf '%s' "$o" | grep -q '4\. ' || { printf 'FAIL 4 steps\n'; fail=1; }
    printf '%s' "$o" | grep -q 'routine handoff' || { printf 'FAIL verdict transparency\n'; fail=1; }
    bash "${BASH_SOURCE[0]}" --no-log --db "$work/fix.db" --session s_over > /dev/null 2>&1
    [ "$?" -eq 1 ] || { printf 'FAIL over exits 1\n'; fail=1; }
    o=$(CONTEXT_BUDGET=1000 bash "${BASH_SOURCE[0]}" --no-log --db "$work/fix.db" --session s_denied 2>&1)
    printf '%s' "$o" | grep -q 'deny-listed' || { printf 'FAIL denied model flagged\n'; fail=1; }
    bash "${BASH_SOURCE[0]}" --no-log --db "$work/fix.db" --session s_ok > /dev/null 2>&1
    [ "$?" -eq 0 ] || { printf 'FAIL clean exits 0\n'; fail=1; }
    o=$(CONTEXT_BUDGET=1000 bash "${BASH_SOURCE[0]}" --json --no-log --db "$work/fix.db" --session s_over 2>&1)
    python3 -c 'import json,sys; d=json.load(sys.stdin); assert set(("ts","rev","session","verdict","guidance","risks")) <= set(d), "keys"; assert len(d["guidance"]) == 4, "4 steps"; assert d["verdict"] == "FAIL", "verdict"' <<< "$o" \
        || { printf 'FAIL json contract\n'; fail=1; }
    CONTEXT_BUDGET=1000 LEDGER_DB="$work/obs.db" bash "${BASH_SOURCE[0]}" --db "$work/fix.db" --session s_over > /dev/null 2>&1
    LEDGER_DB="$work/obs.db" python3 "$REPO/scripts/ledger.py" show --grep session-guard 2>&1 | grep -q 'ADVISORY' \
        || { printf 'FAIL ledger advisory logged\n'; fail=1; }
    printf '%s\n' '# s_over - fixture' '' '## user m1 2026-10-12 10:00:00 UTC' '' 'fixture goal here' '' '## assistant m2 2026-10-12 10:01:00 UTC' '' 'fixture finding here' > "$work/transcript-s_over.md"
    o=$(CONTEXT_BUDGET=1000 LEDGER_DB="$work/obs.db" bash "${BASH_SOURCE[0]}" --db "$work/fix.db" --session s_over --handoff --transcript "$work/transcript-s_over.md" --out "$work/brief-s_over.md" --no-log 2>&1)
    printf '%s' "$o" | grep -q 'handoff offer for s_over' || { printf 'FAIL handoff offer\n'; fail=1; }
    printf '%s' "$o" | grep -q 'used: session-health' || { printf 'FAIL tool chain credited\n'; fail=1; }
    [ -f "$work/brief-s_over.md" ] || { printf 'FAIL brief file written\n'; fail=1; }
    rm -f "$work/fix.db" "$work/obs.db" "$work/brief-s_over.md" "$work/transcript-s_over.md"
    rmdir "$work"
    if [ "$fail" -eq 0 ]; then printf 'session-guard: self-test PASS\n'; else printf 'session-guard: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    local JSON=0 SELFTEST=0 DOLOG=1 SESSION="" HANDOFF=0 OUTF="" TRANSCRIPT=""
    local DB="$REPO/data/opencode/opencode.db" REV=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) JSON=1; shift ;;
            --self-test) SELFTEST=1; shift ;;
            --no-log) DOLOG=0; shift ;;
            --handoff) HANDOFF=1; shift ;;
            --out) OUTF="${2:-}"; shift 2 ;;
            --out=*) OUTF="${1#--out=}"; shift ;;
            --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
            --transcript=*) TRANSCRIPT="${1#--transcript=}"; shift ;;
            --session) SESSION="${2:-}"; shift 2 ;;
            --session=*) SESSION="${1#--session=}"; shift ;;
            --db) DB="${2:-}"; shift 2 ;;
            --db=*) DB="${1#--db=}"; shift ;;
            --rev) REV="${2:-}"; shift 2 ;;
            --rev=*) REV="${1#--rev=}"; shift ;;
            -h | --help)
                printf 'usage: %s [--session ID] [--db PATH] [--json] [--no-log] [--rev REV] [--handoff] [--out FILE] [--transcript PATH] [--self-test]\n' "$0"
                return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    have node || { printf 'GATE FAIL: node required\n'; return 1; }
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 1; }
    [ -f "$DB" ] || { printf 'FAIL: no database at %s\n' "$DB"; return 1; }
    if [ -z "$REV" ]; then
        REV=$(git -C "$REPO" rev-parse --short HEAD 2>&1 || printf 'unknown')
    fi
    RUN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    SEQ=0
    local health=""
    health=$(node --experimental-sqlite "$REPO/scripts/session-health.mjs" "$DB" --json 2>&1 || true)
    local rc
    rc=$(HEALTH_JSON="$health" python3 - "$SESSION" "$JSON" "$REV" "$RUN_TS" "$DB" "$REPO" << 'PYEOF'
import json, os, re, sqlite3, sys
want, as_json, rev, ts, dbp, repo = sys.argv[1], sys.argv[2] == "1", sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
raw = os.environ.get("HEALTH_JSON", "")
if "{" not in raw:
    print("FAIL: session-health produced no report (node/sqlite error)")
    print("RC=1")
    raise SystemExit
d = json.loads(raw[raw.find("{"):])
risks = d.get("risks") or {}
over, denied = risks.get("over", []), risks.get("denied", [])
focus = None
if want:
    focus = next((x for x in over + denied if x.get("session") == want), None)
    if focus is None:
        # A clean session is in neither risk list: verify it exists (read-only)
        # and report PASS rather than an error.
        try:
            pol = json.load(open(repo + "/models.policy.json"))
            deny = pol.get("deny", [])
        except Exception:
            deny = []
        budget = float(os.environ.get("CONTEXT_BUDGET", "200000") or 200000)
        con = sqlite3.connect("file:" + dbp + "?mode=ro", uri=True)
        row = con.execute("SELECT title, model, COALESCE(tokens_input,0), COALESCE(cost,0) FROM session WHERE id=?", (want,)).fetchone()
        con.close()
        if row is None:
            print("unknown session: " + want)
            print("RC=2")
            raise SystemExit
        title, mraw, intok, cost = row
        try:
            mo = json.loads(mraw)
            mid = mo.get("id", "") if isinstance(mo, dict) else str(mo)
            prov = mo.get("providerID", "") if isinstance(mo, dict) else ""
        except Exception:
            mid, prov = mraw or "(none)", ""
        full = (prov + "/" + mid) if prov else mid
        is_denied = full in deny or mid.split("/")[-1] in deny or re.match(r"^opencode/.*-free$", full) is not None
        ratio = (intok / budget) if budget > 0 else 0
        lvl = "over" if intok > budget else ("warn" if ratio >= 0.8 else "ok")
        focus = {"session": want, "title": title, "model": mid, "model_denied": is_denied,
                 "in_tok": intok, "ratio": round(ratio, 2), "level": lvl, "cost": cost, "parts": 0}
else:
    focus = (over + denied or [None])[0]
    if focus is None:
        ho = d.get("handoff") or {}
        focus = {"session": ho.get("session", "(none)"), "title": ho.get("title", ""),
                 "model": "", "model_denied": False, "in_tok": ho.get("in_tok", 0),
                 "ratio": ho.get("ratio", 0), "level": ho.get("level", "ok"),
                 "cost": 0, "parts": 0}
sid = focus.get("session")
lvl, denied_m = focus.get("level"), focus.get("model_denied")
verdict = "FAIL" if (lvl == "over" or denied_m) else ("WARN" if lvl == "warn" else "PASS")
steps = [
    "pause %s: every turn re-sends %s input tokens (%sx the budget)%s" % (
        sid, focus.get("in_tok"), focus.get("ratio"),
        "; the free-tier gateway answers AI_APICallError instead of text" if denied_m else "; expect minutes per turn"),
    "open a fresh session (read HANDOFF.md first)",
    "carry a brief, not the history: run ./scripts/session-guard.sh --handoff --session %s (writes the redacted, leak-checked brief for you), then paste it into the new session; the full transcript stays in logs/ \u2014 never --fork/--continue (copies the context back)" % sid,
    ("drop model %s: deny-listed gateway-metered free tier" % focus.get("model")) if denied_m else "stay on an allow-listed model (opencode-go/*, deepseek/deepseek-flash, gemini-2.5-flash*)",
]
meaning = ("action due now: this session cannot continue efficiently; the prescription is a routine handoff (step 3) \u2014 nothing is broken, nothing is anyone's fault"
           if verdict == "FAIL" else ("watch: approaching budget; plan the handoff soon" if verdict == "WARN" else "clean: keep working"))
if as_json:
    print(json.dumps({"ts": ts, "rev": rev, "session": sid, "verdict": verdict,
                      "meaning": meaning, "guidance": steps,
                      "risks": {"over": len(over), "denied": len(denied)}}))
else:
    print("=== session-guard: %s ===" % sid)
    print("verdict: %s \u2014 %s" % (verdict, meaning))
    for i, s in enumerate(steps, 1):
        print("%d. %s" % (i, s))
print("RC=" + ("1" if verdict == "FAIL" else "0"))
PYEOF
    )
    local out="$rc"
    local exitcode=0
    case "$out" in
        *RC=1) exitcode=1 ;;
        *RC=2) printf '%s\n' "$out" | python3 -c 'import sys; s=sys.stdin.read(); print(s[:s.rfind("RC=")].rstrip())'; return 2 ;;
        *RC=0) exitcode=0 ;;
        *) printf '%s\n' "$out"; return 1 ;;
    esac
    if [ "$JSON" -eq 1 ]; then
        printf '%s' "$out" | python3 -c 'import sys; s=sys.stdin.read(); print(s[:s.rfind("RC=")].strip())'
    else
        printf '%s' "$out" | python3 -c 'import sys; s=sys.stdin.read(); print(s[:s.rfind("RC=")].rstrip())'
    fi
    if [ "$exitcode" -eq 1 ]; then
        log_advisory "FAIL" "session/guard-focus" "guidance issued (see stdout)"
    fi
    if [ "$HANDOFF" -eq 1 ]; then
        run_handoff
        return "$?"
    fi
    return "$exitcode"
}

run_handoff() {
    # The offer, executed: brief -> leak check (inside the brief) -> ledger.
    if [ -z "$SESSION" ]; then
        printf 'handoff needs --session ID\n'
        return 2
    fi
    local out="$OUTF"
    [ -n "$out" ] || out="$REPO/logs/brief-$SESSION.md"
    local hbargs
    hbargs=("$SESSION" --out "$out")
    if [ -n "$TRANSCRIPT" ]; then
        hbargs+=(--transcript "$TRANSCRIPT")
    fi
    if ! bash "$REPO/scripts/handoff-brief.sh" "${hbargs[@]}"; then
        printf 'handoff: brief failed (no transcript? run re-extract-session.sh first)\n'
        return 1
    fi
    local chars=""
    chars=$(wc -c < "$out" | tr -d ' ')
    log_advisory "PASS" "session/handoff-$SESSION" "brief ready at $out ($chars chars, redacted, leak-checked)"
    printf '\n=== handoff offer for %s ===\n' "$SESSION"
    printf 'brief: %s (%s chars, redacted, leak-checked)\n' "$out" "$chars"
    printf 'paste: open a fresh session, paste the brief, state your question\n'
    printf 'used: session-health (risks) - handoff-brief (brief+redact) - secret-scan (leak check) - ledger (this row)\n'
    printf 'the old session stays untouched; never --fork/--continue it\n'
    return 0
}

main "$@"
