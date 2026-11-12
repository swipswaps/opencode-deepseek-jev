#!/usr/bin/env python3
"""
evidence-gate.py — capture and verify runtime evidence (P0, explainer #2).

A completion claim must name an artifact: command, exit code, stdout/stderr,
and (for UI claims) a DOM/screenshot file. `closeout`/`hardening-gate` require
the claims for code/UI changes; a deferral needs a ticket, and SKIP is not PASS.

  python3 scripts/evidence-gate.py --claim gates -- ./scripts/lint.sh
  python3 scripts/evidence-gate.py --claim a11y --artifact logs/a11y.txt -- ./scripts/a11y-audit.mjs ...
  python3 scripts/evidence-gate.py --check --require gates,a11y
  python3 scripts/evidence-gate.py --self-test

Layout: logs/evidence-<rev>/{manifest.json,<claim>.stdout,<claim>.stderr}
Exit: 0 PASS, 1 command failed/capture failed, 2 findings (check), 4 usage.
Constraints: no sed, no 2>/dev/null, no set -e, no rm -rf, no subprocess.run.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def repo_root() -> Path:
    c = HERE
    while c != c.parent:
        if (c / "opencode.json").is_file() and (c / "docker" / "Dockerfile").is_file():
            return c
        c = c.parent
    return HERE.parent


def root() -> Path:
    return Path(os.environ.get("EVIDENCE_ROOT") or repo_root())


def rev() -> str:
    p = subprocess.Popen(["git", "rev-parse", "--short", "HEAD"], cwd=str(root()),
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, _ = p.communicate()
    r = out.decode("utf-8", "replace").strip()
    return r or "worktree"


def evdir(r: str) -> Path:
    return root() / "logs" / ("evidence-" + r)


def load(r: str) -> dict:
    p = evdir(r) / "manifest.json"
    try:
        d = json.loads(p.read_text(encoding="utf-8"))
        if isinstance(d, dict) and isinstance(d.get("claims"), dict):
            return d
    except (OSError, ValueError):
        pass
    return {"rev": r, "claims": {}}


def save(r: str, d: dict) -> Path:
    e = evdir(r)
    e.mkdir(parents=True, exist_ok=True)
    p = e / "manifest.json"
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(d, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, p)
    return p


def run(cmd, cwd=None, timeout=300):
    p = subprocess.Popen(cmd, cwd=str(cwd or root()), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = p.communicate(timeout=timeout)
    return p.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def utcnow() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha_file(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def capture(r: str, name: str, cmd, artifact: str) -> int:
    e = evdir(r)
    e.mkdir(parents=True, exist_ok=True)
    rc, out, err = run(cmd)
    (e / (name + ".stdout")).write_text(out, encoding="utf-8")
    (e / (name + ".stderr")).write_text(err, encoding="utf-8")
    art = ""
    if artifact:
        ap = Path(artifact)
        if not ap.is_absolute():
            ap = root() / ap
        if ap.is_file() and ap.stat().st_size > 0:
            try:
                art = str(ap.resolve().relative_to(root().resolve()))
            except ValueError:
                art = str(ap)
    d = load(r)
    d["rev"] = r
    d["updated"] = utcnow()
    d["claims"][name] = {
        "cmd": " ".join(cmd), "rc": rc, "ts": utcnow(),
        "stdout": str(e / (name + ".stdout")) if out else "",
        "stderr": str(e / (name + ".stderr")) if err else "",
        "artifact": art, "artifact_sha256": sha_file((root() / art) if art and not Path(art).is_absolute() else Path(art)) if art else "",
    }
    save(r, d)
    print("evidence-gate: %s rc=%s (stdout=%dB artifact=%s)" % (name, rc, len(out), art or "none"))
    if rc != 0:
        print(out[-2000:], file=sys.stderr)
        print(err[-2000:], file=sys.stderr)
    return 0 if rc == 0 else 1


def check(r: str, require: str) -> int:
    d = load(r)
    names = [x.strip() for x in (require or "").split(",") if x.strip()]
    if not names:
        names = sorted(d["claims"])
    bad = 0
    if not names:
        print("evidence-gate: NO claims for %s" % r)
        return 2
    for n in names:
        c = d["claims"].get(n)
        if not c:
            print("  FAIL %s: missing claim" % n)
            bad += 1
            continue
        if c.get("rc") != 0:
            print("  FAIL %s: rc=%s" % (n, c.get("rc")))
            bad += 1
        if not (c.get("stdout") or c.get("stderr") or c.get("artifact")):
            print("  FAIL %s: no stdout/stderr/artifact (a claim without proof)" % n)
            bad += 1
        for k in ("stdout", "stderr", "artifact"):
            p = c.get(k) or ""
            if not p:
                continue
            fp = Path(p)
            if not fp.is_absolute():
                fp = root() / fp
            if not fp.is_file() or fp.stat().st_size == 0:
                print("  FAIL %s: %s missing/empty (%s)" % (n, k, p))
                bad += 1
        proven = c.get("rc") == 0 and bool(c.get("stdout") or c.get("stderr") or c.get("artifact"))
        print("  %s %s rc=%s" % ("PASS" if proven else "FAIL", n, c.get("rc")))
    print("evidence-gate: %s (%d claim(s))" % ("PASS" if not bad else "FAIL", len(names)))
    return 0 if not bad else 2


def self_test() -> int:
    import tempfile
    w = Path(tempfile.mkdtemp())
    os.environ["EVIDENCE_ROOT"] = str(w)
    try:
        rc = capture("testrev", "ok", [sys.executable, "-c", "print('evidence-ok')"], "")
        if rc != 0:
            print("evidence-gate: self-test FAIL capture")
            return 1
        if check("testrev", "ok") != 0:
            print("evidence-gate: self-test FAIL check")
            return 1
        rc = capture("testrev", "bad", [sys.executable, "-c", "raise SystemExit(3)"], "")
        if rc == 0 or check("testrev", "bad") == 0:
            print("evidence-gate: self-test FAIL failing command")
            return 1
        rc = capture("testrev", "silent", [sys.executable, "-c", "pass"], "")
        if rc != 0 or check("testrev", "silent") == 0:
            print("evidence-gate: self-test FAIL silent claim accepted")
            return 1
        if check("testrev", "missing") == 0:
            print("evidence-gate: self-test FAIL missing claim")
            return 1
        print("evidence-gate: self-test PASS (capture, rc, missing, silent)")
        return 0
    finally:
        import shutil
        shutil.rmtree(w, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description="Runtime evidence capture/verify")
    ap.add_argument("--rev", default="")
    ap.add_argument("--claim", default="")
    ap.add_argument("--artifact", default="")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--require", default="")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    r = args.rev or rev()
    if args.check:
        return check(r, args.require)
    if not args.claim:
        print("usage: --claim NAME -- COMMAND...", file=sys.stderr)
        return 4
    cmd = list(args.cmd)
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        print("usage: --claim NAME -- COMMAND...", file=sys.stderr)
        return 4
    return capture(r, args.claim, cmd, args.artifact)


if __name__ == "__main__":
    sys.exit(main())
