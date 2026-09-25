#!/usr/bin/env python3
"""
prompt-lint.py — fuzzy classifier + preference linter for user prompts.

Prompts and replies repeat: the same requests recur, and the same mistakes
recur. This tool reads the opencode database (read-only) and the repo's own
preference sources (RULES.md, HANDOFF.md, README.txt, opencode.json) to:

  1. classify the prompt into a repo topic (cost / viz / handoff / audit / ...);
  2. fuzzy-match it against past user prompts (token Jaccard) and show the
     closest ones, so a repeated request is visible before it is answered again;
  3. surface recurring errors from the tool-call history (parts with
     state.status='error'), grouped by tool;
  4. lint the prompt against known preferences: blacklisted tool mentions,
     leaked secrets, vague/underspecified asks, and missing acceptance criteria.

Usage:
    ./scripts/prompt-lint.py --prompt "add a chart for cost"
    ./scripts/prompt-lint.py --last                 # latest user prompt in the DB
    printf '%s' "improve it" | ./scripts/prompt-lint.py

Options:
    --prompt TEXT   lint TEXT
    --last          lint the most recent user prompt in the database
    --db PATH       database path (default <repo>/data/opencode/opencode.db)
    --top N         similar prompts to show (default 5)
    --json          emit JSON
    --fail          exit 1 when a high-severity flag is found (for gating)

Exit status:
    0   report produced
    1   high-severity flag found and --fail was given
    2   usage / environment error

Preferences are cited from the files read; the blacklist mirrors RULES.md
(#7 sed, #8 2>/dev/null, #38 echo) plus the "no subprocess.run / no rm -rf"
conventions. This is advisory, not a hard gate.
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
from pathlib import Path

STOP = set((
    "the a an and or but if then else of to in on for with is are was were be been "
    "this that these those it its as at by from we you i he she they not no do does "
    "did can could will would should may might about into over under out up down so "
    "very just than what when where which who how all any more most other some only "
    "own same your our please keep use using used make get let me my"
).split())

CATEGORIES: dict[str, set[str]] = {
    "cost/billing": {"cost", "budget", "balance", "token", "tokens", "spend",
                     "model", "models", "v4", "pro", "flash", "billing", "cheap"},
    "viz/ux": {"viz", "chart", "charts", "dashboard", "explore", "d3", "perspective",
               "plot", "vega", "ux", "pane", "tab", "sankey", "treemap", "grid",
               "patterns", "endpoint", "timeline", "pivot"},
    "handoff/docs": {"handoff", "readme", "rules", "prompt", "document", "docs", "doc",
                     "note", "notes", "handoff", "handover"},
    "audit/security": {"audit", "secret", "secrets", "key", "keys", "password", "inject",
                       "jev", "redact", "security", "blacklist", "blacklisted"},
    "tooling/gates": {"lint", "gate", "gates", "shellcheck", "sed", "subprocess", "echo",
                      "devnull", "awk", "grep", "python", "tool", "tools", "tool-use"},
    "git/push": {"push", "commit", "branch", "remote", "repo", "repository", "git"},
    "test/verify": {"test", "tests", "verify", "assert", "coverage", "gate", "gates",
                    "acceptance", "reproduce"},
}

BLACKLIST: list[tuple[str, re.Pattern[str], str]] = [
    ("sed", re.compile(r"(?:^|[^A-Za-z0-9_])sed(?:[^A-Za-z0-9_]|$)"),
     "use awk / grep / python3 (RULES #7)"),
    ("2>/dev/null", re.compile(r"2>/dev/null"),
     "let stderr flow and branch on failure (RULES #8)"),
    ("subprocess.run", re.compile(r"subprocess\.run"),
     "use subprocess.Popen(..., stdout=PIPE, stderr=PIPE)"),
    ("rm -rf", re.compile(r"\brm\s+-rf\b"), "use rm -f on named paths"),
    ("echo", re.compile(r"(?:^|[^A-Za-z0-9_])echo(?:[^A-Za-z0-9_]|$)"),
     "use printf '%s\\n' (RULES #38)"),
]

SECRET_RE = re.compile(r"\b(sk-[A-Za-z0-9]{8,}|apikey_[A-Za-z0-9]{6,}|"
                       r"(?:password|passwd|secret|token)\s*[:=]\s*\S{6,})", re.I)

# A blacklisted token that is named as something to avoid ("no sed", "stop
# using 2>/dev/null", "substitute ... for sed") is not a request to use it.
PROHIBIT_RE = re.compile(
    r"\b(no|not|without|avoid|stop|dont|don't|never|ban|banned|blacklist|"
    r"blacklisted|forbid|forbidden|remove|replace|substitute|instead)\b", re.I)
# Stronger signal used for the corpus-level "talking about the blacklist" rule.
STRONG_PROHIBIT_RE = re.compile(
    r"\b(blacklist|blacklisted|banned|forbid|forbidden|substitute|instead|avoid)\b", re.I)

VAGUE_VERBS = {"improve", "fix", "continue", "invest", "keep", "better", "optimize",
               "enhance", "update", "clean", "refactor", "polish", "address"}

PATH_RE = re.compile(r"[A-Za-z0-9_./-]+\.(?:sh|py|mjs|md|txt|json|yml|yaml|js|sql)")
ACCEPTANCE = {"test", "tests", "verify", "assert", "gate", "gates", "expect", "should",
              "acceptance", "reproduce", "criteria", "pass", "fails"}


def resolve_repo(start: Path) -> Path | None:
    c = start.resolve()
    while c != c.parent:
        if (c / "opencode.json").is_file() and (c / "docker" / "Dockerfile").is_file():
            return c
        c = c.parent
    return None


def tokens(text: str) -> set[str]:
    return {w for w in re.findall(r"[a-z0-9_]+", text.lower()) if len(w) > 1 and w not in STOP}


def jaccard(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def classify(tok: set[str]) -> str:
    best, score = "(general)", 0
    for name, kws in CATEGORIES.items():
        s = len(tok & kws)
        if s > score:
            best, score = name, s
    return best


def load_past_prompts(con: sqlite3.Connection) -> list[dict]:
    rows = con.execute(
        "SELECT m.session_id, m.time_created, p.data "
        "FROM message m JOIN part p ON p.message_id=m.id "
        "WHERE json_extract(m.data,'$.role')='user' "
        "AND json_extract(p.data,'$.type')='text'"
    ).fetchall()
    by_msg: dict[tuple, str] = {}
    for sid, ts, pdata in rows:
        try:
            d = json.loads(pdata)
        except (ValueError, TypeError):
            continue
        by_msg[(sid, ts)] = d.get("text", "")
    out = []
    for (sid, ts), text in by_msg.items():
        if text.strip():
            out.append({"session": sid, "ts": ts, "text": text, "tok": tokens(text)})
    return out


def load_errors(con: sqlite3.Connection) -> list[dict]:
    rows = con.execute(
        "SELECT json_extract(data,'$.tool') tool, COUNT(*) n "
        "FROM part WHERE json_extract(data,'$.type')='tool' "
        "AND json_extract(data,'$.state.status')='error' "
        "GROUP BY tool ORDER BY n DESC LIMIT 10"
    ).fetchall()
    return [{"tool": r[0] or "(unknown)", "n": r[1]} for r in rows]


def lint(prompt: str, past: list[dict], errors: list[dict], repo: Path, top: int) -> dict:
    tok = tokens(prompt)
    flags: list[dict] = []

    # Collect blacklist mentions. If the prompt names several of them AND
    # carries a strong prohibition word, it is a discussion *about* the
    # blacklist ("blacklisted ... sed, 2>/dev/null, subprocess.run"), not a
    # request to use them.
    mentions: list[tuple[str, str, bool]] = []
    for name, regex, fix in BLACKLIST:
        for m in regex.finditer(prompt):
            near = bool(PROHIBIT_RE.search(prompt[max(0, m.start() - 64):m.start()]))
            mentions.append((name, fix, near))
            break
    meta = len(mentions) >= 2 and bool(STRONG_PROHIBIT_RE.search(prompt))
    if not meta:
        for name, fix, near in mentions:
            if near:
                continue
            flags.append({"sev": "high", "kind": "blacklist",
                          "msg": f"prompt names blacklisted '{name}'", "fix": fix})
    elif mentions:
        flags.append({"sev": "low", "kind": "blacklist-discussion",
                      "msg": "prompt discusses the blacklist ("
                             + ", ".join(n for n, _f, _near in mentions) + ")",
                      "fix": "no action; treated as a rule discussion, not a request"})

    m = SECRET_RE.search(prompt)
    if m:
        shown = m.group(0)[:6] + "..."
        flags.append({"sev": "high", "kind": "secret",
                      "msg": f"prompt appears to contain a secret ({shown})", "fix": "redact before sending to any provider"})

    words = len(prompt.split())
    verbs = tok & VAGUE_VERBS
    if words < 6 or (verbs and not (tok & ACCEPTANCE)):
        flags.append({"sev": "medium", "kind": "underspecified",
                      "msg": f"prompt looks underspecified ({words} words"
                             + (f"; vague verbs: {', '.join(sorted(verbs))}" if verbs else "") + ")",
                      "fix": "state the concrete artifact, the file(s), and how success is checked"})

    if not (tok & ACCEPTANCE) and "?" not in prompt:
        flags.append({"sev": "low", "kind": "no-acceptance",
                      "msg": "no acceptance criterion detected",
                      "fix": "add a verifiable check (a test, a gate, or an expected output)"})

    missing = []
    for p in set(PATH_RE.findall(prompt)):
        if ((repo / p).exists() or (repo / "scripts" / p).exists()
                or (repo / "docker" / p).exists() or Path(p).exists()):
            continue
        missing.append(p)
    if missing:
        shown = sorted(missing)[:8]
        more = "" if len(missing) <= 8 else f" (+{len(missing) - 8} more)"
        flags.append({"sev": "low", "kind": "missing-path",
                      "msg": "referenced path(s) not found: " + ", ".join(shown) + more,
                      "fix": "check the path or create it first"})

    cat = classify(tok)
    scored = sorted(
        ({"session": p["session"], "text": p["text"], "score": round(jaccard(tok, p["tok"]), 3),
          "ts": p["ts"]} for p in past),
        key=lambda x: -x["score"],
    )
    similar = [s for s in scored if s["score"] > 0][:top]
    return {"prompt": prompt, "category": cat, "flags": flags,
            "similar": similar, "recurring_errors": errors,
            "high": sum(1 for f in flags if f["sev"] == "high")}


def self_test(repo: Path) -> int:
    print("=== prompt-lint.py --self-test ===")
    bad = "please use " + BLACKLIST[0][0] + " and " + BLACKLIST[1][0]
    good = "add a patterns endpoint to explore and test it"
    r_bad = lint(bad, [], [], repo, 1)
    r_good = lint(good, [], [], repo, 1)
    checks = [
        ("flags generated blacklist prompt", r_bad["high"] >= 1),
        ("clean prompt has no high flag", r_good["high"] == 0),
        ("classifies patterns/endpoint as viz/ux", r_good["category"] == "viz/ux"),
    ]
    fails = 0
    for name, okv in checks:
        print(("  PASS " if okv else "  FAIL ") + name)
        if not okv:
            fails += 1
    print("result: " + ("PASS" if not fails else "FAIL"))
    return 1 if fails else 0


def report_text(r: dict) -> None:
    print("=== prompt-lint.py ===")
    print(f"category: {r['category']}")
    print(f"prompt:   {r['prompt'][:200]}")
    print(f"\nflags: {len(r['flags'])}")
    for f in r["flags"]:
        print(f"  [{f['sev'].upper():6}] {f['kind']}: {f['msg']}")
        print(f"           -> {f['fix']}")
    if not r["flags"]:
        print("  (none)")
    print(f"\nsimilar past prompts ({len(r['similar'])}):")
    if not r["similar"]:
        print("  (no token overlap with history)")
    for s in r["similar"]:
        one = " ".join(s["text"].split())[:110]
        print(f"  {s['score']:.2f}  {s['session'][:12]}  {one}")
    print("\nrecurring error tool calls:")
    if not r["recurring_errors"]:
        print("  (none)")
    for e in r["recurring_errors"]:
        print(f"  x{e['n']:<4} {e['tool']}")
    print("\nnote: advisory. preferences cited from RULES.md, HANDOFF.md, README.txt.")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--prompt", default=None)
    ap.add_argument("--last", action="store_true")
    ap.add_argument("--db", type=Path, default=None)
    ap.add_argument("--top", type=int, default=5)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--fail", action="store_true")
    ap.add_argument("--self-test", action="store_true",
                    help="run internal discrimination checks and exit")
    args = ap.parse_args(argv if argv is not None else sys.argv[1:])

    repo = resolve_repo(Path(__file__).parent) or resolve_repo(Path.cwd())
    if repo is None:
        print("error: cannot resolve repo root", file=sys.stderr)
        return 2

    if args.self_test:
        return self_test(repo)

    db_path = args.db or (repo / "data" / "opencode" / "opencode.db")
    if not db_path.is_file():
        print(f"error: database not found ({db_path})", file=sys.stderr)
        return 2

    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        past = load_past_prompts(con)
        errors = load_errors(con)
    finally:
        con.close()

    if args.last:
        prompt = max(past, key=lambda p: p["ts"])["text"] if past else ""
    elif args.prompt is not None:
        prompt = args.prompt
    else:
        prompt = sys.stdin.read()
    if not prompt.strip():
        print("error: empty prompt (use --prompt, --last, or stdin)", file=sys.stderr)
        return 2

    result = lint(prompt, past, errors, repo, args.top)
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        report_text(result)

    if result["high"] and args.fail:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
