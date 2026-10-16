#!/usr/bin/env python3
"""tui-audit.py - READ-ONLY causal audit of a live TUI session's turns.

Answers "why did this session have issues" from the opencode store, and names
the CAUSE of each issue (which tool, which blacklist rule, which error
signature), not just counts. Read-only (mode=ro). No model calls.

    python3 scripts/tui-audit.py [--session ID] [--since-hours N] [--json] [--self-test]

With no --session it picks the most-recently-updated session whose directory is
NOT the web store (/home/node/.opencode) - i.e. the TUI instance in your repo.
Exit 0 report, 2 usage, 1 no session.
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
import time
from collections import Counter
from datetime import datetime, timezone

DEFAULT_DB = "data/opencode/opencode.db"
WEB_DIR = "/home/node/.opencode"


def ro(db: str) -> sqlite3.Connection:
    con = sqlite3.connect("file:" + db + "?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    return con


def pick_tui(con, since_ms: int) -> str:
    r = con.execute(
        "SELECT id, directory FROM session WHERE time_updated>=? ORDER BY time_updated DESC",
        (since_ms,),
    ).fetchall()
    for row in r:
        if (row["directory"] or "") != WEB_DIR:
            return row["id"]
    return r[0]["id"] if r else ""


def classify(err: str, tool: str) -> str:
    t = (err or "").lower()
    if "blacklist" in t:
        m = re.search(r"\(rule #?\d+\)|rule #(\d+)", err or "")
        return "blacklist" + ((" " + m.group(0)) if m else "")
    if "permission" in t or "rejected" in t or "not allowed" in t:
        return "permission"
    if "ai_apicallerror" in t or "free usage" in t or "temporarily unavailable" in t or "429" in t:
        return "gateway/model"
    if "oldstring" in t:
        return "edit-match (oldString not found)"
    if "no such file" in t or "command not found" in t or "cannot find" in t:
        return "missing path/tool"
    if "aborted" in t:
        return "user aborted"
    if "timeout" in t or "timed out" in t:
        return "timeout"
    return "other"


def audit(db: str, sid: str, since_ms: int) -> dict:
    con = ro(db)
    s = con.execute("SELECT * FROM session WHERE id=?", (sid,)).fetchone()
    if s is None:
        return {"error": "unknown session " + sid}
    parts = con.execute(
        "SELECT time_created, time_updated, json_extract(data,'$.type') t, "
        "json_extract(data,'$.tool') tool, json_extract(data,'$.state.status') st, "
        "substr(json_extract(data,'$.state.input.command'),1,160) cmd, "
        "substr(json_extract(data,'$.state.error'),1,200) err "
        "FROM part WHERE session_id=? ORDER BY time_created",
        (sid,),
    ).fetchall()
    msgs = con.execute("SELECT COUNT(*) c FROM message WHERE session_id=?", (sid,)).fetchone()["c"]
    tools = [p for p in parts if p["t"] == "tool"]
    issues = []
    for p in tools:
        if p["st"] == "error" or p["err"]:
            issues.append({
                "kind": "tool_error", "tool": p["tool"],
                "cause": classify(p["err"], p["tool"] or ""),
                "detail": (p["err"] or "")[:160], "command": (p["cmd"] or "")[:120],
            })
    stuck = [{"tool": p["tool"], "command": (p["cmd"] or "")[:120]}
             for p in tools if p["st"] == "running"]
    gaps = sorted(((parts[i]["time_created"] - parts[i - 1]["time_updated"], i) for i in range(1, len(parts))),
                  reverse=True)[:5]
    gap_list = [{"seconds": round(g[0] / 1000),
                 "note": "overnight/idle (>1h is not a stall)" if g[0] > 3600_000 else "idle"} for g in gaps]
    return {
        "session": sid, "title": s["title"], "directory": s["directory"],
        "model": (s["model"] or "")[:40], "agent": s["agent"],
        "messages": msgs, "parts": len(parts), "tool_calls": len(tools),
        "tools": dict(Counter(p["tool"] for p in tools).most_common()),
        "issues": issues, "stuck": stuck, "largest_gaps": gap_list,
        "cost": s["cost"], "tokens_input": s["tokens_input"],
    }


def self_test() -> int:
    import tempfile, os
    d = tempfile.mkdtemp()
    p = os.path.join(d, "f.db")
    c = sqlite3.connect(p)
    c.execute("CREATE TABLE session(id TEXT PRIMARY KEY,title TEXT,directory TEXT,model TEXT,agent TEXT,cost REAL,tokens_input INTEGER,time_created INTEGER,time_updated INTEGER)")
    c.execute("CREATE TABLE message(id TEXT,session_id TEXT,time_created INTEGER)")
    c.execute("CREATE TABLE part(time_created INTEGER,time_updated INTEGER,data TEXT,session_id TEXT)")
    c.execute("INSERT INTO session VALUES('s1','tui','/repo','deepseek',  'build',0.1,100,1,2)")
    c.execute("INSERT INTO part VALUES(1,2,'{\"type\":\"tool\",\"tool\":\"bash\",\"state\":{\"status\":\"error\",\"input\":{\"command\":\"sed x\"},\"error\":\"blacklist-guard blocked this command: sed (rule #7)\"}}','s1')")
    c.commit()
    r = audit(p, "s1", 0)
    ok = (r["tool_calls"] == 1 and r["issues"] and "blacklist" in r["issues"][0]["cause"]
          and r["issues"][0]["cause"].startswith("blacklist"))
    c.close()
    print("tui-audit: self-test PASS" if ok else "tui-audit: self-test FAIL %s" % json.dumps(r))
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--session", default="")
    ap.add_argument("--db", default=DEFAULT_DB)
    ap.add_argument("--since-hours", type=float, default=24)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    import pathlib
    db = a.db
    if not pathlib.Path(db).exists():
        for base in ("/workspace", "."):
            if pathlib.Path(base, "data/opencode/opencode.db").exists():
                db = str(pathlib.Path(base, "data/opencode/opencode.db"))
                break
    since = int((time.time() - a.since_hours * 3600) * 1000)
    con = ro(db)
    sid = a.session or pick_tui(con, since)
    if not sid:
        print("no session found")
        return 1
    rep = audit(db, sid, since)
    if a.json:
        print(json.dumps(rep, indent=2))
        return 0
    print("=== tui-audit @ %s ===" % rep["session"])
    print("title:   %s" % rep["title"])
    print("dir:     %s   model: %s   agent: %s" % (rep["directory"], rep["model"], rep["agent"]))
    print("volume:  %s messages · %s parts · %s tool calls · $%.4f · %s in" % (
        rep["messages"], rep["parts"], rep["tool_calls"], rep["cost"] or 0, rep["tokens_input"]))
    print("tools:   %s" % rep["tools"])
    print("--- issues (%d) ---" % len(rep["issues"]))
    for it in rep["issues"]:
        print("  [%s] %s: %s :: %s" % (it["cause"], it["tool"], it["detail"], it["command"]))
    if not rep["issues"]:
        print("  (none)")
    print("--- stuck tools: %d ---" % len(rep["stuck"]))
    for s in rep["stuck"]:
        print("  %s :: %s" % (s["tool"], s["command"]))
    print("--- largest gaps ---")
    for g in rep["largest_gaps"]:
        print("  %ss (%s)" % (g["seconds"], g["note"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
