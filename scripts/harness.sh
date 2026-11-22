#!/usr/bin/env bash
#
# harness.sh — one command for the whole state of the harness.
#
# Radical on purpose: instead of remembering which gate to run, it runs them
# all, catches failures without stopping (robust), prints the live telemetry
# (guard actions + tool errors), the cost headline, and the in-flight queue,
# and can write a timestamped report beside the run (redundant record).
#
#   ./scripts/harness.sh            # all gates + telemetry + todo
#   ./scripts/harness.sh --fast     # skip the slow dashboard gate
#   ./scripts/harness.sh --export   # also write logs/harness-<UTC>.md
#   ./scripts/harness.sh --json     # machine output only: {ts,rev,passed,failed,gates[]}
#   ./scripts/harness.sh --keep-work  # keep per-gate logs even on success
#   HEARTBEAT=10 ./scripts/harness.sh # heartbeat seconds (0 = quiet)
#   HARNESS_REPO=/other ./scripts/harness.sh --fast  # gate ANOTHER repo with
#       this script, gate-bound.py, ledger.py and lib/ (the marker check is
#       bypassed; gates are /other/scripts/{lint,test-hygiene,...}.sh)
#   HARNESS_STATE=/tmp/st ./scripts/harness.sh       # write verdicts outside a
#       read-only target (default: inside the gated repo, which preflight reads)
#
# Every gate runs under a MEASURED bound (scripts/gate-bound.py: p95*2, floor
# 120s, disclosed 1800s ceiling until 3 samples; GATE_TIMEOUT overrides) and
# prints a live heartbeat, so silence now has context. Bounds are per
# environment: a sandbox/container sample never teaches the host's deadline,
# and untagged legacy samples are ignored. Only PASSING runs seed the bound; a
# failed or timed-out run is never a timing sample. A timeout fails only
# that gate and keeps its log.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

FAST=0
EXPORT=0
JSON=0
KEEP_WORK=0
HEARTBEAT="${HEARTBEAT:-10}"
FAILED_GATES=0
PASS_GATES=0
GATE_JSON=""
FAILED_NAMES=""
CURRENT_GATE=""
TS=""
REV=""
TOOLHOME=""
STATE=""
GATE_ENV=""

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
log_line() { [ "$JSON" -eq 1 ] || printf 'ts=%s level=%s status=%s %s\n' "$(date -u +%H:%M:%S)" "$1" "$2" "$3"; }
ok()   { log_line INFO PASS "$1"; }
bad()  { log_line ERROR FAIL "$1"; }
skip() { log_line WARN SKIP "$1"; }
run()  { log_line INFO RUN "$1"; }
section() { [ "$JSON" -eq 1 ] || printf '\n=== %s ===\n' "$1"; }

# A killed run must not leave GATE_START with no verdict (last-gate.json would
# otherwise keep advertising the previous run as current).
abort_run() {
    local sig="$1"
    trap - INT TERM
    if [ -n "$CURRENT_GATE" ]; then
        if have python3 && [ -f "$TOOLHOME/ledger.py" ]; then
            LEDGER_DB="${LEDGER_DB:-$STATE/data/observability/observability.db}" \
                python3 "$TOOLHOME/ledger.py" record --type GATE_ABORT \
                --actor harness.sh --verdict ABORT \
                --detail "gate=$CURRENT_GATE signal=$sig" --rev "$REV" \
                --source harness.sh --key "gate-$TS-abort-$CURRENT_GATE" 2>&1 \
                || printf 'ledger: GATE_ABORT record failed (non-fatal)\n'
        fi
        mkdir -p "$STATE/data/observability" "$STATE/logs"
        printf '{"ts":"%s","passed":%d,"failed":%d,"state":"aborted","gate":"%s"}\n' \
            "$TS" "$PASS_GATES" "$FAILED_GATES" "$CURRENT_GATE" \
            > "$STATE/data/observability/last-gate.json"
        {
            printf '# gate abort ts=%s gate=%s signal=%s\n' "$TS" "$CURRENT_GATE" "$sig"
            tail -n 20 "$WORK/$CURRENT_GATE.log" 2>&1
            printf '\n'
        } >> "$STATE/logs/harness-failures.log"
        printf 'harness: aborted gate=%s signal=%s; workdir kept: %s\n' \
            "$CURRENT_GATE" "$sig" "$WORK"
    fi
    exit 130
}

run_gate() {
    local name="$1" script="$REPO/scripts/$1.sh" out="$WORK/$1.log"
    local rc=0 res="" bound=0 basis="none" timed=0 start elapsed pid style=none state
    if [ ! -f "$script" ]; then
        skip "gate $name (missing $name.sh)"
        return 0
    fi

    if have python3 && [ -f "$TOOLHOME/gate-bound.py" ]; then
        local b
        b=$(python3 "$TOOLHOME/gate-bound.py" --gate "$name" --env "$GATE_ENV" 2>&1)
        bound=$(printf '%s' "$b" | awk '{ for (i = 1; i <= NF; i++) if (index($i, "bound=") == 1) { sub("bound=", "", $i); printf "%s", $i } }')
        basis=$(printf '%s' "$b" | awk '{ for (i = 1; i <= NF; i++) if (index($i, "basis=") == 1) { sub("basis=", "", $i); printf "%s", $i } }')
    fi
    case "$bound" in ''|*[!0-9]*) bound=0 ;; esac
    [ -n "$basis" ] || basis=none
    [ "$JSON" -eq 0 ] && style=harness

    run "gate $name start bound=${bound}s basis=$basis env=$GATE_ENV"
    CURRENT_GATE="$name"
    start=$(date +%s)
    timeout "$bound" "$script" > "$out" 2>&1 &
    pid=$!
    if [ "$(type -t hb_watch)" = "function" ]; then
        hb_watch "$pid" "$out" "$bound" "$name" "$style" "$HEARTBEAT"
    else
        while [ -d "/proc/$pid" ]; do
            state=$(awk '{ sub(/^[^)]*\) /, ""); printf "%s", $1 }' "/proc/$pid/stat" 2>&1)
            [ "$state" = "Z" ] && break
            sleep 1
        done
    fi
    wait "$pid"
    rc=$?
    elapsed=$(( $(date +%s) - start ))
    CURRENT_GATE=""

    if [ "$rc" -eq 124 ]; then
        timed=1
        res="TIMEOUT bound=${bound}s basis=$basis"
        FAILED_GATES=$((FAILED_GATES + 1))
        bad "gate $name TIMEOUT after ${elapsed}s (bound=${bound}s basis=$basis)"
        if [ "$JSON" -eq 0 ]; then
            printf -- '--- last 20 lines (%s) ---\n' "$out"
            tail -n 20 "$out"
            printf 'next: run ./scripts/diag-harness-stall.sh while live, or set GATE_TIMEOUT=%ss from the basis above\n' "$((bound * 2))"
        fi
    else
        res=$(grep -E '^=== (lint )?result:' "$out" | tail -1)
        res=${res//\"/}
        res=${res//\\/}
        if [ "$rc" -eq 0 ]; then
            PASS_GATES=$((PASS_GATES + 1))
            ok "gate $name pass  $res"
            # Learn the bound only from PASSES. Recording a failed run lets a
            # failure teach the deadline (e.g. a 178s failure would become the
            # p95 sample), which defeats the measurement it is meant to be.
            if have python3 && [ -f "$TOOLHOME/gate-bound.py" ]; then
                python3 "$TOOLHOME/gate-bound.py" --gate "$name" --record "$elapsed" --env "$GATE_ENV" 2>&1 \
                    | awk '{ print "timing: " $0 }' || printf 'timing: record failed (non-fatal)\n'
            fi
        else
            FAILED_GATES=$((FAILED_GATES + 1))
            bad "gate $name FAIL  $res"
            # A failed run is NOT a timing sample; say so instead of silently
            # dropping it, so "why is my bound still based on n=2?" is answerable.
            printf 'timing: gate %s FAILED after %ss; not recorded (pass-only samples)\n' \
                "$name" "$elapsed"
            if [ "$JSON" -eq 0 ]; then
                grep -E 'status=FAIL' "$out" | head -6
            fi
        fi
    fi
    local sep=""
    # Failure evidence must outlive the host/container /tmp split: keep the
    # failing CHECKS (status=FAIL lines) and the tail in the repo, which both
    # sides mount. The tail alone can be 30 all-PASS lines — the 2026-11-15
    # host run recorded the gate name but not which check failed.
    if [ "$rc" -ne 0 ]; then
        FAILED_NAMES="$FAILED_NAMES $name"
        mkdir -p "$REPO/logs"
        local fail_lines
        fail_lines=$(grep -E 'status=FAIL' "$out" | head -n 12)
        {
            printf '# gate failure ts=%s gate=%s rc=%s elapsed=%ss bound=%ss basis=%s\n' \
                "$TS" "$name" "$rc" "$elapsed" "$bound" "$basis"
            if [ -n "$fail_lines" ]; then
                printf '%s\n' "$fail_lines"
            else
                printf '(no status=FAIL line in gate output; tail follows)\n'
            fi
            printf '%s\n' '--- tail ---'
            tail -n 30 "$out"
            printf '\n'
        } >> "$STATE/logs/harness-failures.log"
        if [ -n "$fail_lines" ]; then
            printf 'failed check: %s\n' "$(printf '%s\n' "$fail_lines" | head -n 1)"
        else
            printf 'failed check: not named in gate output; see logs/harness-failures.log\n'
        fi
    fi
    [ -n "$GATE_JSON" ] && sep=","
    GATE_JSON="$GATE_JSON$sep{\"name\":\"$name\",\"rc\":$rc,\"result\":\"$res\",\"bound\":$bound,\"timed_out\":$([ "$timed" -eq 1 ] && printf true || printf false)}"
    REPORT_BODY="$REPORT_BODY
### gate $name (rc=$rc, ${elapsed}s, bound=${bound}s)
$res"
    return 0
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --fast) FAST=1; shift ;;
            --export) EXPORT=1; shift ;;
            --json) JSON=1; shift ;;
            --keep-work) KEEP_WORK=1; shift ;;
            --heartbeat)
                if [ $# -lt 2 ]; then printf 'missing value for --heartbeat\n'; return 2; fi
                HEARTBEAT="$2"; shift 2 ;;
            -h|--help) printf 'usage: %s [--fast] [--export] [--json] [--keep-work] [--heartbeat N]\n' "$0"; return 0 ;;
            *) printf 'usage: %s [--fast] [--export] [--json] [--keep-work] [--heartbeat N]\n' "$0"; return 2 ;;
        esac
    done

    TOOLHOME=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    if [ -n "${HARNESS_REPO:-}" ]; then
        REPO=$(cd "$HARNESS_REPO" && pwd) || {
            printf 'GATE FAIL: HARNESS_REPO is not a directory: %s\n' "$HARNESS_REPO"; return 2; }
    else
        REPO=$(resolve_repo "$TOOLHOME")
        [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    fi
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root (set HARNESS_REPO=<dir> for another repo)\n'
        return 2
    fi
    # STATE is where the verdict, failure tails, timings and ledger are written.
    # Default is the gated repo, so that repo's preflight/next-action can read
    # them. HARNESS_STATE=<dir> keeps a read-only target untouched.
    STATE="${HARNESS_STATE:-$REPO}"
    export GATE_TIMINGS="${GATE_TIMINGS:-$STATE/data/observability/gate-timings.json}"
    GATE_ENV=host
    if [ -x "$REPO/scripts/sandbox-detect.sh" ] && "$REPO/scripts/sandbox-detect.sh" --quiet; then
        GATE_ENV=sandbox
    fi
    WORK=$(mktemp -d)
    local TS REV
    TS=$(date -u +%Y%m%dT%H%M%SZ)
    REV=""
    if have git && [ -d "$REPO/.git" ]; then
        REV=$(git -C "$REPO" rev-parse --short HEAD 2>&1)
    fi
    REPORT_BODY=""
    if [ -f "$TOOLHOME/lib/heartbeat.sh" ]; then
        . "$TOOLHOME/lib/heartbeat.sh"
    elif [ -f "$REPO/scripts/lib/heartbeat.sh" ]; then
        . "$REPO/scripts/lib/heartbeat.sh"
    fi
    case "$HEARTBEAT" in ''|*[!0-9]*) HEARTBEAT=10 ;; esac
    trap 'abort_run INT' INT
    trap 'abort_run TERM' TERM

    # Ledger: bracket the run. Telemetry is non-fatal by explicit handling —
    # a ledger failure must never fail the gate. LEDGER_DB override is the
    # test seam (point it somewhere unwritable to prove this path).
    if have python3 && [ -f "$TOOLHOME/ledger.py" ]; then
        LEDGER_DB="${LEDGER_DB:-$STATE/data/observability/observability.db}" python3 "$TOOLHOME/ledger.py" record --type GATE_START --actor harness.sh --rev "$REV" --source harness.sh --key "gate-$TS-start" 2>&1 || printf 'ledger: GATE_START record failed (telemetry non-fatal)\n'
    fi

    if [ "$JSON" -eq 0 ]; then
        printf '=== harness.sh ===\n'
        printf 'repo: %s\n' "$REPO"
        printf 'utc:  %s\n' "$TS"
        [ -n "$REV" ] && printf 'rev:  %s\n' "$REV"
        printf '\n--- gates ---\n'
    fi

    run_gate lint
    run_gate test-hygiene
    run_gate test-patterns
    run_gate check-placeholders
    if [ "$FAST" -eq 1 ]; then
        skip 'gate test-dashboard (--fast)'
    else
        # lint + test-hygiene already ran above; tell the dashboard gate so it
        # does not re-run them (that double-run nearly doubled the whole suite).
        export GATES_RUN_BY_PARENT=1
        run_gate test-dashboard
        unset GATES_RUN_BY_PARENT
    fi

    if [ "$JSON" -eq 0 ]; then
        if [ -x "$REPO/scripts/learn-rules.py" ]; then
            section "learned rules (corpus -> data/observability/learned-rules.json)"
            "$REPO/scripts/learn-rules.py" --since-days 30 --write 2>&1 | head -n 24
        fi
        if [ -x "$REPO/scripts/issue-solutions.py" ]; then
            section "solution library (-> data/observability/solutions.json)"
            "$REPO/scripts/issue-solutions.py" --write 2>&1 | head -n 12
        fi
        if [ -x "$REPO/scripts/models.sh" ]; then
            section "model catalog (-> data/observability/models.json)"
            local mstart mend mrc mout mbound
            mbound="${MODELS_TIMEOUT:-30}"
            mstart=$(date +%s)
            mout=$(timeout "$mbound" "$REPO/scripts/models.sh" --write 2>&1); mrc=$?
            mend=$(date +%s)
            printf '%s\n' "$mout" | head -n 22
            printf 'model catalog: elapsed=%ss rc=%s bound=%ss (normal <1s on ws24; override MODELS_TIMEOUT)\n' "$((mend - mstart))" "$mrc" "$mbound"
            [ "$mrc" -eq 124 ] && printf 'model catalog: SKIP after %ss; last line above; host load, not a gate\n' "$mbound"
        fi
        if [ -x "$REPO/scripts/doc-budget.sh" ]; then
            section "doc budget (context cost of the read-first corpus)"
            "$REPO/scripts/doc-budget.sh" 2>&1 | tail -n 4
        fi
        if [ -x "$REPO/scripts/logs.sh" ]; then
            section "telemetry (signal: guard + errors)"
            "$REPO/scripts/logs.sh" --source signal --tail 8
        fi
        if [ -x "$REPO/scripts/cost-bottlenecks.sh" ]; then
            section "cost headline"
            "$REPO/scripts/cost-bottlenecks.sh" --top 3 2>&1 | tail -n 14
        fi
        if [ -f "$REPO/TODO.md" ]; then
            section "todo — in flight"
            grep -E '^- \[~\]' "$REPO/TODO.md" || printf '(none in flight)\n'
        fi
    fi

    mkdir -p "$STATE/data/observability" "$STATE/logs"
    printf '{"ts":"%s","passed":%d,"failed":%d,"failed_gates":"%s","state":"complete"}\n' \
        "$TS" "$PASS_GATES" "$FAILED_GATES" "${FAILED_NAMES# }" \
        > "$STATE/data/observability/last-gate.json"
    if [ "$FAILED_GATES" -eq 0 ]; then LEDGER_VERDICT="PASS"; else LEDGER_VERDICT="FAIL"; fi
    if have python3 && [ -f "$TOOLHOME/ledger.py" ]; then
        LEDGER_DB="${LEDGER_DB:-$STATE/data/observability/observability.db}" python3 "$TOOLHOME/ledger.py" record --type GATE --actor harness.sh --verdict "$LEDGER_VERDICT" --detail "passed=$PASS_GATES failed=$FAILED_GATES failed_gates=${FAILED_NAMES# }" --rev "$REV" --source harness.sh --key "gate-$TS" 2>&1 || printf 'ledger: GATE record failed (telemetry non-fatal)\n'
    fi

    if [ "$JSON" -eq 1 ]; then
        printf '{"ts":"%s","rev":"%s","passed":%d,"failed":%d,"end":true,"gates":[%s]}\n' \
            "$TS" "$REV" "$PASS_GATES" "$FAILED_GATES" "$GATE_JSON"
    else
        section "summary"
        printf 'gates passed: %d   gates failed: %d\n' "$PASS_GATES" "$FAILED_GATES"
        printf 'note: test-dashboard.sh re-runs lint + test-hygiene only when run STANDALONE;\n'
        printf '      under harness.sh they run once (GATES_RUN_BY_PARENT).\n'
        printf '@@END harness passed=%d failed=%d ts=%s\n' "$PASS_GATES" "$FAILED_GATES" "$TS"
        if [ "$EXPORT" -eq 1 ]; then
            local rep="$STATE/logs/harness-$TS.md"
            mkdir -p "$STATE/logs"
            {
                printf '# harness report %s\n\n' "$TS"
                printf 'gates passed: %d  failed: %d\n' "$PASS_GATES" "$FAILED_GATES"
                printf '%s\n' "$REPORT_BODY"
                printf '\n## telemetry\n\n```\n'
                "$REPO/scripts/logs.sh" --source signal --tail 20 2>&1
                printf '```\n'
            } > "$rep"
            printf 'report: %s\n' "$rep"
        fi
    fi

    if [ "$FAILED_GATES" -gt 0 ] || [ "$KEEP_WORK" -eq 1 ]; then
        [ "$JSON" -eq 0 ] && printf 'workdir: %s (logs kept)\n' "$WORK"
    else
        find "$WORK" -depth -delete 2>&1
    fi

    [ "$FAILED_GATES" -eq 0 ]
}

main "$@"
