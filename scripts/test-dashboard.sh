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

# --- diagnostic telemetry: ms= on every check line (see lint.sh) ---------
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
    local n
    n=$(now_ms)
    D=$((n - LAST_MS))
    LAST_MS=$n
    if [ "$D" -gt "$SLOW_MS" ]; then SLOW_MS=$D; SLOW_MSG="$1"; fi
}
ok()  { PASS=$((PASS+1)); _stamp "$1"; printf 'ts=%s ms=%s level=INFO  status=PASS msg=%s\n' "$(date -u +%H:%M:%S)" "$D" "$1"; }
bad() { FAIL=$((FAIL+1)); _stamp "$1"; printf 'ts=%s ms=%s level=ERROR status=FAIL msg=%s\n' "$(date -u +%H:%M:%S)" "$D" "$1"; }

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
    has 'href="/runbooks"' "$work/home.html" && ok 'home nav runbooks' || bad 'home nav runbooks'
    has 'href="/explore"' "$work/home.html" && ok 'home nav explore' || bad 'home nav explore'
    has 'href="/docs"' "$work/home.html" && ok 'home nav docs' || bad 'home nav docs'

    curl -s "http://$HOST:$PORT/explore" > "$work/explore.html"
    has '<title>opencode explore</title>' "$work/explore.html" && ok 'explore title' || bad 'explore title'
    has 'id="treemap"' "$work/explore.html" && ok 'explore treemap section' || bad 'explore treemap section'
    has 'id="burn"' "$work/explore.html" && ok 'explore burn section' || bad 'explore burn section'
    has 'id="scatter"' "$work/explore.html" && ok 'explore scatter section' || bad 'explore scatter section'
    has 'id="sankey"' "$work/explore.html" && ok 'explore sankey section' || bad 'explore sankey section'
    has 'id="cloud"' "$work/explore.html" && ok 'explore word-cloud section (restored)' || bad 'explore word-cloud section (restored)'
    has 'id="q2"' "$work/explore.html" && ok 'explore search box' || bad 'explore search box'
    has 'id="stable"' "$work/explore.html" && ok 'explore sessions table' || bad 'explore sessions table'
    has 'id="integrations"' "$work/explore.html" && ok 'explore integrations' || bad 'explore integrations'
    has 'id="dmap"' "$work/explore.html" && ok 'explore db map' || bad 'explore db map'
    has 'id="ocr"' "$work/explore.html" && ok 'explore ocr section' || bad 'explore ocr section'
    has 'data-tab="charts"' "$work/explore.html" && ok 'explore tabs' || bad 'explore tabs'
    has 'id="tabs"' "$work/explore.html" && ok 'explore tabs wired (id=tabs)' || bad 'explore tabs wired (id=tabs)'
    has 'data-tab="overview"' "$work/explore.html" && ok 'explore tab is linkable (hash)' || bad 'explore tab is linkable (hash)'
    has 'id="dupes"' "$work/explore.html" && ok 'explore duplicates section' || bad 'explore duplicates section'
    has 'id="ab"' "$work/explore.html" && ok 'explore ab section' || bad 'explore ab section'
    has 'id="guard"' "$work/explore.html" && ok 'explore guard section' || bad 'explore guard section'
    has 'class="nav"' "$work/explore.html" && ok 'shared nav present' || bad 'shared nav present'
    curl -s "http://$HOST:$PORT/docs" > "$work/docs.html"
    has '<title>opencode docs</title>' "$work/docs.html" && ok 'docs title' || bad 'docs title'
    has 'id="docsel"' "$work/docs.html" && ok 'docs selector' || bad 'docs selector'
    has 'id="docbody"' "$work/docs.html" && ok 'docs body' || bad 'docs body'
    curl -s "http://$HOST:$PORT/api/doc?name=RULES.md" > "$work/doc.txt"
    has 'Substitutions for the blacklist' "$work/doc.txt" && ok 'api/doc serves RULES.md' || bad 'api/doc serves RULES.md'
    curl -s -o /dev/null -w '%{http_code}' "http://$HOST:$PORT/api/doc?name=../../etc/passwd" > "$work/doc404.txt"
    has '404' "$work/doc404.txt" && ok 'api/doc rejects non-whitelisted path' || bad 'api/doc rejects non-whitelisted path'
    curl -s -o /dev/null -w '%{http_code}' "http://$HOST:$PORT/viz" > "$work/vizcode.txt"
    has '302' "$work/vizcode.txt" && ok '/viz redirects (302)' || bad '/viz redirects (302)'
    curl -s -o /dev/null -w '%{http_code}' "http://$HOST:$PORT/vendor/d3.min.js" > "$work/d3code.txt"
    has '200' "$work/d3code.txt" && ok 'vendored d3 served' || bad 'vendored d3 served'
    curl -s -o /dev/null -w '%{http_code}' "http://$HOST:$PORT/vendor/d3-sankey.min.js" > "$work/skcode.txt"
    has '200' "$work/skcode.txt" && ok 'vendored d3-sankey served' || bad 'vendored d3-sankey served'

    curl -s "http://$HOST:$PORT/runbooks" > "$work/runbooks.html"
    has '<title>opencode runbooks</title>' "$work/runbooks.html" && ok 'runbooks title' || bad 'runbooks title'
    has 'Operational scripts surfaced' "$work/runbooks.html" && ok 'runbooks subtitle' || bad 'runbooks subtitle'
    has 'host only' "$work/runbooks.html" && ok 'filter: host only' || bad 'filter: host only'
    has 'container only' "$work/runbooks.html" && ok 'filter: container only' || bad 'filter: container only'
    has 'id="count"' "$work/runbooks.html" && ok 'runbooks count element' || bad 'runbooks count element'

    local page pname
    for page in "$work/home.html" "$work/explore.html" "$work/runbooks.html" "$work/docs.html"; do
        pname=$(basename "$page")
        python3 -c 'import sys,re; h=open(sys.argv[1]).read(); m=re.search(r"<script>(.*?)</script>", h, re.S); sys.stdout.write(m.group(1) if m else "")' "$page" > "$work/${pname}.js"
        if [ -s "$work/${pname}.js" ] && node --check "$work/${pname}.js" 2>"$work/${pname}.err"; then
            ok "inline script parses ($pname)"
        else
            bad "inline script parses ($pname)"
            cat "$work/${pname}.err"
        fi
    done

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
    has 'count=16' "$work/rbcheck.txt" && ok 'runbooks count=16' || bad 'runbooks count=16'

    if [ -x "$REPO/scripts/runbook.sh" ]; then
        "$REPO/scripts/runbook.sh" --list > "$work/rblist.txt"
        local rl_rc=$?
        if [ "$rl_rc" -eq 0 ]; then ok 'runbook.sh --list exits 0'; else bad 'runbook.sh --list exits 0'; fi
        has 'rotate-password|host' "$work/rblist.txt" && ok 'runbook.sh lists rotate-password' || bad 'runbook.sh lists rotate-password'
        has 'litellm|host' "$work/rblist.txt" && ok 'runbook.sh lists litellm' || bad 'runbook.sh lists litellm'
        has 'laya|host' "$work/rblist.txt" && ok 'runbook.sh lists laya' || bad 'runbook.sh lists laya'
        has 'connect-vision|host' "$work/rblist.txt" && ok 'runbook.sh lists connect-vision' || bad 'runbook.sh lists connect-vision'
        has 'ocr-image|container' "$work/rblist.txt" && ok 'runbook.sh lists ocr-image' || bad 'runbook.sh lists ocr-image'
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
        curl -s "http://$HOST:$PORT/api/semantic?q=the&limit=3" > "$work/sem.json"
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("mode")=="fts" and isinstance(d.get("results"),list) else 1)' "$work/sem.json" && ok 'api/semantic (fts)' || bad 'api/semantic (fts)'
        curl -s "http://$HOST:$PORT/api/overview?limit=5" > "$work/ov.json"
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d.get("sessions"),list) and "budget" in d else 1)' "$work/ov.json" && ok 'api/overview' || bad 'api/overview'
        curl -s "http://$HOST:$PORT/api/schema" > "$work/schema.json"
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("tables") and isinstance(d.get("edges"),list) else 1)' "$work/schema.json" && ok 'api/schema' || bad 'api/schema'
        curl -s "http://$HOST:$PORT/api/integrations" > "$work/integ.json"
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if "jev" in d and "laya" in d else 1)' "$work/integ.json" && ok 'api/integrations' || bad 'api/integrations'
        curl -s "http://$HOST:$PORT/api/ab" > "$work/ab.json"
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d.get("runs"),list) and isinstance(d.get("summary"),dict) else 1)' "$work/ab.json" && ok 'api/ab' || bad 'api/ab'
        curl -s "http://$HOST:$PORT/api/signals" > "$work/sig.json"
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if "signatures" in d else 1)' "$work/sig.json" && ok 'api/signals' || bad 'api/signals'
        curl -s "http://$HOST:$PORT/api/guard" > "$work/guard.json"
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if "count" in d and isinstance(d.get("actions"),list) else 1)' "$work/guard.json" && ok 'api/guard' || bad 'api/guard'
        curl -s "http://$HOST:$PORT/api/ocr" > "$work/ocr.json"
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d.get("runs"),list) and "count" in d else 1)' "$work/ocr.json" && ok 'api/ocr' || bad 'api/ocr'
        curl -s "http://$HOST:$PORT/api/duplicates" > "$work/dupes.json"
        python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d,list) else 1)' "$work/dupes.json" && ok 'api/duplicates' || bad 'api/duplicates'
        curl -s "http://$HOST:$PORT/api/export/ocr" > "$work/ocr.csv"
        has 'id,ts,image' "$work/ocr.csv" && ok 'api/export/ocr csv' || bad 'api/export/ocr csv'
    else
        bad 'found a session id for endpoint tests'
    fi

    if [ -f "$REPO/scripts/test-dashboard-ui.mjs" ]; then
        if node "$REPO/scripts/test-dashboard-ui.mjs" "http://$HOST:$PORT" > "$work/ui.txt" 2>&1; then
            ok 'headless UI: dashboard panes populate'
        else
            bad 'headless UI: dashboard panes populate'
            cat "$work/ui.txt"
        fi
        if node "$REPO/scripts/test-dashboard-ui.mjs" "http://$HOST:$PORT" explore > "$work/ui-x.txt" 2>&1; then
            ok 'headless UI: explore script executes'
        else
            bad 'headless UI: explore script executes'
            cat "$work/ui-x.txt"
        fi
    else
        bad 'test-dashboard-ui.mjs present'
    fi

    if [ -x "$REPO/scripts/cost-bottlenecks.sh" ]; then
        "$REPO/scripts/cost-bottlenecks.sh" --top 3 > "$work/cb.txt" 2>&1
        local cb_rc=$?
        if [ "$cb_rc" -eq 0 ] && has 'per_1k_in' "$work/cb.txt"; then ok 'cost-bottlenecks.sh runs'; else bad 'cost-bottlenecks.sh runs'; fi
    else
        bad 'cost-bottlenecks.sh present'
    fi

    if [ -x "$REPO/scripts/semantic-search.sh" ]; then
        "$REPO/scripts/semantic-search.sh" --rebuild > "$work/idx.txt" 2>&1
        local si_rc=$?
        if [ "$si_rc" -eq 0 ] && has 'indexed' "$work/idx.txt"; then ok 'semantic-search.sh builds index'; else bad 'semantic-search.sh builds index'; fi
    else
        bad 'semantic-search.sh present'
    fi

    if [ -x "$REPO/scripts/lint.sh" ]; then
        "$REPO/scripts/lint.sh" > "$work/lint.txt" 2>&1
        local lint_rc=$?
        if [ "$lint_rc" -eq 0 ]; then ok 'lint.sh passes'; else bad 'lint.sh passes'; tail -6 "$work/lint.txt"; fi
    else
        bad 'lint.sh present'
    fi

    if [ -x "$REPO/scripts/test-hygiene.sh" ]; then
        "$REPO/scripts/test-hygiene.sh" > "$work/hygiene.txt" 2>&1
        local hyg_rc=$?
        if [ "$hyg_rc" -eq 0 ]; then ok 'test-hygiene.sh passes'; else bad 'test-hygiene.sh passes'; tail -6 "$work/hygiene.txt"; fi
    else
        bad 'test-hygiene.sh present'
    fi

    if [ -f "$REPO/scripts/ocr-tesseractjs.mjs" ]; then
        node "$REPO/scripts/ocr-tesseractjs.mjs" --self-test > "$work/downscale.txt" 2>&1
        local ds_rc=$?
        if [ "$ds_rc" -eq 0 ] && has 'downscale' "$work/downscale.txt"; then ok 'ocr downscale self-test'; else bad 'ocr downscale self-test'; cat "$work/downscale.txt"; fi
    else
        bad 'ocr-tesseractjs.mjs present'
    fi

    if [ -f "$REPO/scripts/ux-audit.py" ]; then
        if python3 -m py_compile "$REPO/scripts/ux-audit.py"; then ok 'ux-audit.py compiles'; else bad 'ux-audit.py compiles'; fi
    else
        bad 'ux-audit.py present'
    fi

    kill -TERM "$srv" || true
    wait "$srv" || true

    if [ -n "$SLOW_MSG" ]; then
        printf 'slowest: %s (%sms)\n' "$SLOW_MSG" "$SLOW_MS"
    fi
    printf '\n=== result: %d pass, %d fail ===\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ] && return 0 || return 1
}

main "$@"
