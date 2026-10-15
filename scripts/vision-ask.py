#!/usr/bin/env python3
"""vision-ask.py - ask a multimodal model what is on screen (semantic UX check).

The dark-dashboard OCR is garbled, so word/visual assertions ("is the Gantt
visible?", "is the empty Session-detail card gone?") need a vision model. Use
the ALLOW-LISTED, cheapest vision model we have: gemini-2.5-flash
(models.policy.json), via its OpenAI-compatible endpoint. Key from
GEMINI_API_KEY (env or --env-file, default .env.local).

    python3 scripts/vision-ask.py --image shot.png --question "Is a Gantt chart visible? yes/no"
    python3 scripts/vision-ask.py --image shot.png --question "..." --json
    python3 scripts/vision-ask.py --self-test      # offline, no network

One HTTP POST to Gemini. No other network. Read-only to the repo.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
MODEL = os.environ.get("VISION_MODEL", "gemini-2.5-flash")


def load_key(env_file: str) -> str:
    key = os.environ.get("GEMINI_API_KEY", "").strip()
    if key:
        return key
    p = pathlib.Path(env_file)
    if p.exists():
        for line in p.read_text().splitlines():
            if line.startswith("GEMINI_API_KEY="):
                return line.split("=", 1)[1].strip()
    return ""


def build_body(img_bytes: bytes, question: str) -> dict:
    b64 = base64.b64encode(img_bytes).decode("ascii")
    return {
        "model": MODEL,
        "max_tokens": 150,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": question},
                    {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}},
                ],
            }
        ],
    }


def ask(img_bytes: bytes, question: str, key: str, timeout: int) -> str:
    req = urllib.request.Request(
        ENDPOINT,
        data=json.dumps(build_body(img_bytes, question)).encode("utf-8"),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise SystemExit("HTTP %s: %s" % (e.code, e.read().decode("utf-8", "replace")[:300]))
    try:
        return d["choices"][0]["message"]["content"].strip()
    except Exception:
        return json.dumps(d)[:300]


def self_test() -> int:
    fail = 0
    body = build_body(b"PNGX", "is it there?")
    if body["model"] != MODEL or "image_url" not in body["messages"][0]["content"][1]:
        print("FAIL body shape")
        fail = 1
    if "base64,UE5HWA==" not in body["messages"][0]["content"][1]["image_url"]["url"]:
        print("FAIL base64 encode")
        fail = 1
    print("vision-ask: self-test PASS" if not fail else "vision-ask: self-test FAIL")
    return fail


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default="")
    ap.add_argument("--question", default="")
    ap.add_argument("--env-file", default=".env.local")
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if not a.image or not a.question:
        print("usage: vision-ask.py --image FILE --question TEXT [--json] [--self-test]")
        return 2
    key = load_key(a.env_file)
    if not key:
        print("FAIL: GEMINI_API_KEY not set (env or %s)" % a.env_file)
        return 2
    try:
        img = pathlib.Path(a.image).read_bytes()
    except OSError as e:
        print("FAIL: cannot read image: %s" % e)
        return 2
    ans = ask(img, a.question, key, a.timeout)
    print(json.dumps({"model": MODEL, "question": a.question, "answer": ans}) if a.json else ans)
    return 0


if __name__ == "__main__":
    sys.exit(main())
