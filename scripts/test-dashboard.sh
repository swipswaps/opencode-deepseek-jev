#!/usr/bin/env bash
#
# test-dashboard.sh — end-to-end gate for the read-only observability
# dashboard (dashboard.mjs). Starts the server on a scratch port and
# asserts on the served HTML, the /api/runbooks payload, and — critically —
# that the inline browser script is syntactically valid. The parse gate
# catches escape regressions (e.g. a raw newline inside a quoted JS string)
# that a substring grep would never flag.
#
# Constraints: no sed, no 2>/dev/null, no set -e, no top-level exit,
#   no rm -rf, no subprocess.run, no bare kill, printf only, main() wrapper.
#
set -o pipefail

PASS=0
FAIL=0
PORT="${TEST_DASH_PORT:-5196}"
HOST="127.0.0.1"

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
has() { grep -qF "$1" "$2"; }

ok()  { PASS=$((PASS+1)); printf 'ts=%s level=INFO  status=PASS msg=%s\n' "$(date -u +%H:%M:%S)" "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'ts=%s level=ERROR status=FAIL msg=%s\n' "$(date -u +%H:%M:%S)" "$1"; }

main() {
    local REPO
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi

    local db="$REPO/data/opencode/opencode.db"
    if [ ! -f "$db" ]; then
        printf 'FAIL: no database at %s\n' "$db"
        return 1
    fi
    local t
    for t in node curl python3; do
        if ! have "$t"; then
            printf 'FAIL: %s required\n' "$t"
            return 1
        fi
    done

    local work="/tmp/dash-test-$(date -u +%H%M%S)"
    mkdir -p "$work"

    printf '=== test-dashboard.sh ===\n'
    printf 'port: %s\n' "$PORT"

    if node --check "$REPO/scripts/dashboard.mjs" 2>"$work/check.err"; then
        ok 'dashboard.mjs parses'
    else
        bad 'dashboard.mjs parses'
        cat "$work/check.err"
        return 1
    fi

    node --no-warnings --experimental-sqlite "$REPO/scripts/dashboard.mjs" "$db" "$PORT" "$HOST" "$REPO/scripts/audit-config.sh" >"$work/server.log" 2>&1 &
    local srv=$!

    local code="" tries=0
    while [ "$tries" -lt 40 ]; do
        code=$(curl -s -o /dev/null -w '%{http_code}' "http://$HOST:$PORT/" 2>&1 || true)
        [ "$code" = "200" ] && break
        tries=$((tries+1)); sleep 0.25
    done
    [ "$code" = "200" ] && ok 'server ready (200 on /)' || bad 'server ready (200 on /)'

    curl -s "http://$HOST:$PORT/" > "$work/home.html"
    has '[runbooks]' "$work/home.html" && ok 'home nav [runbooks]' || bad 'home nav [runbooks]'

    curl -s "http://$HOST:$PORT/runbooks" > "$work/runbooks.html"
    has '<title>opencode runbooks</title>' "$work/runbooks.html" && ok 'runbooks title' || bad 'runbooks title'
    has 'Operational scripts surfaced' "$work/runbooks.html" && ok 'runbooks subtitle' || bad 'runbooks subtitle'
    has 'host only' "$work/runbooks.html" && ok 'filter: host only' || bad 'filter: host only'
    has 'container only' "$work/runbooks.html" && ok 'filter: container only' || bad 'filter: container only'
    has 'id="count"' "$work/runbooks.html" && ok 'runbooks count element' || bad 'runbooks count element'

    python3 -c 'import sys,re; h=open(sys.argv[1]).read(); m=re.search(r"<script>(.*?)</script>", h, re.S); sys.stdout.write(m.group(1) if m else "")' "$work/runbooks.html" > "$work/inline.js"
    if [ -s "$work/inline.js" ] && node --check "$work/inline.js" 2>"$work/inline.err"; then
        ok 'inline browser script parses'
    else
        bad 'inline browser script parses'
        cat "$work/inline.err"
    fi

    curl -s "http://$HOST:$PORT/api/runbooks" > "$work/runbooks.json"
    python3 - "$work/runbooks.json" > "$work/rbcheck.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
errs = []
ids = [r.get("id") for r in d] if isinstance(d, list) else []
for want in ("rotate-password", "litellm", "laya"):
    if want not in ids:
        errs.append("missing runbook " + want)
if not isinstance(d, list):
    errs.append("payload is not a list")
else:
    for r in d:
        for f in ("id", "title", "purpose", "where", "commands"):
            if not r.get(f):
                errs.append("runbook %s missing %s" % (r.get("id"), f))
        if r.get("where") not in ("host", "container"):
            errs.append("runbook %s bad where=%r" % (r.get("id"), r.get("where")))
print("count=%d" % len(d))
for e in errs:
    print("  - " + e)
sys.exit(1 if errs else 0)
PY
    local rb_rc=$?
    if [ "$rb_rc" -eq 0 ]; then
        ok 'runbooks payload valid'
    else
        bad 'runbooks payload valid'
        cat "$work/rbcheck.txt"
    fi
    has 'count=7' "$work/rbcheck.txt" && ok 'runbooks count=7' || bad 'runbooks count=7'

    if [ -x "$REPO/scripts/runbook.sh" ]; then
        "$REPO/scripts/runbook.sh" --list > "$work/rblist.txt"
        local rl_rc=$?
        if [ "$rl_rc" -eq 0 ]; then ok 'runbook.sh --list exits 0'; else bad 'runbook.sh --list exits 0'; fi
        has 'rotate-password|host' "$work/rblist.txt" && ok 'runbook.sh lists rotate-password' || bad 'runbook.sh lists rotate-password'
        has 'litellm|host' "$work/rblist.txt" && ok 'runbook.sh lists litellm' || bad 'runbook.sh lists litellm'
        has 'laya|host' "$work/rblist.txt" && ok 'runbook.sh lists laya' || bad 'runbook.sh lists laya'
    else
        bad 'runbook.sh present and executable'
    fi

    has 'id="q"' "$work/home.html" && ok 'home search box' || bad 'home search box'
    has 'id="drill"' "$work/home.html" && ok 'home drill panel' || bad 'home drill panel'

    curl -s "http://$HOST:$PORT/api/sessions?limit=1" > "$work/s1.json"
    local sid
    sid=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[0]["id"] if d else "")' "$work/s1.json")
    if [ -n "$sid" ]; then
        curl -s "http://$HOST:$PORT/api/session?id=$sid" > "$work/sd.json"
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("session") and isinstance(d.get("parts"),list) else 1)' "$work/sd.json" && ok 'api/session detail' || bad 'api/session detail'
        curl -s "http://$HOST:$PORT/api/export/session?id=$sid&format=md" > "$work/exp.md"
        has '# ' "$work/exp.md" && ok 'api/export/session md' || bad 'api/export/session md'
        curl -s "http://$HOST:$PORT/api/search?q=the&limit=3" > "$work/search.json"
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d.get("sessions"),list) and isinstance(d.get("hits"),list) else 1)' "$work/search.json" && ok 'api/search' || bad 'api/search'
    else
        bad 'found a session id for endpoint tests'
    fi

    if [ -x "$REPO/scripts/cost-bottlenecks.sh" ]; then
        "$REPO/scripts/cost-bottlenecks.sh" --top 3 > "$work/cb.txt" 2>&1
        local cb_rc=$?
        if [ "$cb_rc" -eq 0 ] && has 'per_1k_in' "$work/cb.txt"; then ok 'cost-bottlenecks.sh runs'; else bad 'cost-bottlenecks.sh runs'; fi
    else
        bad 'cost-bottlenecks.sh present'
    fi

    kill -TERM "$srv" || true
    wait "$srv" || true

    printf '\n=== result: %d pass, %d fail ===\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ] && return 0 || return 1
}

main "$@"
