#!/usr/bin/env python3
"""guard-classify.py - semantic beforeTool guard (durable-pi's jev-damage-control).

Our blacklist-guard matches PATTERNS (sed, rm -rf, ...). This adds a SEMANTIC
layer: before a risky shell command runs, ask the cheap SubQ Snap classifier
(subq-snap-preview) whether it is irreversible/destructive, and block it. The
verdict is stored as a DURABLE MEMO keyed by the command hash, so a restart
never re-asks (the pi-durable idea). Fails OPEN if the classifier is
unreachable (durable-pi: "when Jev is unreachable, the command runs").

    ./scripts/guard-classify.py --command "rm -rf /data"        # -> BLOCK
    ./scripts/guard-classify.py --command "ls -la"              # -> ALLOW
    ./scripts/guard-classify.py --command "..." --json
    ./scripts/guard-classify.py --self-test                     # offline

Exit 0 ALLOW, 1 BLOCK, 2 usage. Key: SUBQ_API_KEY (env or .env.local).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

ENDPOINT = os.environ.get("SUBQ_URL", "https://api.subq.ai/v1/systemone")
MODEL = os.environ.get("SUBQ_MODEL", "subq-snap-preview")
MEMO_DEFAULT = "data/observability/guard-memo.json"


def load_key(env_file: str) -> str:
    k = os.environ.get("SUBQ_API_KEY", "").strip()
    if k:
        return k
    p = pathlib.Path(env_file)
    if p.exists():
        for line in p.read_text().splitlines():
            if line.startswith("SUBQ_API_KEY="):
                return line.split("=", 1)[1].strip()
    return ""


def dhash(cmd: str) -> str:
    return hashlib.sha256(cmd.strip().encode("utf-8")).hexdigest()[:16]


def memo_get(path: str, key: str):
    try:
        d = json.loads(pathlib.Path(path).read_text())
        return d.get(key)
    except Exception:
        return None


def memo_put(path: str, key: str, verdict: str):
    p = pathlib.Path(path)
    try:
        d = json.loads(p.read_text()) if p.exists() else {}
    except Exception:
        d = {}
    d[key] = {"verdict": verdict, "ts": int(time.time())}
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(d, indent=2))


def body(cmd: str) -> dict:
    return {
        "model": MODEL,
        "state": "Shell command about to run:\n" + cmd[:4000],
        "questions": {
            "irreversible": {
                "type": "noul",
                "instructions": "Is this command irreversible or destructive?",
                "criteria": {
                    "true": "Deletes/overwrites data, force-pushes, drops a table/DB, kills a service, formats, or cannot be undone.",
                    "false": "Read-only, additive, or safely reversible.",
                },
            }
        },
    }


def classify(cmd: str, key: str, timeout: int):
    req = urllib.request.Request(
        ENDPOINT, data=json.dumps(body(cmd)).encode("utf-8"),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.loads(r.read().decode("utf-8"))
    p = float((d.get("answers") or {}).get("irreversible", {}).get("noul", 0))
    return ("BLOCK" if p >= 0.5 else "ALLOW"), p


def self_test() -> int:
    fail = 0
    b = body("rm -rf /")
    if b["model"] != MODEL or b["questions"]["irreversible"]["type"] != "noul":
        print("FAIL body")
        fail = 1
    if dhash("a") == dhash("b") or dhash("a") != dhash("a"):
        print("FAIL hash")
        fail = 1
    import tempfile
    d = tempfile.mkdtemp()
    m = os.path.join(d, "m.json")
    memo_put(m, dhash("ls"), "ALLOW")
    if (memo_get(m, dhash("ls")) or {}).get("verdict") != "ALLOW":
        print("FAIL memo")
        fail = 1
    print("guard-classify: self-test PASS" if not fail else "guard-classify: self-test FAIL")
    return fail


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--command", default="")
    ap.add_argument("--memo", default=MEMO_DEFAULT)
    ap.add_argument("--env-file", default=".env.local")
    ap.add_argument("--timeout", type=int, default=20)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--no-memo", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    cmd = a.command
    if not cmd:
        print("usage: guard-classify.py --command \"...\" [--json] [--self-test]")
        return 2
    key = dhash(cmd)
    if not a.no_memo:
        m = memo_get(a.memo, key)
        if m:
            v = m.get("verdict", "ALLOW")
            print(json.dumps({"verdict": v, "cached": True, "command": cmd, "memo": key}) if a.json
                  else "%s%s (memoized)" % (v, " \u2014 blocked" if v == "BLOCK" else ""))
            return 0 if v == "ALLOW" else 1
    k = load_key(a.env_file)
    if not k:
        print(json.dumps({"verdict": "ALLOW", "reason": "no SUBQ_API_KEY (fail-open)", "command": cmd}) if a.json
              else "ALLOW (no SUBQ_API_KEY \u2014 fail-open, durable-pi: unreachable guard runs the command)")
        return 0
    try:
        verdict, p = classify(cmd, k, a.timeout)
    except (urllib.error.URLError, urllib.error.HTTPError, OSError) as e:
        print(json.dumps({"verdict": "ALLOW", "reason": "classifier unreachable (fail-open): %s" % str(e)[:80], "command": cmd}) if a.json
              else "ALLOW (classifier unreachable \u2014 fail-open)")
        return 0
    if not a.no_memo:
        memo_put(a.memo, key, verdict)
    if a.json:
        print(json.dumps({"verdict": verdict, "noul": round(p, 3), "cached": False, "command": cmd, "memo": key}))
    else:
        print("%s (p=%0.2f)  %s" % (verdict, p, cmd))
    return 0 if verdict == "ALLOW" else 1


if __name__ == "__main__":
    sys.exit(main())
