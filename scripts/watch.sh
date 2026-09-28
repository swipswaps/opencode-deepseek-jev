#!/usr/bin/env bash
#
# watch.sh — read-only live problem monitor.
#
# The user repeatedly asked for a live monitor. The repo had no such tool:
# `thinking.sh` tails activity and `session-health.mjs` detects stalls once,
# but nothing shows ONLY what is newly wrong since the last sweep. This fills
# that gap without a daemon: one sweep by default, `--loop` to repeat.
#
# It reports, read-only and offline (no model call):
#   gate            data/observability/last-gate.json passed?
#   session-health  running / dead / blank counts (via session-health.mjs --live)
#   guard           NEW block/fix/advisory lines in guard.log since the cursor
#   app             NEW level=ERROR/WARN lines in opencode.log since the cursor
#
# The DB is never written. The only state kept is two byte offsets under
# data/observability/.watch/ (gitignored). Cursors mean a repeated sweep shows
# 0 new — the way a monitor should (no echo of archival lines as if live).
#
# Usage: watch.sh [--once] [--loop SEC] [--self-test]
# Env (self-test seams): WATCH_REPO WATCH_DB WATCH_GUARD WATCH_APP
#                        WATCH_LAST_GATE WATCH_STATE
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
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

# new_lines FILE CURSOR GREP_RE LABEL -> prints new (uncursored) matching lines
# and advances the cursor. A shorter file (rotation) resets to 0.
new_lines() {
    local f="$1" cur="$2" re="$3" label="$4"
    local total=0 prev=0
    if [ ! -f "$f" ]; then
        printf '%s: (no file)\n' "$label"
        return 0
    fi
    total=$(wc -c < "$f" | tr -d ' ')
    if [ ! -f "$cur" ]; then
        # First sweep: initialise at EOF so historical lines are NOT echoed as
        # if live (the exact archival-as-alarm failure this tool exists to stop).
        printf '%s' "$total" > "$cur"
        printf '%s: 0 new (cursor initialised at EOF; %s historical lines suppressed)\n' "$label" "$total"
        return 0
    fi
    prev=$(tr -d ' ' < "$cur")
    [ -n "$prev" ] || prev=0
    [ "$prev" -le "$total" ] || prev=0
    local n
    n=$(tail -c +"$((prev + 1))" "$f" | grep -cE "$re")
    printf '%s' "$total" > "$cur"
    printf '%s: %s new\n' "$label" "$n"
    tail -c +"$((prev + 1))" "$f" | grep -E "$re" | while IFS= read -r line; do
        printf '  %s\n' "$line"
    done
    return 0
}

sweep() {
    local ts; ts=$(date -u +%H:%M:%SZ)
    printf '\n=== watch @ %s (repo=%s) ===\n' "$ts" "${REPO##*/}"

    # gate
    local gate="unknown"
    if [ -f "$LAST_GATE" ] && have python3; then
        gate=$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1])); print("passed" if d.get("passed") else "FAILED")
except Exception:
    print("unknown")' "$LAST_GATE")
    fi
    printf 'gate: %s\n' "$gate"

    # session-health (read-only over the DB; --live fails safe when no server)
    if have node && [ -f "$REPO/scripts/session-health.mjs" ] && [ -f "$DB" ]; then
        node --experimental-sqlite "$REPO/scripts/session-health.mjs" "$DB" --live --json 2>&1 \
            | python3 -c 'import json,sys
s=sys.stdin.read(); i=s.find("{")
try:
    c=json.loads(s[i:]).get("counts",{})
    print("session-health: running=%s dead=%s blank=%s scanned=%s" % (c.get("running_tools",0), c.get("dead_tools",0), c.get("blank_tails",0), c.get("sessions_scanned",0)))
except Exception:
    print("session-health: unavailable")'
    else
        printf 'session-health: unavailable\n'
    fi

    mkdir -p "$STATE"
    new_lines "$GUARD" "$STATE/guard.cursor" '"verdict":"(block|fix|advisory)"' "guard"
    new_lines "$APP" "$STATE/app.cursor" 'level=(ERROR|WARN)' "app"
    return 0
}

self_test() {
    local d; d=$(mktemp -d)
    mkdir -p "$d/state"
    printf '%s\n' '{"verdict":"block","command":"ls /blocked"}' '{"verdict":"loaded"}' > "$d/guard.log"
    printf '%s\n' 'ts=1 level=INFO ok' 'ts=2 level=ERROR boom' > "$d/app.log"
    printf '%s\n' '{"passed":true}' > "$d/last-gate.json"
    export WATCH_REPO="$d" WATCH_DB="$d/none.db" WATCH_GUARD="$d/guard.log"
    export WATCH_APP="$d/app.log" WATCH_LAST_GATE="$d/last-gate.json" WATCH_STATE="$d/state"
    local o1 o2 o3 ok=0
    o1=$(bash "$0" --once 2>&1)
    printf '%s\n' "$o1" | grep -q 'gate: passed' && printf '  PASS gate parsed\n' || { printf '  FAIL gate parsed\n'; ok=1; }
    printf '%s\n' "$o1" | grep -q 'guard: 0 new (cursor initialised' && printf '  PASS first sweep suppresses history (guard)\n' || { printf '  FAIL first sweep guard init\n'; ok=1; }
    printf '%s\n' "$o1" | grep -q 'app: 0 new (cursor initialised' && printf '  PASS first sweep suppresses history (app)\n' || { printf '  FAIL first sweep app init\n'; ok=1; }
    printf '%s\n' '{"verdict":"block","command":"ls /blocked2"}' >> "$d/guard.log"
    printf '%s\n' 'ts=3 level=ERROR new' >> "$d/app.log"
    o2=$(bash "$0" --once 2>&1)
    o3=$(bash "$0" --once 2>&1)
    printf '%s\n' "$o2" | grep -q 'guard: 1 new' && printf '  PASS new guard action detected\n' || { printf '  FAIL new guard action\n'; ok=1; }
    printf '%s\n' "$o2" | grep -q 'app: 1 new' && printf '  PASS new app error detected\n' || { printf '  FAIL new app error\n'; ok=1; }
    printf '%s\n' "$o3" | grep -q 'guard: 0 new' && printf '  PASS cursor suppresses re-show (guard 0 new)\n' || { printf '  FAIL cursor guard\n'; ok=1; }
    printf '%s\n' "$o3" | grep -q 'app: 0 new' && printf '  PASS cursor suppresses re-show (app 0 new)\n' || { printf '  FAIL cursor app\n'; ok=1; }
    rm -f "$d"/guard.log "$d"/app.log "$d"/last-gate.json "$d"/state/guard.cursor "$d"/state/app.cursor
    rmdir "$d/state" "$d"
    printf 'result: %s\n' "$([ "$ok" -eq 0 ] && printf PASS || printf FAIL)"
    return "$ok"
}

main() {
    local loop=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --self-test) self_test; return $? ;;
            --once) shift ;;
            --loop) loop="${2:-5}"; shift 2 ;;
            -h|--help) printf 'usage: %s [--once] [--loop SEC] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'usage: %s [--once] [--loop SEC] [--self-test]\n' "$0" >&2; return 2 ;;
        esac
    done

    REPO="${WATCH_REPO:-$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")}"
    [ -z "$REPO" ] && REPO="${WATCH_REPO:-$(resolve_repo "$PWD")}"
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'; return 2
    fi
    DB="${WATCH_DB:-$REPO/data/opencode/opencode.db}"
    GUARD="${WATCH_GUARD:-$REPO/data/observability/guard.log}"
    APP="${WATCH_APP:-$HOME/.local/share/opencode/log/opencode.log}"
    LAST_GATE="${WATCH_LAST_GATE:-$REPO/data/observability/last-gate.json}"
    STATE="${WATCH_STATE:-$REPO/data/observability/.watch}"

    if [ -n "$loop" ]; then
        while :; do sweep; sleep "$loop"; done
    fi
    sweep
    return 0
}

main "$@"
