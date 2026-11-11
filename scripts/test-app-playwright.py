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
import time
from pathlib import Path

ROUTES = [
    {"id": "overview", "heading": "Overview", "must": ["Project pulse", "Cost"]},
    {"id": "activity", "heading": "Activity timeline", "must": ["Activity timeline"]},
    {"id": "sessions", "heading": "Sessions", "must": ["Sessions"]},
    {"id": "todos", "heading": "Todos", "must": ["Todos"]},
    {"id": "usability", "heading": "Usability", "must": ["Automated evidence", "Run the guided test", "How the guided test works"]},
    {"id": "settings", "heading": "Settings", "must": ["Settings", "Keys", "Confirm provider id"]},
]

IGNORE_CONSOLE = ("ERR_ABORTED", "/api/stream", "net::ERR_ABORTED", "ERR_HTTP2_PROTOCOL_ERROR",
                  "ERR_CONNECTION_REFUSED", "ERR_CONNECTION_RESET", "ERR_NETWORK_CHANGED")


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="Playwright battery for /app pages")
    ap.add_argument("--base", default=os.environ.get("APP_BASE", "https://localhost:5099"))
    ap.add_argument("--user", default=os.environ.get("APP_USER", "opencode"))
    ap.add_argument("--password", default=os.environ.get("OPENCODE_SERVER_PASSWORD", ""))
    ap.add_argument("--timeout", type=int, default=20000, help="per-wait timeout in ms")
    ap.add_argument("--deadline", type=int, default=240, help="global budget in seconds")
    ap.add_argument("--retries", type=int, default=2, help="retries per route on a transient failure")
    ap.add_argument("--route", default="", help="only this route id (debug)")
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


def wait_visible_text(page, text: str, timeout: int) -> bool:
    """Wait for a VISIBLE match. On mobile the permanent drawer is display:none,
    so get_by_text(...).first can resolve to a hidden nav label; require a
    visible node so the check targets page content."""
    loc = page.get_by_text(text, exact=False)
    deadline = time.time() + max(1.0, timeout / 1000.0)
    while time.time() < deadline:
        for i in range(min(loc.count(), 12)):
            try:
                if loc.nth(i).is_visible():
                    return True
            except Exception:  # noqa: BLE001 - a detached/animating node is not a match
                continue
        page.wait_for_timeout(200)
    return False


def _check_once(context, base: str, route: dict, timeout: int, shots: Path, width: int, height: int) -> dict:
    page = context.new_page()
    page.set_viewport_size({"width": width, "height": height})
    page.set_default_timeout(timeout)
    page.set_default_navigation_timeout(timeout)
    errors: list[str] = []
    console_errors(page, errors)
    url = base.rstrip("/") + "/app/#" + route["id"]
    result = {"id": route["id"], "width": width, "ok": True, "errors": errors, "overflow_px": 0, "shot": ""}
    try:
        page.goto(url, wait_until="domcontentloaded", timeout=timeout)
        page.get_by_role("heading", name=route["heading"], exact=True).first.wait_for(timeout=timeout)
        for text in route["must"]:
            if not wait_visible_text(page, text, timeout):
                errors.append("missing visible text: " + text)
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
    try:
        page.close()
    except Exception as e:  # noqa: BLE001 - a closed/interrupted page is not a test failure
        errors.append("close: %s" % e)
    result["ok"] = not errors
    return result


def check_route(context, base: str, route: dict, timeout: int, shots: Path, width: int, height: int, retries: int) -> dict:
    result = None
    for attempt in range(retries + 1):
        result = _check_once(context, base, route, timeout, shots, width, height)
        result["attempt"] = attempt + 1
        if result["ok"]:
            return result
        if attempt < retries:
            time.sleep(0.8)
    return result


def preflight(browser, base: str, timeout: int, creds):
    """Fail fast when the dashboard itself is unreachable: one page load of
    /app/ must render the Overview heading. Avoids 12 x timeout when the
    server/caddy is down or flapping."""
    budget = min(timeout, 15000)
    context = browser.new_context(
        ignore_https_errors=True,
        http_credentials=creds,
        viewport={"width": 1280, "height": 900},
        reduced_motion="reduce",
    )
    page = context.new_page()
    page.set_default_timeout(budget)
    page.set_default_navigation_timeout(budget)
    try:
        page.goto(base.rstrip("/") + "/app/", wait_until="domcontentloaded", timeout=budget)
        page.get_by_role("heading", name="Overview", exact=True).first.wait_for(timeout=budget)
        return True, ""
    except Exception as e:  # noqa: BLE001
        return False, str(e)
    finally:
        try:
            page.close()
        except Exception:  # noqa: BLE001
            pass
        try:
            context.close()
        except Exception:  # noqa: BLE001
            pass


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
    start_mono = time.monotonic()
    routes = [r for r in ROUTES if not args.route or r["id"] == args.route]
    if not routes:
        print("FAIL: unknown --route %r (choose: %s)" % (args.route, ", ".join(r["id"] for r in ROUTES)), file=sys.stderr)
        return 2

    interrupted = False
    with sync_playwright() as p:
        browser = None
        try:
            browser = p.chromium.launch(headless=not args.headed)
        except Exception as e:  # noqa: BLE001
            print("FAIL: cannot launch Chromium (%s)" % e, file=sys.stderr)
            print("  install: python -m playwright install chromium", file=sys.stderr)
            return 2
        try:
            ok, err = preflight(browser, args.base, args.timeout, creds)
            if not ok:
                print("FAIL: dashboard unreachable at %s/app/: %s" % (args.base, err), file=sys.stderr)
                print("  check: curl -sk -o /dev/null -w '%%{http_code}\\n' %s/" % args.base, file=sys.stderr)
                print("  hint: caddy 502/timeouts mean the upstream dashboard is down or restarting", file=sys.stderr)
                return 2
            for width, height, label in ((1280, 900, "desktop"), (390, 844, "mobile")):
                context = browser.new_context(
                    ignore_https_errors=True,
                    http_credentials=creds,
                    viewport={"width": width, "height": height},
                    reduced_motion="reduce",
                )
                try:
                    for route in routes:
                        if time.monotonic() - start_mono > args.deadline:
                            results.append({
                                "id": route["id"], "mode": label, "width": width, "ok": False,
                                "errors": ["global deadline %ss exceeded" % args.deadline],
                                "overflow_px": 0, "shot": "",
                            })
                            if not args.json:
                                print("  FAIL %-9s %-8s deadline exceeded" % (route["id"], label), flush=True)
                            continue
                        if not args.json:
                            print("  ...  %-9s %-8s" % (route["id"], label), flush=True)
                        r = check_route(context, args.base, route, args.timeout, shots, width, height, args.retries)
                        r["mode"] = label
                        results.append(r)
                        if not args.json:
                            print("  %-4s %-9s %-8s overflow=%dpx %s" % (
                                "PASS" if r["ok"] else "FAIL", r["id"], label, r["overflow_px"], r["shot"]), flush=True)
                            for e in r["errors"]:
                                print("       - %s" % e, flush=True)
                finally:
                    try:
                        context.close()
                    except Exception:  # noqa: BLE001
                        pass
        except KeyboardInterrupt:
            interrupted = True
            print("\ninterrupted: closing browser", file=sys.stderr)
        finally:
            if browser is not None:
                try:
                    browser.close()
                except Exception:  # noqa: BLE001
                    pass
    if interrupted:
        print("interrupted: %d result(s) recorded before Ctrl-C" % len(results), file=sys.stderr)
        return 130

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
        if failures:
            print("failures:", flush=True)
            for r in failures:
                print("  FAIL %-9s %-8s overflow=%dpx" % (r["id"], r["mode"], r["overflow_px"]), flush=True)
                for e in r["errors"]:
                    print("       - %s" % e, flush=True)
        print("summary: %d pass, %d fail in %.1fs (shots: %s)" % (summary["pass"], summary["fail"], elapsed, shots), flush=True)
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
