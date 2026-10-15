#!/usr/bin/env bash
#
# notify.sh — push recent sentinel FAIL flags to a webhook sink.
#
# The gap vs the LLM-observability tools (Langfuse/Phoenix): they ALERT; this
# stack only logged ADVISORY rows to the ledger. This reads the ledger
# (observability.db, type=ADVISORY verdict=FAIL), builds JSON, and POSTs it to
# $NOTIFY_WEBHOOK — no model spend, no backend, no new service.
#
#   NOTIFY_WEBHOOK=<url> ./scripts/notify.sh [--last N] [--dry-run]
#   ./scripts/notify.sh --self-test        # offline fixture
#
# No webhook set -> prints the payload and exits 0 (SKIP, not a failure).
# Exit 0 ok/skip, 1 post failed, 2 usage.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.
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

payload() {
    # payload DB N -> JSON on stdout
    python3 - "$1" "$2" << 'PYEOF'
import json, sqlite3, sys
db, n = sys.argv[1], int(sys.argv[2])
con = sqlite3.connect("file:" + db + "?mode=ro", uri=True)
rows = list(con.execute(
    "SELECT ts,resource,detail FROM ledger WHERE type='ADVISORY' AND verdict='FAIL' "
    "ORDER BY id DESC LIMIT ?", (n,)))
print(json.dumps({"source": "sentinel", "count": len(rows),
                  "flags": [{"ts": r[0], "resource": r[1], "detail": r[2]} for r in rows]}))
PYEOF
}

self_test() {
    local w out
    w=$(mktemp -d)
    python3 - "$w/o.db" << 'PYEOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE ledger(id INTEGER PRIMARY KEY, ts TEXT, resource TEXT, detail TEXT, type TEXT, verdict TEXT)")
c.execute("INSERT INTO ledger(ts,resource,detail,type,verdict) VALUES('t','r','d','ADVISORY','FAIL')")
c.commit()
PYEOF
    out=$(payload "$w/o.db" 5)
    printf '%s' "$out" | grep -q '"count": 1' || { printf 'FAIL payload count\n'; rm -f "$w/o.db"; rmdir "$w"; return 1; }
    rm -f "$w/o.db"
    rmdir "$w"
    printf 'notify: self-test PASS\n'
}

main() {
    local REPO N=10 DRY=0
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    [ -z "$REPO" ] && { printf 'GATE FAIL: cannot resolve repo root\n'; return 2; }
    while [ $# -gt 0 ]; do
        case "$1" in
            --last) N="${2:-10}"; shift 2 ;;
            --dry-run) DRY=1; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) printf 'usage: NOTIFY_WEBHOOK=<url> %s [--last N] [--dry-run] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 1; }
    local DB="$REPO/data/observability/observability.db"
    [ -f "$DB" ] || { printf 'FAIL: no %s\n' "$DB"; return 1; }
    local pl
    pl=$(payload "$DB" "$N")
    if [ "$DRY" -eq 1 ]; then
        printf '%s\n' "$pl"
        return 0
    fi
    if [ -z "${NOTIFY_WEBHOOK:-}" ]; then
        printf 'SKIP: NOTIFY_WEBHOOK unset — payload built, not sent\n'
        return 0
    fi
    have curl || { printf 'FAIL: curl required to POST\n'; return 1; }
    local code
    code=$(printf '%s' "$pl" | curl -sS -o /dev/null -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' --data-binary @- "$NOTIFY_WEBHOOK")
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'FAIL: POST failed (curl rc=%s)\n' "$rc"
        return 1
    fi
    case "$code" in
        2*) printf 'POST ok (http %s), up to %s flag(s)\n' "$code" "$N" ;;
        *) printf 'FAIL: webhook returned http %s\n' "$code"; return 1 ;;
    esac
    return 0
}

main "$@"
