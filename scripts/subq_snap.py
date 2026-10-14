#!/usr/bin/env python3
"""subq_snap.py - deterministic client for SubQ's Decisions API (Snap).

SubQ Snap (model `subq-snap-preview`, `POST /v1/systemone`) turns a `state`
into TYPED decisions - noul (yes/no probability), choice, score - far cheaper
than a chat/review call (billed on input only, $0.05 / 1M tokens; output is
free). Use it as a FIRST-PASS triage gate before an expensive second opinion
(for example the Jev review MCP, which needs its own key), and run it on a
bounded DIGEST rather than a whole context so the context window is not the
failure mode.

    ./scripts/subq_snap.py --state-file FILE --question escalate \
        --instructions "..." [--true "..."] [--false "..."]         # noul
    ./scripts/subq_snap.py --state "..." --question queue --type choice \
        --criteria "a=descA,b=descB,c"                              # choice
    ./scripts/subq_snap.py --state "..." --question acuity --type score \
        --criteria "within a week,within a day,within an hour"      # score
    ./scripts/subq_snap.py --dry-run ...    # print the request body, no send
    ./scripts/subq_snap.py --self-test      # offline, no network

Key: SUBQ_API_KEY (env, or --env-file, default .env.local). Seams: SUBQ_MODEL,
SUBQ_URL. One HTTP POST to api.subq.ai; no other network. Read-only to the repo.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import urllib.error
import urllib.request

DEFAULT_URL = "https://api.subq.ai/v1/systemone"
DEFAULT_MODEL = "subq-snap-preview"


def load_key(env_file: str) -> str:
    import os

    key = os.environ.get("SUBQ_API_KEY", "").strip()
    if key:
        return key
    p = pathlib.Path(env_file)
    if p.exists():
        for line in p.read_text().splitlines():
            if line.startswith("SUBQ_API_KEY="):
                return line.split("=", 1)[1].strip()
    return ""


def build_questions(args: argparse.Namespace) -> dict:
    q: dict = {}
    if args.type == "noul":
        item: dict = {"type": "noul", "instructions": args.instructions}
        crit = {}
        if args.true:
            crit["true"] = args.true
        if args.false:
            crit["false"] = args.false
        if crit:
            item["criteria"] = crit
        q[args.question] = item
    elif args.type == "choice":
        crit = {}
        for tok in (args.criteria or "").split(","):
            tok = tok.strip()
            if not tok:
                continue
            if "=" in tok:
                k, v = tok.split("=", 1)
                crit[k.strip()] = v.strip() or None
            else:
                crit[tok] = None
        q[args.question] = {
            "type": "choice",
            "instructions": args.instructions,
            "criteria": crit,
        }
    elif args.type == "score":
        levels = [t.strip() for t in (args.criteria or "").split(",") if t.strip()]
        q[args.question] = {
            "type": "score",
            "instructions": args.instructions,
            "criteria": levels,
        }
    return q


def build_body(args: argparse.Namespace) -> dict:
    state = (
        pathlib.Path(args.state_file).read_text()
        if args.state_file
        else (args.state or "")
    )
    return {
        "model": args.model,
        "state": state,
        "questions": build_questions(args),
    }


def format_answer(name: str, ans: dict) -> str:
    t = ans.get("type")
    if t == "noul":
        p = ans.get("noul", 0)
        return "%s: noul=%.3f (%s)" % (name, p, "yes" if p >= 0.5 else "no")
    if t == "choice":
        probs = ans.get("probabilities") or {}
        top = ans.get("choice", "?")
        return "%s: choice=%s conf=%.2f probs=%s" % (
            name,
            top,
            ans.get("confidence", 0) or 0,
            json.dumps(probs, separators=(",", ":")),
        )
    if t == "score":
        legend = ans.get("legend") or {}
        lvl = legend.get(str(int(round(ans.get("score", 0) or 0))), "")
        return "%s: score=%.2f (%s) conf=%.2f" % (
            name,
            ans.get("score", 0) or 0,
            lvl,
            ans.get("confidence", 0) or 0,
        )
    return "%s: %s" % (name, json.dumps(ans))


def post(body: dict, key: str, url: str, timeout: int) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + key,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        raise SystemExit("HTTP %s: %s" % (e.code, detail[:300]))


def self_test() -> int:
    fail = 0
    ns = argparse.Namespace(
        type="noul",
        question="escalate",
        instructions="Should a human review this?",
        true="over budget",
        false="within budget",
        criteria=None,
        state="in=2699178 (13.5x)",
        state_file=None,
        model=DEFAULT_MODEL,
    )
    body = build_body(ns)
    if body["model"] != DEFAULT_MODEL or body["questions"]["escalate"]["type"] != "noul":
        print("FAIL noul body shape")
        fail = 1
    if "true" not in body["questions"]["escalate"]["criteria"]:
        print("FAIL noul criteria")
        fail = 1
    out = format_answer("escalate", {"type": "noul", "noul": 0.92})
    if "0.92" not in out or "yes" not in out:
        print("FAIL noul answer format")
        fail = 1
    out = format_answer(
        "queue",
        {"type": "choice", "choice": "b", "confidence": 0.7, "probabilities": {"a": 0.3, "b": 0.7}},
    )
    if "choice=b" not in out or "0.70" not in out:
        print("FAIL choice answer format")
        fail = 1
    out = format_answer(
        "acuity",
        {"type": "score", "score": 1.86, "legend": {"2": "hour"}, "confidence": 0.79},
    )
    if "1.86" not in out or "hour" not in out:
        print("FAIL score answer format")
        fail = 1
    print("subq_snap: self-test PASS" if not fail else "subq_snap: self-test FAIL")
    return fail


def main() -> int:
    ap = argparse.ArgumentParser(description="SubQ Snap Decisions API client")
    ap.add_argument("--state", default="")
    ap.add_argument("--state-file", default="")
    ap.add_argument("--question", default="q")
    ap.add_argument("--type", choices=["noul", "choice", "score"], default="noul")
    ap.add_argument("--instructions", default="")
    ap.add_argument("--true", dest="true", default="")
    ap.add_argument("--false", dest="false", default="")
    ap.add_argument("--criteria", default="")
    ap.add_argument("--env-file", default=".env.local")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--url", default=DEFAULT_URL)
    ap.add_argument("--timeout", type=int, default=30)
    ap.add_argument("--json", action="store_true", help="print the raw response")
    ap.add_argument("--dry-run", action="store_true", help="print the request body only")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    body = build_body(args)
    if args.dry_run:
        print(json.dumps(body, indent=2))
        return 0

    key = load_key(args.env_file)
    if not key:
        print("FAIL: SUBQ_API_KEY not set (env or %s)" % args.env_file)
        return 2
    # Seams let the model/URL be overridden without editing this file.
    import os

    body["model"] = os.environ.get("SUBQ_MODEL", body["model"])
    url = os.environ.get("SUBQ_URL", args.url)
    data = post(body, key, url, args.timeout)
    if args.json:
        print(json.dumps(data, indent=2))
        return 0
    answers = data.get("answers") or {}
    for name in body["questions"]:
        if name in answers:
            print(format_answer(name, answers[name]))
    usage = data.get("usage") or {}
    print(
        "usage: in=%s out=%s"
        % (usage.get("input_tokens", "?"), usage.get("output_tokens", 0))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
