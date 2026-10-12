#!/usr/bin/env bash
#
# test-tooling.sh — contract test for the harness tooling's machine interfaces.
#
# The gates prove the repo compiles and serves; the tools' `--self-test`s prove
# their internal logic. This proves the USER-FACING CONTRACTS a wrapper or
# plugin depends on: every tool that advertises `--json` emits parseable JSON
# with the keys t callers read. It deliberately does NOT call harness.sh (which
# would recurse), so it is safe to run from test-hygiene.sh.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit, no rm -rf,
#   no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

PASS=0
FAIL=0

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

# --- telemetry: ms= per check, named slowest (same idiom as the gates) ------
now_ms() {
    local t="${EPOCHREALTIME:-}"
    if [ -z "$t" ]; then printf '%s000' "$(date +%s)"; return; fi
    local s="${t%%.*}" us="${t#*.}"
    [ -n "$us" ] || us=0
    printf '%d' "$(( s * 1000 + 10#${us:0:3} ))"
}
LAST_MS=$(now_ms)
SLOW_MS=0
SLOW_MSG=""
_stamp() {
    local n; n=$(now_ms); D=$((n - LAST_MS)); LAST_MS=$n
    if [ "$D" -gt "$SLOW_MS" ]; then SLOW_MS=$D; SLOW_MSG="$1"; fi
}
ok()  { PASS=$((PASS+1)); _stamp "$1"; printf 'ts=%s ms=%s level=INFO  status=PASS %s\n' "$(date -u +%H:%M:%S)" "$D" "$1"; }
bad() { FAIL=$((FAIL+1)); _stamp "$1"; printf 'ts=%s ms=%s level=ERROR status=FAIL %s\n' "$(date -u +%H:%M:%S)" "$D" "$1"; }

# validate_json NAME FILE "assert-expr"   (expr may use d)
validate_json() {
    local name="$1" file="$2" expr="$3"
    if python3 -c "import json,sys
d=None
try:
    d=json.load(open(sys.argv[1]))
except Exception as e:
    print('parse error:', e); sys.exit(2)
assert $expr
" "$file" 2>&1; then
        ok "contract: $name"
    else
        bad "contract: $name"
        head -3 "$file"
    fi
}

run_json() {  # tool... > file ; returns rc
    local file="$1"; shift
    "$@" > "$file" 2>&1
}

main() {
    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    if ! have python3; then
        printf 'FAIL: python3 required\n'
        return 1
    fi
    local work
    work=$(mktemp -d)

    printf '=== test-tooling.sh ===\n'

    # preflight: exit 0 or 1 both valid (STOP is a valid answer); JSON contract matters.
    if [ -x "$REPO/scripts/preflight.sh" ]; then
        "$REPO/scripts/preflight.sh" --json > "$work/preflight.json" 2>&1
        validate_json "preflight.sh --json" "$work/preflight.json" '"ready" in d and "critical" in d and "warn" in d'
    fi

    if [ -x "$REPO/scripts/doc-budget.sh" ]; then
        run_json "$work/docs.json" "$REPO/scripts/doc-budget.sh" --json
        validate_json "doc-budget.sh --json" "$work/docs.json" '"total_tokens" in d and "budget" in d'
    fi

    if [ -f "$REPO/scripts/learn-rules.py" ]; then
        run_json "$work/rules.json" python3 "$REPO/scripts/learn-rules.py" --json
        validate_json "learn-rules.py --json" "$work/rules.json" '"shapes" in d and "avoid" in d and "recovery" in d'
    fi

    if [ -f "$REPO/scripts/issue-solutions.py" ]; then
        run_json "$work/sol.json" python3 "$REPO/scripts/issue-solutions.py" --json
        validate_json "issue-solutions.py --json" "$work/sol.json" '"issues" in d and "total_errors" in d'
    fi

    if [ -f "$REPO/scripts/audit-tool-calls.py" ]; then
        run_json "$work/atc.json" python3 "$REPO/scripts/audit-tool-calls.py" --json
        validate_json "audit-tool-calls.py --json" "$work/atc.json" '"blacklist_hits" in d and "patterns" in d'
    fi

    if [ -f "$REPO/scripts/prompt-lint.py" ]; then
        run_json "$work/pl.json" python3 "$REPO/scripts/prompt-lint.py" --last --json
        validate_json "prompt-lint.py --last --json" "$work/pl.json" '"category" in d and "flags" in d'
    fi

    local cat="$REPO/data/observability/models.json"
    if [ -f "$REPO/scripts/models.py" ] && [ -f "$cat" ]; then
        run_json "$work/models.json" python3 "$REPO/scripts/models.py" --catalog "$cat" --json
        validate_json "models.py --catalog --json" "$work/models.json" '"verdict" in d and "models" in d and "recommended" in d'
    fi

    if [ -x "$REPO/scripts/logs.sh" ]; then
        if "$REPO/scripts/logs.sh" --source packet > "$work/logs.txt" 2>&1; then
            ok "logs.sh --source packet runs"
        else
            bad "logs.sh --source packet runs"
        fi
    fi

    if [ -f "$REPO/scripts/recover-4096.sh" ]; then
        run_json "$work/rec.json" bash "$REPO/scripts/recover-4096.sh" --json --no-log
        validate_json "recover-4096.sh --json" "$work/rec.json" '"checks" in d and "passed" in d and "failed" in d and "skipped" in d'
    fi

    if [ -f "$REPO/scripts/session-guard.sh" ]; then
        run_json "$work/sguard.json" bash "$REPO/scripts/session-guard.sh" --json --no-log
        validate_json "session-guard.sh --json" "$work/sguard.json" '"session" in d and "verdict" in d and "meaning" in d and "guidance" in d and len(d["guidance"]) == 4'
    fi

    if [ -f "$REPO/scripts/sentinel.sh" ]; then
        run_json "$work/sen.json" bash "$REPO/scripts/sentinel.sh" --json --no-log
        validate_json "sentinel.sh --json" "$work/sen.json" '"tripped" in d and "trips" in d and "counts" in d and "latest" in d and "slow" in d'
    fi

    if [ -f "$REPO/scripts/latency-timeline.sh" ]; then
        # Offline contract: fixture DB + fixture access log, no docker needed.
        local ltw
        ltw=$(mktemp -d)
        python3 - "$ltw/fix.db" << 'PYEOF'
import sqlite3, sys, time
con = sqlite3.connect(sys.argv[1])
con.execute('CREATE TABLE session(id TEXT PRIMARY KEY)')
con.execute('CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)')
con.execute("INSERT INTO session VALUES('s1')")
now = int(time.time() * 1000)
con.execute("INSERT INTO part VALUES('p1','m','s1',?,?,?)", (now - 5000, now - 1000, '{"type":"tool"}'))
con.commit()
PYEOF
        printf '%s\n' '{"logger":"http.log.access.log0","ts":1750000000,"duration":2.5,"request":{"method":"GET","uri":"/x"},"status":200}' > "$ltw/acc.log"
        run_json "$work/lt.json" bash "$REPO/scripts/latency-timeline.sh" --session s1 --db "$ltw/fix.db" --access-log "$ltw/acc.log" --window 60 --json
        validate_json "latency-timeline.sh --json" "$work/lt.json" '"session" in d and "parts" in d and "fetches" in d and "summary" in d'
        rm -f "$ltw/fix.db" "$ltw/acc.log"
        rmdir "$ltw"
    fi

    # The explore treemap uses the vendored d3. The page must call it as a
    # layout with a tile function; calling d3.treemapResquarify() as a layout
    # throws in the browser. Prove the exact call pattern works against the
    # vendored bundle.
    if have node && [ -f "$REPO/scripts/vendor/d3.min.js" ]; then
        if node -e '
const d3 = require(process.argv[1]);
const root = d3.hierarchy({ children: [{ v: 3 }, { v: 1 }, { v: 2 }] }).sum((d) => d.v || 0);
d3.treemap().size([300, 200]).paddingInner(2).tile(d3.treemapResquarify)(root);
if (!(root.x1 > 0)) throw new Error("layout did not run");
' "$REPO/scripts/vendor/d3.min.js" > "$work/d3.txt" 2>&1; then
            ok "vendored d3 treemap (layout+tile) works"
        else
            bad "vendored d3 treemap (layout+tile) works"
            cat "$work/d3.txt"
        fi
    fi

    if [ -n "$SLOW_MSG" ]; then
        printf 'slowest: %s (%sms)\n' "$SLOW_MSG" "$SLOW_MS"
    fi
    rm -f "$work"/*.json "$work"/*.txt
    rmdir "$work"

    printf '\n=== result: %d pass, %d fail ===\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ] && return 0 || return 1
}

main "$@"
