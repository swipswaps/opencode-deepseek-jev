#!/usr/bin/env python3
"""
review-gate.py — independent adversarial review of a diff (P0).

WHY: the explainer's failure mode #1 is premature completion/self-attestation.
The agent that wrote the change must not be the only reviewer. This gate sends
a REDACTED diff to a separate, tool-less model with a fixed rubric and stores a
PASS/FAIL artifact keyed by the diff SHA. `hardening-gate`/`closeout` require a
PASS for MED/HIGH changes; docs-only changes may skip.

  python3 scripts/review-gate.py --run          # review the working tree diff
  python3 scripts/review-gate.py --check        # PASS artifact for this diff?
  python3 scripts/review-gate.py --gate         # tier-aware: LOW=ok, MED/HIGH require PASS
  python3 scripts/review-gate.py --self-test    # offline, no model call

Artifact: logs/review-<diffsha12>.json  (redacted findings; no raw diff, no key)
Env: REVIEW_MODEL (default deepseek-chat), DEEPSEEK_API_KEY (or .env.local),
     DEEPSEEK_BASE_URL (default https://api.deepseek.com).
Exit: 0 PASS, 2 FAIL/required-and-missing, 3 SKIP (no model/key), 4 usage.

Constraints: no sed, no 2>/dev/null, no set -e, no rm -rf, no subprocess.run,
  no bare kill, printf only, main() wrapper.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent


def repo_root() -> Path:
    c = HERE
    while c != c.parent:
        if (c / "opencode.json").is_file() and (c / "docker" / "Dockerfile").is_file():
            return c
        c = c.parent
    return HERE.parent


REPO = repo_root()
LOGS = REPO / "logs"
MODEL = os.environ.get("REVIEW_MODEL", "deepseek-chat")
BASE = os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com")

SECRET_PATTERNS = [
    r"sk-[A-Za-z0-9_\-]{16,}",
    r"sk-ant-[A-Za-z0-9_\-]{16,}",
    r"apikey_[A-Za-z0-9_]{12,}",
    r"AIza[A-Za-z0-9_\-]{20,}",
    r"(?i)bearer\s+[A-Za-z0-9._~+/=\-]{16,}",
    r"(?i)(api[_-]?key|password|secret|token)\s*[:=]\s*['\"]?[A-Za-z0-9_\-+/.=]{16,}['\"]?",
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----",
]
REDACT = re.compile("|".join(p.replace("(?i)", "") for p in SECRET_PATTERNS), re.IGNORECASE)


def redact(text: str) -> str:
    return REDACT.sub("[REDACTED]", str(text or ""))


def utcnow() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sh(cmd, timeout=60):
    p = subprocess.Popen(cmd, cwd=str(REPO), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, err = p.communicate(timeout=timeout)
    return p.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def collect():
    """Return (diff_text, changed_paths, truncated)."""
    _, staged, _ = sh(["git", "diff", "--cached", "--"])
    diff = staged
    _, status, _ = sh(["git", "status", "--porcelain"])
    paths = [line[3:].strip() for line in status.splitlines() if line[3:].strip()]
    if not diff.strip():
        rc, last, _ = sh(["git", "show", "--format=", "--no-ext-diff", "--patch", "HEAD"])
        if rc == 0 and last.strip():
            _, names, _ = sh(["git", "show", "--name-only", "--format=", "HEAD"])
            diff = last
            paths = [x for x in names.splitlines() if x.strip()]
    parts = [diff]
    # Only the staged content is reviewed and sent. Untracked/unstaged files
    # are deliberately excluded: they are not part of the commit and could
    # contain secrets the redaction has not seen.
    text = redact("\n".join(parts))
    cap = int(os.environ.get("REVIEW_DIFF_CAP", "200000"))
    truncated = len(text) > cap
    return (text[:cap] + ("\n[diff truncated at %d bytes]" % cap if truncated else ""),
            sorted(set(paths)), truncated)


def tier(paths) -> str:
    if not paths:
        return "LOW"
    high = ("web/src/", "scripts/", "docker/", "opencode.json", "models.policy.json", ".opencode/")
    low = ("docs/", "README.md", "HANDOFF.md", "TODO.md", "notes/")
    if any(p.startswith(high) for p in paths):
        return "HIGH"
    if paths and all(p.startswith(low) for p in paths):
        return "LOW"
    return "MED"


def key() -> str:
    k = os.environ.get("DEEPSEEK_API_KEY", "").strip()
    if k:
        return k
    try:
        for line in (REPO / ".env.local").read_text(encoding="utf-8").splitlines():
            if line.startswith("DEEPSEEK_API_KEY="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


PROMPT_VERSION = "v2"
PROMPT = """You are an independent adversarial reviewer. You see only the
redacted diff below; do not ask for tools or files. Judge correctness, security,
data loss, broken build/runtime, missing verification, and scope creep. Be
concise. Output ONLY one JSON object, no markdown fences and no prose before or after:
{"verdict":"PASS"|"FAIL","findings":[{"severity":"high|med|low","file":"...","issue":"...","fix":"..."}]}
FAIL if anything is unproven or unsafe. PASS only when the diff is sound.

CLAIM: {claim}

CHANGED PATHS: {paths}

DIFF:
{diff}
"""


def call_model(prompt: str) -> str:
    k = key()
    if not k:
        return ""
    body = json.dumps({"model": MODEL, "temperature": 0, "max_tokens": 4000,
                       "messages": [{"role": "user", "content": prompt}]}).encode()
    req = urllib.request.Request(BASE.rstrip("/") + "/chat/completions", data=body,
                                 headers={"Content-Type": "application/json",
                                          "Authorization": "Bearer " + k})
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            data = json.loads(r.read().decode("utf-8", "replace"))
        return str(((data.get("choices") or [{}])[0].get("message") or {}).get("content") or "")
    except Exception:  # noqa: BLE001 - provider/network failure is a SKIP
        return ""


def parse_verdict(text: str):
    s = str(text or "")
    i = s.find("{")
    while i >= 0:
        try:
            doc, _ = json.JSONDecoder().raw_decode(s[i:])
            if isinstance(doc, dict) and doc.get("verdict") in ("PASS", "FAIL"):
                findings = doc.get("findings") or []
                return (doc.get("verdict"), findings if isinstance(findings, list) else [])
        except ValueError:
            pass
        i = s.find("{", i + 1)
    return ("FAIL", [{"severity": "high", "file": "", "issue": "reviewer did not return the required JSON verdict", "fix": "re-run the review"}])


def artifact(payload):
    LOGS.mkdir(parents=True, exist_ok=True)
    path = LOGS / ("review-" + payload["diff_sha"][:12] + ".json")
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, indent=1, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)
    return path


def cmd_run(args) -> int:
    diff, paths, truncated = collect()
    sha = hashlib.sha256(diff.encode()).hexdigest()
    t = tier(paths)
    old = LOGS / ("review-" + sha[:12] + ".json")
    if old.is_file() and not args.force:
        try:
            d = json.loads(old.read_text(encoding="utf-8"))
            if d.get("verdict") == "PASS" and d.get("diff_sha") == sha and d.get("prompt") == PROMPT_VERSION:
                print("review-gate: cached PASS (%s, tier=%s)" % (old.name, t))
                return 0
        except (OSError, ValueError):
            pass
    prompt = (PROMPT.replace("{claim}", args.claim or "(unspecified)")
              .replace("{paths}", ", ".join(paths) or "(none)")
              .replace("{diff}", diff))
    raw = call_model(prompt)
    if not raw:
        print("review-gate: SKIP (no DEEPSEEK_API_KEY or provider failure); not a PASS")
        return 3
    verdict, findings = parse_verdict(raw)
    payload = {"ts": utcnow(), "rev": sh(["git", "rev-parse", "--short", "HEAD"])[1].strip(),
               "diff_sha": sha, "tier": t, "model": MODEL, "verdict": verdict,
               "findings": findings, "changed_paths": paths, "truncated": truncated,
               "redacted": True, "bytes": len(diff), "prompt": PROMPT_VERSION, "raw": raw[:8000]}
    path = artifact(payload)
    print("review-gate: %s tier=%s findings=%d -> %s" % (verdict, t, len(findings), path))
    for f in findings[:8]:
        print("  [%s] %s: %s" % (f.get("severity", "?"), f.get("file", "?"), f.get("issue", "")))
    return 0 if verdict == "PASS" else 2


def cmd_check(args) -> int:
    diff, paths, _ = collect()
    sha = hashlib.sha256(diff.encode()).hexdigest()
    t = tier(paths)
    path = LOGS / ("review-" + sha[:12] + ".json")
    if args.gate and t == "LOW":
        print("review-gate: SKIP tier=LOW (review not required)")
        return 0
    if not path.is_file():
        print("review-gate: NO REVIEW for diff %s (tier=%s)" % (sha[:12], t))
        return 2 if args.gate else 3
    try:
        d = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        print("review-gate: unreadable artifact %s" % path)
        return 2
    ok = d.get("diff_sha") == sha and d.get("verdict") == "PASS"
    print("review-gate: %s (%s, tier=%s)" % ("PASS" if ok else "FAIL", path.name, t))
    return 0 if ok else 2


def self_test() -> int:
    cases = [
        (["web/src/App.jsx"], "HIGH"),
        (["docs/X.md"], "LOW"),
        (["scripts/x.sh", "README.md"], "HIGH"),
        (["notes/x.txt"], "LOW"),
    ]
    fail = 0
    for paths, want in cases:
        got = tier(paths)
        if got != want:
            fail += 1
            print("  FAIL tier %s -> %s (want %s)" % (paths, got, want))
    sample = 'noise {"verdict":"PASS","findings":[]} tail'
    v, f = parse_verdict(sample)
    if v != "PASS" or f:
        fail += 1
        print("  FAIL parse verdict")
    bad = parse_verdict("I cannot do JSON")
    if bad[0] != "FAIL":
        fail += 1
        print("  FAIL parse invalid should FAIL")
    red = redact("x " + "sk-" + "abcdefghijklmnopqrstuvwxyz" + " y")
    if "sk-" in red:
        fail += 1
        print("  FAIL redaction")
    h = hashlib.sha256(b"abc").hexdigest()
    if len(h) != 64:
        fail += 1
    print("review-gate: self-test %s" % ("PASS" if not fail else "FAIL"))
    return 0 if not fail else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Independent adversarial diff review")
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--gate", action="store_true", help="tier-aware check for hardening/closeout")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--claim", default="")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.check or args.gate:
        return cmd_check(args)
    return cmd_run(args)


if __name__ == "__main__":
    sys.exit(main())
