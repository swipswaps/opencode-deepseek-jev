#!/usr/bin/env python3
"""ask-claude.py - GATED escalation / second-opinion reviewer via the Anthropic API.

NEVER runs by default. Claude is ~10x the cost of the current stack and is NOT
on the spend policy allow-list (models.policy.json), so this refuses unless you
pass BOTH `--reason "<why>"` AND `--yes` (or CLAUDE_ALLOW=1). It is for a
deliberate second opinion or a hard debug ONLY - vision uses PaddleOCR (host)
or Gemini (when keyed), never Claude. Consult the operator before running.

    ./scripts/ask-claude.py --reason "diff review, Jev is down" --prompt "$(git diff)" --yes
    ./scripts/ask-claude.py --reason "..." --prompt-file /tmp/p.txt --dry-run

Key: ANTHROPIC_API_KEY (env or --env-file, default .env.local). --dry-run prints
the plan + rough cost estimate and makes no call. No other network.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

ENDPOINT = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"
DEFAULT_MODEL = os.environ.get("CLAUDE_MODEL", "claude-sonnet-4-5")
MIN_REASON = 8


def load_key(env_file: str) -> str:
    k = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if k:
        return k
    p = pathlib.Path(env_file)
    if p.exists():
        for line in p.read_text().splitlines():
            if line.startswith("ANTHROPIC_API_KEY="):
                return line.split("=", 1)[1].strip()
    return ""


def est_usd(prompt: str, max_out: int) -> float:
    # rough: ~4 chars/token; Claude sonnet ~ $3/M in, $15/M out. An estimate, not a quote.
    in_tok = len(prompt) / 4.0
    return (in_tok * 3.0 + max_out * 15.0) / 1_000_000.0


def call(prompt: str, model: str, max_tokens: int, key: str, timeout: int) -> str:
    body = {"model": model, "max_tokens": max_tokens,
            "messages": [{"role": "user", "content": prompt}]}
    req = urllib.request.Request(
        ENDPOINT, data=json.dumps(body).encode("utf-8"),
        headers={"x-api-key": key, "anthropic-version": ANTHROPIC_VERSION,
                 "content-type": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise SystemExit("HTTP %s: %s" % (e.code, e.read().decode("utf-8", "replace")[:300]))
    try:
        return d["content"][0]["text"].strip()
    except Exception:
        return json.dumps(d)[:400]


def self_test() -> int:
    fail = 0
    e = est_usd("x" * 4000, 100)
    if not (0.004 < e < 0.005):
        print("FAIL est_usd", e)
        fail = 1
    print("ask-claude: self-test PASS" if not fail else "ask-claude: self-test FAIL")
    return fail


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--reason", default="")
    ap.add_argument("--prompt", default="")
    ap.add_argument("--prompt-file", default="")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--max-tokens", type=int, default=1024)
    ap.add_argument("--env-file", default=".env.local")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()

    prompt = a.prompt or (pathlib.Path(a.prompt_file).read_text() if a.prompt_file else "")
    if not prompt:
        print("usage: ask-claude.py --reason TEXT --prompt TEXT|--prompt-file F [--yes] [--dry-run]")
        return 2

    gate = len(a.reason.strip()) >= MIN_REASON
    allow = a.yes or os.environ.get("CLAUDE_ALLOW") == "1"

    if a.dry_run:
        print("=== ask-claude DRY-RUN (no call) ===")
        print("model:      %s" % a.model)
        print("prompt:     %d chars" % len(prompt))
        print("est cost:   ~$%.4f (rough)" % est_usd(prompt, a.max_tokens))
        print("reason:     %s" % (a.reason or "(MISSING)"))
        print("gate:       reason=%s confirm=%s -> %s" % (
            "ok" if gate else "OPEN", "ok" if allow else "OPEN",
            "WOULD CALL" if (gate and allow) else "BLOCKED"))
        return 0

    if not gate:
        print("REFUSED: Claude is ASK-tier and deliberation-only. Pass "
              "--reason \"<why this needs Claude>\" (>=%d chars)." % MIN_REASON)
    if not allow:
        print("REFUSED: also pass --yes (or CLAUDE_ALLOW=1) after CONSULTING the "
              "operator - never auto-use Claude.")
    if not (gate and allow):
        return 2

    key = load_key(a.env_file)
    if not key:
        print("FAIL: ANTHROPIC_API_KEY not set (env or %s)" % a.env_file)
        return 2
    print(call(prompt, a.model, a.max_tokens, key, a.timeout))
    return 0


if __name__ == "__main__":
    sys.exit(main())
