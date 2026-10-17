#!/usr/bin/env bash
#
# progress-review.sh — periodic supervisor of the DEV LOOP's progression.
#
# The sentinel watches session/model health (cost, stalls, gateway). This is its
# sibling for pi-durable's other half: is the *loop* still advancing? One sweep
# reads `next-action.sh` (rev, last gate, next unit, blockers), compares it to
# the previous sweep, and:
#   - ADVANCE: rev or gate advanced since the last sweep -> one durable PASS row
#     (the progression is recorded, not just felt).
#   - STALL:   no rev/gate advance for PROGRESS_STALL_TICKS sweeps -> one durable
#     FAIL row with the next unit + blockers (a stalled loop is news).
#   - INIT/QUIET: first sweep initialises silently; a single unchanged tick is
#     not yet a stall. Only news trips (the sentinel's cry-wolf doctrine).
#
# Stable per-incident keys (`progress-advance-<rev>` / `progress-stall-<rev>`)
# mean a persisting condition is ONE ledger row (UNIQUE(source,key)), never one
# per sweep. Read-only except the ledger and a small state file.
#
#   ./scripts/progress-review.sh [--once] [--json] [--no-log] [--self-test]
#
# Env seams: PROGRESS_STATE (state file), PROGRESS_STALL_TICKS (default 2),
# LEDGER_DB, NEXT_ACTION_REPO (forwarded). Install: ./scripts/progress-review-install.sh.
# Exit 0 clean/quiet, 1 stalled, 2 usage/resolve error.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No top-level exit. No 2>/dev/null.
# No subprocess.run. No bare kill. printf only. main() wrapper.
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

log_row() {
    # log_row VERDICT DETAIL KEY RESOURCE — guarded, never fails the sweep.
    [ "$DOLOG" -eq 1 ] || return 0
    have python3 || return 0
    python3 "$REPO/scripts/ledger.py" record --type ADVISORY \
        --actor progress-review --tool progress-review --resource "$4" \
        --verdict "$1" --detail "$2" --rev "$REV" \
        --source progress-review --key "$3" \
        > /dev/null 2>&1 || true
    return 0
}

decide() {
    # decide STALL_TICKS REPO TMPFILE — reads next-action + prior state,
    # writes the new state, prints the decision JSON. One python pass.
    NEXT_ACTION_REPO="${NEXT_ACTION_REPO:-$2}" \
    bash "$REPO/scripts/next-action.sh" --json > "$3" 2>&1 || true
    NA_STATE="$3" PROGRESS_STATE="$STATE" PROGRESS_STALL_TICKS="$1" \
    python3 - <<'PY'
import json, os, datetime

na = {}
try:
    na = json.load(open(os.environ["NA_STATE"]))
except Exception:
    na = {}
stall_ticks = int(os.environ.get("PROGRESS_STALL_TICKS", "2") or 2)
state_path = os.environ["PROGRESS_STATE"]

rev = str(na.get("rev", "?"))
gate = (na.get("last_gate") or {})
gate_ts = str(gate.get("ts", ""))
next_txt = (na.get("next") or {}).get("text") or ""
blockers = na.get("blockers") or []
since = na.get("since_gate") or {}

prev = {}
try:
    prev = json.load(open(state_path))
except Exception:
    prev = {}

first = not prev
advanced = (not first) and (rev != str(prev.get("rev", "")) or gate_ts != str(prev.get("gate_ts", "")))
if first:
    ticks = 0
elif advanced:
    ticks = 0
else:
    ticks = int(prev.get("unchanged_ticks", 0)) + 1

if first:
    decision = "init"
elif advanced:
    decision = "advance"
elif ticks >= stall_ticks:
    decision = "stall"
else:
    decision = "quiet"

ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
os.makedirs(os.path.dirname(state_path), exist_ok=True)
json.dump({"ts": ts, "rev": rev, "gate_ts": gate_ts, "unchanged_ticks": ticks}, open(state_path, "w"), indent=2)

if decision == "stall":
    detail = "dev loop stalled: no rev/gate advance for %d sweep(s) (rev %s). next: %s" % (ticks, rev, next_txt or "(none)")
    if blockers:
        detail += " | blockers: " + "; ".join(blockers)
    verdict, key = "FAIL", "progress-stall-" + rev
elif decision == "advance":
    n = since.get("n_commits", 0)
    detail = "loop advanced: rev %s (+%s commit(s) since gate, %s event(s))" % (rev, n, since.get("events", 0))
    verdict, key = "PASS", "progress-advance-" + rev
else:
    verdict, key = "", ""

print(json.dumps({"ts": ts, "rev": rev, "decision": decision, "ticks": ticks,
                  "gate_ts": gate_ts, "next": next_txt, "blockers": blockers,
                  "verdict": verdict, "detail": detail if verdict else "",
                  "key": key, "stall_ticks": stall_ticks}))
PY
}

self_test() {
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    have git || { printf 'FAIL git missing\n'; return 1; }
    local work fail=0
    work=$(mktemp -d)
    mkdir -p "$work/repo/docker" "$work/repo/data/observability" "$work/state" || { printf 'FAIL mkdir\n'; return 1; }
    printf '%s\n' '{}' > "$work/repo/opencode.json"
    printf '%s\n' 'FROM scratch' > "$work/repo/docker/Dockerfile"
    printf '%s\n' '# TODO' '' '## Queue (ranked, top first)' '' '- [ ] UNIT-A' > "$work/repo/TODO.md"
    printf '%s\n' '{"ts":"20260101T000000Z","passed":3,"failed":0}' > "$work/repo/data/observability/last-gate.json"
    printf '%s\n' '{"tier1_tokens":100,"budget":35000,"over":0}' > "$work/repo/data/observability/docs.json"
    git -C "$work/repo" init -q && git -C "$work/repo" add -A && git -C "$work/repo" -c user.email=t@t -c user.name=t commit -qm init
    local S="$work/state/p.json" L="$work/obs.db" N="$work/repo"
    local o=""
    # tick 1: init (no trip)
    o=$(NEXT_ACTION_REPO="$N" LEDGER_DB="$L" PROGRESS_STATE="$S" PROGRESS_STALL_TICKS=2 bash "${BASH_SOURCE[0]}" --once --no-log --json 2>&1)
    printf '%s' "$o" | grep -q '"decision": "init"' || { printf 'FAIL tick1 init\n'; fail=1; }
    # tick 2: one quiet tick (no trip)
    o=$(NEXT_ACTION_REPO="$N" LEDGER_DB="$L" PROGRESS_STATE="$S" PROGRESS_STALL_TICKS=2 bash "${BASH_SOURCE[0]}" --once --no-log --json 2>&1)
    printf '%s' "$o" | grep -q '"decision": "quiet"' || { printf 'FAIL tick2 quiet\n'; fail=1; }
    # tick 3: stall trips
    NEXT_ACTION_REPO="$N" LEDGER_DB="$L" PROGRESS_STATE="$S" PROGRESS_STALL_TICKS=2 bash "${BASH_SOURCE[0]}" --once --no-log --json > "$work/t3.txt" 2>&1
    [ "$?" -eq 1 ] || { printf 'FAIL tick3 exit 1\n'; fail=1; }
    grep -q '"decision": "stall"' "$work/t3.txt" || { printf 'FAIL tick3 stall\n'; fail=1; }
    # a commit advances -> PASS row, ticks reset
    printf 'x\n' > "$work/repo/NEW"; git -C "$work/repo" add -A && git -C "$work/repo" -c user.email=t@t -c user.name=t commit -qm advance
    o=$(NEXT_ACTION_REPO="$N" LEDGER_DB="$L" PROGRESS_STATE="$S" PROGRESS_STALL_TICKS=2 bash "${BASH_SOURCE[0]}" --once --json 2>&1)
    printf '%s' "$o" | grep -q '"decision": "advance"' || { printf 'FAIL advance\n'; fail=1; }
    LEDGER_DB="$L" python3 "$REPO/scripts/ledger.py" show --grep progress 2>&1 | grep -q 'ADVISORY' || { printf 'FAIL ledger rows\n'; fail=1; }
    rm -f "$work/repo/NEW" "$work/repo/TODO.md" "$work/repo/opencode.json" "$work/repo/docker/Dockerfile" "$work/repo/data/observability/last-gate.json" "$work/repo/data/observability/docs.json" "$work/state/p.json" "$work/t3.txt" "$work/obs.db"
    rm -r "$work/repo/.git"
    rmdir "$work/repo/data/observability" "$work/repo/data" "$work/repo/docker" "$work/repo" "$work/state" "$work"
    if [ "$fail" -eq 0 ]; then printf 'progress-review: self-test PASS\n'; else printf 'progress-review: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    local ONCE=1 JSON=0 DOLOG=1 SELFTEST=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --once) ONCE=1; shift ;;
            --json) JSON=1; shift ;;
            --no-log) DOLOG=0; shift ;;
            --self-test) SELFTEST=1; shift ;;
            -h | --help) printf 'usage: %s [--once] [--json] [--no-log] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    [ "$ONCE" -eq 1 ] || { printf 'usage: periodic runs go through the systemd timer\n'; return 2; }
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 2; }
    have node || { printf 'GATE FAIL: node required\n'; return 2; }

    STATE="${PROGRESS_STATE:-$REPO/data/observability/.watch/progress-review.json}"
    export STATE REPO DOLOG
    REV=$(git -C "$REPO" rev-parse --short HEAD 2>&1 || printf 'unknown')
    export REV
    local TICKS="${PROGRESS_STALL_TICKS:-2}"
    local tmp="" out=""
    tmp=$(mktemp)
    out=$(decide "$TICKS" "$REPO" "$tmp")
    rm -f "$tmp"
    [ -n "$out" ] || { printf 'FAIL: no decision\n'; return 2; }

    local decision verdict detail key
    decision=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["decision"])')
    verdict=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])')
    detail=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["detail"])')
    key=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')

    if [ "$decision" = "advance" ] || [ "$decision" = "stall" ]; then
        log_row "$verdict" "$detail" "$key" "loop/progress-review"
    fi

    if [ "$JSON" -eq 1 ]; then
        printf '%s\n' "$out"
    else
        printf '=== progress-review @ %s ===\n' "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ts"])')"
        case "$decision" in
            init) printf 'init: first sweep, baseline recorded (no trip)\n' ;;
            quiet) printf 'quiet: no rev/gate advance this sweep (%s tick(s); stall at %s)\n' \
                "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticks"])')" \
                "$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["stall_ticks"])')" ;;
            advance) printf 'ADVANCE: %s\n' "$detail" ;;
            stall) printf 'STALL: %s\n' "$detail"
                printf 'run ./scripts/next-action.sh for the verdict\n' ;;
        esac
    fi

    if [ "$decision" = "stall" ] && [ -n "${NOTIFY_WEBHOOK:-}" ] && [ -x "$REPO/scripts/notify.sh" ]; then
        "$REPO/scripts/notify.sh" --last 20 || printf 'WARN: notify.sh post failed\n'
    fi
    [ "$decision" = "stall" ] && return 1
    return 0
}

main "$@"
