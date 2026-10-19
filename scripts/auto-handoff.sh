#!/usr/bin/env bash
#
# auto-handoff.sh — ACT on the budget STOP: produce the fresh-session brief
# automatically, not as advice (E-action, closes RULES #76's loop).
#
# RULES #76 makes an over-budget session a hard STOP, and the prescription is a
# handoff. But "detect" and "act" were separate: the agent had to notice the STOP
# and then *remember* to run `session-guard.sh --handoff`. This script is the
# action: at the trip point it targets the LATEST over-budget session (the same
# row preflight.sh gates on), produces the redacted, leak-checked brief, and
# prints the paste path — idempotently, so a repeated preflight per turn costs
# nothing after the first. It never spends and never forks/continues.
#
#   ./scripts/auto-handoff.sh [--session ID] [--db PATH] [--out FILE]
#                             [--transcript PATH] [--force] [--json]
#   ./scripts/auto-handoff.sh --self-test
#
# Exit 0 when a brief is ready or none is due; 1 when action is due but the
# brief could not be produced; 2 on usage/resolve errors.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null. No subprocess.run.
# No bare kill. printf only. main() wrapper.
#
set -o pipefail

SESSION=""
DB=""
OUT=""
TRANSCRIPT=""
FORCE=0
JSON=0
SELFTEST=0
BUDGET="${CONTEXT_BUDGET:-200000}"

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

# latest_session DB -> "id<TAB>tokens" for the newest session, or empty.
latest_session() {
    [ -f "$1" ] || return 0
    have sqlite3 || return 0
    sqlite3 "$1" "SELECT id || ' ' || COALESCE(tokens_input,0) FROM session ORDER BY time_created DESC LIMIT 1;" 2>&1
}

self_test() {
    have node || { printf 'FAIL node missing\n'; return 1; }
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    have sqlite3 || { printf 'FAIL sqlite3 missing\n'; return 1; }
    local fail=0 work=""
    work=$(mktemp -d)
    python3 - "$work/fix.db" << 'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute('CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT, model TEXT, tokens_input INTEGER, cost REAL, time_created INTEGER, time_updated INTEGER)')
con.execute('CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)')
con.execute("INSERT INTO session VALUES('s_old','old','{\"id\":\"deepseek-flash\"}',9000,0.05,1,2)")
con.execute("INSERT INTO session VALUES('s_over','over','{\"id\":\"deepseek-flash\"}',5000,0.07,7,8)")
con.execute("INSERT INTO session VALUES('s_ok','ok','{\"id\":\"deepseek-flash\"}',100,0,5,6)")
con.execute("INSERT INTO part VALUES('p1','m','s_over',7,8,'{\"type\":\"text\",\"text\":\"hi\"}')")
con.commit()
PYEOF
    printf '%s\n' '# s_over - fixture' '' '## user m1 2026-10-12 10:00:00 UTC' '' 'fixture goal here' '' '## assistant m2 2026-10-12 10:01:00 UTC' '' 'fixture finding here' '' '## user m3 2026-10-12 10:02:00 UTC' '' 'open question here?' > "$work/transcript-s_over.md"

    local o="" out="$work/brief.md"
    o=$(CONTEXT_BUDGET=1000 LEDGER_DB="$work/obs.db" bash "${BASH_SOURCE[0]}" \
        --db "$work/fix.db" --transcript "$work/transcript-s_over.md" --out "$out" 2>&1)
    printf '%s' "$o" | grep -q 'brief ready' || { printf 'FAIL over-budget produces a brief\n'; fail=1; }
    [ -f "$out" ] || { printf 'FAIL brief file written\n'; fail=1; }
    grep -q '# Handoff brief' "$out" 2>&1 || grep -q 'Handoff brief' "$out" || { printf 'FAIL brief content\n'; fail=1; }
    local sum1 sum2
    sum1=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$out")
    o=$(CONTEXT_BUDGET=1000 LEDGER_DB="$work/obs.db" bash "${BASH_SOURCE[0]}" \
        --db "$work/fix.db" --transcript "$work/transcript-s_over.md" --out "$out" 2>&1)
    sum2=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$out")
    [ "$sum1" = "$sum2" ] || { printf 'FAIL re-run regenerates (not idempotent)\n'; fail=1; }
    printf '%s' "$o" | grep -q 'already ready\|brief ready' || { printf 'FAIL re-run reports ready\n'; fail=1; }

    # newest session under budget -> no action.
    python3 - "$work/fix.db" << 'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("INSERT INTO session VALUES('s_new','new','{\"id\":\"deepseek-flash\"}',10,0,9,10)")
con.commit()
PYEOF
    o=$(CONTEXT_BUDGET=1000 LEDGER_DB="$work/obs.db" bash "${BASH_SOURCE[0]}" --db "$work/fix.db" --out "$work/none.md" 2>&1)
    printf '%s' "$o" | grep -q 'nothing to do' || { printf 'FAIL clean newest is a no-op\n'; fail=1; }
    [ -f "$work/none.md" ] && { printf 'FAIL no-op wrote a brief\n'; fail=1; }
    printf '%s' "$o" | grep -q 'nothing to do' && [ ! -f "$work/none.md" ] || true

    rm -f "$work/fix.db" "$work/obs.db" "$work/brief.md" "$work/none.md" "$work/transcript-s_over.md"
    rmdir "$work"
    if [ "$fail" -eq 0 ]; then printf 'auto-handoff: self-test PASS\n'; else printf 'auto-handoff: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --self-test) SELFTEST=1; shift ;;
            --session) SESSION="${2:-}"; shift 2 ;;
            --session=*) SESSION="${1#--session=}"; shift ;;
            --db) DB="${2:-}"; shift 2 ;;
            --db=*) DB="${1#--db=}"; shift ;;
            --out) OUT="${2:-}"; shift 2 ;;
            --out=*) OUT="${1#--out=}"; shift ;;
            --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
            --transcript=*) TRANSCRIPT="${1#--transcript=}"; shift ;;
            --force) FORCE=1; shift ;;
            --json) JSON=1; shift ;;
            -h | --help) printf 'usage: %s [--session ID] [--db PATH] [--out FILE] [--transcript PATH] [--force] [--json] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    if [ "$SELFTEST" -eq 1 ]; then self_test; return "$?"; fi
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 2; }

    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    [ -z "$REPO" ] && { printf 'GATE FAIL: cannot resolve repo root\n'; return 2; }
    [ -n "$DB" ] || DB="$REPO/data/opencode/opencode.db"

    local sid="$SESSION" row tok=""
    if [ -z "$sid" ]; then
        row=$(latest_session "$DB")
        sid=${row%% *}
        tok=${row##* }
        case "${tok:-0}" in
            ''|*[!0-9]*) printf 'auto-handoff: cannot read the latest session (db=%s)\n' "$DB"; return 0 ;;
        esac
        if [ "$tok" -lt "$BUDGET" ]; then
            if [ "$JSON" -eq 1 ]; then
                printf '{"session":"%s","action":"none","brief":""}\n' "$sid"
            else
                printf 'auto-handoff: nothing to do (latest session %s/%s within budget)\n' "$tok" "$BUDGET"
            fi
            return 0
        fi
    fi
    [ -n "$OUT" ] || OUT="$REPO/logs/brief-$sid.md"

    if [ -f "$OUT" ] && [ "$FORCE" -eq 0 ]; then
        if [ "$JSON" -eq 1 ]; then
            printf '{"session":"%s","action":"ready","brief":"%s"}\n' "$sid" "$OUT"
        else
            printf 'auto-handoff: brief already ready: %s (--force to regenerate)\n' "$OUT"
        fi
        return 0
    fi

    local args=("--handoff" "--session" "$sid" "--db" "$DB" "--out" "$OUT")
    [ -n "$TRANSCRIPT" ] && args+=("--transcript" "$TRANSCRIPT")
    local sg=""
    sg=$(bash "$REPO/scripts/session-guard.sh" "${args[@]}" 2>&1)
    local rc=$?
    if [ "$rc" -ne 0 ] || [ ! -f "$OUT" ]; then
        printf 'auto-handoff: FAILED to produce a brief for %s\n' "$sid"
        printf '%s\n' "$sg" | tail -3
        return 1
    fi
    if [ "$JSON" -eq 1 ]; then
        printf '{"session":"%s","action":"handoff","brief":"%s"}\n' "$sid" "$OUT"
    else
        printf 'auto-handoff: brief ready: %s\n' "$OUT"
        printf 'next: open a fresh session and paste it; do NOT --fork/--continue %s\n' "$sid"
    fi
    return 0
}

main "$@"
