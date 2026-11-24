#!/usr/bin/env python3
"""self-test-contract.py — a `--self-test` flag must execute a real test.

The guard-health outage: `self_test()` was defined, `--self-test` was advertised,
and `main` skipped the call. The gate ran the flag, got exit 0, and the stale /
no-hook cases never executed. A test that is never called is prose, not proof.

This tool forbids that circumvention mechanically:

  --check        every scripts/*.sh|*.py that advertises --self-test must either
                 have no named entrypoint (an inline self-test) or invoke it in
                 code, with a non-empty body. Comments and quoted strings do not
                 count.
  --trace NAME   run `bash -x NAME --self-test` and require the trace to show the
                 entrypoint executing AND at least one pass/fail assertion after
                 it. This catches a call placed in an unreachable branch.
  --self-test    fixtures: good, dead (defined/not called), commented-out call,
                 vacuous body, unreachable call, advertised-without-handler, and
                 Python equivalents.

Read-only apart from --trace, which runs the script's own self-test in a temp
working directory. Offline. No model call.

Exit: 0 pass, 1 findings, 2 usage/internal error.
"""

import argparse
import ast
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "scripts"
DEFAULT_TIMEOUT = 120
SHELL_SUFFIXES = {".sh", ".bash"}
PY_SUFFIXES = {".py"}

SHELL_DEF = re.compile(
    r"(?m)^[ \t]*(?:function[ \t]+)?(self_test|selfTest)[ \t]*(?:\([ \t]*\))?[ \t]*\{"
)
PY_CALL = re.compile(r"\b(self_test|selfTest)\s*\(")
ASSERT_TRACE = re.compile(r"(?m)^\++\s*(?:pass|fail)\b|printf[^\n]*(?:PASS|FAIL|result)")


def blank_shell(text):
    """Blank comments and quoted regions while preserving offsets and lines."""
    out = list(text)
    i = 0
    quote = None
    n = len(text)
    while i < n:
        c = text[i]
        if quote:
            if c == "\\" and quote == '"' and i + 1 < n:
                out[i] = " "
                out[i + 1] = " "
                i += 2
                continue
            if c == quote:
                quote = None
            if c != "\n":
                out[i] = " "
            i += 1
            continue
        if c in ('"', "'"):
            quote = c
            out[i] = " "
            i += 1
            continue
        if c == "#" and (i == 0 or text[i - 1] in " \t;|&(\n\r"):
            j = text.find("\n", i)
            if j < 0:
                j = n
            for k in range(i, j):
                out[k] = " "
            i = j
            continue
        i += 1
    return "".join(out)


def strip_comments(text):
    """Blank comments only; keep quoted text so --self-test in code still counts."""
    out = list(text)
    i = 0
    quote = None
    n = len(text)
    while i < n:
        c = text[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in ('"', "'"):
            quote = c
            i += 1
            continue
        if c == "#" and (i == 0 or text[i - 1] in " \t;|&(\n\r"):
            j = text.find("\n", i)
            if j < 0:
                j = n
            for k in range(i, j):
                out[k] = " "
            i = j
            continue
        i += 1
    return "".join(out)


def shell_body(text, brace_pos):
    depth = 0
    i = brace_pos
    quote = None
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in ('"', "'"):
            quote = c
        elif c == "#" and (i == 0 or text[i - 1] in " \t;|&(\n\r"):
            j = text.find("\n", i)
            i = len(text) if j < 0 else j
            continue
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[brace_pos + 1 : i]
        i += 1
    return ""


def shell_vacuous(body):
    clean = blank_shell(body)
    words = [w for w in re.split(r"[\s;]+", clean) if w]
    meaningful = [w for w in words if w not in {":", "true", "return", "0", "!"}]
    return not meaningful


def py_functions(tree, name):
    return [
        node
        for node in ast.walk(tree)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name
    ]


def py_calls(tree, name):
    return [
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == name
    ]


def py_vacuous(fn):
    for node in fn.body:
        if isinstance(node, ast.Pass):
            continue
        if isinstance(node, ast.Return) and node.value is None:
            continue
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Constant):
            continue
        return False
    return True


def finding(kind, path, line, detail):
    return {
        "kind": kind,
        "path": str(path),
        "line": line,
        "detail": detail,
    }


def check_shell(path, text):
    findings = []
    code = strip_comments(text)
    handler = "--self-test" in code
    defs = list(SHELL_DEF.finditer(text))
    if not defs:
        return findings
    if not handler:
        findings.append(
            finding("no-handler", path, 1, "self_test exists but --self-test never appears in code")
        )
    for m in defs:
        name = m.group(1)
        start = m.end() - 1
        body = shell_body(text, start)
        if shell_vacuous(body):
            findings.append(
                finding("vacuous", path, text[: m.start()].count("\n") + 1, f"{name}() body is empty")
            )
        after = code[m.end() :]
        called = re.search(r"(?m)(?<![\w.])" + re.escape(name) + r"(?![\w])", after)
        if not called:
            findings.append(
                finding(
                    "dead",
                    path,
                    text[: m.start()].count("\n") + 1,
                    f"{name}() is defined but never called in code (the guard-health bug)",
                )
            )
    return findings


def check_python(path, text):
    findings = []
    try:
        tree = ast.parse(text)
    except SyntaxError as exc:
        return [finding("syntax", path, exc.lineno or 1, exc.msg)]
    names = {node.name for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)}
    names &= {"self_test", "selfTest"}
    if not names:
        return findings
    for name in sorted(names):
        fns = py_functions(tree, name)
        calls = py_calls(tree, name)
        for fn in fns:
            if py_vacuous(fn):
                findings.append(
                    finding("vacuous", path, fn.lineno, f"{name}() body is empty")
                )
        if not calls:
            findings.append(
                finding(
                    "dead",
                    path,
                    fns[0].lineno,
                    f"{name}() is defined but never called (the guard-health bug)",
                )
            )
    return findings


def check_path(path):
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        return [finding("unreadable", path, 1, str(exc))]
    if path.suffix in SHELL_SUFFIXES:
        return check_shell(path, text)
    if path.suffix in PY_SUFFIXES:
        return check_python(path, text)
    return []


def check_all(root):
    findings = []
    scanned = 0
    for path in sorted(root.iterdir()):
        if not path.is_file() or path.suffix not in SHELL_SUFFIXES | PY_SUFFIXES:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if "--self-test" not in text and "self_test" not in text and "selfTest" not in text:
            continue
        scanned += 1
        findings.extend(check_path(path))
    return scanned, findings


def trace_shell(path, timeout):
    command = ["bash", "-x", str(path), "--self-test"]
    try:
        proc = subprocess.Popen(
            command,
            cwd=str(REPO),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            out, err = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, err = proc.communicate()
            return [finding("timeout", path, 1, f"self-test exceeded {timeout}s")]
    except OSError as exc:
        return [finding("exec", path, 1, str(exc))]
    if proc.returncode != 0:
        return [
            finding(
                "self-test-failed",
                path,
                1,
                f"--self-test exited {proc.returncode}: {(err or out).strip().splitlines()[-1:] or ''}",
            )
        ]
    call = re.search(r"(?m)^\++\s*(self_test|selfTest)\b", err)
    if not call:
        return [
            finding(
                "not-executed",
                path,
                1,
                "--self-test exited 0 but bash -x never entered self_test (dead/conditional call)",
            )
        ]
    tail = err[call.end() :]
    if not ASSERT_TRACE.search(tail):
        return [
            finding(
                "no-assertion",
                path,
                1,
                "self_test ran but the trace shows no pass/fail assertion",
            )
        ]
    return []


FIXTURES = {
    "good.sh": "\n".join(
        [
            "#!/usr/bin/env bash",
            "pass() { printf 'PASS %s\\n' \"$*\"; }",
            "self_test() { pass fixture; }",
            "main() {",
            "    if [ \"${1:-}\" = \"--self-test\" ]; then self_test; return 0; fi",
            "    return 0",
            "}",
            "main \"$@\"",
            "",
        ]
    ),
    "dead.sh": "\n".join(
        [
            "#!/usr/bin/env bash",
            "pass() { printf 'PASS %s\\n' \"$*\"; }",
            "self_test() { pass fixture; }",
            "main() {",
            "    if [ \"${1:-}\" = \"--self-test\" ]; then printf 'skipped\\n'; return 0; fi",
            "    return 0",
            "}",
            "main \"$@\"",
            "",
        ]
    ),
    "commented.sh": "\n".join(
        [
            "#!/usr/bin/env bash",
            "pass() { printf 'PASS %s\\n' \"$*\"; }",
            "self_test() { pass fixture; }",
            "main() {",
            "    # self_test",
            "    if [ \"${1:-}\" = \"--self-test\" ]; then printf 'skipped\\n'; return 0; fi",
            "    return 0",
            "}",
            "main \"$@\"",
            "",
        ]
    ),
    "vacuous.sh": "\n".join(
        [
            "#!/usr/bin/env bash",
            "self_test() { :; }",
            "main() {",
            "    if [ \"${1:-}\" = \"--self-test\" ]; then self_test; return 0; fi",
            "    return 0",
            "}",
            "main \"$@\"",
            "",
        ]
    ),
    "hidden.sh": "\n".join(
        [
            "#!/usr/bin/env bash",
            "pass() { printf 'PASS %s\\n' \"$*\"; }",
            "self_test() { pass fixture; }",
            "main() {",
            "    if false; then self_test; fi",
            "    if [ \"${1:-}\" = \"--self-test\" ]; then printf 'exit 0\\n'; return 0; fi",
            "    return 0",
            "}",
            "main \"$@\"",
            "",
        ]
    ),
    "nohandler.sh": "\n".join(
        [
            "#!/usr/bin/env bash",
            "self_test() { printf 'PASS fixture\\n'; }",
            "main() { self_test; return 0; }",
            "main \"$@\"",
            "",
        ]
    ),
    "good.py": "\n".join(
        [
            "import sys",
            "def self_test():",
            "    print('PASS fixture')",
            "if __name__ == '__main__':",
            "    if '--self-test' in sys.argv:",
            "        self_test()",
            "",
        ]
    ),
    "dead.py": "\n".join(
        [
            "import sys",
            "def self_test():",
            "    print('PASS fixture')",
            "if __name__ == '__main__':",
            "    if '--self-test' in sys.argv:",
            "        print('skipped')",
            "",
        ]
    ),
    "vacuous.py": "\n".join(
        [
            "import sys",
            "def self_test():",
            "    pass",
            "if __name__ == '__main__':",
            "    if '--self-test' in sys.argv:",
            "        self_test()",
            "",
        ]
    ),
}


def self_test():
    failures = []

    def check(name, ok, detail=""):
        print(("  PASS " if ok else "  FAIL ") + name + ("" if ok else " -> " + detail))
        if not ok:
            failures.append(name)

    with tempfile.TemporaryDirectory(prefix="self-test-contract-") as tmp:
        root = Path(tmp)
        for name, body in FIXTURES.items():
            (root / name).write_text(body, encoding="utf-8")
        cases = {
            "good.sh": set(),
            "dead.sh": {"dead"},
            "commented.sh": {"dead"},
            "vacuous.sh": {"vacuous"},
            "hidden.sh": set(),
            "nohandler.sh": {"no-handler"},
            "good.py": set(),
            "dead.py": {"dead"},
            "vacuous.py": {"vacuous"},
        }
        for name, expected in cases.items():
            got = {f["kind"] for f in check_path(root / name)}
            check(f"static {name}: {sorted(expected) or 'clean'}", got == expected, str(got))
        hidden = trace_shell(root / "hidden.sh", 10)
        check(
            "trace hidden.sh: unreachable call caught",
            any(f["kind"] == "not-executed" for f in hidden),
            str(hidden),
        )
        good = trace_shell(root / "good.sh", 10)
        check("trace good.sh: executed assertion passes", good == [], str(good))
    print("result: PASS" if not failures else "result: FAIL")
    return 0 if not failures else 1


def render(scanned, findings):
    if not findings:
        print(f"self-test-contract: PASS ({scanned} file(s) scanned)")
        return 0
    print(f"self-test-contract: FAIL ({len(findings)} finding(s) in {scanned} file(s))")
    for f in findings:
        print(f"  {f['path']}:{f['line']}: {f['kind']}: {f['detail']}")
    return 1


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="self-test-contract.py",
        description="Require every advertised --self-test to execute a real test.",
    )
    parser.add_argument("--check", action="store_true", help="scan scripts/ (default)")
    parser.add_argument("--trace", metavar="SCRIPT", action="append", default=[],
                        help="run bash -x SCRIPT --self-test and prove the entrypoint executed")
    parser.add_argument("--self-test", action="store_true", help="run built-in fixtures")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT, help="trace timeout seconds")
    parser.add_argument("paths", nargs="*", help="extra files to check")
    args = parser.parse_args(argv)

    if args.self_test:
        return self_test()

    findings = []
    scanned = 0
    if args.paths:
        for raw in args.paths:
            path = Path(raw)
            if not path.is_absolute():
                path = REPO / path
            scanned += 1
            findings.extend(check_path(path))
    elif args.check or not args.trace:
        scanned, findings = check_all(SCRIPTS)

    for name in args.trace:
        path = Path(name)
        if not path.is_absolute():
            path = SCRIPTS / path
        if path.suffix not in SHELL_SUFFIXES:
            findings.append(finding("unsupported-trace", path, 1, "trace supports shell scripts only"))
            continue
        findings.extend(trace_shell(path, args.timeout))

    if args.json:
        print(json.dumps({"status": "FAIL" if findings else "PASS", "scanned": scanned,
                          "findings": findings}, indent=1))
        return 1 if findings else 0
    return render(scanned, findings)


if __name__ == "__main__":
    sys.exit(main())
