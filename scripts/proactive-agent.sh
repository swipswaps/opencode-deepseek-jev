#!/usr/bin/env bash
#
# proactive-agent.sh — turn NEW alerts into owned tasks + a durable digest.
#
# The loop already detects (sentinel, progress-review), acts on a budget STOP
# (auto-handoff), and refreshes derived state (fts-refresh). What it lacked was
# a consumer that turns NEW ADVISORY rows into owned work and writes one brief:
# that is this agent. It is read-only against the stores (the opencode DB is
# never written) and writes only the ledger, task rows and a JSON digest.
#
#   ./scripts/proactive-agent.sh            # --once (default)
#   ./scripts/proactive-agent.sh --self-test
#
# Cursor-bounded: the first run records the newest alert timestamp and creates
# NO tasks (a bootstrap, so 58 historical rows do not flood the queue). Later
# runs register at most PROACTIVE_MAX_NEW (default 10) NEW alerts as tasks
# (owner `proactive`, idempotent by title). A preflight STOP runs auto-handoff
# and records the STOP; it never spends.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null. No subprocess.run.
# printf only. main() wrapper.
#
set -o pipefail

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

have() { command -v "$1" >/dev/null 2>&1; }

self_test() {
    local fail=0 work=""
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    work=$(mktemp -d)
    local alerts=""
    alerts='{"alerts":[{"kind":"slow_fetch","sev":"high","resource":"GET /api/x","last":"2026-10-20T00:00:00Z"},{"kind":"old","sev":"low","resource":"GET /api/old","last":"2026-10-18T00:00:00Z"}]}'
    printf '%s' '2026-10-19T00:00:00Z' > "$work/cur"
    PROACTIVE_ALERTS_JSON="$alerts" \
    PROACTIVE_NEXT_JSON='{"next":{"text":"TUNNEL-1"},"blockers":[],"external":[]}' \
    PROACTIVE_SKIP_PREFLIGHT=1 PROACTIVE_OUT="$work/out.json" PROACTIVE_CURSOR="$work/cur" \
    LEDGER_DB="$work/obs.db" bash "${BASH_SOURCE[0]}" --once > "$work/run1.txt" 2>&1 \
        || { printf 'FAIL first run\n'; fail=1; }
    [ -f "$work/out.json" ] || { printf 'FAIL digest missing\n'; fail=1; }
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("tasks_created")==1 and d.get("new_alerts")==1 else 1)' "$work/out.json" \
        || { printf 'FAIL new alert/task count\n'; fail=1; }
    LEDGER_DB="$work/obs.db" python3 "$REPO/scripts/task-id.py" list --all 2>&1 | grep -q 'proactive: slow_fetch GET /api/x' \
        || { printf 'FAIL task not registered\n'; fail=1; }
    PROACTIVE_ALERTS_JSON="$alerts" \
    PROACTIVE_NEXT_JSON='{"next":{"text":"TUNNEL-1"},"blockers":[],"external":[]}' \
    PROACTIVE_SKIP_PREFLIGHT=1 PROACTIVE_OUT="$work/out2.json" PROACTIVE_CURSOR="$work/cur" \
    LEDGER_DB="$work/obs.db" bash "${BASH_SOURCE[0]}" --once > "$work/run2.txt" 2>&1 \
        || { printf 'FAIL second run\n'; fail=1; }
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("tasks_created")==0 else 1)' "$work/out2.json" \
        || { printf 'FAIL cursor did not dedupe\n'; fail=1; }
    # bootstrap: no cursor -> no historical tasks, cursor set.
    rm -f "$work/cur"
    PROACTIVE_ALERTS_JSON="$alerts" PROACTIVE_NEXT_JSON='{}' PROACTIVE_SKIP_PREFLIGHT=1 \
    PROACTIVE_OUT="$work/out3.json" PROACTIVE_CURSOR="$work/cur" LEDGER_DB="$work/obs.db" \
    bash "${BASH_SOURCE[0]}" --once > "$work/run3.txt" 2>&1 || { printf 'FAIL bootstrap run\n'; fail=1; }
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("tasks_created")==0 else 1)' "$work/out3.json" \
        || { printf 'FAIL bootstrap created tasks\n'; fail=1; }
    [ -s "$work/cur" ] || { printf 'FAIL bootstrap cursor\n'; fail=1; }
    LEDGER_DB="$work/obs.db" python3 "$REPO/scripts/ledger.py" show --grep proactive 2>&1 | grep -q 'PROACTIVE' \
        || { printf 'FAIL ledger row\n'; fail=1; }
    rm -f "$work/obs.db" "$work/out.json" "$work/out2.json" "$work/out3.json" "$work/cur" \
        "$work/run1.txt" "$work/run2.txt" "$work/run3.txt"
    rmdir "$work"
    if [ "$fail" -eq 0 ]; then printf 'proactive-agent: self-test PASS\n'; else printf 'proactive-agent: self-test FAIL\n'; fi
    return "$fail"
}

once() {
    local REPO="$1" work="" verdict="PASS" pre="preflight READY" nnew=0
    work=$(mktemp -d)
    local RUN_TS=""
    RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
    local CURSOR="${PROACTIVE_CURSOR:-$REPO/data/observability/proactive.cursor}"
    local OUT="${PROACTIVE_OUT:-$REPO/data/observability/proactive.json}"
    local MAX_NEW="${PROACTIVE_MAX_NEW:-10}"

    if [ "${PROACTIVE_SKIP_PREFLIGHT:-0}" != "1" ] && [ -x "$REPO/scripts/preflight.sh" ]; then
        local prc=0
        bash "$REPO/scripts/preflight.sh" --json > "$work/pre.json" 2>&1 || prc=$?
        if [ "$prc" -ne 0 ]; then
            verdict="STOP"
            bash "$REPO/scripts/auto-handoff.sh" > "$work/handoff.txt" 2>&1 || true
            pre="preflight STOP; auto-handoff $(tail -n 1 "$work/handoff.txt")"
        fi
    fi

    if [ -n "${PROACTIVE_ALERTS_JSON:-}" ]; then
        printf '%s' "$PROACTIVE_ALERTS_JSON" > "$work/alerts.json"
    else
        python3 "$REPO/scripts/triage-alerts.py" --json > "$work/alerts.json" 2> "$work/alerts.err" || true
    fi
    if [ -n "${PROACTIVE_NEXT_JSON:-}" ]; then
        printf '%s' "$PROACTIVE_NEXT_JSON" > "$work/next.json"
    else
        bash "$REPO/scripts/next-action.sh" --json > "$work/next.json" 2> "$work/next.err" || true
    fi

    python3 - "$work/alerts.json" "$CURSOR" "$MAX_NEW" "$work" << 'PYEOF'
import json, os, sys
ap, cursor, maxn, work = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
try:
    d = json.load(open(ap))
except Exception:
    d = {}
alerts = d.get("alerts", []) if isinstance(d, dict) else []
lasts = [a.get("last", "") for a in alerts if a.get("last")]
newest = max(lasts) if lasts else ""
try:
    cur = open(cursor).read().strip()
except OSError:
    cur = ""
if not cur:
    selected = []                      # bootstrap: never flood on history
else:
    selected = [a for a in alerts if a.get("last", "") and a.get("last", "") > cur]
sev = {"critical": 0, "high": 1, "medium": 2, "low": 3}
selected.sort(key=lambda a: (sev.get(a.get("sev", ""), 9), a.get("last", "")))
selected = selected[:maxn]
with open(os.path.join(work, "new.tsv"), "w") as fh:
    for a in selected:
        fh.write("%s\t%s\n" % (a.get("kind", "alert"), a.get("resource", "")))
if newest and newest > cur:
    os.makedirs(os.path.dirname(cursor) or ".", exist_ok=True)
    open(cursor, "w").write(newest)
json.dump({"selected": len(selected), "newest": newest, "cursor_before": cur},
          open(os.path.join(work, "sel.json"), "w"))
PYEOF

    if [ -s "$work/new.tsv" ]; then
        local kind="" resource=""
        while IFS=$'\t' read -r kind resource; do
            [ -n "$kind" ] || continue
            python3 "$REPO/scripts/task-id.py" new --title "proactive: $kind $resource" --owner proactive > /dev/null 2>&1 || true
            nnew=$((nnew + 1))
        done < "$work/new.tsv"
    fi
    [ "$verdict" = "STOP" ] || { [ "$nnew" -gt 0 ] && verdict="ATTENTION"; }

    python3 - "$work/next.json" "$work/sel.json" "$OUT" "$nnew" "$verdict" "$pre" << 'PYEOF'
import datetime, json, os, sys
nextp, selp, outp, nnew, verdict, pre = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], sys.argv[6]
try:
    nx = json.load(open(nextp))
except Exception:
    nx = {}
try:
    sel = json.load(open(selp))
except Exception:
    sel = {}
d = {"ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
     "verdict": verdict, "preflight": pre,
     "new_alerts": sel.get("selected", 0), "tasks_created": nnew,
     "next": nx.get("next"), "blockers": nx.get("blockers", []),
     "external": nx.get("external", [])}
os.makedirs(os.path.dirname(outp) or ".", exist_ok=True)
tmp = outp + ".tmp"
json.dump(d, open(tmp, "w"), indent=1)
os.replace(tmp, outp)
PYEOF

    python3 "$REPO/scripts/ledger.py" record --type PROACTIVE --actor proactive-agent \
        --tool proactive --resource "loop" --verdict "$verdict" \
        --detail "new_alerts=$nnew; $pre" --source proactive-agent \
        --key "proactive-$RUN_TS-$$" > /dev/null 2>&1 || true

    printf 'proactive: %s; new alerts=%s; tasks registered=%s\n' "$verdict" "${nnew}" "${nnew}"
    printf 'digest: %s\n' "$OUT"
    python3 - "$OUT" << 'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
n = d.get("next") or {}
t = n.get("text") if isinstance(n, dict) else str(n)
print("next: %s" % (t or "(none)"))
if d.get("blockers"):
    print("blockers: " + ", ".join(str(b) for b in d["blockers"]))
if d.get("external"):
    print("external: " + ", ".join(str(e.get("resource", e)) for e in d["external"]))
PYEOF
    rm -f "$work/pre.json" "$work/handoff.txt" "$work/alerts.json" "$work/alerts.err" \
        "$work/next.json" "$work/next.err" "$work/new.tsv" "$work/sel.json"
    rmdir "$work"
    [ "$verdict" = "STOP" ] && return 3
    return 0
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    case "${1:-}" in
        ""|--once) once "$REPO"; return "$?" ;;
        --self-test) self_test; return "$?" ;;
        -h|--help) printf 'usage: %s [--once|--self-test]\n' "$0"; return 0 ;;
        *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
    esac
}

main "$@"
