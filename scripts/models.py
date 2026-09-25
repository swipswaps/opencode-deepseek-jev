#!/usr/bin/env python3
"""
models.py — model catalog + cost policy. Local, no model call.

Pricing and capabilities come from `opencode models --verbose`. Apply
models.policy.json to decide, for the current model, one of:

    ALLOW  within policy (free, allow-listed, or <= max_input_per_m_usd)
    ASK    over policy but cheaper/qualified alternatives exist — alert the
           user and let them choose (docs, /models in the UI)
    BLOCK  explicitly denied, or no allowed alternative exists

This replaces a blunt "flash or STOP": there are many cheap and specialty
models; the policy states the ceiling and the chooser lists the options.

Usage:
    opencode models --verbose | ./scripts/models.py --current deepseek/deepseek-flash
    ./scripts/models.py --input dump.txt --policy models.policy.json --json
    ./scripts/models.py --catalog data/observability/models.json --write
    ./scripts/models.py --self-test
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from datetime import datetime, timezone

BLOCK_RE = re.compile(r"(?m)^([A-Za-z0-9_.:-]+/[A-Za-z0-9_.:-]+)\s*$")


def resolve_repo(start: Path) -> Path | None:
    c = start.resolve()
    while c != c.parent:
        if (c / "opencode.json").is_file() and (c / "docker" / "Dockerfile").is_file():
            return c
        c = c.parent
    return None


def parse_verbose(text: str) -> list[dict]:
    parts = BLOCK_RE.split(text)
    it = iter(parts[1:])
    out = []
    for mid, body in zip(it, it):
        try:
            j = json.loads(body)
        except ValueError:
            continue
        cost = j.get("cost", {}) or {}
        cache = cost.get("cache", {}) or {}
        lim = j.get("limit", {}) or {}
        cap = j.get("capabilities", {}) or {}
        inp = float(cost.get("input", 0) or 0)
        out.append({
            "id": mid,
            "provider": mid.split("/", 1)[0],
            "input": inp,
            "output": float(cost.get("output", 0) or 0),
            "cache_read": float(cache.get("read", 0) or 0),
            "context": int(lim.get("context", 0) or 0),
            "attachment": bool(cap.get("attachment")),
            "toolcall": bool(cap.get("toolcall")),
            "free": inp == 0,
        })
    return out


def short(x: str | None) -> str | None:
    return x.split("/", 1)[-1] if x else x


def listed(x: str | None, lst: list[str]) -> bool:
    return x in lst or short(x) in lst


def allowed(m: dict, p: dict) -> bool:
    if listed(m["id"], p.get("deny", [])):
        return False
    if listed(m["id"], p.get("allow", [])):
        return True
    if m["free"]:
        return True
    if p.get("require_toolcall") and not m["toolcall"]:
        return False
    if p.get("require_attachment") and not m["attachment"]:
        return False
    return m["input"] <= float(p.get("max_input_per_m_usd", 0.2))


def decide(models: list[dict], p: dict, current: str | None) -> dict:
    ok = [m for m in models if allowed(m, p)]
    ok.sort(key=lambda m: (m["input"], m["output"], m["id"]))
    recommended = ok[0] if ok else None

    deny = p.get("deny", [])
    verdict = "ALLOW"
    reason = "within policy"
    if not ok:
        verdict, reason = "BLOCK", "no model satisfies the policy"
    elif listed(current, deny):
        verdict, reason = "BLOCK", f"{current} is deny-listed"
    else:
        cur = next((m for m in models
                    if m["id"] == current or short(m["id"]) == short(current)), None)
        if cur is None:
            verdict, reason = "ASK", "current model not in the catalog"
        elif allowed(cur, p):
            verdict, reason = "ALLOW", "current model within policy"
        else:
            verdict, reason = "ASK", "current model is over policy; cheaper options exist"

    return {
        "ts": datetime.now(timezone.utc).isoformat(),
        "current": current,
        "verdict": verdict,
        "reason": reason,
        "recommended": recommended,
        "policy": p,
        "models": models,
        "allowed": [m["id"] for m in ok],
    }


def report(r: dict) -> None:
    p = r["policy"]
    print("=== models.py ===")
    print(f"policy: max_input=${p.get('max_input_per_m_usd')}/1M  allow={p.get('allow')}  deny={p.get('deny')}")
    print("\ncatalog (input/1M, context, flags):")
    for m in r["models"]:
        flag = "ok " if m["id"] in r["allowed"] else "no "
        att = "img" if m["attachment"] else "   "
        tool = "tool" if m["toolcall"] else "    "
        print(f"  {flag} {m['id']:<42} ${m['input']:<6} ctx={m['context']:<8} {att} {tool}")
    print(f"\ncurrent:     {r['current']}")
    print(f"verdict:     {r['verdict']}  ({r['reason']})")
    rec = r["recommended"]
    print(f"recommended: {rec['id'] if rec else '(none)'}")
    if r["verdict"] == "ASK" and rec:
        print(f"\nalert: {r['current']} is over policy. To switch:")
        print(f"  /models            (TUI)  or  opencode run -m {rec['id']}")


def self_test() -> int:
    print("=== models.py --self-test ===")
    sample = (
        "opencode/free-1\n"
        '{"id":"free-1","providerID":"opencode","cost":{"input":0,"output":0,"cache":{"read":0}},"limit":{"context":200000},"capabilities":{"toolcall":true,"attachment":true}}\n'
        "deepseek/deepseek-flash\n"
        '{"id":"deepseek-flash","providerID":"deepseek","cost":{"input":0.15,"output":0.6,"cache":{"read":0.003}},"limit":{"context":1000000},"capabilities":{"toolcall":true,"attachment":true}}\n'
        "deepseek/deepseek-v4-pro\n"
        '{"id":"deepseek-v4-pro","providerID":"deepseek","cost":{"input":0.435,"output":0.87,"cache":{"read":0.003625}},"limit":{"context":1000000},"capabilities":{"toolcall":true,"attachment":false}}\n'
    )
    models = parse_verbose(sample)
    p = {"max_input_per_m_usd": 0.2, "require_toolcall": True, "allow": ["deepseek-flash"], "deny": ["deepseek-v4-pro"]}
    checks = [
        ("parses 3 models", len(models) == 3),
        ("free model always allowed", allowed(next(m for m in models if m["id"] == "opencode/free-1"), p)),
        ("allow-listed flash allowed", allowed(next(m for m in models if m["id"] == "deepseek/deepseek-flash"), p)),
        ("deny-listed v4-pro blocked", not allowed(next(m for m in models if m["id"] == "deepseek/deepseek-v4-pro"), p)),
        ("free model recommended first", decide(models, p, "deepseek/deepseek-v4-pro")["recommended"]["id"].startswith("opencode/")),
        ("v4-pro verdict is BLOCK (deny)", decide(models, p, "deepseek/deepseek-v4-pro")["verdict"] == "BLOCK"),
        ("flash verdict is ALLOW", decide(models, p, "deepseek/deepseek-flash")["verdict"] == "ALLOW"),
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
    ap.add_argument("--input", type=Path, default=None)
    ap.add_argument("--catalog", type=Path, default=None, help="read a written models.json")
    ap.add_argument("--policy", type=Path, default=None)
    ap.add_argument("--current", default=None)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv if argv is not None else sys.argv[1:])

    if args.self_test:
        return self_test()

    repo = resolve_repo(Path(__file__).parent) or resolve_repo(Path.cwd())
    if repo is None:
        print("error: cannot resolve repo root", file=sys.stderr)
        return 2

    policy_path = args.policy or (repo / "models.policy.json")
    try:
        policy = json.loads(policy_path.read_text())
    except Exception:
        policy = {"max_input_per_m_usd": 0.2, "allow": [], "deny": []}

    current = args.current
    if current is None:
        try:
            current = json.loads((repo / "opencode.json").read_text()).get("model")
        except Exception:
            current = None

    if args.catalog:
        try:
            base = json.loads(args.catalog.read_text())
        except Exception:
            print(f"error: cannot read catalog {args.catalog}", file=sys.stderr)
            return 2
        result = decide(base.get("models", []), policy, current)
    else:
        if args.input:
            text = args.input.read_text()
        else:
            text = sys.stdin.read()
        models = parse_verbose(text)
        result = decide(models, policy, current)

    if args.write:
        out = repo / "data" / "observability" / "models.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(result, indent=2) + "\n")
        print(f"wrote {out}")

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        report(result)

    return 1 if result["verdict"] == "BLOCK" else 0


if __name__ == "__main__":
    sys.exit(main())
