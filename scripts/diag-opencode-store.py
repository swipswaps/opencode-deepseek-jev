#!/usr/bin/env python3
"""
diag-opencode-store.py - read-only telemetry for the opencode chat store.

The opencode web UI, the TUI and all agents share one SQLite database
(default: data/opencode/opencode.db). When the UI "does not load" it is
tempting to blame the store; this script separates *store health* from
*transport health* so the two are not conflated.

Guarantees
----------
* Opens the database with SQLite URI mode=ro and PRAGMA query_only=1.
* Writes nothing. No journal changes, no checkpoint, no vacuum.
* Every query is bounded by a wall-clock deadline via a progress handler,
  so a live writer can never hang the diagnostic.
* Full integrity checking is opt-in (--integrity) because on a large live
  database it can block behind the writer; its absence is NOT a failure.

Usage
-----
  python3 scripts/diag-opencode-store.py [--db PATH] [--json] [--integrity]

Exit: 0 store readable, 2 store unreadable/corrupt, 3 readable with warnings.
"""

import argparse
import json
import pathlib
import sqlite3
import sys
import time

CORE_TABLES = [
    "session",
    "message",
    "part",
    "session_message",
    "project",
    "todo",
    "event",
    "client_log",
]


class Deadline(Exception):
    pass


def connect(db_path):
    uri = "file:%s?mode=ro" % db_path
    con = sqlite3.connect(uri, uri=True, timeout=5)
    con.execute("PRAGMA query_only=1")
    con.execute("PRAGMA busy_timeout=5000")
    return con


def bounded(con, sql, args=(), seconds=4.0):
    """Run one query; abort it if it outlives the deadline."""
    end = time.time() + seconds

    def handler():
        return 1 if time.time() > end else 0

    con.set_progress_handler(handler, 50000)
    try:
        return con.execute(sql, args).fetchall()
    except sqlite3.OperationalError as exc:
        if "interrupt" in str(exc).lower():
            return None
        raise
    finally:
        con.set_progress_handler(None, 0)


def count(con, table, seconds=3.0):
    rows = bounded(con, 'SELECT count(*) FROM "%s"' % table, seconds=seconds)
    return None if rows is None else rows[0][0]


def sizes(db_path):
    out = {}
    for suffix in ("", "-wal", "-shm"):
        p = pathlib.Path(str(db_path) + suffix)
        out["db" + suffix if suffix else "db"] = p.stat().st_size if p.exists() else 0
    return out


def stuck_tools(con, seconds=6.0, min_age=900):
    """Tool parts whose state.status never advanced past running/pending.

    Parts younger than min_age are the diagnostic's own in-flight calls (or
    a normally slow tool), so they are not evidence of a hang.
    """
    rows = bounded(
        con,
        "SELECT session_id, data, time_created FROM part "
        "WHERE json_extract(data,'$.type')='tool' "
        "AND json_extract(data,'$.state.status') IN ('running','pending') "
        "ORDER BY time_created DESC LIMIT 40",
        seconds=seconds,
    )
    if rows is None:
        return None
    now = time.time()
    out = []
    for session_id, data, created in rows:
        try:
            d = json.loads(data)
        except Exception:
            continue
        state = d.get("state") or {}
        cmd = (state.get("input") or {}).get("command") or ""
        age = int(now - (created or now) / 1000.0) if created else None
        if age is not None and age < min_age:
            continue
        out.append(
            {
                "session": session_id,
                "tool": d.get("tool"),
                "status": state.get("status"),
                "started_at": created,
                "age_s": age,
                "command": cmd[:160],
            }
        )
    return out


def tool_errors(con, seconds=6.0):
    rows = bounded(
        con,
        "SELECT session_id, data, time_created FROM part "
        "WHERE json_extract(data,'$.type')='tool' "
        "AND json_extract(data,'$.state.status')='error' "
        "ORDER BY time_created DESC LIMIT 10",
        seconds=seconds,
    )
    if rows is None:
        return None
    out = []
    for session_id, data, created in rows:
        try:
            d = json.loads(data)
        except Exception:
            continue
        state = d.get("state") or {}
        out.append(
            {
                "session": session_id,
                "tool": d.get("tool"),
                "started_at": created,
                "error": str(state.get("error"))[:200],
            }
        )
    return out


def recent_sessions(con, limit=8):
    rows = bounded(
        con,
        "SELECT id, time_created, time_updated, directory, title, cost, "
        "tokens_input, tokens_output FROM session "
        "ORDER BY time_created DESC LIMIT ?",
        (limit,),
    )
    if rows is None:
        return None
    out = []
    for sid, created, updated, directory, title, cost, tin, tout in rows:
        out.append(
            {
                "id": sid,
                "created": created,
                "updated": updated,
                "directory": directory,
                "title": (title or "")[:80],
                "cost": cost,
                "tokens_in": tin,
                "tokens_out": tout,
            }
        )
    return out


def integrity(con, seconds=120.0):
    rows = bounded(con, "PRAGMA quick_check(1)", seconds=seconds)
    if rows is None:
        return "INCONCLUSIVE (deadline reached behind a live writer)"
    return rows[0][0] if rows else "INCONCLUSIVE"


def main(argv):
    ap = argparse.ArgumentParser(description="Read-only opencode chat-store telemetry")
    ap.add_argument("--db", default="data/opencode/opencode.db",
                    help="path to opencode.db (default: data/opencode/opencode.db)")
    ap.add_argument("--json", action="store_true", help="emit JSON instead of text")
    ap.add_argument("--integrity", action="store_true",
                    help="run PRAGMA quick_check (can block on a live DB)")
    ap.add_argument("--stuck-after", type=int, default=900,
                    help="only report running/pending tools older than N seconds "
                         "(default: 900)")
    args = ap.parse_args(argv)

    db_path = pathlib.Path(args.db)
    report = {"db": str(db_path), "readable": False, "sizes": {}, "counts": {},
              "recent_sessions": [], "stuck_tools": [], "tool_errors": [],
              "integrity": "skipped"}

    if not db_path.exists():
        report["error"] = "database file not found"
        emit(report, args.json)
        return 2

    report["sizes"] = sizes(db_path)

    try:
        con = connect(db_path)
        report["journal_mode"] = bounded(con, "PRAGMA journal_mode")[0][0]
        report["readable"] = True
        for table in CORE_TABLES:
            report["counts"][table] = count(con, table)
        report["recent_sessions"] = recent_sessions(con) or []
        report["stuck_tools"] = stuck_tools(con, min_age=args.stuck_after) or []
        report["tool_errors"] = tool_errors(con) or []
        if args.integrity:
            report["integrity"] = integrity(con)
        con.close()
    except Exception as exc:  # noqa: BLE001 - diagnostic must never traceback
        report["error"] = "%s: %s" % (type(exc).__name__, exc)
        emit(report, args.json)
        return 2

    emit(report, args.json)

    if not report["readable"]:
        return 2
    if report["stuck_tools"] or report["tool_errors"]:
        return 3
    return 0


def fmt_bytes(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return "%.2f %s" % (n, unit)
        n /= 1024.0


def emit(r, as_json):
    if as_json:
        print(json.dumps(r, indent=2))
        return
    print("store: %s" % r["db"])
    if r.get("error"):
        print("  status: UNREADABLE (%s)" % r["error"])
    else:
        print("  status: %s  journal_mode=%s"
              % ("READABLE" if r["readable"] else "UNREADABLE", r.get("journal_mode")))
    s = r.get("sizes", {})
    print("  size: db=%s wal=%s shm=%s"
          % (fmt_bytes(s.get("db", 0)), fmt_bytes(s.get("db-wal", 0)),
             fmt_bytes(s.get("db-shm", 0))))
    print("  integrity: %s" % r.get("integrity"))
    if r.get("counts"):
        print("  counts: " + " ".join(
            "%s=%s" % (k, r["counts"].get(k)) for k in CORE_TABLES))
    sessions = r.get("recent_sessions") or []
    if sessions:
        print("  recent sessions:")
        for x in sessions[:5]:
            print("    %s  %s  %s" % (x["id"], x.get("directory"), x.get("title")))
    stuck = r.get("stuck_tools") or []
    print("  stuck tool parts: %d%s"
          % (len(stuck), "  (WARN)" if stuck else ""))
    for x in stuck[:5]:
        print("    %s %s/%s age=%ss  %s"
              % (x["session"], x["tool"], x["status"], x["age_s"], x["command"]))
    errs = r.get("tool_errors") or []
    print("  errored tool parts: %d%s"
          % (len(errs), "  (WARN)" if errs else ""))
    for x in errs[:5]:
        print("    %s %s  %s" % (x["session"], x["tool"], x["error"]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
