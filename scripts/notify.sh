#!/usr/bin/env bash
#
# notify.sh — push recent sentinel FAIL flags to a webhook sink.
#
# The gap vs the LLM-observability tools (Langfuse/Phoenix): they ALERT; this
# stack only logged ADVISORY rows to the ledger. This reads the ledger
# (observability.db, type=ADVISORY verdict=FAIL), builds JSON, and POSTs it to
# $NOTIFY_WEBHOOK — no model spend, no backend, no new service.
#
#   NOTIFY_WEBHOOK=<url> ./scripts/notify.sh [--last N] [--dry-run] [--all]
#   ./scripts/notify.sh --self-test        # offline fixture
#
# Cursor-deduped by default: only ledger rows with id greater than the persisted
# cursor (data/observability/notify.cursor) are sent, and the cursor advances
# only after a successful POST. This stops the same last-N FAIL flags from being
# re-posted on every sentinel tick. --all / --force ignores the cursor.
#
# No webhook set -> prints the payload and exits 0 (SKIP, not a failure).
# Exit 0 ok/skip, 1 post failed, 2 usage.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No exit 1. No 2>/dev/null.
# No subprocess.run. No kill without signal.
#
set -o pipefail

have() { command -v "$1" > /dev/null; }

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
    # payload DB N SINCE -> line 1 cursor (max id), line 2 count, line 3 JSON
    python3 - "$1" "$2" "$3" << 'PYEOF'
import json, sqlite3, sys
db, n, since = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
con = sqlite3.connect("file:" + db + "?mode=ro", uri=True)
rows = list(con.execute(
    "SELECT id,ts,resource,detail FROM ledger WHERE type='ADVISORY' AND verdict='FAIL' "
    "AND id > ? ORDER BY id DESC LIMIT ?", (since, n)))
cursor = rows[0][0] if rows else since
print(cursor)
print(len(rows))
print(json.dumps({"source": "sentinel", "count": len(rows), "cursor": cursor,
                  "flags": [{"ts": r[1], "resource": r[2], "detail": r[3]} for r in rows]}))
PYEOF
}

self_test() {
    local w out cursor count
    w=$(mktemp -d)
    python3 - "$w/o.db" << 'PYEOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE ledger(id INTEGER PRIMARY KEY, ts TEXT, resource TEXT, detail TEXT, type TEXT, verdict TEXT)")
c.execute("INSERT INTO ledger(ts,resource,detail,type,verdict) VALUES('t','r','d','ADVISORY','FAIL')")
c.commit()
PYEOF
    out=$(payload "$w/o.db" 5 0)
    cursor=$(printf '%s\n' "$out" | awk 'NR==1{print;exit}')
    count=$(printf '%s\n' "$out" | awk 'NR==2{print;exit}')
    [ "$cursor" = "1" ] || { printf 'FAIL cursor=%s\n' "$cursor"; rm -f "$w/o.db"; rmdir "$w"; return 1; }
    [ "$count" = "1" ] || { printf 'FAIL payload count=%s\n' "$count"; rm -f "$w/o.db"; rmdir "$w"; return 1; }
    out=$(payload "$w/o.db" 5 1)
    count=$(printf '%s\n' "$out" | awk 'NR==2{print;exit}')
    [ "$count" = "0" ] || { printf 'FAIL cursor dedup count=%s\n' "$count"; rm -f "$w/o.db"; rmdir "$w"; return 1; }
    rm -f "$w/o.db"
    rmdir "$w"
    printf 'notify: self-test PASS (payload + cursor dedup)\n'
}

main() {
    local REPO N=10 DRY=0 FORCE=0
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    [ -z "$REPO" ] && { printf 'GATE FAIL: cannot resolve repo root\n'; return 2; }
    while [ $# -gt 0 ]; do
        case "$1" in
            --last) N="${2:-10}"; shift 2 ;;
            --dry-run) DRY=1; shift ;;
            --all | --force) FORCE=1; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) printf 'usage: NOTIFY_WEBHOOK=<url> %s [--last N] [--dry-run] [--all] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 1; }
    local DB="$REPO/data/observability/observability.db"
    [ -f "$DB" ] || { printf 'FAIL: no %s\n' "$DB"; return 1; }
    local CURSOR_FILE="$REPO/data/observability/notify.cursor" since=0
    if [ "$FORCE" -eq 0 ] && [ -f "$CURSOR_FILE" ]; then
        since=$(cat "$CURSOR_FILE")
    fi
    case "$since" in '' | *[!0-9]*) since=0 ;; esac
    local out cursor count pl
    out=$(payload "$DB" "$N" "$since")
    cursor=$(printf '%s\n' "$out" | awk 'NR==1{print;exit}')
    count=$(printf '%s\n' "$out" | awk 'NR==2{print;exit}')
    pl=$(printf '%s\n' "$out" | awk 'NR>=3')
    case "$count" in '' | *[!0-9]*) count=0 ;; esac
    if [ "$count" -eq 0 ]; then
        printf 'SKIP: no new FAIL flags since cursor=%s\n' "$since"
        return 0
    fi
    if [ "$DRY" -eq 1 ]; then
        printf '%s\n' "$pl"
        return 0
    fi
    if [ -z "${NOTIFY_WEBHOOK:-}" ]; then
        printf 'SKIP: NOTIFY_WEBHOOK unset — %s new flag(s) not sent (cursor stays %s)\n' "$count" "$since"
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
        2*)
            mkdir -p "$(dirname "$CURSOR_FILE")"
            printf '%s\n' "$cursor" > "$CURSOR_FILE"
            printf 'POST ok (http %s), %s new flag(s), cursor=%s\n' "$code" "$count" "$cursor"
            ;;
        *) printf 'FAIL: webhook returned http %s\n' "$code"; return 1 ;;
    esac
    return 0
}

main "$@"
