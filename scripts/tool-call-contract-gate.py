#!/usr/bin/env python3
"""tool-call-contract-gate.py — new-hits ratchet over the agent's own tool calls.

`audit-tool-calls.py` reports every blacklisted construct in the transcript, but
nothing called it with `--fail`, so the uses accumulated as a report instead of
stopping the loop (RULES #92/#98: a signal that only reports is not a loop).
This wraps the SAME matcher (`load_commands` + `scan`) in a ratchet:

  * the first run in a session seeds the baseline with that session's count
    (pre-existing debt is acknowledged, not a surprise STOP);
  * a HIGHER count in the same session fails closed — a fresh blacklist use
    stops the session and the operator hands off;
  * a LOWER count is recorded, so the baseline only tightens;
  * a new session starts from a fresh seed (handoff doctrine), so one bad
    session does not brick the repo forever.

Usage:
    ./scripts/tool-call-contract-gate.py [--check] [--json]
    ./scripts/tool-call-contract-gate.py --self-test
    ./scripts/tool-call-contract-gate.py --db PATH --baseline PATH --recent N

Exit: 0 clean/unchanged/ratcheted/seeded, 1 new hits or corrupt baseline,
      3 transcript database not found (caller decides warn vs STOP).

Constraints: imports the audit module in-process (no subprocess execution), no
sed, no stderr suppression, explicit failure branches.

Rule references: RULES.md #8 (the stderr redirect), #38 (printf), #92/#98
(a signal must act, and a critical check must fail closed).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path


def resolve_repo(start: Path) -> Path | None:
    c = start.resolve()
    while c != c.parent:
        if (c / "opencode.json").is_file() and (c / "docker" / "Dockerfile").is_file():
            return c
        c = c.parent
    return None


def load_audit(repo: Path):
    path = repo / "scripts" / "audit-tool-calls.py"
    spec = importlib.util.spec_from_file_location("audit_tool_calls", path)
    if spec is None or spec.loader is None:
        raise FileNotFoundError(f"cannot load audit module: {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def resolve_db(repo: Path) -> Path:
    """One resolver: delegate to scripts/db-path.sh (host and sandbox differ)."""
    script = repo / "scripts" / "db-path.sh"
    if script.is_file():
        proc = subprocess.Popen(
            ["bash", str(script)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        out, _err = proc.communicate()
        if proc.returncode == 0 and out.strip():
            return Path(out.strip())
    return repo / "data" / "opencode" / "opencode.db"


def latest_session(db: Path) -> str:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        row = con.execute(
            "SELECT id FROM session ORDER BY time_created DESC LIMIT 1"
        ).fetchone()
        return str(row[0]) if row else ""
    except sqlite3.Error:
        return ""
    finally:
        con.close()


def collect(audit, db: Path, recent: int) -> dict:
    commands = audit.load_commands(db, recent)
    hits = audit.scan(commands)
    total = sum(h["count"] for h in hits.values())
    sid = ""
    if commands:
        sid = str(max(commands, key=lambda r: r[1])[0])
    if not sid:
        sid = latest_session(db)
    samples: list[str] = []
    for _name, h in hits.items():
        for s in h["samples"]:
            if len(samples) < 5:
                samples.append(" ".join(str(s["cmd"]).split())[:200])
    return {
        "session": sid,
        "hits": total,
        "scanned": len(commands),
        "samples": samples,
    }


def read_baseline(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return {"corrupt": str(exc)}
    return data if isinstance(data, dict) else {"corrupt": "not an object"}


def write_baseline(path: Path, session: str, hits: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = json.dumps({"session": session, "hits": hits}, indent=2) + "\n"
    path.write_text(body, encoding="utf-8")


def decide(baseline_path: Path, session: str, hits: int) -> dict:
    """Ratchet: seed a new session, fail on growth, record shrinkage."""
    base = read_baseline(baseline_path)
    if base.get("corrupt"):
        return {
            "status": "FAIL",
            "reason": "baseline-corrupt",
            "session": session,
            "hits": hits,
            "baseline": None,
        }
    old = base.get("hits")
    seeded = base.get("session") != session or not isinstance(old, int)
    if seeded:
        write_baseline(baseline_path, session, hits)
        return {
            "status": "PASS",
            "reason": "seeded",
            "session": session,
            "hits": hits,
            "baseline": hits,
        }
    if hits > old:
        # Do not advance the baseline on failure: that would hide the hit.
        return {
            "status": "FAIL",
            "reason": "new-hits",
            "session": session,
            "hits": hits,
            "baseline": old,
        }
    if hits < old:
        write_baseline(baseline_path, session, hits)
        return {
            "status": "PASS",
            "reason": "ratcheted-down",
            "session": session,
            "hits": hits,
            "baseline": hits,
        }
    return {
        "status": "PASS",
        "reason": "unchanged",
        "session": session,
        "hits": hits,
        "baseline": old,
    }


def emit(result: dict, as_json: bool) -> None:
    if as_json:
        print(json.dumps(result))
        return
    print("=== tool-call-contract-gate ===")
    for s in result.get("samples", []):
        print(f"sample: {s}")
    print(f"db={result.get('db', '?')}")
    print(f"session={result.get('session', '?')}")
    print(f"hits={result.get('hits')} baseline={result.get('baseline')}")
    print(f"status={result.get('status')} reason={result.get('reason')}")


def self_test() -> int:
    print("=== tool-call-contract-gate.py --self-test ===")
    fails = 0

    def check(name: str, ok: bool) -> None:
        nonlocal fails
        print(("  PASS " if ok else "  FAIL ") + name)
        if not ok:
            fails += 1

    repo = resolve_repo(Path(__file__).parent)
    check("repo resolves", repo is not None)
    if repo is None:
        return 1
    audit = load_audit(repo)

    with tempfile.TemporaryDirectory(prefix="contractgate.") as tmp:
        tmpdir = Path(tmp)
        db = tmpdir / "opencode.db"
        con = sqlite3.connect(db)
        con.executescript(
            "CREATE TABLE session(id TEXT PRIMARY KEY, time_created INTEGER);"
            "CREATE TABLE part(id TEXT PRIMARY KEY, session_id TEXT, "
            "time_created INTEGER, data TEXT);"
        )
        con.execute("INSERT INTO session VALUES ('s_old', 1000)")
        con.execute("INSERT INTO session VALUES ('s_new', 2000)")
        rows = [
            ("p1", "s_old", 1100, "ls x 2>/dev/null"),
            ("p2", "s_new", 2100, "ls x 2>/dev/null"),
            ("p3", "s_new", 2200, "sed -i x f"),
            ("p4", "s_new", 2300, "grep 'sed' f"),
            ("p5", "s_new", 2400, "grep '2>/dev/null' f"),
        ]
        for pid, sid, ts, cmd in rows:
            data = json.dumps(
                {"type": "tool", "state": {"input": {"command": cmd}}}
            )
            con.execute("INSERT INTO part VALUES (?,?,?,?)", (pid, sid, ts, data))
        con.commit()
        con.close()

        got = collect(audit, db, 1)
        check("latest session selected", got["session"] == "s_new")
        check("two real hits counted", got["hits"] == 2)
        check("quoted patterns are not hits", "grep 'sed' f" not in got["samples"])

        base = tmpdir / "baseline.json"
        r = decide(base, "s_new", 2)
        check("new session seeds baseline", r["status"] == "PASS" and r["reason"] == "seeded")
        check("seeded baseline written", read_baseline(base).get("hits") == 2)

        r = decide(base, "s_new", 2)
        check("unchanged count passes", r["status"] == "PASS" and r["reason"] == "unchanged")

        r = decide(base, "s_new", 3)
        check("growth fails closed", r["status"] == "FAIL" and r["reason"] == "new-hits")
        check("failed run does not advance baseline", read_baseline(base).get("hits") == 2)

        r = decide(base, "s_new", 1)
        check("shrink ratchets down", r["status"] == "PASS" and read_baseline(base).get("hits") == 1)

        r = decide(base, "s_other", 9)
        check("new session resets the ratchet", r["status"] == "PASS" and r["reason"] == "seeded")

        base.write_text("{not json", encoding="utf-8")
        r = decide(base, "s_other", 9)
        check("corrupt baseline fails closed", r["status"] == "FAIL" and r["reason"] == "baseline-corrupt")

    print("result: " + ("PASS" if not fails else "FAIL"))
    return 1 if fails else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--check", action="store_true", help="run the ratchet (default)")
    ap.add_argument("--json", action="store_true", help="emit one JSON object")
    ap.add_argument("--self-test", action="store_true", help="run internal checks and exit")
    ap.add_argument("--db", type=Path, default=None, help="transcript database path")
    ap.add_argument("--baseline", type=Path, default=None, help="baseline JSON path")
    ap.add_argument("--recent", type=int, default=1, help="audit the N most recent sessions")
    args = ap.parse_args(argv if argv is not None else sys.argv[1:])

    if args.self_test:
        return self_test()

    repo = resolve_repo(Path(__file__).parent)
    if repo is None:
        repo = resolve_repo(Path.cwd())
    if repo is None:
        print("status=FAIL reason=repo-not-found")
        return 2

    db = args.db
    if db is None:
        db = resolve_db(repo)
    if db is None or not db.is_file():
        print(f"status=SKIP reason=no-db db={db}")
        return 3

    baseline = args.baseline or (repo / "data" / "observability" / "tool-call-baseline.json")
    audit = load_audit(repo)
    got = collect(audit, db, args.recent)
    result = decide(baseline, got["session"], got["hits"])
    result["db"] = str(db)
    result["samples"] = got["samples"]
    emit(result, args.json)
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
