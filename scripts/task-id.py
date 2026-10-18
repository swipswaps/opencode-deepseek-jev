#!/usr/bin/env python3
"""
task-id.py — durable, addressed task identity (E4).

WHY: a TODO.md unit has no stable ID and the opencode DB `todo` is session-local
(94 done / 10 in_progress / 14 pending, all ended), so a unit cannot be
ADDRESSED across sessions: begin, handoff, and close all re-derive it from free
text. `beads`/`backlog` give a durable addressed unit as a new dependency; this
is the same property over the ledger we already run.

WHAT: the append-only ledger (the store triage/next-action read) gains two
row types:

    TASK        id -> title + owner (the OPEN declaration, minted once)
    TASK_STATE  an id's lifecycle transition (CLOSED)

`new` mints (or returns) a stable id for a title and records its owner; `close`
ends it; `show`/`list` read the latest state. Rows are de-duped by
(source,source_key), so a re-mint is a no-op — the falsifiable property.

Usage:
    python3 scripts/task-id.py new --title "..." [--id T-xxxx] [--owner A]
    python3 scripts/task-id.py close --id T-xxxx
    python3 scripts/task-id.py show --id T-xxxx [--json]
    python3 scripts/task-id.py list [--json] [--all]
    python3 scripts/task-id.py --self-test

Env: LEDGER_DB (test seam; same as ledger.py). Stdlib only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import socket
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger  # noqa: E402 — shared schema/insert, one ledger


def slug(text: str) -> str:
    return re.sub(r"^-+|-+$", "", re.sub(r"[^a-z0-9]+", "-", text.lower()))[:48]


def actor() -> str:
    for var in ("LOOP_LOCK_ACTOR", "OPENCODE_SESSION"):
        val = os.environ.get(var)
        if val:
            return val
    return "%s:%s" % (socket.gethostname(), os.environ.get("USER", "user"))


def mint_id(title: str) -> str:
    return "T-" + hashlib.sha1(("task:" + slug(title)).encode()).hexdigest()[:6]


def latest(con) -> dict:
    """resource -> (verdict, title/detail, owner/actor) for TASK* rows."""
    state: dict = {}
    for typ in ("TASK", "TASK_STATE"):
        for res, verdict, detail, actor_ in con.execute(
                "SELECT resource,verdict,detail,actor FROM ledger "
                "WHERE type=? ORDER BY id", (typ,)).fetchall():
            state[res] = (verdict, detail, actor_)
    return state


def cmd_new(args: argparse.Namespace) -> int:
    title = (args.title or "").strip()
    if not title and not args.id:
        print("task-id new: --title (or --id) is required", file=sys.stderr)
        return 2
    con = ledger.connect(ledger.db_path())
    state = latest(con)
    tid = args.id.strip().rstrip(":")
    if not tid:
        # reuse an OPEN id that already names this title (idempotent re-mint).
        for res, (verdict, detail, _a) in state.items():
            if (verdict or "").upper() != "CLOSED" and detail == title:
                tid = res
                break
        if not tid:
            tid = mint_id(title)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,40}", tid):
        print("task-id new: bad id %r (letters/digits/._-)" % tid, file=sys.stderr)
        con.close()
        return 2
    owner = args.owner or actor()
    new = ledger.insert(con, {"type": "TASK", "actor": owner, "tool": "new",
                              "resource": tid, "verdict": "OPEN", "detail": title,
                              "source": "task-id.new", "source_key": "task:" + tid})
    con.close()
    print("task-id: %s %s\t%s\towner=%s" % ("minted" if new else "existing",
                                            tid, title, owner))
    print(tid)
    return 0


def cmd_close(args: argparse.Namespace) -> int:
    tid = (args.id or "").strip()
    con = ledger.connect(ledger.db_path())
    if not tid and getattr(args, "title", ""):
        want = args.title.strip()
        for res, (verdict, detail, _a) in latest(con).items():
            if (verdict or "").upper() != "CLOSED" and detail == want:
                tid = res
                break
    if not tid:
        print("task-id close: --id (or --title) is required", file=sys.stderr)
        con.close()
        return 2
    new = ledger.insert(con, {"type": "TASK_STATE", "actor": actor(), "tool": "close",
                              "resource": tid, "verdict": "CLOSED", "detail": "",
                              "source": "task-id.close",
                              "source_key": "task-state:%s:CLOSED" % tid})
    con.close()
    print("task-id: %s %s CLOSED" % ("closed" if new else "already-closed", tid))
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    tid = (args.id or "").strip()
    con = ledger.connect(ledger.db_path())
    state = latest(con)
    con.close()
    if tid not in state:
        print("task-id: unknown id %s" % tid, file=sys.stderr)
        return 1
    verdict, title, owner = state[tid]
    if args.json:
        print(json.dumps({"id": tid, "state": verdict, "title": title,
                          "owner": owner}))
    else:
        print("%s\t%s\t%s\towner=%s" % (tid, verdict, title, owner))
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    con = ledger.connect(ledger.db_path())
    state = latest(con)
    con.close()
    rows = [{"id": r, "state": v[0], "title": v[1], "owner": v[2]}
            for r, v in state.items()
            if args.all or (v[0] or "").upper() != "CLOSED"]
    rows.sort(key=lambda x: x["id"])
    if args.json:
        print(json.dumps(rows))
        return 0
    if not rows:
        print("task-id: no open tasks")
        return 0
    for r in rows:
        print("%-10s %-8s owner=%-18s %s" % (r["id"], r["state"], r["owner"], r["title"]))
    return 0


def self_test() -> int:
    import tempfile
    fails = 0

    def check(cond: bool, label: str) -> None:
        nonlocal fails
        print(("ok " if cond else "NOT OK ") + label)
        if not cond:
            fails += 1

    with tempfile.TemporaryDirectory() as tmp:
        os.environ["LEDGER_DB"] = os.path.join(tmp, "obs.db")
        try:
            n1 = argparse.Namespace(title="Owned task identity", id="", owner="alice")
            check(cmd_new(n1) == 0, "new mints an id")
            con = ledger.connect(ledger.db_path())
            tid = con.execute("SELECT resource FROM ledger WHERE type='TASK'").fetchone()[0]
            con.close()
            check(bool(re.fullmatch(r"T-[0-9a-f]{6}", tid)), "id shape T-<6hex>")

            # idempotent re-mint by title returns the same id.
            import io
            from contextlib import redirect_stdout
            buf = io.StringIO()
            with redirect_stdout(buf):
                cmd_new(argparse.Namespace(title="Owned task identity", id="", owner="alice"))
            check(buf.getvalue().strip().splitlines()[-1] == tid, "re-mint returns same id")
            con = ledger.connect(ledger.db_path())
            nt = con.execute("SELECT COUNT(*) FROM ledger WHERE type='TASK'").fetchone()[0]
            con.close()
            check(nt == 1, "re-mint inserts 0 rows (idempotent)")

            # explicit id (pin), like TUNNEL-1.
            check(cmd_new(argparse.Namespace(title="Tunnel flap", id="TUNNEL-1",
                                             owner="bob")) == 0, "explicit id accepted")
            buf = io.StringIO()
            with redirect_stdout(buf):
                cmd_list(argparse.Namespace(json=True, all=False))
            rows = json.loads(buf.getvalue())
            check(len(rows) == 2, "two open tasks listed")

            check(cmd_close(argparse.Namespace(id=tid)) == 0, "close works")
            check(cmd_close(argparse.Namespace(id=tid)) == 0, "re-close is a no-op")
            buf = io.StringIO()
            with redirect_stdout(buf):
                cmd_list(argparse.Namespace(json=False, all=False))
            check(tid not in buf.getvalue(), "closed task hidden from open list")
            buf = io.StringIO()
            with redirect_stdout(buf):
                cmd_list(argparse.Namespace(json=True, all=True))
            check(any(r["id"] == tid and r["state"] == "CLOSED"
                      for r in json.loads(buf.getvalue())), "--all shows closed")

            check(cmd_close(argparse.Namespace(id="", title="Tunnel flap")) == 0,
                  "close by title resolves the id")
            # rebuilt from storage? the registry IS the ledger read path.
            con = ledger.connect(ledger.db_path())
            state = latest(con)
            con.close()
            check(state["TUNNEL-1"][0] == "CLOSED" and state[tid][0] == "CLOSED",
                  "latest state per id from the ledger")
        finally:
            del os.environ["LEDGER_DB"]
    print("self-test: %s (%d failures)" % ("PASS" if fails == 0 else "FAIL", fails))
    return 0 if fails == 0 else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    sub = ap.add_subparsers(dest="cmd")
    n = sub.add_parser("new")
    n.add_argument("--title", default="")
    n.add_argument("--id", default="")
    n.add_argument("--owner", default="")
    c = sub.add_parser("close")
    c.add_argument("--id", default="")
    c.add_argument("--title", default="")
    s = sub.add_parser("show")
    s.add_argument("--id", default="")
    s.add_argument("--json", action="store_true")
    li = sub.add_parser("list")
    li.add_argument("--json", action="store_true")
    li.add_argument("--all", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv if argv is not None else sys.argv[1:])
    if args.self_test:
        return self_test()
    if args.cmd == "new":
        return cmd_new(args)
    if args.cmd == "close":
        return cmd_close(args)
    if args.cmd == "show":
        return cmd_show(args)
    if args.cmd == "list":
        return cmd_list(args)
    ap.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
