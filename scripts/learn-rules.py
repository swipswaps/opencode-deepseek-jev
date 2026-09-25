#!/usr/bin/env python3
"""
learn-rules.py — learn deterministic rules from the chat/repo corpus.

The other tools describe *which* patterns recur (n-grams, error signatures).
This one tries to answer *why* one action works where another does not, by
building contrastive triples from the tool-call log:

    (state)      the error signature that just happened (or "")
    (action)     the shape of the next tool call ("grep", "edit", …)
    (outcome)    did that next call complete, or did it error too?

Aggregated over the corpus, that yields two kinds of rule:

  avoid   a shape with a high failure rate            → do not use it
  prefer  a shape that recovers a given error         → use it instead

Rules are written to data/observability/learned-rules.json and are ADVISORY:
the guard records them, but nothing is blocked until a human promotes a
confirmed pattern into RULES.md / the guard's fixed blacklist. That is the
deterministic loop — learn → review → codify → enforce — with the corpus
providing the evidence and a person providing the decision.

Recency matters: a pattern learned before a key rotation is stale and must not
be enforced forever. Use --since-days to bound the window.

Usage:
    ./scripts/learn-rules.py [--since-days N] [--json] [--write] [--self-test]
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


def signature(err: str) -> str:
    line = (err or "").strip().splitlines()[0] if (err or "").strip() else ""
    line = PATH_RE.sub("PATH", line)
    line = NUMBER_RE.sub("N", line)
    return " ".join(line.split())[:110] or "(no message)"


def shape(tool: str, cmd: str) -> str:
    if tool == "bash" and cmd:
        for tok in cmd.strip().split():
            if "=" in tok and not tok.startswith("-"):
                continue
            return tok
        return "bash"
    return tool or "?"


def load_parts(db: Path, since_days: int | None) -> list[dict]:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    try:
        sql = (
            "SELECT session_id, time_created, "
            "json_extract(data,'$.tool'), json_extract(data,'$.state.status'), "
            "json_extract(data,'$.state.input.command'), json_extract(data,'$.state.error') "
            "FROM part WHERE json_extract(data,'$.type')='tool' "
            "ORDER BY session_id, time_created"
        )
        rows = con.execute(sql).fetchall()
        if since_days:
            cutoff = int(datetime.now(timezone.utc).timestamp() * 1000) - since_days * 86400000
            rows = [r for r in rows if int(r[1]) >= cutoff]
        return [{"session": r[0], "ts": int(r[1]), "tool": r[2], "status": r[3],
                 "command": r[4], "error": r[5]} for r in rows]
    finally:
        con.close()


def learn(parts: list[dict], min_total: int, fail_rate: float, ok_rate: float) -> dict:
    shape_stats: dict[str, Counter] = defaultdict(Counter)
    recovery: dict[str, dict] = defaultdict(lambda: {"recover": Counter(), "fail": Counter()})

    by_sess: dict[str, list[dict]] = defaultdict(list)
    for p in parts:
        by_sess[p["session"]].append(p)

    for _s, ps in by_sess.items():
        ps.sort(key=lambda x: x["ts"])
        for i, p in enumerate(ps):
            s = shape(p["tool"], p["command"])
            shape_stats[s]["total"] += 1
            if p.get("status") == "error":
                shape_stats[s]["errors"] += 1
                if i + 1 < len(ps):
                    nxt = ps[i + 1]
                    ns = shape(nxt["tool"], nxt["command"])
                    key = signature(p.get("error", ""))
                    if nxt.get("status") == "completed":
                        recovery[key]["recover"][ns] += 1
                    else:
                        recovery[key]["fail"][ns] += 1

    shapes = []
    for s, c in shape_stats.items():
        n = c["total"]
        e = c["errors"]
        shapes.append({"shape": s, "total": n, "errors": e, "rate": (e / n) if n else 0.0})
    shapes.sort(key=lambda x: (-x["rate"], -x["total"]))

    avoid = [x for x in shapes if x["total"] >= min_total and x["rate"] >= fail_rate]
    prefer = [x for x in shapes if x["total"] >= min_total and x["rate"] <= ok_rate]

    rec = []
    for key, d in recovery.items():
        if not d["recover"] and not d["fail"]:
            continue
        best = d["recover"].most_common(1)
        rec.append({
            "signature": key,
            "best": ({"shape": best[0][0], "n": best[0][1]} if best else None),
            "avoid": [{"shape": s, "n": n} for s, n in d["fail"].most_common(3)],
        })
    rec.sort(key=lambda x: -(x["best"]["n"] if x["best"] else 0))

    return {"shapes": shapes, "avoid": avoid, "prefer": prefer, "recovery": rec}


def report(r: dict) -> None:
    print("=== learn-rules.py ===")
    print("\nshape failure rates (total / errors / rate):")
    for x in r["shapes"][:12]:
        print(f"  {x['total']:>4} {x['errors']:>3} {x['rate'] * 100:>3.0f}%  {x['shape']}")
    print("\nAVOID (high failure):")
    if not r["avoid"]:
        print("  (none above threshold)")
    for x in r["avoid"]:
        print(f"  {x['shape']}  fails {x['rate'] * 100:.0f}% of {x['total']}")
    print("\nPREFER (reliable):")
    for x in r["prefer"][:8]:
        print(f"  {x['shape']}  fails only {x['rate'] * 100:.0f}% of {x['total']}")
    print("\nRECOVERY (error -> action that worked):")
    if not r["recovery"]:
        print("  (no paired errors in window)")
    for x in r["recovery"][:8]:
        b = x["best"]
        bs = f"{b['shape']} (x{b['n']})" if b else "(none)"
        av = ", ".join(f"{a['shape']}x{a['n']}" for a in x["avoid"]) or "-"
        print(f"  [{x['signature'][:48]}]  -> {bs}   (avoid: {av})")
    print("\nnote: ADVISORY. Promote a confirmed rule into RULES.md / the guard")
    print("      blacklist to make it deterministic. Bound the window with")
    print("      --since-days so a stale pattern (e.g. a rotated key) expires.")


def self_test() -> int:
    print("=== learn-rules.py --self-test ===")
    parts = [
        {"session": "s", "ts": 1, "tool": "edit", "status": "error",
         "command": None, "error": "Could not find oldString"},
        {"session": "s", "ts": 2, "tool": "bash", "status": "completed",
         "command": "grep -n x f", "error": None},
        {"session": "s", "ts": 3, "tool": "jev-review_jev_review", "status": "error",
         "command": None, "error": "JEV_API_KEY rejected"},
        {"session": "s", "ts": 4, "tool": "jev-review_jev_review", "status": "error",
         "command": None, "error": "JEV_API_KEY rejected"},
    ]
    r = learn(parts, min_total=1, fail_rate=0.5, ok_rate=0.1)
    checks = [
        ("recovers an error with the next completed action",
         any(x["best"] and x["best"]["shape"] == "grep" for x in r["recovery"])),
        ("flags the twice-failing shape as avoid",
         any(x["shape"] == "jev-review_jev_review" for x in r["avoid"])),
        ("grep is preferred", any(x["shape"] == "grep" for x in r["prefer"])),
        ("signature normalises the message",
         signature("fail /a/b 42") == "fail PATH N"),
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
    ap.add_argument("--since-days", type=int, default=None)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--write", action="store_true", help="write data/observability/learned-rules.json")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--min-total", type=int, default=3)
    ap.add_argument("--db", type=Path, default=None)
    args = ap.parse_args(argv if argv is not None else sys.argv[1:])

    if args.self_test:
        return self_test()

    repo = resolve_repo(Path(__file__).parent) or resolve_repo(Path.cwd())
    if repo is None:
        print("error: cannot resolve repo root", file=sys.stderr)
        return 2
    db = args.db or (repo / "data" / "opencode" / "opencode.db")
    if not db.is_file():
        print(f"error: database not found ({db})", file=sys.stderr)
        return 2

    result = learn(load_parts(db, args.since_days), args.min_total, 0.5, 0.1)
    result["ts"] = datetime.now(timezone.utc).isoformat()
    result["since_days"] = args.since_days

    if args.write:
        out = repo / "data" / "observability" / "learned-rules.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(result, indent=2) + "\n")
        print(f"wrote {out}")

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        report(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
