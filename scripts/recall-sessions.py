#!/usr/bin/env python3
"""recall-sessions.py — Hermes-style keyword recall over opencode sessions.

Usage:
  python3 scripts/recall-sessions.py <keyword> [--limit N]
  python3 scripts/recall-sessions.py duckdns --limit 10

Read-only (sqlite mode=ro). Searches session titles first, then message
bodies, printing id + directory + title + updated time as provenance.
"""
import sqlite3
import sys
import os

DB = os.environ.get(
    "OPENCODE_DB", "/home/owner/.local/share/opencode/opencode.db"
)


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 2
    kw = argv[1].lower()
    limit = 10
    if "--limit" in argv:
        try:
            limit = int(argv[argv.index("--limit") + 1])
        except (ValueError, IndexError):
            pass
    con = sqlite3.connect("file:" + DB + "?mode=ro", uri=True)
    cur = con.cursor()
    print("db:", DB)
    rows = cur.execute(
        "SELECT id, directory, title, time_updated FROM session "
        "WHERE lower(title) LIKE ? ORDER BY time_updated DESC LIMIT ?",
        ("%" + kw + "%", limit),
    ).fetchall()
    print("title-hits:", len(rows))
    for sid, d, t, u in rows:
        print("-", sid, "|", d, "|", (t or "")[:80])
    mrows = cur.execute(
        "SELECT session_id, COUNT(*) FROM message "
        "WHERE lower(data) LIKE ? GROUP BY session_id LIMIT ?",
        ("%" + kw + "%", limit),
    ).fetchall()
    print("message-hits:", len(mrows))
    for sid, n in mrows:
        meta = cur.execute(
            "SELECT directory, title FROM session WHERE id=?", (sid,)
        ).fetchone()
        d, t = meta if meta else ("?", "?")
        print("-", sid, "msgs=" + str(n), "|", d, "|", (t or "")[:80])
    con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
