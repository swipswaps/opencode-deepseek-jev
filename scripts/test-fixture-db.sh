#!/usr/bin/env bash
#
# test-fixture-db.sh — build a small opencode.db fixture for the contract tests.
#
# The DB-reading tools (audit-tool-calls, prompt-lint, issue-solutions,
# learn-rules, sentinel, session-guard) need only the session/message/part/todo
# schema and a little realistic data; scanning the LIVE 626 MB store inside a
# gate is pure cost. This seeds a few-KB fixture so those contracts run in
# milliseconds. Same schema the real store uses (columns only; no FK enforcement).
#
#   ./scripts/test-fixture-db.sh [--out PATH]   # prints the db path
#   ./scripts/test-fixture-db.sh --self-test
#
# Env: none. Stdlib only (python3). No model calls.
#
# Plain ASCII. No sed. No rm -rf. No set -e. No 2>/dev/null. No subprocess.run.
#
set -o pipefail

have() { command -v "$1" >/dev/null 2>&1; }

build() {
    # build PATH — create the fixture at PATH (overwrites).
    python3 - "$1" <<'PY'
import json, sqlite3, sys

path = sys.argv[1]
con = sqlite3.connect(path)
con.execute("CREATE TABLE session(id TEXT PRIMARY KEY, project_id TEXT, workspace_id TEXT, parent_id TEXT, slug TEXT, directory TEXT, path TEXT, title TEXT, version TEXT, share_url TEXT, summary_additions INTEGER, summary_deletions INTEGER, summary_files INTEGER, summary_diffs TEXT, metadata TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, revert TEXT, permission TEXT, agent TEXT, model TEXT, time_created INTEGER, time_updated INTEGER, time_compacting INTEGER, time_archived INTEGER)")
con.execute("CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)")
con.execute("CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)")
con.execute("CREATE TABLE todo(session_id TEXT, content TEXT, status TEXT, priority TEXT, position INTEGER, time_created INTEGER, time_updated INTEGER)")
con.execute("CREATE TABLE session_message(id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT)")

now = 1792000000000
model = json.dumps({"id": "deepseek-v4.1-flash", "providerID": "deepseek"})
con.execute("INSERT INTO session(id,project_id,slug,directory,title,version,cost,tokens_input,tokens_output,tokens_reasoning,model,time_created,time_updated) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
            ("ses_fixture1", "prj1", "fixture", "/workspace", "Fixture session", "1.0", 0.02, 1234, 200, 0, model, now - 60000, now))
con.execute("INSERT INTO message VALUES(?,?,?,?,?)", ("msg_u1", "ses_fixture1", now - 60000, now - 60000, json.dumps({"role": "user"})))
con.execute("INSERT INTO message VALUES(?,?,?,?,?)", ("msg_a1", "ses_fixture1", now - 55000, now - 55000, json.dumps({"role": "assistant"})))
con.execute("INSERT INTO part VALUES(?,?,?,?,?,?)", ("prt_t1", "msg_u1", "ses_fixture1", now - 60000, now - 60000, json.dumps({"type": "text", "text": "audit the page and fix the broken call in the script"})))
con.execute("INSERT INTO part VALUES(?,?,?,?,?,?)", ("prt_tool_err", "msg_a1", "ses_fixture1", now - 58000, now - 57000, json.dumps({"type": "tool", "tool": "bash", "state": {"status": "error", "input": {"command": "cat no-such-file.sh"}, "error": "No such file or directory"}})))
con.execute("INSERT INTO part VALUES(?,?,?,?,?,?)", ("prt_tool_ok", "msg_a1", "ses_fixture1", now - 56000, now - 55000, json.dumps({"type": "tool", "tool": "bash", "state": {"status": "completed", "input": {"command": "awk 'NR==1' scripts/x.sh"}, "output": "ok"}})))
con.execute("INSERT INTO part VALUES(?,?,?,?,?,?)", ("prt_t2", "msg_a1", "ses_fixture1", now - 54000, now - 54000, json.dumps({"type": "text", "text": "done: fixed the broken call"})))
con.execute("INSERT INTO part VALUES(?,?,?,?,?,?)", ("prt_r1", "msg_a1", "ses_fixture1", now - 59000, now - 59000, json.dumps({"type": "reasoning", "text": "the broken call fails here"})))
con.execute("INSERT INTO todo VALUES(?,?,?,?,?,?,?)", ("ses_fixture1", "replace the broken call with awk", "completed", "high", 0, now - 59000, now - 54000))
con.execute("INSERT INTO session_message VALUES(?,?,?,?,?,?,?)", ("sm1", "ses_fixture1", "text", 1, now - 54000, now - 54000, json.dumps({"type": "text"})))
con.commit()
con.close()
print(path)
PY
}

self_test() {
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    local work fail=0 out=""
    work=$(mktemp -d)
    out=$(build "$work/fix.db" 2>&1)
    if [ ! -s "$work/fix.db" ]; then printf 'FAIL fixture not written\n'; fail=1; fi
    python3 - "$work/fix.db" <<'PY' || { printf 'FAIL fixture schema/data\n'; fail=1; }
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
assert c.execute("SELECT count(*) FROM session").fetchone()[0] == 1
assert c.execute("SELECT count(*) FROM part").fetchone()[0] >= 4
assert c.execute("SELECT count(*) FROM part WHERE data LIKE '%error%'").fetchone()[0] >= 1
PY
    rm -f "$work/fix.db"
    rmdir "$work"
    if [ "$fail" -eq 0 ]; then printf 'test-fixture-db: self-test PASS\n'; else printf 'test-fixture-db: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    local OUT=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --out) OUT="${2:-}"; shift 2 ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) printf 'usage: %s [--out PATH] [--self-test]\n' "$0"; return 0 ;;
            *) printf 'unknown arg: %s\n' "$1"; return 2 ;;
        esac
    done
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 2; }
    if [ -z "$OUT" ]; then
        OUT=$(mktemp -d)/opencode.db
    fi
    build "$OUT"
    return 0
}

main "$@"
