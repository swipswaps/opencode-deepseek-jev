#!/usr/bin/env python3
"""acronym-lint.py - flag acronyms/abbreviations used before they are expanded.

Enforces RULES.md #96 and the explain-first skill: the FIRST mention of an
all-caps token must be expanded ("Service Level Objective (SLO)") or introduced
as a glossary entry ("SLO - Service Level Objective"). Later mentions may use the
short form.

  ./scripts/acronym-lint.py FILE
  printf '%s\n' 'The SLO is high.' | ./scripts/acronym-lint.py
  ./scripts/acronym-lint.py --strict --json README.md
  ./scripts/acronym-lint.py --self-test

Exit 0 clean, 1 findings, 2 usage/unreadable. --strict disables the common
allowlist (API, CLI, JSON, ...); --allow A,B replaces it.

No dependencies. Plain ASCII. No subprocess.
"""
import json
import re
import sys

# Universally understood in this repo; --strict disables the allowlist.
ALLOW = {
    "AI", "API", "CD", "CI", "CLI", "CPU", "CSV", "DB", "DNS", "GPU", "HTML",
    "HTTP", "HTTPS", "ID", "IP", "JSON", "LLM", "MIT", "NOTE", "NO", "OK", "OS",
    # SHA: deliberate exception for the hash name used in every handoff/review.
    "PDF", "PR", "RAM", "SHA", "SQL", "SSH", "TLS", "TODO", "TUI", "UI", "URL", "UTC",
    "XML", "YAML", "YES",
}

TOKEN = re.compile(r"\b[A-Z][A-Z0-9]{1,5}\b")


def is_defined(tok, lines, idx):
    """True when the token's first mention is expanded/glossed nearby."""
    window = lines[max(0, idx - 1): idx + 1]
    pat_paren = re.compile(r"\([^()]*\b" + re.escape(tok) + r"\b[^()]*\)")
    pat_prefix = re.compile(r"\b" + re.escape(tok) + r"\s*\([^()]+\)")
    pat_gloss = re.compile(r"^\s*[-*]?\s*" + re.escape(tok) + r"\s*[-\u2013\u2014:]\s+\S")
    for line in window:
        if pat_paren.search(line) or pat_prefix.search(line) or pat_gloss.search(line):
            return True
    return False


def scan(text, allow, strict=False):
    lines = text.splitlines()
    first = {}
    for i, line in enumerate(lines):
        for match in TOKEN.finditer(line):
            tok = match.group(0)
            if tok not in first:
                first[tok] = i
    findings = []
    for tok, idx in first.items():
        if not strict and tok in allow:
            continue
        if is_defined(tok, lines, idx):
            continue
        findings.append({
            "line": idx + 1,
            "acronym": tok,
            "context": lines[idx].strip()[:160],
        })
    findings.sort(key=lambda f: (f["line"], f["acronym"]))
    return findings


def self_test():
    fail = 0

    def check(name, ok):
        nonlocal fail
        print(("  PASS " if ok else "  FAIL ") + name)
        if not ok:
            fail += 1

    check("defined expands", scan("A Service Level Objective (SLO) is a target. The SLO is 50%.", ALLOW) == [])
    found = scan("The SLO is 50%.", ALLOW)
    check("undefined flagged", len(found) == 1 and found[0]["acronym"] == "SLO")
    check("allowlist", scan("Use the API and JSON.", ALLOW) == [])
    check("strict flags allowlist", len(scan("Use the API and JSON.", ALLOW, strict=True)) == 2)
    check("glossary", scan("SLO - Service Level Objective", ALLOW) == [])
    print("result: " + ("FAIL" if fail else "PASS"))
    return 1 if fail else 0


def usage():
    print("usage: %s [FILE] [--json] [--strict] [--allow A,B] [--self-test]" % sys.argv[0])
    print("  FILE omitted or '-' reads stdin. Exit 0 clean, 1 findings, 2 usage.")


def main(argv):
    path = ""
    json_out = False
    strict = False
    allow = set(ALLOW)
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == "--self-test":
            return self_test()
        elif arg == "--json":
            json_out = True
        elif arg == "--strict":
            strict = True
        elif arg == "--allow":
            i += 1
            if i >= len(argv):
                print("acronym-lint: --allow needs a comma list")
                return 2
            allow = {x.strip().upper() for x in argv[i].split(",") if x.strip()}
        elif arg in ("-h", "--help"):
            usage()
            return 0
        elif arg == "-":
            path = ""
        elif arg.startswith("-"):
            print("acronym-lint: unknown arg %s" % arg)
            usage()
            return 2
        else:
            path = arg
        i += 1

    if path:
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError as err:
            print("acronym-lint: cannot read %s: %s" % (path, err))
            return 2
    else:
        text = sys.stdin.read()

    findings = scan(text, allow, strict)
    if json_out:
        print(json.dumps({"findings": findings, "count": len(findings)}))
    else:
        for f in findings:
            print("line %s: %s - %s" % (f["line"], f["acronym"], f["context"]))
        if findings:
            print("acronym-lint: %d undefined acronym(s)" % len(findings))
        else:
            print("acronym-lint: clean")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
