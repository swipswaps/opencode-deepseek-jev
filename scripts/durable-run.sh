#!/usr/bin/env bash
#
# durable-run.sh — checkpoint / resume for multi-step shell jobs.
#
# pi-durable: "every step of a run is a task that stores a checkpoint before it
# moves on. If the process dies, a new process opens the same storage, finds the
# unfinished tasks, and continues each one from its last checkpoint."
#
# This is that pattern for shell: a job names its steps; a completed step is
# recorded durably and SKIPPED on the next run, so re-running a job after a crash
# resumes instead of repeating. State lives in a JSONL file (one line per step).
#
#   ./scripts/durable-run.sh --job NAME --step ID -- <command...>
#   ./scripts/durable-run.sh --job NAME --step ID --force -- <command...>
#   ./scripts/durable-run.sh --job NAME --status
#   ./scripts/durable-run.sh --job NAME --reset
#   ./scripts/durable-run.sh --self-test
#
# env: DURABLE_JOB_DIR (default: <repo>/data/observability/jobs)
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null. No subprocess.run.
#
set -o pipefail

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

# done? prints "1" if step already recorded ok, else "0". $1=state file $2=step
step_done() {
    [ -f "$1" ] || { printf '0'; return 0; }
    python3 - "$1" "$2" << 'PYEOF'
import json, sys
want = sys.argv[2]
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("step") == want and e.get("ok") is True:
        print("1"); sys.exit(0)
print("0")
PYEOF
}

# record $2=step $3=ok(0/1) into state file $1 (durable append)
step_record() {
    python3 - "$1" "$2" "$3" << 'PYEOF'
import json, sys, time
path, step, ok = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps({"step": step, "ok": ok, "ts": int(time.time())}) + "\n")
    fh.flush()
PYEOF
}

self_test() {
    local work fail=0
    work=$(mktemp -d) || { printf 'FAIL: mktemp\n'; return 1; }
    DURABLE_JOB_DIR="$work" bash "${BASH_SOURCE[0]}" --job t --step a -- sh -c 'printf ran > '"$work"'/a.out' >/dev/null 2>&1
    [ -f "$work/a.out" ] || { printf 'FAIL: step a did not run\n'; fail=1; }
    DURABLE_JOB_DIR="$work" bash "${BASH_SOURCE[0]}" --job t --step a -- sh -c 'printf ran2 > '"$work"'/a2.out' >/dev/null 2>&1
    [ -f "$work/a2.out" ] && { printf 'FAIL: completed step re-ran (no checkpoint)\n'; fail=1; }
    DURABLE_JOB_DIR="$work" bash "${BASH_SOURCE[0]}" --job t --step a --force -- sh -c 'printf ran3 > '"$work"'/a3.out' >/dev/null 2>&1
    [ -f "$work/a3.out" ] || { printf 'FAIL: --force did not re-run\n'; fail=1; }
    DURABLE_JOB_DIR="$work" bash "${BASH_SOURCE[0]}" --job t --step b -- sh -c 'exit 7' >/dev/null 2>&1
    [ "$?" -eq 7 ] || { printf 'FAIL: failing step did not propagate its code\n'; fail=1; }
    DURABLE_JOB_DIR="$work" bash "${BASH_SOURCE[0]}" --job t --step b -- sh -c 'printf x > '"$work"'/b2.out' >/dev/null 2>&1
    [ -f "$work/b2.out" ] || { printf 'FAIL: a failed step must be retried (not checkpointed)\n'; fail=1; }
    DURABLE_JOB_DIR="$work" bash "${BASH_SOURCE[0]}" --job t --status >/dev/null 2>&1 || { printf 'FAIL: --status\n'; fail=1; }
    printf 'durable-run: self-test %s\n' "$([ "$fail" -eq 0 ] && printf PASS || printf FAIL)"
    return "$fail"
}

main() {
    local REPO JOB="" STEP="" FORCE=0 MODE=run
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    [ -z "$REPO" ] && { printf 'GATE FAIL: cannot resolve repo root\n'; return 2; }
    local JOB_DIR="${DURABLE_JOB_DIR:-$REPO/data/observability/jobs}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --job) JOB="${2:-}"; shift 2 ;;
            --step) STEP="${2:-}"; shift 2 ;;
            --force) FORCE=1; shift ;;
            --status) MODE=status; shift ;;
            --reset) MODE=reset; shift ;;
            --self-test) self_test; return "$?" ;;
            --) shift; break ;;
            -h | --help) printf 'usage: %s --job NAME [--step ID [--force]] -- CMD | --status | --reset | --self-test\n' "$0"; return 0 ;;
            *) break ;;
        esac
    done
    [ -n "$JOB" ] || { printf 'need --job NAME\n'; return 2; }
    case "$JOB" in *[!A-Za-z0-9._-]*|"") printf 'bad job name (A-Za-z0-9._- only)\n'; return 2 ;; esac
    local STATE="$JOB_DIR/$JOB.jsonl"
    case "$MODE" in
        status)
            if [ -f "$STATE" ]; then printf '%s:\n' "$JOB"; cat "$STATE"; else printf '%s: (no checkpoints)\n' "$JOB"; fi
            return 0 ;;
        reset)
            if [ -f "$STATE" ]; then rm -f "$STATE" && printf 'reset %s\n' "$JOB"; else printf '%s: (nothing to reset)\n' "$JOB"; fi
            return 0 ;;
    esac
    [ -n "$STEP" ] || { printf 'need --step ID\n'; return 2; }
    case "$STEP" in *[!A-Za-z0-9._:-]*|"") printf 'bad step id\n'; return 2 ;; esac
    mkdir -p "$JOB_DIR" || { printf 'FAIL: cannot create %s\n' "$JOB_DIR"; return 1; }
    if [ "$FORCE" -eq 0 ] && [ "$(step_done "$STATE" "$STEP")" = "1" ]; then
        printf 'durable-run: skip (done): %s/%s\n' "$JOB" "$STEP"
        return 0
    fi
    [ $# -gt 0 ] || { printf 'need a command after --\n'; return 2; }
    printf 'durable-run: run %s/%s -> %s\n' "$JOB" "$STEP" "$1"
    "$@"
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        step_record "$STATE" "$STEP" 1
        printf 'durable-run: done %s/%s\n' "$JOB" "$STEP"
    else
        step_record "$STATE" "$STEP" 0
        printf 'durable-run: FAILED %s/%s (rc=%s); fix and re-run to resume\n' "$JOB" "$STEP" "$rc"
    fi
    return "$rc"
}

main "$@"
