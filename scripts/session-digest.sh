#!/usr/bin/env bash
#
# session-digest.sh — deterministic, DB-ONLY digest of ONE session's current
# state, for a handoff WITHOUT replaying the transcript into an LLM.
#
# Why this exists (the "non-latest, over-budget, not deny-listed" problem):
# an over-budget session cannot be fixed in place — every turn re-sends its
# whole context (the cost driver) — and --fork/--continue copies that context
# forward. The way out is a FRESH session plus the FEW critical facts.
# handoff-brief.sh derives those from a full transcript (606 KB -> ~2.9 KB);
# this reads the DATABASE directly and emits a bounded digest in one pass, so
# there is no large transcript file at rest holding secret-shaped lines, and
# no model call is ever made (no spend). Curate the facts, do not replay the
# history into a model.
#
#   ./scripts/session-digest.sh <session-id> [--db PATH] [--max-bytes N]
#   ./scripts/session-digest.sh --self-test   # offline fixture, no network
#
# Read-only (SQLite mode=ro). Output is passed through redact.mjs when node
# is available. Exit 0 digest, 1 unknown session, 2 usage error.
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
            printf '%s' "$c"
            return 0
        fi
        c=$(dirname "$c")
    done
    return 1
}

digest() {
    # digest DB SID BUDGET MAXB -> digest markdown on stdout
    python3 - "$1" "$2" "$3" "$4" << 'PYEOF'
import json, sqlite3, sys
from datetime import datetime, timezone

db, sid, budget, maxb = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
con = sqlite3.connect("file:" + db + "?mode=ro", uri=True)
con.row_factory = sqlite3.Row

s = con.execute("SELECT * FROM session WHERE id=?", (sid,)).fetchone()
if s is None:
    print("unknown session: " + sid)
    sys.exit(3)

def model_id(m):
    try:
        o = json.loads(m)
        if isinstance(o, dict):
            return o.get("id") or o.get("modelID") or m
        return o or m
    except Exception:
        return m or "(none)"

def iso(ms):
    try:
        return datetime.fromtimestamp(int(ms) / 1000.0, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except Exception:
        return "?"

def age(ms):
    try:
        s = (datetime.now(timezone.utc).timestamp() - int(ms) / 1000.0)
        if s < 3600:
            return "%dm" % (s / 60)
        if s < 86400:
            return "%.1fh" % (s / 3600)
        return "%.1fd" % (s / 86400)
    except Exception:
        return "?"

def last_text(role):
    r = con.execute(
        "SELECT p.data FROM part p JOIN message m ON m.id=p.message_id "
        "WHERE p.session_id=? AND json_extract(m.data,'$.role')=? "
        "AND json_extract(p.data,'$.type')='text' ORDER BY p.time_created DESC LIMIT 1",
        (sid, role),
    ).fetchone()
    if r is None:
        return ""
    try:
        return " ".join((json.loads(r[0]).get("text") or "").split())
    except Exception:
        return ""

def clip(t, n):
    return t if len(t) <= n else t[: n - 1] + "\u2026"

in_tok = int(s["tokens_input"] or 0)
ratio = (in_tok / budget) if budget else 0.0
parts = con.execute("SELECT COUNT(*) FROM part WHERE session_id=?", (sid,)).fetchone()[0]
msgs = con.execute("SELECT COUNT(*) FROM message WHERE session_id=?", (sid,)).fetchone()[0]
todos = con.execute(
    "SELECT content, status FROM todo WHERE session_id=? "
    "AND status IN ('pending','in_progress') ORDER BY position ASC LIMIT 10",
    (sid,),
).fetchall()
rt = con.execute(
    "SELECT json_extract(data,'$.tool') t, json_extract(data,'$.state.input.command') c, "
    "time_created tc FROM part WHERE session_id=? AND json_extract(data,'$.type')='tool' "
    "AND json_extract(data,'$.state.status')='running' ORDER BY time_created DESC LIMIT 1",
    (sid,),
).fetchone()

out = []
out.append("# Session digest \u2014 " + sid)
out.append("")
out.append("title:  " + (s["title"] or "(untitled)"))
out.append("model:  " + str(model_id(s["model"])) + "  agent: " + str(s["agent"] or "?"))
out.append("dir:    " + str(s["directory"] or "?") + "  version: " + str(s["version"] or "?"))
out.append("time:   created " + iso(s["time_created"]) + "  updated " + iso(s["time_updated"]) + " (" + age(s["time_updated"]) + " ago)")
out.append("")
out.append("budget: in=%s (%.2fx of %s) \u00b7 cost=$%.4f \u00b7 out=%s \u00b7 reasoning=%s \u00b7 cache_read=%s" % (
    in_tok, ratio, budget, float(s["cost"] or 0), s["tokens_output"], s["tokens_reasoning"], s["tokens_cache_read"]))
out.append("size:   parts=%s \u00b7 messages=%s" % (parts, msgs))
out.append("")
out.append("## Last user ask")
out.append(clip(last_text("user"), 500) or "(none)")
out.append("")
out.append("## Last assistant text")
out.append(clip(last_text("assistant"), 500) or "(none)")
out.append("")
out.append("## Open todos (%d)" % len(todos))
for t in todos:
    out.append("- [%s] %s" % (t["status"], clip(" ".join((t["content"] or "").split()), 120)))
if not todos:
    out.append("- (none)")
if rt is not None:
    out.append("")
    out.append("## Running/stalled tool")
    out.append("%s running %s (started %s): %s" % (
        rt["t"] or "?", age(rt["tc"]), iso(rt["tc"]), clip(rt["c"] or "", 120)))
if ratio > 1:
    out.append("")
    out.append("## Over budget (%.2fx)" % ratio)
    out.append("STOP prompting this session. Start a FRESH session and paste this")
    out.append("digest; every further turn re-sends ~%s tokens. Never --fork/--continue." % in_tok)

text = "\n".join(out) + "\n"
if len(text) > maxb:
    text = text[: maxb - 20] + "\n\u2026 (truncated)\n"
sys.stdout.write(text)
PYEOF
}

self_test() {
    local fail=0 work out
    work=$(mktemp -d)
    python3 - "$work/fix.db" << 'PYEOF'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT, slug TEXT, directory TEXT, path TEXT, version TEXT, agent TEXT, model TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, time_created INTEGER, time_updated INTEGER)")
con.execute("CREATE TABLE message(id TEXT, session_id TEXT, data TEXT)")
con.execute("CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)")
con.execute("CREATE TABLE todo(id TEXT, session_id TEXT, content TEXT, status TEXT, priority TEXT, position INTEGER)")
con.execute("INSERT INTO session VALUES('s_over','User types ok','calm-canyon','/home/node/.opencode','','1.18.32','build','{\"id\":\"deepseek-v4.1-flash\"}',0.4945,2699178,96073,176523,81766270,0,1000,2000)")
con.execute("INSERT INTO message VALUES('mu','s_over','{\"role\":\"user\"}')")
con.execute("INSERT INTO message VALUES('ma','s_over','{\"role\":\"assistant\"}')")
con.execute("INSERT INTO part VALUES('pu','mu','s_over',1500,1500,'{\"type\":\"text\",\"text\":\"audit anew the page then upgrade the prompt\"}')")
con.execute("INSERT INTO part VALUES('pa','ma','s_over',1600,1600,'{\"type\":\"text\",\"text\":\"the digest should be bounded\"}')")
con.execute("INSERT INTO todo VALUES('t1','s_over','ship T7','pending','high',0)")
con.execute("INSERT INTO todo VALUES('t2','s_over','old thing','completed','',1)")
con.execute("INSERT INTO part VALUES('pr','ma','s_over',1700,1700,'{\"type\":\"tool\",\"tool\":\"bash\",\"state\":{\"status\":\"running\",\"input\":{\"command\":\"sleep 999\"}}}')")
con.commit()
PYEOF
    out=$(bash "${BASH_SOURCE[0]}" s_over --db "$work/fix.db" 2>&1)
    printf '%s' "$out" | grep -q '13.50x of 200000' || { printf 'FAIL digest reports ratio\n'; fail=1; }
    printf '%s' "$out" | grep -q 'audit anew the page' || { printf 'FAIL digest reports last user ask\n'; fail=1; }
    printf '%s' "$out" | grep -q 'ship T7' || { printf 'FAIL digest lists open todos\n'; fail=1; }
    printf '%s' "$out" | grep -q 'old thing' && { printf 'FAIL digest listed a completed todo\n'; fail=1; }
    printf '%s' "$out" | grep -q '## Over budget' || { printf 'FAIL digest flags over-budget directive\n'; fail=1; }
    printf '%s' "$out" | grep -q '## Running/stalled tool' || { printf 'FAIL digest reports running tool\n'; fail=1; }
    out=$(bash "${BASH_SOURCE[0]}" does_not_exist --db "$work/fix.db" 2>&1)
    printf '%s' "$out" | grep -q 'unknown session' || { printf 'FAIL digest rejects unknown session\n'; fail=1; }
    out=$(bash "${BASH_SOURCE[0]}" s_over --db "$work/fix.db" --max-bytes 200 2>&1)
    printf '%s' "$out" | grep -q 'truncated' || { printf 'FAIL digest honours --max-bytes\n'; fail=1; }
    rm -f "$work/fix.db"
    rmdir "$work"
    if [ "$fail" -eq 0 ]; then printf 'session-digest: self-test PASS\n'; else printf 'session-digest: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    [ -z "$REPO" ] && { printf 'GATE FAIL: cannot resolve repo root\n'; return 2; }
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 2; }
    local SID="" DB="" MAXB=2600 BUDGET="${CONTEXT_BUDGET:-200000}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --db) [ -n "$2" ] || { printf 'usage: %s <id> [--db PATH]\n' "$0"; return 2; }; DB="$2"; shift 2 ;;
            --max-bytes) [ -n "$2" ] || { printf 'usage: %s <id> [--max-bytes N]\n' "$0"; return 2; }; MAXB="$2"; shift 2 ;;
            --self-test) self_test; return "$?" ;;
            -h | --help) printf 'usage: %s <session-id> [--db PATH] [--max-bytes N] [--self-test]\n' "$0"; return 0 ;;
            -*) printf 'unknown arg: %s\n' "$1"; return 2 ;;
            *) SID="$1"; shift ;;
        esac
    done
    [ -n "$SID" ] || { printf 'usage: %s <session-id> [--db PATH] [--max-bytes N]\n' "$0"; return 2; }
    [ -n "$DB" ] || DB="$REPO/data/opencode/opencode.db"
    [ -f "$DB" ] || { printf 'FAIL: no database at %s\n' "$DB"; return 1; }
    local text
    text=$(digest "$DB" "$SID" "$BUDGET" "$MAXB")
    if printf '%s' "$text" | grep -q '^unknown session:'; then
        printf '%s\n' "$text"
        return 1
    fi
    if have node && [ -f "$REPO/scripts/redact.mjs" ]; then
        text=$(printf '%s' "$text" | node "$REPO/scripts/redact.mjs" 2>&1 || printf '%s' "$text")
    fi
    printf '%s\n' "$text"
    return 0
}

main "$@"
