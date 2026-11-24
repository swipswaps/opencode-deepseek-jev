#!/usr/bin/env python3
"""check-placeholders.py — reject unresolved placeholders in copy-paste commands.

Why
---
The agent emitted `gh run watch -R swipswaps/foil-cfd-site <run-id> --exit-status`
(the literal placeholder, not a real ID) in a runbook-style answer. The operator
pasted it verbatim and got:

    -bash: run-id: No such file or directory

A command block is a delivery artifact: if it contains `<run-id>`, `YOUR_TOKEN`,
or similar, it cannot be pasted and is not an answer (RULES #99). This detector
scans shell fences only, so ordinary prose/markup is not a false positive.

Modes
-----
    --self-test                       prove the detector discriminates (gate)
    --text "..."                      scan a whole string as shell
    --file PATH [--file PATH ...]     scan markdown shell fences (or whole file)
    --db [--since-hours N]            scan assistant messages in the opencode DB
         [--cursor PATH] [--advance]   cursor = last time_created scanned
    --json                            machine-readable findings

Exit codes: 0 no findings (or clean self-test), 1 findings/failed self-test,
2 environment error (e.g. DB missing when --db was asked for).

Constraints: stdlib only; no subprocess; reads the DB read-only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

ANGLE = re.compile(r"(?<![\w<])<([a-z][a-z0-9]*(?:-[a-z0-9]+)*)>(?!\w)")
ENVVAR = re.compile(r"\b(?:YOUR|MY|REPLACE|INSERT|CHANGEME|EXAMPLE|TODO)[A-Z0-9_]{1,}\b")
DASHED = re.compile(r"\bYOUR-[a-z0-9][a-z0-9-]*\b")

# Tokens that are legitimate prose in a shell fence, not unresolved values.
ALLOW = {
    "br", "hr", "div", "span", "path", "code", "pre", "strong", "em",
    "table", "thead", "tbody", "tr", "td", "th", "svg", "circle", "rect",
}

SHELL_FENCE = re.compile(
    r"```[ \t]*(?:bash|sh|shell|zsh|console)[ \t]*\n(.*?)```",
    re.IGNORECASE | re.DOTALL,
)


class Finding:
    def __init__(self, token: str, line: int, text: str) -> None:
        self.token = token
        self.line = line
        self.text = text.strip()[:160]

    def as_dict(self) -> dict:
        return {"token": self.token, "line": self.line, "text": self.text}


def scan_shell(text: str) -> list[Finding]:
    out: list[Finding] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        seen: set[str] = set()
        for match in ANGLE.finditer(line):
            token = match.group(1)
            if token in ALLOW or token in seen:
                continue
            seen.add(token)
            out.append(Finding(f"<{token}>", lineno, line))
        for regex in (ENVVAR, DASHED):
            for match in regex.finditer(line):
                token = match.group(0)
                if token in seen:
                    continue
                seen.add(token)
                out.append(Finding(token, lineno, line))
    return out


# A line that is a URL, or an internal/tailnet hostname. On such a line any
# angle token is an unresolved placeholder. Filename templates like
# `<verb>-<noun>.sh` are NOT internal domains, so they are not flagged.
URL_OR_INTERNAL = re.compile(
    r"https?://|\.(?:ts\.net|local|internal|lan|home|tailnet)\b",
    re.IGNORECASE,
)


def scan_urls(text: str) -> list[Finding]:
    out: list[Finding] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        if not URL_OR_INTERNAL.search(line):
            continue
        seen: set[str] = set()
        for match in ANGLE.finditer(line):
            token = match.group(1)
            if token in ALLOW or token in seen:
                continue
            seen.add(token)
            out.append(Finding(f"<{token}>", lineno, line))
    return out


def shell_blocks(text: str) -> str:
    blocks = [m.group(1) for m in SHELL_FENCE.finditer(text)]
    return "\n".join(blocks)


def scan_file(path: Path) -> list[Finding]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        print(f"status=FAIL file={path} error={exc}", file=sys.stderr)
        return [Finding("<unreadable>", 0, str(exc))]
    haystack = shell_blocks(text) if path.suffix.lower() in {".md", ".txt"} else text
    return scan_shell(haystack) + scan_urls(text)


def db_candidates() -> list[Path]:
    env = os.environ.get("OPENCODE_DB")
    cands = [Path(env)] if env else []
    cands += [
        REPO / "data/opencode/opencode.db",
        Path("/home/node/.local/share/opencode/opencode.db"),
        Path("/home/owner/.local/share/opencode/opencode.db"),
    ]
    return cands


def resolve_db() -> Path | None:
    for path in db_candidates():
        if path.is_file():
            return path
    return None


def read_cursor(path: Path) -> int | None:
    try:
        return int(path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None


def write_cursor(path: Path, value: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"{value}\n", encoding="utf-8")


def scan_db(cursor_path: Path, since_hours: int, advance: bool) -> tuple[int, list[dict], dict]:
    db = resolve_db()
    if db is None:
        print("status=FAIL error=no opencode.db found (set OPENCODE_DB)", file=sys.stderr)
        return 2, [], {}

    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    con.row_factory = sqlite3.Row
    cur = con.cursor()

    cursor = read_cursor(cursor_path)
    baseline = False
    if cursor is None:
        row = cur.execute(
            "select coalesce(max(time_created), 0) as t from part"
        ).fetchone()
        cursor = int(row["t"]) if row else 0
        baseline = True
        if advance:
            write_cursor(cursor_path, cursor)

    if since_hours > 0:
        floor = int((time.time() - since_hours * 3600) * 1000)
        cursor = max(cursor, floor)

    rows = cur.execute(
        """
        select p.id as id, p.session_id as session_id, p.time_created as ts, p.data as data
        from part p
        join message m on m.id = p.message_id
        where p.time_created > ?
          and p.data like '%"type":"text"%'
          and m.data like '%"role":"assistant"%'
        order by p.time_created asc
        """,
        (cursor,),
    ).fetchall()

    findings: list[dict] = []
    latest = cursor
    for row in rows:
        latest = max(latest, int(row["ts"]))
        try:
            data = json.loads(row["data"])
        except (ValueError, TypeError):
            continue
        if data.get("type") != "text":
            continue
        text = data.get("text") or ""
        for block in SHELL_FENCE.finditer(text):
            for finding in scan_shell(block.group(1)):
                item = finding.as_dict()
                item.update(part=row["id"], session=row["session_id"], ts=row["ts"])
                findings.append(item)
        for finding in scan_urls(text):
            item = finding.as_dict()
            item.update(part=row["id"], session=row["session_id"], ts=row["ts"])
            findings.append(item)

    if findings:
        return 1, findings, {"scanned": len(rows), "baseline": baseline, "cursor": cursor}

    if advance and latest > cursor:
        write_cursor(cursor_path, latest)

    return 0, [], {"scanned": len(rows), "baseline": baseline, "cursor": latest, "db": str(db)}


def self_test() -> int:
    cases = [
        ("bad-angle", "gh run watch -R swipswaps/foil-cfd-site <run-id> --exit-status", True),
        ("bad-env", "curl -H \"Authorization: Bearer YOUR_TOKEN\" https://example.test", True),
        (
            "clean-lookup",
            "gh run watch \"$(gh run list -R o/r --limit 1 --json databaseId "
            "--jq '.[0].databaseId')\" --exit-status",
            False,
        ),
        ("clean-html-in-prose", "Use <div> in the layout.", False),
        ("bad-here-doc", "cat <<'EOF'\nhello <world>\nEOF", True),
        ("bad-url-placeholder", "Open https://<ws24>.<tailnet>.ts.net/api/health", True),
    ]

    failures = 0
    for name, text, should_find in cases:
        found = scan_shell(shell_blocks(f"```bash\n{text}\n```")) if name.startswith("clean") else scan_shell(text)
        found = found + scan_urls(text)
        got = len(found) > 0
        # The heredoc body is still shell input: <world> is an unresolved token.
        if got != should_find:
            failures += 1
            print(f"status=FAIL case={name} expected_finding={should_find} got={got}")
        else:
            print(f"status=PASS case={name} findings={len(found)}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Reject unresolved placeholders in shell commands.")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--text")
    parser.add_argument("--file", action="append", default=[])
    parser.add_argument("--db", action="store_true")
    parser.add_argument("--since-hours", type=int, default=0)
    parser.add_argument("--cursor", default=str(REPO / "logs/placeholder-cursor"))
    parser.add_argument("--advance", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        rc = self_test()
        print(f"status={'PASS' if rc == 0 else 'FAIL'} msg=self-test")
        return rc

    findings: list[dict] = []
    meta: dict = {}

    if args.text is not None:
        findings = [f.as_dict() for f in scan_shell(args.text)]
        meta = {"mode": "text"}

    for path_str in args.file:
        path = Path(path_str)
        hits = scan_file(path)
        findings += [dict(f.as_dict(), file=str(path)) for f in hits]
        meta.setdefault("mode", "file")

    if args.db:
        rc, db_findings, db_meta = scan_db(Path(args.cursor), args.since_hours, args.advance)
        if rc == 2:
            return 2
        findings += db_findings
        meta["db"] = db_meta

    if args.json:
        print(json.dumps({"status": "FAIL" if findings else "PASS", "findings": findings, "meta": meta}, indent=2))
    else:
        for item in findings:
            where = item.get("file") or item.get("part") or "text"
            print(
                f"status=FAIL token={item['token']} line={item['line']} "
                f"where={where} text={item['text']}"
            )
        if meta:
            summary = " ".join(f"{k}={v}" for k, v in meta.items() if k != "mode")
            print(f"status={'FAIL' if findings else 'PASS'} mode={meta.get('mode', 'db')} {summary}".rstrip())

    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
