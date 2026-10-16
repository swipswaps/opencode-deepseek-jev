#!/usr/bin/env bash
#
# search-history.sh — durable-pi's `search_history`, locally.
#
# After a handoff, the fresh session must still reach the transcript it left
# behind (the pi-durable idea: compaction/reset never deletes history —
# `search_history` pages through all of it, before a compaction or a reset).
# This searches the STORED parts (text, tool, reasoning, patch) by substring,
# read-only, so the digest + brief + this = a complete handoff.
#
#   ./scripts/search-history.sh <text> [--session ID] [--limit N] [--json]
#   ./scripts/search-history.sh --self-test      # offline fixture
#
# Exit 0 matches, 1 none, 2 usage.
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

query() {
    # query DB TEXT SESSION LIMIT JSON -> matches on stdout; exit 0/1
    python3 - "$1" "$2" "$3" "$4" "$5" << 'PYEOF'
import json, sqlite3, sys
from datetime import datetime, timezone
db, text, sess, limit, as_json = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5] == "1"
con = sqlite3.connect("file:" + db + "?mode=ro", uri=True)
sql = ("SELECT p.session_id sid, p.time_created tc, "
       "json_extract(p.data,'$.type') t, "
       "substr(coalesce(json_extract(p.data,'$.text'), "
       "json_extract(p.data,'$.state.input.command'), "
       "json_extract(p.data,'$.tool'), ''),1,200) snip "
       "FROM part p WHERE json_extract(p.data,'$.type') IS NOT NULL AND p.data LIKE ? ")
args = ["%" + text + "%"]
if sess:
    sql += "AND p.session_id=? "
    args.append(sess)
sql += "ORDER BY p.time_created DESC LIMIT ?"
args.append(limit)
rows = list(con.execute(sql, args))
out = []
for r in rows:
    ts = datetime.fromtimestamp(r[1] / 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    out.append({"session": r[0], "ts": ts, "type": r[2], "snippet": " ".join((r[3] or "").split())[:180]})
if as_json:
    print(json.dumps({"query": text, "count": len(out), "matches": out}, indent=2))
else:
    print("=== search-history %r (session=%s) : %d match(es) ===" % (text, sess or "any", len(out)))
    for m in out:
        print("  %s  %s  [%s]  %s" % (m["session"][:24], m["ts"], m["type"], m["snippet"]))
sys.exit(0 if out else 1)
PYEOF
}

self_test() {
    local w rc
    w=$(mktemp -d)
    python3 - "$w/f.db" << 'PYEOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE part(session_id TEXT, time_created INTEGER, data TEXT)")
c.execute("INSERT INTO part VALUES('s1',1000,'{\"type\":\"text\",\"text\":\"the flaky login test story\"}')")
c.execute("INSERT INTO part VALUES('s1',2000,'{\"type\":\"tool\",\"tool\":\"bash\",\"state\":{\"input\":{\"command\":\"pytest -k login\"}}}')")
c.commit()
PYEOF
    query "$w/f.db" "login" "" 10 1 > "$w/o.json"; rc=$?
    grep -q '"count": 2' "$w/o.json" || { printf 'FAIL match count\n'; rm -f "$w/f.db" "$w/o.json"; rmdir "$w"; return 1; }
    query "$w/f.db" "zzzznope" "" 10 0 > "$w/n.txt"; rc2=$?
    [ "$rc2" -eq 1 ] || { printf 'FAIL no-match exit\n'; rm -f "$w/f.db" "$w/o.json" "$w/n.txt"; rmdir "$w"; return 1; }
    rm -f "$w/f.db" "$w/o.json" "$w/n.txt"
    rmdir "$w"
    printf 'search-history: self-test PASS\n'
}

main() {
    local REPO TEXT="" SESS="" LIMIT=20 JSON=0
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    [ -z "$REPO" ] && { printf 'GATE FAIL: cannot resolve repo root\n'; return 2; }
    while [ $# -gt 0 ]; do
        case "$1" in
            --session) SESS="${2:-}"; shift 2 ;;
            --limit) LIMIT="${2:-20}"; shift 2 ;;
            --json) JSON=1; shift ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) printf 'usage: %s <text> [--session ID] [--limit N] [--json] [--self-test]\n' "$0"; return 0 ;;
            -*) printf 'unknown arg: %s\n' "$1"; return 2 ;;
            *) TEXT="$1"; shift ;;
        esac
    done
    [ -n "$TEXT" ] || { printf 'usage: %s <text> [--session ID] [--limit N] [--json]\n' "$0"; return 2; }
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 1; }
    local DB="${SEARCH_DB:-$REPO/data/opencode/opencode.db}"
    [ -f "$DB" ] || { printf 'FAIL: no %s\n' "$DB"; return 1; }
    query "$DB" "$TEXT" "$SESS" "$LIMIT" "$JSON"
}

main "$@"
