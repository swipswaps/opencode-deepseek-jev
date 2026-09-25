#!/usr/bin/env python3
"""
issue-solutions.py — mine the chat database for recurring errors and the
command that fixed them, proven by the logs.

Free and local: no model call, no network. It reads the opencode database
read-only and reconstructs, per session, what went wrong and what worked next:

  issue    a tool call with state.status='error'  (state.error is the message)
  solution the NEXT tool call in the same session with state.status='completed'

Aggregating (issue-signature -> follow-up commands) turns the raw transcript
into a ranked answer of "this keeps breaking, and this is what fixes it" —
each row citing the actual error text and the command that resolved it.

Usage:
    ./scripts/issue-solutions.py [--recent N] [--top N] [--json] [--self-test]

Options:
    --recent N   only the N most recent sessions (default: all)
    --top N      issues to show (default 15)
    --json       emit JSON
    --self-test  run the pairing logic on synthetic data and exit

Exit status: 0 report produced; 1 self-test failed; 2 usage/environment error.
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

NUMBER_RE = re.compile(r"\d+")
PATH_RE = re.compile(r"/[^\s'\"]+")


def resolve_repo(start: Path) -> Path | None:
    c = start.resolve()
    while c != c.parent:
        if (c / "opencode.json").is_file() and (c / "docker" / "Dockerfile").is_file():
            return c
        c = c.parent
    return None


def first_line(text: str) -> str:
    return (text or "").strip().splitlines()[0] if (text or "").strip() else ""


def signature(err: str) -> str:
    line = first_line(err)
    line = PATH_RE.sub("PATH", line)
    line = NUMBER_RE.sub("N", line)
    line = " ".join(line.split())
    return line[:110] or "(no error message)"


def norm_cmd(cmd: str) -> str:
    return " ".join((cmd or "").split())[:90]


def mine(parts: list[dict]) -> dict:
    by_sess: dict[str, list[dict]] = defaultdict(list)
    for p in parts:
        by_sess[p["session"]].append(p)

    groups: dict[str, dict] = {}
    total_err = 0
    paired = 0
    for _sess, ps in by_sess.items():
        ps.sort(key=lambda x: x["ts"])
        for i, p in enumerate(ps):
            if p.get("status") != "error":
                continue
            total_err += 1
            sig = signature(p.get("error", ""))
            g = groups.setdefault(sig, {"count": 0, "tools": Counter(), "sample": first_line(p.get("error", "")),
                                        "fixes": Counter()})
            g["count"] += 1
            g["tools"][p.get("tool") or "?"] += 1
            for q in ps[i + 1:]:
                if q.get("status") == "completed":
                    g["fixes"][(q.get("tool") or "?", norm_cmd(q.get("command") or q.get("path") or ""))] += 1
                    paired += 1
                    break

    order = sorted(groups.items(), key=lambda kv: -kv[1]["count"])
    issues = []
    for sig, g in order:
        issues.append({
            "signature": sig,
            "count": g["count"],
            "tools": dict(g["tools"]),
            "sample": g["sample"],
            "fixes": [{"tool": t, "command": c, "n": n} for (t, c), n in g["fixes"].most_common(3)],
        })
    return {"total_errors": total_err, "paired": paired, "issues": issues}


def load_parts(db_path: Path, recent: int | None) -> list[dict]:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        sql = (
            "SELECT session_id, time_created, "
            "json_extract(data,'$.tool'), json_extract(data,'$.state.status'), "
            "json_extract(data,'$.state.input.command'), json_extract(data,'$.state.input.filePath'), "
            "json_extract(data,'$.state.error') "
            "FROM part WHERE json_extract(data,'$.type')='tool' "
            "ORDER BY session_id, time_created"
        )
        rows = con.execute(sql).fetchall()
        if recent:
            keep = {r[0] for r in con.execute(
                "SELECT id FROM session ORDER BY time_created DESC LIMIT ?", (recent,)).fetchall()}
            rows = [r for r in rows if r[0] in keep]
        return [{"session": r[0], "ts": int(r[1]), "tool": r[2], "status": r[3],
                 "command": r[4], "path": r[5], "error": r[6]} for r in rows]
    finally:
        con.close()


def report_text(r: dict, top: int) -> None:
    print("=== issue-solutions.py ===")
    print(f"error tool calls: {r['total_errors']}  paired with a later success: {r['paired']}")
    if not r["issues"]:
        print("\nresult: no errors in range — nothing to learn from.")
        return
    print("\nranked issues (signature) -> proven fix (next completed call):")
    for g in r["issues"][:top]:
        tools = ", ".join(f"{t}x{n}" for t, n in g["tools"].items())
        print(f"\n  [{g['count']:>2}] {g['signature']}   (tool: {tools})")
        if g["sample"] and g["sample"] != g["signature"]:
            print(f"       evidence: {g['sample'][:110]}")
        if g["fixes"]:
            for f in g["fixes"]:
                cmd = f["command"] or "(no command)"
                print(f"       fix x{f['n']}: {f['tool']}  {cmd}")
        else:
            print("       fix: (no later success in the same session)")


def self_test() -> int:
    print("=== issue-solutions.py --self-test ===")
    parts = [
        {"session": "s1", "ts": 1, "tool": "edit", "status": "error",
         "command": None, "path": "a.sh", "error": "Could not find oldString in the file."},
        {"session": "s1", "ts": 2, "tool": "edit", "status": "completed",
         "command": None, "path": "a.sh", "error": None},
        {"session": "s1", "ts": 3, "tool": "edit", "status": "error",
         "command": None, "path": "b.sh", "error": "Could not find oldString in the file."},
        {"session": "s1", "ts": 4, "tool": "write", "status": "completed",
         "command": None, "path": "b.sh", "error": None},
        {"session": "s2", "ts": 5, "tool": "bash", "status": "error",
         "command": "cat missing", "path": None, "error": "No such file or directory"},
    ]
    r = mine(parts)
    checks = [
        ("counts all errors", r["total_errors"] == 3),
        ("pairs only errors that have a later success", r["paired"] == 2),
        ("groups identical signatures", any(g["count"] == 2 for g in r["issues"])),
        ("normalises paths and numbers in the key",
         signature("Error at /a/b/c line 42") == "Error at PATH line N"),
    ]
    fails = 0
    for name, ok in checks:
        print(("  PASS " if ok else "  FAIL ") + name)
        if not ok:
            fails += 1
    print("result: " + ("PASS" if not fails else "FAIL"))
    return 1 if fails else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--recent", type=int, default=None)
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--write", action="store_true",
                    help="persist data/observability/solutions.json for the UI")
    ap.add_argument("--db", type=Path, default=None)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv if argv is not None else sys.argv[1:])

    if args.self_test:
        return self_test()

    repo = resolve_repo(Path(__file__).parent) or resolve_repo(Path.cwd())
    if repo is None:
        print("error: cannot resolve repo root", file=sys.stderr)
        return 2
    db_path = args.db or (repo / "data" / "opencode" / "opencode.db")
    if not db_path.is_file():
        print(f"error: database not found ({db_path})", file=sys.stderr)
        return 2

    result = mine(load_parts(db_path, args.recent))
    result["ts"] = datetime.now(timezone.utc).isoformat()
    if args.write:
        out = repo / "data" / "observability" / "solutions.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(result, indent=2) + "\n")
        print(f"wrote {out}")
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        report_text(result, args.top)
    return 0


if __name__ == "__main__":
    sys.exit(main())
