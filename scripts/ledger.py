#!/usr/bin/env python3
"""
ledger.py — append-only event ledger in data/observability/observability.db.

WHAT: one row per harness gate run and guard verdict: queryable history so
"what changed?" is answerable from evidence instead of inference. Table:

    ledger(id, ts, type, actor, tool, resource, verdict, detail, rev,
           source, source_key UNIQUE)

Live writers: harness.sh records GATE_START at main start and GATE with
passed/failed at finish (both guarded non-fatal — telemetry must never
fail a gate). Guard verdicts flow via `ingest-guard` (explicit; full
auto-wire into web-entrypoint is a host step). History arrives via
`backfill` (guard.log + last-gate.json + harness --export reports),
which is idempotent: UNIQUE(source,source_key) makes re-runs insert 0
rows — the falsifiable property. Read with `logs.sh --source ledger`
or `ledger.py show`.

Usage:
    python3 scripts/ledger.py init
    python3 scripts/ledger.py record --type GATE --verdict PASS --detail ... [--rev ... --source ... --key ...]
    python3 scripts/ledger.py ingest-guard
    python3 scripts/ledger.py backfill
    python3 scripts/ledger.py show [--tail N] [--since MIN] [--type T] [--grep RE] [--json]
    python3 scripts/ledger.py --self-test     # offline, tmp DB + fixtures

Env: LEDGER_DB overrides the database path (test seam; also proves the
non-fatal path when pointed somewhere unwritable). Stdlib only.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import sqlite3
import sys

SCHEMA = """CREATE TABLE IF NOT EXISTS ledger(
  id INTEGER PRIMARY KEY,
  ts TEXT NOT NULL,
  type TEXT NOT NULL,
  actor TEXT DEFAULT '',
  tool TEXT DEFAULT '',
  resource TEXT DEFAULT '',
  verdict TEXT DEFAULT '',
  detail TEXT DEFAULT '',
  rev TEXT DEFAULT '',
  source TEXT DEFAULT '',
  source_key TEXT UNIQUE
)"""
OFFSET_FILE = "ledger-offset.json"


def repo_root() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    c = here
    while c != "/":
        if os.path.isfile(os.path.join(c, "opencode.json")) and \
                os.path.isdir(os.path.join(c, "docker")):
            return c
        c = os.path.dirname(c)
    return here


def db_path() -> str:
    override = os.environ.get("LEDGER_DB")
    if override:
        return override
    return os.path.join(repo_root(), "data", "observability", "observability.db")


def connect(db: str) -> sqlite3.Connection:
    os.makedirs(os.path.dirname(os.path.abspath(db)), exist_ok=True)
    con = sqlite3.connect(db)
    con.execute(SCHEMA)
    return con


def utcnow() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def cmd_init(_args: argparse.Namespace) -> int:
    connect(db_path()).close()
    print("ledger: table ready")
    return 0


def insert(con: sqlite3.Connection, row: dict) -> bool:
    """Insert-or-ignore. Returns True when the row was new."""
    cur = con.execute(
        "INSERT OR IGNORE INTO ledger(ts,type,actor,tool,resource,verdict,"
        "detail,rev,source,source_key) VALUES(?,?,?,?,?,?,?,?,?,?)",
        (row.get("ts") or utcnow(), row.get("type", ""), row.get("actor", ""),
         row.get("tool", ""), row.get("resource", ""), row.get("verdict", ""),
         row.get("detail", ""), row.get("rev", ""), row.get("source", ""),
         row.get("source_key", "")))
    con.commit()
    return cur.rowcount == 1


def cmd_record(args: argparse.Namespace) -> int:
    if not args.type:
        print("ledger record: --type is required", file=sys.stderr)
        return 2
    try:
        con = connect(db_path())
    except OSError as e:
        print(f"ledger record: cannot open db ({e})", file=sys.stderr)
        return 1
    key = args.key or hashlib.sha256(
        (args.type + args.verdict + args.detail + utcnow()).encode()).hexdigest()[:16]
    new = insert(con, {"ts": args.ts or utcnow(), "type": args.type,
                       "actor": args.actor or "", "tool": args.tool or "",
                       "resource": args.resource or "", "verdict": args.verdict or "",
                       "detail": args.detail or "", "rev": args.rev or "",
                       "source": args.source or "ledger.record",
                       "source_key": key})
    con.close()
    print(f"ledger: {'recorded' if new else 'duplicate-skipped'} {args.type} {key}")
    return 0


def guard_path() -> str:
    return os.path.join(repo_root(), "data", "observability", "guard.log")


def offset_path() -> str:
    return os.path.join(repo_root(), "data", "observability", OFFSET_FILE)


def ingest_lines(con: sqlite3.Connection, lines: list[str]) -> int:
    """Maps guard.log JSON lines to GUARD rows. Returns new-row count."""
    added = 0
    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            e = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if not isinstance(e, dict) or "verdict" not in e:
            continue
        cmd = str(e.get("command") or e.get("sample") or e.get("message") or "")[:160]
        key = hashlib.sha256(raw.encode()).hexdigest()[:16]
        if insert(con, {"ts": str(e.get("ts") or utcnow()), "type": "GUARD",
                        "actor": "blacklist-guard",
                        "tool": cmd, "resource": "",
                        "verdict": str(e.get("verdict", "")),
                        "detail": str(e.get("message") or "")[:300],
                        "rev": "", "source": "guard.log", "source_key": key}):
            added += 1
    return added


def cmd_ingest_guard(_args: argparse.Namespace) -> int:
    gp = guard_path()
    if not os.path.isfile(gp):
        print("ledger: no guard.log yet")
        return 0
    off = 0
    op = offset_path()
    try:
        prev = json.load(open(op))
        if prev.get("size") == os.path.getsize(gp):
            off = prev.get("offset", 0)
        elif os.path.getsize(gp) < prev.get("size", 0):
            off = 0  # rotated/truncated: rescan
        else:
            off = prev.get("offset", 0)
    except (OSError, ValueError, KeyError):
        off = 0
    with open(gp, "rb") as fh:
        fh.seek(off)
        chunk = fh.read().decode("utf-8", errors="replace")
        new_off = fh.tell()
    con = connect(db_path())
    added = ingest_lines(con, chunk.splitlines())
    con.close()
    try:
        json.dump({"offset": new_off, "size": os.path.getsize(gp)},
                  open(op, "w"))
    except OSError as e:
        print(f"ledger: offset not persisted ({e}); re-ingest stays safe (idempotent)")
    print(f"ledger: ingest-guard +{added} rows")
    return 0


def cmd_backfill(_args: argparse.Namespace) -> int:
    root = repo_root()
    con = connect(db_path())
    total = 0
    gp = guard_path()
    if os.path.isfile(gp):
        with open(gp, encoding="utf-8", errors="replace") as fh:
            total += ingest_lines(con, fh.read().splitlines())
    lg = os.path.join(root, "data", "observability", "last-gate.json")
    if os.path.isfile(lg):
        try:
            g = json.load(open(lg))
            verdict = "PASS" if not g.get("failed") else "FAIL"
            if insert(con, {"ts": str(g.get("ts", "")), "type": "GATE",
                            "actor": "harness.sh", "verdict": verdict,
                            "detail": f"passed={g.get('passed', '?')} failed={g.get('failed', '?')}",
                            "source": "last-gate.json",
                            "source_key": "last-gate-" + str(g.get("ts", ""))}):
                total += 1
        except (OSError, ValueError) as e:
            print(f"ledger: last-gate.json skipped ({e})")
    logs = os.path.join(root, "logs")
    if os.path.isdir(logs):
        for name in sorted(os.listdir(logs)):
            m = re.fullmatch(r"harness-(\d{8}T\d{6}Z)\.md", name)
            if not m:
                continue
            try:
                body = open(os.path.join(logs, name), encoding="utf-8",
                            errors="replace").read()
            except OSError:
                continue
            gm = re.search(r"gates passed:\s*(\d+)\s+failed:\s*(\d+)", body)
            detail = gm.group(0) if gm else "harness export"
            verdict = "PASS" if gm and gm.group(2) == "0" else ("FAIL" if gm else "")
            if insert(con, {"ts": m.group(1), "type": "GATE_REPORT",
                            "actor": "harness.sh", "verdict": verdict,
                            "detail": detail, "resource": name,
                            "source": "harness-export", "source_key": name}):
                total += 1
    con.close()
    print(f"ledger: backfill +{total} rows (re-run must print +0)")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    con = connect(db_path())
    try:
        rows = con.execute(
            "SELECT ts,type,actor,verdict,tool,detail,rev FROM ledger "
            "ORDER BY id DESC LIMIT ?", (args.tail,)).fetchall()
    except sqlite3.OperationalError as e:
        print(f"ledger: cannot read ({e})", file=sys.stderr)
        return 2
    con.close()
    if args.since:
        try:
            cutoff = datetime.datetime.now(datetime.timezone.utc).timestamp() - int(args.since) * 60
            rows = [r for r in rows
                    if datetime.datetime.fromisoformat(r[0].replace("Z", "+00:00")).timestamp() >= cutoff]
        except ValueError:
            pass
    if args.type:
        rows = [r for r in rows if r[1] == args.type]
    if args.grep:
        try:
            rx = re.compile(args.grep)
        except re.error as e:
            print(f"ledger: bad --grep ({e})", file=sys.stderr)
            return 2
        rows = [r for r in rows if rx.search(" ".join(str(c) for c in r))]
    rows.reverse()
    if args.json:
        print(json.dumps([{"ts": r[0], "type": r[1], "actor": r[2],
                           "verdict": r[3], "tool": r[4],
                           "detail": r[5], "rev": r[6]} for r in rows], indent=1))
        return 0
    if not rows:
        print("(ledger empty)")
        return 0
    for ts, typ, actor, verdict, tool, detail, rev in rows:
        head = f"{ts} {typ} {verdict}".rstrip()
        tail = f" {tool}" if tool else ""
        if detail:
            tail += f" — {detail[:120]}"
        if rev:
            tail += f" [{rev}]"
        print(head + tail)
    return 0


def self_test() -> int:
    """Offline fixtures on a tmp DB: schema, record, idempotent re-ingest,
    filters, hostile rows. Deterministic, no network."""
    import tempfile
    fails = 0

    def check(cond: bool, label: str) -> None:
        nonlocal fails
        print(("ok " if cond else "NOT OK ") + label)
        if not cond:
            fails += 1

    with tempfile.TemporaryDirectory() as tmp:
        db = os.path.join(tmp, "obs.db")
        os.environ["LEDGER_DB"] = db
        try:
            con = connect(db)
            cols = [r[1] for r in con.execute("PRAGMA table_info(ledger)")]
            check(cols == ["id", "ts", "type", "actor", "tool", "resource",
                           "verdict", "detail", "rev", "source", "source_key"],
                  "schema columns")
            check(insert(con, {"ts": "2026-01-01T00:00:00Z", "type": "GATE",
                               "verdict": "PASS", "source": "t",
                               "source_key": "k1"}), "record inserts")
            check(not insert(con, {"ts": "2026-01-01T00:00:00Z", "type": "GATE",
                                   "verdict": "PASS", "source": "t",
                                   "source_key": "k1"}), "duplicate key ignored")
            n = ingest_lines(con, [
                '{"ts":"2026-01-02T00:00:00Z","verdict":"block","command":"rm -rf x"}',
                "not json",
                '{"ts":"2026-01-02T00:00:01Z","verdict":"loaded"}',
                '{"noverdict":1}',
            ])
            check(n == 2, "guard ingest (2 valid, 2 skipped)")
            n2 = ingest_lines(con, [
                '{"ts":"2026-01-02T00:00:00Z","verdict":"block","command":"rm -rf x"}',
            ])
            check(n2 == 0, "re-ingest inserts 0 (idempotent)")
            check(con.execute("SELECT COUNT(*) FROM ledger").fetchone()[0] == 3,
                  "row count")
            con.close()
            del os.environ["LEDGER_DB"]
        except Exception as e:  # noqa: BLE001 — self-test must report, not crash
            check(False, f"unexpected exception: {e}")
    print(f"self-test: {'PASS' if fails == 0 else 'FAIL'} ({fails} failures)")
    return 0 if fails == 0 else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("init")
    r = sub.add_parser("record")
    r.add_argument("--type", default="")
    r.add_argument("--actor", default="")
    r.add_argument("--tool", default="")
    r.add_argument("--resource", default="")
    r.add_argument("--verdict", default="")
    r.add_argument("--detail", default="")
    r.add_argument("--rev", default="")
    r.add_argument("--source", default="")
    r.add_argument("--key", default="")
    r.add_argument("--ts", default="")
    sub.add_parser("ingest-guard")
    sub.add_parser("backfill")
    s = sub.add_parser("show")
    s.add_argument("--tail", type=int, default=40)
    s.add_argument("--since", default="")
    s.add_argument("--type", default="")
    s.add_argument("--grep", default="")
    s.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv if argv is not None else sys.argv[1:])
    if args.self_test:
        return self_test()
    if args.cmd == "init":
        return cmd_init(args)
    if args.cmd == "record":
        return cmd_record(args)
    if args.cmd == "ingest-guard":
        return cmd_ingest_guard(args)
    if args.cmd == "backfill":
        return cmd_backfill(args)
    if args.cmd == "show":
        return cmd_show(args)
    ap.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
