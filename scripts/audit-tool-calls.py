#!/usr/bin/env python3
"""
audit-tool-calls.py — audit the agent's OWN tool calls for the blacklist.

`lint.sh` enforces the rule set on the *files* in the repo. This enforces it
on what the agent actually *ran*: in the opencode database every tool call is
a `part` row whose `data.state.input.command` holds the command string. There
is no other gate over runtime behaviour, which is how `sed`, `2>/dev/null` and
`subprocess.run` accumulate silently while "thinking".

The audit reports each blacklisted pattern (count, sessions, sample commands)
and prints the sanctioned substitute. It is read-only.

Usage:
    ./scripts/audit-tool-calls.py [--recent N] [--db PATH] [--json] [--fail]

    --recent N   only audit the N most recent sessions (default: all)
    --db PATH    override the database path (default: <repo>/data/opencode/opencode.db)
    --json       emit a JSON report instead of the human table
    --fail       exit 1 if any blacklist hit exists (for gating)

Exit status:
    0   report produced (no hits, or hits without --fail)
    1   hits found and --fail was given
    2   usage / environment error

Rule references: RULES.md #7 (no sed), #8 (no 2>/dev/null), #38 (printf not
echo); "No subprocess.run" and "No rm -rf" in the general conventions.
Substitutions: see the "Substitutions for the blacklist" table in RULES.md.
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from pathlib import Path

# name -> (regex, substitute, rule)
# Matches require the token at a command position (start of command, or after
# a separator) so that `grep "sed"` / `echo "2>/dev/null"` do not count.
_BOUNDARY = r"(?:^|[;&|()]\s*)"
BLACKLIST: list[tuple[str, re.Pattern[str], str, str]] = [
    ("sed", re.compile(_BOUNDARY + r"sed\s"),
     "awk / grep / python3", "#7"),
    ("2>/dev/null", re.compile(r"2>/dev/null"),
     "let stderr flow; branch on the failure", "#8"),
    ("subprocess.run", re.compile(r"\bsubprocess\.run\s*\("),
     "subprocess.Popen(..., stdout=PIPE, stderr=PIPE) + read()", "convention"),
    ("rm -rf", re.compile(_BOUNDARY + r"rm\s+-rf\b"),
     "rm -f on named paths", "convention"),
    ("echo", re.compile(_BOUNDARY + r"echo\s"),
     "printf '%s\\n'", "#38"),
]


def resolve_repo(start: Path) -> Path | None:
    c = start.resolve()
    while c != c.parent:
        if (c / "opencode.json").is_file() and (c / "docker" / "Dockerfile").is_file():
            return c
        c = c.parent
    return None


def default_db() -> Path | None:
    repo = resolve_repo(Path(__file__).parent)
    if repo is None:
        repo = resolve_repo(Path.cwd())
    if repo is None:
        return None
    return repo / "data" / "opencode" / "opencode.db"


def load_commands(db_path: Path, recent: int | None) -> list[tuple[str, int, str]]:
    """Return (session_id, time_created, command) for every tool call with a command."""
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        sql = (
            "SELECT session_id, time_created, json_extract(data,'$.state.input.command') "
            "FROM part WHERE json_extract(data,'$.type')='tool' "
            "AND json_extract(data,'$.state.input.command') IS NOT NULL"
        )
        rows = con.execute(sql).fetchall()
        if recent:
            latest = con.execute(
                "SELECT id FROM session ORDER BY time_created DESC LIMIT ?", (recent,)
            ).fetchall()
            keep = {r[0] for r in latest}
            rows = [r for r in rows if r[0] in keep]
        return [(r[0], int(r[1]), str(r[2])) for r in rows]
    finally:
        con.close()


def strip_quotes(cmd: str) -> str:
    """Blank out single/double-quoted regions so a pattern that is merely
    *searched for* (`grep 'sed'`) is not counted as *used* (`sed -n ...`).
    Naive (no escape handling); good enough for command-position matching."""
    out: list[str] = []
    quote: str | None = None
    for ch in cmd:
        if quote:
            if ch == quote:
                quote = None
            out.append(" ")
        elif ch in "\"'":
            quote = ch
            out.append(" ")
        else:
            out.append(ch)
    return "".join(out)


def scan(commands: list[tuple[str, int, str]]) -> dict:
    hits: dict[str, dict] = {name: {"count": 0, "sessions": {}, "samples": []} for name, *_ in BLACKLIST}
    for session_id, ts, cmd in commands:
        bare = strip_quotes(cmd)
        for name, regex, _sub, _rule in BLACKLIST:
            if regex.search(bare):
                h = hits[name]
                h["count"] += 1
                h["sessions"][session_id] = h["sessions"].get(session_id, 0) + 1
                if len(h["samples"]) < 5:
                    h["samples"].append({"session": session_id, "ts": ts, "cmd": cmd[:200]})
    return hits


def report_text(hits: dict, n_commands: int) -> int:
    print("=== audit-tool-calls.py ===")
    print(f"tool calls scanned: {n_commands}")
    total = sum(h["count"] for h in hits.values())
    print(f"blacklist hits:     {total}")
    if total == 0:
        print("\nresult: clean — no blacklisted tool calls in the database.")
        return 0
    for name, regex, sub, rule in BLACKLIST:
        h = hits[name]
        if not h["count"]:
            continue
        top = sorted(h["sessions"].items(), key=lambda kv: -kv[1])[:5]
        print(f"\n  {name}  x{h['count']}  (rule {rule})")
        print(f"    substitute: {sub}")
        print("    sessions:   " + ", ".join(f"{s[:12]}({c})" for s, c in top))
        for s in h["samples"]:
            snippet = " ".join(s["cmd"].split())
            print(f"      - {s['session'][:12]}  {snippet}")
    print("\nresult: HITS — the blacklist is being used at runtime (see RULES.md substitutions).")
    return 1


def self_test() -> int:
    print("=== audit-tool-calls.py --self-test ===")
    checks = [
        ("strip_quotes blanks a searched pattern", "sed" not in strip_quotes("grep 'sed' x")),
        ("scan flags a real sed call", scan([("s", 0, "sed -i x")])["sed"]["count"] == 1),
        ("scan ignores a searched sed", scan([("s", 0, "grep 'sed' x")])["sed"]["count"] == 0),
        ("scan flags 2>/dev/null", scan([("s", 0, "ls x 2>/dev/null")])["2>/dev/null"]["count"] == 1),
        ("scan does not flag a mentioned subprocess.run",
         scan([("s", 0, "echo 'subprocess.run'")])["subprocess.run"]["count"] == 0),
    ]
    fails = 0
    for name, okv in checks:
        print(("  PASS " if okv else "  FAIL ") + name)
        if not okv:
            fails += 1
    print("result: " + ("PASS" if not fails else "FAIL"))
    return 1 if fails else 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--recent", type=int, default=None, help="audit only the N most recent sessions")
    ap.add_argument("--db", type=Path, default=None, help="database path")
    ap.add_argument("--json", action="store_true", help="emit JSON")
    ap.add_argument("--fail", action="store_true", help="exit 1 if any hit exists")
    ap.add_argument("--self-test", action="store_true", help="run internal checks and exit")
    args = ap.parse_args(argv if argv is not None else sys.argv[1:])

    if args.self_test:
        return self_test()

    db_path = args.db or default_db()
    if db_path is None or not db_path.is_file():
        print(f"error: database not found ({db_path})", file=sys.stderr)
        return 2

    commands = load_commands(db_path, args.recent)
    hits = scan(commands)
    total = sum(h["count"] for h in hits.values())

    if args.json:
        out = {
            "db": str(db_path),
            "tool_calls_scanned": len(commands),
            "blacklist_hits": total,
            "patterns": {
                name: {"count": hits[name]["count"], "sessions": hits[name]["sessions"],
                       "samples": hits[name]["samples"], "substitute": sub, "rule": rule}
                for name, _r, sub, rule in BLACKLIST
            },
        }
        print(json.dumps(out, indent=2))
    else:
        report_text(hits, len(commands))

    if total and args.fail:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
