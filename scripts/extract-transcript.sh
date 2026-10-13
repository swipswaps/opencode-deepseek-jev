#!/usr/bin/env bash
#
# extract-transcript.sh — transcript from the store, no browser required.
#
# re-extract-session.sh reproduces a browser extract (DOM + CDP + the
# /session/:id/message route). That chain fails exactly when you need it
# most: the message route stalls under a saturating loop, and headless
# hosts have no rendering tab. This reads messages+parts straight from
# opencode.db (read-only) and writes the same markdown shape, so
# handoff-brief.sh (which accepts logs/ses_<id>.txt) keeps working.
#
# Same fidelity contract as re-extract: reasoning capped at 300 chars, tool
# I/O at 1500, every cap prints its mark. Point-in-time snapshot: a live
# session keeps writing while this reads; the brief says so.
#
# Secrets note: pasted `env` blocks come along verbatim. The file is
# gitignored logs/, and handoff-brief.sh redacts on export — never paste
# the raw transcript into a session.
#
#   ./scripts/extract-transcript.sh <session-id> [--out FILE] [--max-parts N]
#   ./scripts/extract-transcript.sh --self-test   # offline fixture
#
# Exit 0 on write, 1 when the session has no messages, 2 on usage errors.
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

dump_py() {
    # dump_py DB SESSION OUT MAXPARTS — see header for the contract.
    python3 - "$1" "$2" "$3" "$4" << 'PYEOF'
import json, sqlite3, sys, datetime
dbp, sid, outp, maxparts = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
con = sqlite3.connect("file:" + dbp + "?mode=ro", uri=True)
srow = con.execute("SELECT title FROM session WHERE id=?", (sid,)).fetchone()
if srow is None:
    print("FAIL: unknown session " + sid)
    raise SystemExit(1)
msgs = con.execute("SELECT id, data, time_created FROM message WHERE session_id=? ORDER BY time_created", (sid,)).fetchall()
if not msgs:
    print("FAIL: session has no messages")
    raise SystemExit(1)
def cut(s, n):
    s = s or ""
    return s[:n] + (" [...%d chars capped]" % (len(s) - n) if len(s) > n else "")
def ts(ms):
    try:
        return datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    except Exception:
        return str(ms)
lines = ["# %s - %s" % (sid, (srow[0] or "")), ""]
nparts = 0
for mid, mdata, mtc in msgs:
    try:
        m = json.loads(mdata or "{}")
    except Exception:
        continue
    role = m.get("role", "?")
    lines += ["## %s %s %s" % (role, mid, ts(mtc)), ""]
    utext = m.get("text") or ""
    if role == "user" and utext.strip():
        lines += [cut(utext.strip(), 2000), ""]
    for pid, pdata in con.execute(
            "SELECT id, data FROM part WHERE message_id=? ORDER BY time_created LIMIT 200", (mid,)):
        if nparts >= maxparts:
            break
        nparts += 1
        try:
            p = json.loads(pdata or "{}")
        except Exception:
            continue
        t = p.get("type", "?")
        st = p.get("state") or {}
        if t == "text":
            body = ""
            if isinstance(p.get("text"), str):
                body = p["text"]
            elif isinstance(st.get("text"), str):
                body = st["text"]
            if body.strip():
                lines += [cut(body.strip(), 2000), ""]
        elif t == "reasoning":
            lines += ["[reasoning]", cut(str(p.get("text") or st.get("text") or ""), 300), ""]
        elif t == "tool":
            inp = st.get("input") or {}
            out = st.get("output") or ""
            lines += ["[%s %s]" % (st.get("tool") or p.get("tool") or "tool", pid),
                      "input: " + cut(json.dumps(inp)[:1500], 1500),
                      "output: " + cut(str(out)[:1500], 1500), ""]
        elif t in ("step-start", "step-finish"):
            lines += ["[%s]" % t, ""]
    if nparts >= maxparts:
        lines += ["[...part cap %d reached; snapshot]" % maxparts, ""]
        break
lines += ["snapshot of a live store; session kept writing after this point", ""]
open(outp, "w").write("\n".join(lines))
print("wrote %s (%d bytes, %d msgs, %d parts)" % (outp, len("\n".join(lines)), len(msgs), nparts))
PYEOF
}

self_test() {
    local fail=0 work=""
    have python3 || { printf 'FAIL python3 missing\n'; return 1; }
    work=$(mktemp -d)
    python3 - "$work/fix.db" << 'PYEOF'
import sqlite3, json, sys
con = sqlite3.connect(sys.argv[1])
con.execute('CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT)')
con.execute('CREATE TABLE message(id TEXT, session_id TEXT, data TEXT, time_created INTEGER)')
con.execute('CREATE TABLE part(id TEXT, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)')
con.execute("INSERT INTO session VALUES('s1','t')")
con.execute("INSERT INTO message VALUES('m1','s1',?,1000)", (json.dumps({"role": "user", "text": "goal here"}),))
con.execute("INSERT INTO part VALUES('p1','m1','s1',1001,1002,?)", (json.dumps({"type": "tool", "state": {"tool": "bash", "status": "completed", "input": {"command": "ls"}, "output": "ok"}}),))
con.execute("INSERT INTO part VALUES('p2','m1','s1',1003,1003,?)", (json.dumps({"type": "reasoning", "text": "x" * 500}),))
con.commit()
PYEOF
    local o=""
    o=$(bash "${BASH_SOURCE[0]}" --db "$work/fix.db" --out-dir "$work" s1 2>&1)
    printf '%s' "$o" | grep -q 'wrote' || { printf 'FAIL wrote line\n'; fail=1; }
    [ -f "$work/ses_s1.txt" ] || { printf 'FAIL output file\n'; fail=1; }
    grep -q 'goal here' "$work/ses_s1.txt" || { printf 'FAIL user text\n'; fail=1; }
    grep -q '\[bash p1\]' "$work/ses_s1.txt" || { printf 'FAIL tool line\n'; fail=1; }
    grep -q 'capped' "$work/ses_s1.txt" || { printf 'FAIL cap mark\n'; fail=1; }
    bash "${BASH_SOURCE[0]}" --db "$work/fix.db" --out-dir "$work" s_missing > /dev/null 2>&1
    [ "$?" -eq 1 ] || { printf 'FAIL unknown session exits 1\n'; fail=1; }
    rm -f "$work/fix.db" "$work/ses_s1.txt"
    rmdir "$work"
    if [ "$fail" -eq 0 ]; then printf 'extract-transcript: self-test PASS\n'; else printf 'extract-transcript: self-test FAIL\n'; fi
    return "$fail"
}

main() {
    REPO=$(resolve_repo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)")
    [ -z "$REPO" ] && REPO=$(resolve_repo "$PWD")
    if [ -z "$REPO" ]; then
        printf 'GATE FAIL: cannot resolve repo root\n'
        return 2
    fi
    local SESSION="" OUT="" OUTDIR="" MAXP=5000 DB="$REPO/data/opencode/opencode.db"
    while [ $# -gt 0 ]; do
        case "$1" in
            --self-test) self_test; return "$?" ;;
            --out) OUT="${2:-}"; shift 2 ;;
            --out=*) OUT="${1#--out=}"; shift ;;
            --out-dir) OUTDIR="${2:-}"; shift 2 ;;
            --out-dir=*) OUTDIR="${1#--out-dir=}"; shift ;;
            --max-parts) MAXP="${2:-5000}"; shift 2 ;;
            --db) DB="${2:-}"; shift 2 ;;
            --db=*) DB="${1#--db=}"; shift ;;
            -h | --help)
                printf 'usage: %s <session-id> [--out FILE] [--out-dir DIR] [--max-parts N] [--db PATH] [--self-test]\n' "$0"
                return 0 ;;
            -*) printf 'unknown arg: %s\n' "$1"; return 2 ;;
            *) SESSION="$1"; shift ;;
        esac
    done
    [ -n "$SESSION" ] || { printf 'usage: %s <session-id> ...\n' "$0"; return 2; }
    have python3 || { printf 'GATE FAIL: python3 required\n'; return 1; }
    [ -f "$DB" ] || { printf 'FAIL: no database at %s\n' "$DB"; return 1; }
    case "$MAXP" in ''|*[!0-9]*) printf 'max-parts must be an integer\n'; return 2 ;; esac
    if [ -z "$OUT" ]; then
        if [ -n "$OUTDIR" ]; then
            OUT="$OUTDIR/ses_$SESSION.txt"
        else
            OUT="$REPO/logs/ses_$SESSION.txt"
        fi
    fi
    mkdir -p "$(dirname "$OUT")"
    dump_py "$DB" "$SESSION" "$OUT" "$MAXP"
}

main "$@"
