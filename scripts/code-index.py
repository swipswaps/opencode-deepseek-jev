#!/usr/bin/env python3
"""
code-index.py — assemble, index and flag the repo's own code into SQLite.

The observability DB holds the *chat*; this holds the *code*, so code can be
inspected alongside it (and later classified by Jev/Laya/DeepSeek). It scans
the repo's code/config/doc files, records per-file metadata and top-level
symbols, and flags blacklist patterns plus TODO/FIXME markers. Free, local.

    ./scripts/code-index.py                 # (re)build and summarize
    ./scripts/code-index.py --flags         # list flags (file:line name)
    ./scripts/code-index.py --list          # list files by size
    ./scripts/code-index.py --grep REGEX    # files whose path/symbols match
    ./scripts/code-index.py --json
    ./scripts/code-index.py --self-test

Writes data/observability/code.db (table code + code_flag). Read-only over the
repo. Classifier note: the authoritative classifier is scan-constraints.py;
this is a lighter per-line flag for the dashboard.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
from pathlib import Path

EXTS = {".sh", ".py", ".mjs", ".js", ".ts", ".tsx", ".jsx", ".md", ".txt",
        ".json", ".yml", ".yaml", ".sql", ".html", ".css"}
EXCLUDE = {"node_modules", "data", "logs", ".git", "__pycache__", "vendor",
           "dist", "build", ".cache", ".npm", ".local", "archive"}

FLAGS = [
    ("sed", re.compile(r"(?:^|[^A-Za-z0-9_])sed(?:[^A-Za-z0-9_]|$)")),
    ("2>/dev/null", re.compile(r"2>/dev/null")),
    ("subprocess.run", re.compile(r"subprocess\.run")),
    ("rm -rf", re.compile(r"\brm\s+-rf\b")),
    ("set -e", re.compile(r"(?:^|[^A-Za-z0-9_])set\s+-e(?:[^A-Za-z0-9_]|$)")),
    ("exit 1", re.compile(r"(?:^|[^A-Za-z0-9_])exit\s+1(?:[^A-Za-z0-9_]|$)")),
    ("echo", re.compile(r"(?:^|[^A-Za-z0-9_])echo(?:[^A-Za-z0-9_]|$)")),
    ("TODO", re.compile(r"\b(TODO|FIXME|HACK|XXX)\b")),
]
SYMS = [
    re.compile(r"^\s*(?:async\s+)?function\s+([A-Za-z0-9_]+)"),
    re.compile(r"^def\s+([A-Za-z0-9_]+)"),
    re.compile(r"^class\s+([A-Za-z0-9_]+)"),
    re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{"),
    re.compile(r"^(?:export\s+)?const\s+([A-Za-z0-9_]+)\s*="),
]


def resolve_repo(start: Path) -> Path | None:
    c = start.resolve()
    while c != c.parent:
        if (c / "opencode.json").is_file() and (c / "docker" / "Dockerfile").is_file():
            return c
        c = c.parent
    return None


def iter_files(roots: list[Path]) -> list[Path]:
    seen: dict[Path, None] = {}
    for root in roots:
        if not root.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(root, onerror=lambda _e: None):
            dirnames[:] = [d for d in dirnames
                           if d not in EXCLUDE and not (d.startswith(".") and d != ".opencode")]
            for name in filenames:
                p = Path(dirpath) / name
                if p.suffix.lower() in EXTS and p.is_file():
                    seen[p] = None
    return list(seen)


def rel_of(p: Path, repo: Path) -> str:
    try:
        return str(p.relative_to(repo))
    except ValueError:
        return str(p)


CODE_EXTS = EXTS - {".md", ".txt"}


def analyze(text: str, ext: str) -> tuple[list[str], list[tuple[str, int, str]]]:
    symbols: list[str] = []
    flags: list[tuple[str, int, str]] = []
    is_code = ext in CODE_EXTS
    for i, line in enumerate(text.splitlines(), start=1):
        if is_code and not line.lstrip().startswith("#"):
            for rx in SYMS:
                m = rx.match(line)
                if m:
                    symbols.append(m.group(1))
                    break
            for name, rx in FLAGS:
                if name != "TODO" and rx.search(line):
                    flags.append((name, i, " ".join(line.split())[:160]))
        if re.search(r"\b(TODO|FIXME|HACK|XXX)\b", line):
            flags.append(("TODO", i, " ".join(line.split())[:160]))
    return symbols, flags


def build(repo: Path, db_path: Path, roots: list[Path]) -> dict:
    files = iter_files(roots)
    con = sqlite3.connect(str(db_path))
    try:
        con.executescript(
            "DROP TABLE IF EXISTS code;"
            "CREATE TABLE code(path TEXT PRIMARY KEY, ext TEXT, bytes INT, lines INT,"
            " symbols TEXT, flags_n INT, sha TEXT);"
            "DROP TABLE IF EXISTS code_flag;"
            "CREATE TABLE code_flag(path TEXT, name TEXT, line INT, text TEXT);"
        )
        total_flags = 0
        ins = con.prepare if hasattr(con, "prepare") else None  # noqa: F841
        for p in files:
            try:
                text = p.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            rel = rel_of(p, repo)
            symbols, flags = analyze(text, p.suffix.lower())
            sha = hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:16]
            con.execute("INSERT INTO code VALUES (?,?,?,?,?,?,?)",
                        (rel, p.suffix, len(text.encode("utf-8")), text.count("\n") + 1,
                         " ".join(symbols), len(flags), sha))
            for name, line, txt in flags:
                con.execute("INSERT INTO code_flag VALUES (?,?,?,?)", (rel, name, line, txt))
            total_flags += len(flags)
        con.commit()
        return {"files": len(files), "flags": total_flags, "db": str(db_path)}
    finally:
        con.close()


def query(db_path: Path, sql: str, args: tuple = ()) -> list[tuple]:
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        return con.execute(sql, args).fetchall()
    finally:
        con.close()


def flag_names(db_path: Path) -> list[dict]:
    rows = query(db_path, "SELECT name, COUNT(*) n FROM code_flag GROUP BY name ORDER BY n DESC")
    return [{"name": r[0], "n": r[1]} for r in rows]


def self_test() -> int:
    import tempfile
    print("=== code-index.py --self-test ===")
    d = Path(tempfile.mkdtemp())
    (d / "opencode.json").write_text("{}")
    (d / "docker").mkdir()
    (d / "docker" / "Dockerfile").write_text("FROM x")
    (d / "scripts").mkdir()
    (d / "scripts" / "a.sh").write_text("#!/bin/bash\nmain() {\n  sed -i x  # TODO fix\n  exit 1\n}\n")
    syms, flags = analyze((d / "scripts" / "a.sh").read_text(), ".sh")
    checks = [
        ("finds the shell function", "main" in syms),
        ("flags sed", any(f[0] == "sed" for f in flags)),
        ("flags exit 1", any(f[0] == "exit 1" for f in flags)),
        ("flags TODO", any(f[0] == "TODO" for f in flags)),
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
    ap.add_argument("--flags", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--grep", default=None)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--db", type=Path, default=None)
    ap.add_argument("--root", action="append", default=[],
                    help="extra directory to scan recursively (repeatable); default: the repo")
    args = ap.parse_args(argv if argv is not None else sys.argv[1:])

    if args.self_test:
        return self_test()

    repo = resolve_repo(Path(__file__).parent) or resolve_repo(Path.cwd())
    if repo is None:
        print("error: cannot resolve repo root", file=sys.stderr)
        return 2
    db = args.db or (repo / "data" / "observability" / "code.db")
    db.parent.mkdir(parents=True, exist_ok=True)

    summary = build(repo, db, [Path(r) for r in args.root] or [repo])

    if args.grep:
        rx = re.compile(args.grep)
        rows = query(db, "SELECT path, symbols FROM code")
        hits = [r[0] for r in rows if rx.search(r[0] + " " + (r[1] or ""))]
        print("\n".join(hits) or "(no match)")
    elif args.flags:
        rows = query(db, "SELECT path, name, line, text FROM code_flag ORDER BY path, line LIMIT 200")
        for r in rows:
            print(f"{r[0]}:{r[2]}  {r[1]:14} {r[3]}")
        print(f"\\n{len(rows)} flag rows (top names: {', '.join(x['name'] for x in flag_names(db)[:6])})")
    elif args.list:
        rows = query(db, "SELECT path, bytes, lines, flags_n FROM code ORDER BY bytes DESC LIMIT 200")
        for r in rows:
            print(f"{r[1]:>8} {r[2]:>6}L  flags={r[3]:<4} {r[0]}")
    elif args.json:
        print(json.dumps({"summary": summary, "flag_names": flag_names(db)}, indent=2))
    else:
        print(f"=== code-index.py ===")
        print(f"files: {summary['files']}   flags: {summary['flags']}   db: {summary['db']}")
        print("top flags: " + ", ".join(f"{x['name']}={x['n']}" for x in flag_names(db)[:8]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
