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
#
# Exit 0 only if every gate that ran passed. A missing gate is SKIP (not PASS).
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

FAST=0
EXPORT=0
JSON=0
FAILED_GATES=0
PASS_GATES=0
GATE_JSON=""

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
section() { [ "$JSON" -eq 1 ] || printf '\n=== %s ===\n' "$1"; }

run_gate() {
    local name="$1" script="$REPO/scripts/$1.sh" out="$WORK/$1.log"
    local rc=0 res=""
    if [ ! -f "$script" ]; then
        skip "gate $name (missing $name.sh)"
        return 0
    fi
    "$script" > "$out" 2>&1
    rc=$?
    res=$(grep -E '^=== (lint )?result:' "$out" | tail -1)
    res=${res//\"/}
    res=${res//\\/}
    if [ "$rc" -eq 0 ]; then
        PASS_GATES=$((PASS_GATES + 1))
        ok "gate $name pass  $res"
    else
        FAILED_GATES=$((FAILED_GATES + 1))
        bad "gate $name FAIL  $res"
        if [ "$JSON" -eq 0 ]; then
            grep -E 'status=FAIL' "$out" | head -6
        fi
    fi
    local sep=""
    [ -n "$GATE_JSON" ] && sep=","
    GATE_JSON="$GATE_JSON$sep{\"name\":\"$name\",\"rc\":$rc,\"result\":\"$res\"}"
    REPORT_BODY="$REPORT_BODY
### gate $name (rc=$rc)
$res"
    return 0
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --fast) FAST=1; shift ;;
            --export) EXPORT=1; shift ;;
            --json) JSON=1; shift ;;
            -h|--help) printf 'usage: %s [--fast] [--export] [--json]\n' "$0"; return 0 ;;
            *) printf 'usage: %s [--fast] [--export] [--json]\n' "$0"; return 2 ;;
        esac
    done

    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    WORK=$(mktemp -d)
    local TS REV
    TS=$(date -u +%Y%m%dT%H%M%SZ)
    REV=""
    if have git && [ -d "$REPO/.git" ]; then
        REV=$(git -C "$REPO" rev-parse --short HEAD 2>&1)
    fi
    REPORT_BODY=""

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
    if [ "$FAST" -eq 1 ]; then
        skip 'gate test-dashboard (--fast)'
    else
        run_gate test-dashboard
    fi

    if [ "$JSON" -eq 0 ]; then
        if [ -x "$REPO/scripts/learn-rules.py" ]; then
            section "learned rules (corpus -> data/observability/learned-rules.json)"
            "$REPO/scripts/learn-rules.py" --since-days 30 --write 2>&1 | head -n 18
        fi
        if [ -x "$REPO/scripts/issue-solutions.py" ]; then
            section "solution library (-> data/observability/solutions.json)"
            "$REPO/scripts/issue-solutions.py" --write 2>&1 | head -n 12
        fi
        if [ -x "$REPO/scripts/models.sh" ]; then
            section "model catalog (-> data/observability/models.json)"
            "$REPO/scripts/models.sh" --write 2>&1 | head -n 22
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

    mkdir -p "$REPO/data/observability"
    printf '{"ts":"%s","passed":%d,"failed":%d}\n' "$TS" "$PASS_GATES" "$FAILED_GATES" \
        > "$REPO/data/observability/last-gate.json"

    if [ "$JSON" -eq 1 ]; then
        printf '{"ts":"%s","rev":"%s","passed":%d,"failed":%d,"gates":[%s]}\n' \
            "$TS" "$REV" "$PASS_GATES" "$FAILED_GATES" "$GATE_JSON"
    else
        section "summary"
        printf 'gates passed: %d   gates failed: %d\n' "$PASS_GATES" "$FAILED_GATES"
        printf 'note: test-dashboard.sh already runs lint.sh and test-hygiene.sh.\n'
        if [ "$EXPORT" -eq 1 ]; then
            local rep="$REPO/logs/harness-$TS.md"
            mkdir -p "$REPO/logs"
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

    rm -f "$WORK"/*.log
    rmdir "$WORK"

    [ "$FAILED_GATES" -eq 0 ]
}

main "$@"
