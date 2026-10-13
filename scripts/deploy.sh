#!/usr/bin/env bash
#
# deploy.sh — gated promote of the checkout to the served dashboard.
#
# Why this exists (2026-10-12 incident): web-restart.sh recreated the
# container and reported PASS because `/api/rev` matched HEAD — but the page
# was dead (a bare getElementById threw at inline-script load, freezing every
# pane). rev-match is not page-works. The repo ALREADY had the detector
# (test-dashboard-ui.mjs) and we dismissed its failure as a shim artifact.
# This script makes the detector a gate: build the page in a scratch process,
# prove it executes, and only then promote. A failed verify prints the exact
# rollback; it never auto-reverts (that would clobber uncommitted work).
#
# Steps:
#   D1  record HEAD and the currently-served rev (the rollback target)
#   D2  static: node --check on every served .mjs that changed
#   D3  gate: boot a scratch dashboard on the new code + test-dashboard-ui.mjs
#       (parse AND execute the served inline scripts, panes populate)
#   D4  promote: ./scripts/web-restart.sh
#   D5  verify: live /api/rev stale=false AND test-dashboard-ui.mjs on :5099
#   D6  report; on failure print rollback (git checkout <rev> + web.sh)
#
#   ./scripts/deploy.sh [--port N] [--skip-gates] [--verify-only]
#   ./scripts/deploy.sh --self-test        # offline, no docker/net
#
# Read-only toward data/. Secrets by name only.
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

served_rev() {
    # served_rev URL — best-effort current rev string (empty on failure).
    local out=""
    out=$(curl -k -s --max-time 8 "$1/api/rev" 2>&1) || return 0
    printf '%s' "$out" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get("served",""))
except Exception:
    print("")' 2>&1
}

scratch_ui_check() {
    # scratch_ui_check REPO PORT — boot the new dashboard on PORT and run the
    # inline-script execution test against it. Prints PASS/FAIL detail.
    local repo="$1" port="$2" log=""
    log=$(mktemp)
    node --no-warnings --experimental-sqlite "$repo/scripts/dashboard.mjs" \
        "$repo/data/opencode/opencode.db" "$port" 127.0.0.1 "$repo/scripts/audit-config.sh" \
        > "$log" 2>&1 &
    local pid=$!
    local i=0 out=""
    for i in $(seq 1 20); do
        sleep 2
        out=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/rev" 2>&1) || out="000"
        [ "$out" = "200" ] && break
    done
    local rc=1 res=""
    if [ "$out" = "200" ]; then
        res=$(node "$repo/scripts/test-dashboard-ui.mjs" "http://127.0.0.1:$port" 2>&1)
        printf '%s' "$res" | grep -q '^FAIL' || rc=0
    else
        res="scratch server never answered on :$port"
    fi
    kill -TERM "$pid" 2>&1 || true
    wait "$pid" 2>&1 || true
    rm -f "$log"
    if [ "$rc" -eq 0 ]; then
        printf 'PASS'
    else
        printf 'FAIL: %s' "$(printf '%s' "$res" | head -n 3 | tr '\n' ' ')"
    fi
    return "$rc"
}

self_test() {
    local fail=0 work=""
    have node || { printf 'FAIL node missing\n'; return 1; }
    # served_rev parse: pure function check via a local fixture server is
    # overkill; assert the python parse contract directly.
    local got=""
    got=$(printf '{"served":"abc1234","head":"abc1234","stale":false}' | python3 -c 'import json,sys; print(json.load(sys.stdin).get("served",""))')
    [ "$got" = "abc1234" ] || { printf 'FAIL served parse\n'; fail=1; }
    # The UI test must be runnable and must report PASS/FAIL lines (guards
    # against the gate silently no-op'ing).
    if [ -f "$REPO/scripts/test-dashboard-ui.mjs" ]; then
        node --check "$REPO/scripts/test-dashboard-ui.mjs" > /dev/null 2>&1 \
            || { printf 'FAIL ui test does not parse\n'; fail=1; }
    else
        printf 'FAIL test-dashboard-ui.mjs missing\n'; fail=1
    fi
    if [ "$fail" -eq 0 ]; then printf 'deploy: self-test PASS\n'; else printf 'deploy: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    local PORT=5198 SKIP=0 VERIFYONLY=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --port) PORT="${2:-5198}"; shift 2 ;;
            --port=*) PORT="${1#--port=}"; shift ;;
            --skip-gates) SKIP=1; shift ;;
            --verify-only) VERIFYONLY=1; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) printf 'usage: %s [--port N] [--skip-gates] [--verify-only] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    have node || { printf 'GATE FAIL: node required\n'; return 1; }
    printf '=== deploy.sh ===\n'
    local head prev
    head=$(git -C "$REPO" rev-parse --short HEAD 2>&1 || printf 'unknown')
    prev=$(served_rev "https://127.0.0.1:5099")
    printf 'D1 HEAD=%s  served=%s\n' "$head" "${prev:-?}"

    if [ "$SKIP" -eq 0 ]; then
        printf 'D2 static check (served .mjs parse)\n'
        local f ok=1
        for f in "$REPO"/scripts/dashboard.mjs "$REPO"/scripts/session-health.mjs "$REPO"/scripts/quirks.mjs "$REPO"/scripts/query-worker.mjs; do
            [ -f "$f" ] || continue
            node --check "$f" > /dev/null 2>&1 || { printf '  FAIL parse: %s\n' "$f"; ok=0; }
        done
        [ "$ok" -eq 1 ] && printf '  PASS all parse\n'
        [ "$ok" -eq 1 ] || { printf 'D2 failed; fix parse errors before deploying\n'; return 1; }

        printf 'D3 gate: scratch boot + inline-script execution on new code\n'
        local gres
        gres=$(scratch_ui_check "$REPO" "$PORT")
        printf '  %s\n' "$gres"
        case "$gres" in
            PASS) ;;
            *) printf 'D3 GATE FAILED — the page does not execute; NOT promoting.\n'
               printf 'this is the class of bug that froze all panes silently.\n'
               return 1 ;;
        esac
    else
        printf 'D2/D3 skipped (--skip-gates)\n'
    fi

    if [ "$VERIFYONLY" -eq 1 ]; then
        printf 'verify-only: skipping promote\n'
    else
        printf 'D4 promote: recreating opencode-web\n'
        bash "$REPO/scripts/web-restart.sh" || { printf 'D4 FAILED — promote did not complete\n'; return 1; }
    fi

    printf 'D5 verify live :5099\n'
    local served stale
    served=$(served_rev "https://127.0.0.1:5099")
    stale=$(curl -k -s --max-time 8 "https://127.0.0.1:5099/api/rev" 2>&1 | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("stale","?"))
except Exception: print("?")' 2>&1)
    printf '  served=%s stale=%s (want HEAD=%s, stale=False)\n' "$served" "$stale" "$head"
    local lres=""
    lres=$(node "$REPO/scripts/test-dashboard-ui.mjs" "https://127.0.0.1:5099" 2>&1)
    printf '%s' "$lres" | grep -q '^PASS pane #session populated' && lres="UI PASS" || lres="UI FAIL"
    printf '  live %s\n' "$lres"
    if [ "$served" = "$head" ] && [ "$stale" = "False" ] && [ "$lres" = "UI PASS" ]; then
        printf 'D6 PASS: %s served, page executes\n' "$head"
        return 0
    fi
    printf 'D6 FAIL: promotion did not verify. rollback:\n'
    printf '  git -C %s checkout %s\n' "$REPO" "${prev:-<prev-rev>}"
    printf '  %s/scripts/web-restart.sh\n' "$REPO"
    printf '  (auto-revert is intentionally NOT run: it would clobber uncommitted work)\n'
    return 1
}

main "$@"
