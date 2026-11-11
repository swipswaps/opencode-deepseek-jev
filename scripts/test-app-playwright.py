#!/usr/bin/env python3
"""
test-app-playwright.py — real-browser test of every /app page and component.

The classic pages have a headless inline-script test (test-dashboard-ui.mjs).
The MUI app at /app/ renders client-side, so it needs a real browser. This
battery drives Playwright Chromium through every hash route and asserts:

  - the view heading and its key content render;
  - no page error and no console error (SSE aborts are ignored);
  - no page-level horizontal overflow at desktop (1280x900) and mobile
    (390x844) widths — tables scroll inside their containers;
  - the bottom navigation is present on mobile;
  - the Settings confirm box rejects an unconfirmed action (no mutation);
  - the Usability view links to the dedicated /usability runner.

Usage (host, with the repo browser venv):
    ./scripts/browser-python.sh scripts/test-app-playwright.py
    ./scripts/browser-python.sh scripts/test-app-playwright.py \
        --base https://localhost:5099 --password "$OPENCODE_SERVER_PASSWORD"
    ./scripts/browser-python.sh scripts/test-app-playwright.py --headed --json
    ./scripts/browser-python.sh scripts/test-app-playwright.py --shots logs/app-pw

Exit 0 all routes pass, 1 a failure, 2 usage or Playwright missing.
The password is read from --password or $OPENCODE_SERVER_PASSWORD; it is never
printed. Screenshots go to logs/ (gitignored) by default.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
from pathlib import Path

ROUTES = [
    {"id": "overview", "heading": "Overview", "must": ["Project pulse", "Cost"]},
    {"id": "activity", "heading": "Activity timeline", "must": ["Activity timeline"]},
    {"id": "sessions", "heading": "Sessions", "must": ["Sessions"]},
    {"id": "todos", "heading": "Todos", "must": ["Todos"]},
    {"id": "usability", "heading": "Usability", "must": ["Automated evidence", "Run the guided test", "How the guided test works"]},
    {"id": "settings", "heading": "Settings", "must": ["Settings", "Keys", "Confirm provider id"]},
]

IGNORE_CONSOLE = ("ERR_ABORTED", "/api/stream", "net::ERR_ABORTED")


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Playwright battery for /app pages")
    ap.add_argument("--base", default=os.environ.get("APP_BASE", "https://localhost:5099"))
    ap.add_argument("--user", default=os.environ.get("APP_USER", "opencode"))
    ap.add_argument("--password", default=os.environ.get("OPENCODE_SERVER_PASSWORD", ""))
    ap.add_argument("--timeout", type=int, default=20000, help="per-wait timeout in ms")
    ap.add_argument("--headed", action="store_true", help="show the browser")
    ap.add_argument("--json", action="store_true", help="machine-readable summary")
    ap.add_argument("--shots", default="", help="screenshot dir (default logs/app-playwright-<ts>)")
    return ap.parse_args()


def console_errors(page, bucket: list) -> None:
    def on_console(msg):
        if msg.type != "error":
            return
        text = msg.text or ""
        if any(skip in text for skip in IGNORE_CONSOLE):
            return
        bucket.append("console: " + text)

    def on_pageerror(err):
        bucket.append("pageerror: " + str(err))

    page.on("console", on_console)
    page.on("pageerror", on_pageerror)


def overflow_px(page) -> int:
    return int(page.evaluate("Math.max(0, document.documentElement.scrollWidth - window.innerWidth)"))


def check_route(context, base: str, route: dict, timeout: int, shots: Path, width: int, height: int) -> dict:
    page = context.new_page()
    page.set_viewport_size({"width": width, "height": height})
    errors: list[str] = []
    console_errors(page, errors)
    url = base.rstrip("/") + "/app/#" + route["id"]
    result = {"id": route["id"], "width": width, "ok": True, "errors": errors, "overflow_px": 0, "shot": ""}
    try:
        page.goto(url, wait_until="load", timeout=timeout)
        page.get_by_role("heading", name=route["heading"], exact=True).first.wait_for(timeout=timeout)
        for text in route["must"]:
            page.get_by_text(text, exact=False).first.wait_for(timeout=timeout)
        result["overflow_px"] = overflow_px(page)
        if result["overflow_px"] > 2:
            errors.append("page overflows horizontally by %dpx" % result["overflow_px"])
        if width < 700:
            nav = page.locator("nav.MuiBottomNavigation-root, .MuiBottomNavigation-root").first
            if nav.count() == 0:
                errors.append("mobile bottom navigation missing")
        if route["id"] == "settings":
            field = page.get_by_label("Confirm provider id")
            field.fill("not-a-provider")
            pause = page.get_by_role("button", name="pause")
            resume = page.get_by_role("button", name="resume")
            button = pause.first if pause.count() > 0 else (resume.first if resume.count() > 0 else None)
            if button is not None:
                button.click()
                status = page.get_by_role("status")
                if status.count() == 0 or "type" not in (status.first.text_content() or ""):
                    errors.append("settings confirm guard did not fire")
                field.fill("")
            else:
                errors.append("settings: no pause/resume button found")
        if route["id"] == "usability":
            link = page.get_by_role("link", name="Run the guided test").first
            href = link.get_attribute("href") or ""
            if "/usability" not in href:
                errors.append("usability link does not point at /usability (got %r)" % href)
        shot = shots / ("%s-%d.png" % (route["id"], width))
        page.screenshot(path=str(shot), full_page=True)
        result["shot"] = str(shot)
    except Exception as e:  # noqa: BLE001 - report the browser failure verbatim
        errors.append("exception: %s" % e)
    page.close()
    result["ok"] = not errors
    return result


def main() -> int:
    args = parse_args()
    try:
        from playwright.sync_api import sync_playwright
    except Exception as e:  # noqa: BLE001
        print("FAIL: Playwright is not installed for this Python (%s)" % e, file=sys.stderr)
        print("  host:  ./scripts/browser-python.sh scripts/test-app-playwright.py", file=sys.stderr)
        print("  setup: bash scripts/browser-tools-install.sh --with-browsers", file=sys.stderr)
        return 2

    shots = Path(args.shots or ("logs/app-playwright-" + now()))
    shots.mkdir(parents=True, exist_ok=True)
    creds = {"username": args.user, "password": args.password} if args.password else None
    results: list[dict] = []
    started = datetime.datetime.now(datetime.timezone.utc)

    with sync_playwright() as p:
        try:
            browser = p.chromium.launch(headless=not args.headed)
        except Exception as e:  # noqa: BLE001
            print("FAIL: cannot launch Chromium (%s)" % e, file=sys.stderr)
            print("  install: python -m playwright install chromium", file=sys.stderr)
            return 2
        for width, height, label in ((1280, 900, "desktop"), (390, 844, "mobile")):
            context = browser.new_context(
                ignore_https_errors=True,
                http_credentials=creds,
                viewport={"width": width, "height": height},
                reduced_motion="reduce",
            )
            for route in ROUTES:
                r = check_route(context, args.base, route, args.timeout, shots, width, height)
                r["mode"] = label
                results.append(r)
            context.close()
        browser.close()

    failures = [r for r in results if not r["ok"]]
    elapsed = (datetime.datetime.now(datetime.timezone.utc) - started).total_seconds()
    summary = {
        "base": args.base,
        "ts": started.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "elapsed_s": round(elapsed, 2),
        "pass": len(results) - len(failures),
        "fail": len(failures),
        "shots": str(shots),
        "results": results,
    }
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print("=== test-app-playwright ===")
        print("base: %s" % args.base)
        for r in results:
            mark = "PASS" if r["ok"] else "FAIL"
            print("  %-4s %-8s %-9s overflow=%dpx %s" % (mark, r["id"], r["mode"], r["overflow_px"], r["shot"]))
            for e in r["errors"]:
                print("       - %s" % e)
        print("summary: %d pass, %d fail in %.1fs (shots: %s)" % (summary["pass"], summary["fail"], elapsed, shots))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
