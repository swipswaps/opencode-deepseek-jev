#!/usr/bin/env python3
"""
fuzzy-search.py — typo-tolerant search over the session index.

semantic-search.sh is exact-token FTS5/bm25: a mistyped token ("edti") finds
nothing. This adds the fuzzy layer the TODO asked for: tokenize the query and
each part, score by exact hits plus near-matches (difflib), and rank. It reads
the on-disk index built by semantic-search.sh --rebuild (parts_fts) and joins
session titles from the main database.

Free, local, read-only, no model call.

Usage:
    python3 scripts/fuzzy-search.py <query...> [--limit N] [--json]
    ./scripts/semantic-search.sh --fuzzy <query...>     # same, one entry point
    python3 scripts/fuzzy-search.py --self-test
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import sqlite3
import sys
from pathlib import Path

TOKEN_RE = re.compile(r"[a-z0-9_]+")


def resolve_repo(start: Path) -> Path | None:
    c = start.resolve()
    while c != c.parent:
        if (c / "opencode.json").is_file() and (c / "docker" / "Dockerfile").is_file():
            return c
        c = c.parent
    return None


def tokens(text: str) -> list[str]:
    return TOKEN_RE.findall((text or "").lower())


def score(qtokens: list[str], text: str) -> float:
    """Fraction of query tokens found exactly, plus partial credit for a typos."""
    if not qtokens:
        return 0.0
    toks = set(tokens(text))
    if not toks:
        return 0.0
    hit = 0.0
    for t in qtokens:
        if t in toks:
            hit += 1.0
        else:
            m = difflib.get_close_matches(t, toks, n=1, cutoff=0.6)
            if m:
                hit += 0.7
    return hit / len(qtokens)


def load(index: Path, db: Path) -> tuple[list[tuple], dict]:
    con = sqlite3.connect(f"file:{index}?mode=ro", uri=True)
    try:
        rows = con.execute("SELECT part_id, session_id, type, text FROM parts_fts").fetchall()
    finally:
        con.close()
    titles: dict[str, str] = {}
    try:
        c2 = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        for sid, title in c2.execute("SELECT id, title FROM session"):
            titles[sid] = title
        c2.close()
    except Exception:
        pass
    return rows, titles


def search(q: str, index: Path, db: Path, limit: int) -> list[dict]:
    qt = tokens(q)
    rows, titles = load(index, db)
    scored = []
    for pid, sid, typ, text in rows:
        s = score(qt, text)
        if s > 0:
            scored.append((s, pid, sid, typ, text or ""))
    scored.sort(key=lambda x: -x[0])
    out = []
    for s, pid, sid, typ, text in scored[:limit]:
        out.append({
            "score": round(s, 3), "part": pid, "session": sid,
            "title": titles.get(sid, ""), "type": typ,
            "snippet": " ".join(text.split())[:160],
        })
    return out


def self_test() -> int:
    print("=== fuzzy-search.py --self-test ===")
    checks = [
        ("exact token scores 1.0", score(["edit"], "the edit function") == 1.0),
        ("typo still scores > 0", score(["edti"], "the edit function") > 0.0),
        ("missing scores 0", score(["zzzz"], "the edit function") == 0.0),
        ("two tokens partial", 0.4 < score(["edit", "zzzz"], "the edit function") < 0.6),
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
    ap.add_argument("query", nargs="*")
    ap.add_argument("--index", type=Path, default=None)
    ap.add_argument("--db", type=Path, default=None)
    ap.add_argument("--limit", type=int, default=15)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv if argv is not None else sys.argv[1:])

    if args.self_test:
        return self_test()

    repo = resolve_repo(Path(__file__).parent) or resolve_repo(Path.cwd())
    if repo is None:
        print("error: cannot resolve repo root", file=sys.stderr)
        return 2
    index = args.index or (repo / "data" / "search" / "opencode-index.db")
    db = args.db or (repo / "data" / "opencode" / "opencode.db")
    if not index.is_file():
        print(f"error: no index at {index} (run ./scripts/semantic-search.sh --rebuild)", file=sys.stderr)
        return 2
    q = " ".join(args.query)
    if not q.strip():
        print("error: empty query", file=sys.stderr)
        return 2

    results = search(q, index, db, args.limit)
    if args.json:
        print(json.dumps({"q": q, "results": results}, indent=2))
    else:
        print(f"=== fuzzy-search.py :: {q} ===")
        if not results:
            print("(no matches)")
        for r in results:
            print(f"  {r['score']:.2f}  [{r['type']}] {r['title'][:34]:34} {r['snippet']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
