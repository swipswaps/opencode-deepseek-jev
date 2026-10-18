#!/usr/bin/env bash
#
# loop-state.sh — durable checkpoint of the DEV LOOP's current segment.
#
# pi-durable: a segment that starts records a checkpoint before it moves on, so
# a fresh process (a new session after a handoff) finds the unfinished segment
# and continues — or, if it ended, SKIPS it. Built on durable-run.sh's job store
# (job `dev-loop`) rather than a second mechanism:
#   b:<slug>:<rev>          segment begun at <rev>
#   e:<slug>:<green|red>    segment ended (gate green/red)
# A slug is derived from the unit text (stable), so begin/end pair up and a
# handoff resumes the in-flight unit instead of re-deriving it from the diary.
#
#   ./scripts/loop-state.sh --begin "close telemetry residual"
#   ./scripts/loop-state.sh --end   "close telemetry residual" [--red]
#   ./scripts/loop-state.sh --show [--json]
#   ./scripts/loop-state.sh --self-test
#
# Env: DURABLE_JOB_DIR (default <repo>/data/observability/jobs).
# Exit 0 always (guidance/state); 2 usage/resolve error.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No top-level exit. No 2>/dev/null.
# No subprocess.run. No bare kill. printf only. main() wrapper.
#
set -o pipefail

JSON=0
MODE=""
UNIT=""
RED=0
SELFTEST=0

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

slug() {
    # slug "some unit text" -> some-unit-text (lowercase, runs of non-alnum -> -)
    printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | cut -c1-48
}

show_state() {
    # show_state JOB_DIR — read the job's JSONL, print in-flight + last done.
    LOOP_JOB_DIR="$1" LOOP_JSON="$JSON" python3 - <<'PY'
import json, os

jd = os.environ["LOOP_JOB_DIR"]
as_json = os.environ.get("LOOP_JSON") == "1"
path = os.path.join(jd, "dev-loop.jsonl")
begins, ends = {}, {}
if os.path.exists(path):
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        step = str(e.get("step", ""))
        if step.startswith("b:") and e.get("ok"):
            parts = step.split(":")
            if len(parts) >= 3:
                begins[parts[1]] = {"unit": parts[1], "rev": parts[2], "ts": e.get("ts")}
        elif step.startswith("e:") and e.get("ok"):
            parts = step.split(":")
            if len(parts) >= 2:
                ends[parts[1]] = {"gate": (parts[2] if len(parts) > 2 else "green"), "ts": e.get("ts")}
inflight = [b for s, b in begins.items() if s not in ends]
inflight.sort(key=lambda x: x.get("ts") or 0)
cur = inflight[-1] if inflight else None
done = None
if ends:
    lid = max(ends, key=lambda s: ends[s].get("ts") or 0)
    done = {"unit": lid, "gate": ends[lid]["gate"], "ts": ends[lid]["ts"]}
out = {"in_flight": cur, "last_done": done, "n_in_flight": len(inflight)}
if as_json:
    print(json.dumps(out))
else:
    if cur:
        print("in-flight: %s (begun at %s)" % (cur["unit"], cur["rev"]))
        print("resume this unit, or `loop-state.sh --end \"%s\"` when its gate is green + committed" % cur["unit"])
    else:
        print("in-flight: (none)")
    if done:
        print("last done: %s [%s]" % (done["unit"], done["gate"]))
PY
}

self_test() {
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    local work fail=0
    work=$(mktemp -d)
    local SELF
    SELF="${BASH_SOURCE[0]}"
    local o=""
    DURABLE_JOB_DIR="$work" bash "$SELF" --begin "Fix the widget" > /dev/null 2>&1
    o=$(DURABLE_JOB_DIR="$work" bash "$SELF" --show --json 2>&1)
    printf '%s' "$o" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["in_flight"] and d["in_flight"]["unit"]=="fix-the-widget", d; assert d["n_in_flight"]==1' \
        || { printf 'FAIL begin/show in-flight\n'; fail=1; }
    DURABLE_JOB_DIR="$work" bash "$SELF" --end "Fix the widget" > /dev/null 2>&1
    o=$(DURABLE_JOB_DIR="$work" bash "$SELF" --show --json 2>&1)
    printf '%s' "$o" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["in_flight"] is None, d; assert d["last_done"]["unit"]=="fix-the-widget" and d["last_done"]["gate"]=="green", d' \
        || { printf 'FAIL end/show done\n'; fail=1; }
    DURABLE_JOB_DIR="$work" bash "$SELF" --begin "Second unit" > /dev/null 2>&1
    DURABLE_JOB_DIR="$work" bash "$SELF" --end "Second unit" --red > /dev/null 2>&1
    o=$(DURABLE_JOB_DIR="$work" bash "$SELF" --show --json 2>&1)
    printf '%s' "$o" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["last_done"]["gate"]=="red", d' \
        || { printf 'FAIL red gate end\n'; fail=1; }
    o=$(DURABLE_JOB_DIR="$work" bash "$SELF" --show 2>&1)
    printf '%s' "$o" | grep -q 'last done: second-unit \[red\]' || { printf 'FAIL text show\n'; fail=1; }
    # E3: a second LIVE session cannot begin while the lease is held.
    LOOP_LOCK_ACTOR=live1 DURABLE_JOB_DIR="$work" bash "$SELF" --begin "Locked unit" > /dev/null 2>&1
    LOOP_LOCK_ACTOR=live2 DURABLE_JOB_DIR="$work" bash "$SELF" --begin "Other session" > /dev/null 2>&1
    [ "$?" -eq 3 ] || { printf 'FAIL concurrent begin not refused (rc=%s)\n' "$?"; fail=1; }
    LOOP_LOCK_ACTOR=live1 DURABLE_JOB_DIR="$work" bash "$SELF" --end "Locked unit" > /dev/null 2>&1
    rm -f "$work/dev-loop.jsonl" "$work/dev-loop.lock" "$work/dev-loop.lock.flock"
    rmdir "$work"
    if [ "$fail" -eq 0 ]; then printf 'loop-state: self-test PASS\n'; else printf 'loop-state: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --begin) MODE=begin; UNIT="${2:-}"; shift 2 ;;
            --end) MODE=end; UNIT="${2:-}"; shift 2 ;;
            --show) MODE=show; shift ;;
            --json) JSON=1; shift ;;
            --red) RED=1; shift ;;
            --self-test) SELFTEST=1; shift ;;
            -h | --help) printf 'usage: %s --begin UNIT | --end UNIT [--red] | --show [--json] | --self-test\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    if [ -z "$MODE" ]; then printf 'usage: %s --begin UNIT | --end UNIT [--red] | --show [--json] | --self-test\n' "$0"; return 2; fi
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 2; }

    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    local JOB_DIR="${DURABLE_JOB_DIR:-$REPO/data/observability/jobs}"
    local DUR="$REPO/scripts/durable-run.sh"

    case "$MODE" in
        begin)
            [ -n "$UNIT" ] || { printf 'need a unit text\n'; return 2; }
            local rev slugid LOCK acquired
            LOCK="${LOOP_LOCK_FILE:-$JOB_DIR/dev-loop.lock}"
            # E3: only one live session may own the dev loop. A busy lease
            # refuses the begin (never silently clobbers another's segment).
            if ! acquired=$(LOOP_LOCK_FILE="$LOCK" bash "$REPO/scripts/loop-lock.sh" --acquire --unit "$UNIT" 2>&1); then
                printf '%s\n' "$acquired"
                printf 'loop-state: refused — dev loop is locked by another live session\n'
                return 3
            fi
            rev=$(git -C "$REPO" rev-parse --short HEAD 2>&1 || printf 'unknown')
            slugid=$(slug "$UNIT")
            DURABLE_JOB_DIR="$JOB_DIR" bash "$DUR" --job dev-loop --step "b:$slugid:$rev" -- true > /dev/null 2>&1 || true
            printf 'loop-state: in-flight %s (at %s)\n' "$slugid" "$rev"
            ;;
        end)
            [ -n "$UNIT" ] || { printf 'need a unit text\n'; return 2; }
            local gate slugid2 LOCK2
            LOCK2="${LOOP_LOCK_FILE:-$JOB_DIR/dev-loop.lock}"
            LOOP_LOCK_FILE="$LOCK2" bash "$REPO/scripts/loop-lock.sh" --release > /dev/null 2>&1 || true
            gate="green"; [ "$RED" -eq 1 ] && gate="red"
            slugid2=$(slug "$UNIT")
            DURABLE_JOB_DIR="$JOB_DIR" bash "$DUR" --job dev-loop --step "e:$slugid2:$gate" -- true > /dev/null 2>&1 || true
            printf 'loop-state: ended %s [%s]\n' "$slugid2" "$gate"
            ;;
        show)
            show_state "$JOB_DIR"
            ;;
    esac
    return 0
}

main "$@"
