#!/usr/bin/env python3
"""
ux-audit.py — measure /explore usability with Playwright (host-side).

Reports objective signals: page height vs viewport, panel/tab counts, tab
toggle behaviour, async-panel resolution, and page errors, then writes a
full-page screenshot. Runs wherever Playwright's bundled chromium is
installed (in-container and host-side).

Usage (host, requires playwright):
    pip install playwright && playwright install chromium
    python3 scripts/ux-audit.py [url] [outdir]

Output (stdout): machine-readable `key=value` lines plus a `PASS/FAIL`
verdict. Screenshots land in outdir (default logs/ux/).
"""

import os
import sys
import time

from playwright.sync_api import sync_playwright

URL = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:5099/explore"
OUT = sys.argv[2] if len(sys.argv) > 2 else "logs/ux"
READY_TIMEOUT_MS = 60000

FAIL = 0


def check(cond, label, detail=""):
    global FAIL
    print(("PASS " if cond else "FAIL ") + label + ((" " + detail) if detail else ""))
    if not cond:
        FAIL += 1


def main():
    os.makedirs(OUT, exist_ok=True)
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={"width": 1200, "height": 900})
        errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)))
        pg.goto(URL, wait_until="domcontentloaded", timeout=20000)
        # Never networkidle (2 s polling + ~10 s cold single-threaded
        # /api/health = timeouts on healthy pages) and never
        # page.wait_for_function with a string expression: it compiles via
        # an eval-like call on every poll tick, tripping the dashboard's
        # own CSP (no unsafe-eval) as a pageerror — a harness artifact
        # (proven 2026-09-29). Poll with evaluate (CSP-clean) instead.
        deadline = time.monotonic() + READY_TIMEOUT_MS / 1000
        while time.monotonic() < deadline:
            left = pg.evaluate("document.querySelectorAll('[data-loading]').length")
            if left == 0:
                break
            pg.wait_for_timeout(2000)
        pg.wait_for_timeout(800)

        loading_left = pg.evaluate("document.querySelectorAll('[data-loading]').length")
        print("loading_left=%d" % loading_left)
        check(loading_left == 0, "async panels resolved", "left=%d" % loading_left)

        height = pg.evaluate("() => document.body.scrollHeight")
        vh = pg.evaluate("() => window.innerHeight")
        panels = pg.evaluate("() => document.querySelectorAll('.chart,.card').length")
        tabs = pg.evaluate("() => document.querySelectorAll('.tab').length")
        panes = pg.evaluate("() => document.querySelectorAll('.pane').length")

        print("url=%s" % URL)
        print("body_height=%d viewport=%d panels=%d tabs=%d panes=%d" % (height, vh, panels, tabs, panes))

        check(panes > 0, "tabbed layout present", "panes=%d" % panes)
        check(height <= vh * 1.5, "page fits ~1.5x viewport", "%.1fx" % (height / vh))

        if tabs:
            names = pg.evaluate("() => Array.from(document.querySelectorAll('.tab')).map(function(t){return t.textContent.trim()})")
            for n in names:
                pg.click("button.tab:has-text('%s')" % n)
                pg.wait_for_timeout(200)
                active = pg.evaluate(
                    "() => Array.from(document.querySelectorAll('.pane')).filter(function(x){return x.style.display !== 'none'}).length"
                )
                check(active >= 1, "tab switch", "%s -> %d visible" % (n, active))

        pg.screenshot(path=os.path.join(OUT, "explore.png"), full_page=True)
        print("pageerrors=%d" % len(errs))
        for e in errs[:3]:
            print("  error: %s" % e)
        check(len(errs) == 0, "no page errors")
        b.close()

    print("result=%s" % ("PASS" if FAIL == 0 else "FAIL"))
    sys.exit(0 if FAIL == 0 else 1)


if __name__ == "__main__":
    main()
