#!/usr/bin/env python3
"""guard-evasion-scan.py — detect stderr-hiding evasions (RULE #8).

`2>/dev/null` is removed by the live guard, so the same intent gets re-spelled
as `>/dev/null 2>&1`, `&>/dev/null`, or `exec 2>/dev/null`. This scanner finds
those spellings in three places:

    --command CMD     one command string (what the model is about to run)
    --file PATH       a script/doc line by line (repeatable)
    --repo            tracked scripts/*.sh, scripts/*.py, .opencode/plugins/*.js
    --log [PATH]      past tool calls recorded in data/observability/guard.log

Read-only. Exit 0 clean, 1 hits, 2 usage error.

    ./scripts/guard-evasion-scan.py --command 'ls >/dev/null 2>&1'
    ./scripts/guard-evasion-scan.py --repo
    ./scripts/guard-evasion-scan.py --log
    ./scripts/guard-evasion-scan.py --self-test

Companion pieces: the live block is RULES in .opencode/plugins/blacklist-guard.js;
historical tool calls are audited by scripts/audit-tool-calls.py; source files by
scripts/scan-constraints.py. This script is the focused, testable detector.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# (name, regex, why)
EVASIONS = [
    ("2>/dev/null", re.compile(r"2\s*>>?\s*/dev/null"),
     "fd 2 to /dev/null hides stderr (the proof of failure)"),
    ("&>/dev/null", re.compile(r"&>>?\s*/dev/null"),
     "&> discards stdout AND stderr"),
    (">/dev/null 2>&1", re.compile(r"(?:^|[^0-9])1?>>?\s*/dev/null\s+2\s*>&\s*1"),
     "stdout->/dev/null then 2>&1 sends stderr there too"),
    ("exec 2>/dev/null", re.compile(r"\bexec\s+2\s*>>?\s*/dev/null"),
     "permanently discards stderr for the rest of the shell"),
]

# Files whose job is to define these patterns; never report them as offenders.
DEFAULT_EXCLUDE = {
    "scripts/guard-evasion-scan.py",
    "scripts/scan-constraints.py",
    "scripts/audit-tool-calls.py",
    "scripts/blacklist-guard-self-test.mjs",
    ".opencode/plugins/blacklist-guard.js",
}


def strip_quotes(s: str) -> str:
    out = []
    quote = None
    for ch in s:
        if quote:
            if ch == quote:
                quote = None
            out.append(" ")
        elif ch in ("'", '"'):
            quote = ch
            out.append(" ")
        else:
            out.append(ch)
    return "".join(out)


def scan_text(text: str, quote_aware: bool = True):
    bare = strip_quotes(text) if quote_aware else text
    for name, pat, why in EVASIONS:
        for _ in pat.finditer(bare):
            yield name, why


def cmd_mode(cmd: str) -> int:
    hits = list(scan_text(cmd, quote_aware=True))
    if not hits:
        print("PASS  no stderr-hiding evasion")
        return 0
    print("BLOCK  stderr-hiding evasion in command:")
    print("  " + cmd)
    for name, why in hits:
        print("  - " + name + ": " + why)
    print("  fix: keep stderr visible (redirect only stdout with >/dev/null); "
          "or capture `out=$(cmd 2>&1)` and print it.")
    return 1


def file_mode(path: Path, show: bool) -> int:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        print("error: cannot read " + str(path) + ": " + str(exc), file=sys.stderr)
        return 2
    hits = 0
    for i, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            continue
        found = list(scan_text(line, quote_aware=True))
        if not found:
            continue
        hits += 1
        for name, why in found:
            print(str(path) + ":" + str(i) + ": " + name + ": " + why)
        if show:
            print("    " + line.strip())
    return 1 if hits else 0


def repo_mode(root: Path, show: bool) -> int:
    files: list[Path] = []
    for pat in ("scripts/*.sh", "scripts/*.py", ".opencode/plugins/*.js"):
        files.extend(sorted(root.glob(pat)))
    total = 0
    for f in files:
        rel = f.relative_to(root).as_posix()
        if rel in DEFAULT_EXCLUDE:
            continue
        if file_mode(f, show):
            total += 1
    if total:
        print("\n" + str(total) + " file(s) contain stderr-hiding evasions", file=sys.stderr)
        return 1
    print("PASS  no stderr-hiding evasions in scanned files")
    return 0


def log_mode(path: Path) -> int:
    if not path.is_file():
        print("error: no log at " + str(path), file=sys.stderr)
        return 2
    hits = 0
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        cmd = rec.get("command") or rec.get("sample") or ""
        if not cmd:
            continue
        found = list(scan_text(str(cmd), quote_aware=True))
        if not found:
            continue
        hits += 1
        names = ",".join(sorted({n for n, _ in found}))
        print(str(rec.get("ts", "?")) + "  verdict=" + str(rec.get("verdict", "?")) + "  " + names)
        print("    " + str(cmd)[:200])
    if hits:
        print("\n" + str(hits) + " historical tool call(s) used a stderr-hiding evasion", file=sys.stderr)
        return 1
    print("PASS  no stderr-hiding evasions in the log")
    return 0


def self_test() -> int:
    fail = 0
    cases = [
        ("ls >/dev/null 2>&1", True, ">/dev/null 2>&1"),
        ("ls 1>/dev/null 2>&1", True, ">/dev/null 2>&1"),
        ("ls &>/dev/null", True, "&>/dev/null"),
        ("exec 2>/dev/null", True, "2>/dev/null"),
        ("ls 2>/dev/null", True, "2>/dev/null"),
        ("ls >/dev/null", False, ""),
        ("ls 2>&1 | grep x", False, ""),
        ("echo '2>/dev/null'", False, ""),
        ("echo '&>/dev/null'", False, ""),
    ]
    for cmd, want, name in cases:
        got = {n for n, _ in scan_text(cmd, quote_aware=True)}
        ok = (name in got) if want else (not got)
        if not ok:
            fail += 1
            print("  FAIL " + repr(cmd) + " -> " + repr(sorted(got)))
    # file mode: flagged line + comment + quoted line
    tmp = Path("/tmp/opencode/guard-evasion-fixture.sh")
    try:
        tmp.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(
            "# 2>/dev/null in a comment is documentation\n"
            "ls x >/dev/null 2>&1\n"
            "printf '%s\\n' '2>/dev/null'\n",
            encoding="utf-8",
        )
        rc = file_mode(tmp, show=False)
        if rc != 1:
            fail += 1
            print("  FAIL file mode should find exactly the bare evasion")
        tmp.unlink(missing_ok=True)
    except OSError as exc:
        fail += 1
        print("  FAIL file fixture: " + str(exc))
    if fail:
        print("guard-evasion-scan: self-test FAIL")
        return 1
    print("guard-evasion-scan: self-test PASS (command + file + quoted/comment)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--command")
    ap.add_argument("--file", action="append", default=[])
    ap.add_argument("--repo", action="store_true")
    ap.add_argument("--log", nargs="?", const="__default__")
    ap.add_argument("--show", action="store_true", help="print the offending line")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--root", default=None)
    args = ap.parse_args()

    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parent.parent

    if args.self_test:
        return self_test()
    if args.command is not None:
        return cmd_mode(args.command)
    if args.file:
        rc = 0
        for f in args.file:
            rc = max(rc, file_mode(Path(f), args.show))
        return rc
    if args.repo:
        return repo_mode(root, args.show)
    if args.log is not None:
        p = Path(args.log)
        if args.log == "__default__":
            p = root / "data" / "observability" / "guard.log"
        return log_mode(p)
    print("error: choose --command, --file, --repo, --log, or --self-test", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
