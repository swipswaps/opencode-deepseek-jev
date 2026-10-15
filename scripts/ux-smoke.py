#!/usr/bin/env python3
"""ux-smoke.py - live UX smoke assertions for the :5099 observability pages.

Driven from the sandbox through the HOST browser over CDP (RULES #62), because
no browser can launch locally (missing system libs). This is the runnable-now
bridge to tester-army/e2e: e2e is the durable natural-language framework
(Playwright; run it on the host), and this encodes the same payoff as plain
assertions so a session can gate the UX without a host browser.

Checks (per page and board interaction):
  - the page LOADS at all (a slow/stalled server is a failure, not a skip)
  - lang set, exactly one <h1>, <main> + skip-link (a11y floor)
  - no leftover visible "loading..." after the settle wait
  - /explore: the empty "Session detail" card is hidden on load
  - board tab: the Gantt SVG and the Kanban cards render

    CDP_HOST=<h> CDP_PORT=<p> python3 scripts/ux-smoke.py [--base URL] [--json] [--settle S]

Exit 0 all pass, 2 any fail. SKIP (no CDP) prints status=SKIP and exits 0
(SKIP is not PASS, RULES #37). No model spend.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
import time

from playwright.sync_api import sync_playwright

PAGES = ["/", "/explore", "/models", "/runbooks", "/manage", "/docs"]
OUT = pathlib.Path(__file__).resolve().parent.parent / "data" / "observability" / "ux-smoke.json"

AUDIT_JS = """()=>({
  lang: document.documentElement.lang || '',
  h1: document.querySelectorAll('h1').length,
  main: !!document.querySelector('main'),
  skip: !!document.querySelector('a[href="#main"], .skip-link'),
  loading: [...document.querySelectorAll('[data-loading]')].filter(e => e.offsetParent !== null).length
})"""


def check_page(pg, base, path, settle) -> list:
    pg.goto(base + path, wait_until="domcontentloaded", timeout=20000)
    pg.wait_for_timeout(settle * 1000)
    a = pg.evaluate(AUDIT_JS)
    return [
        ("%s load" % path, True, ""),
        ("%s lang" % path, bool(a["lang"]), str(a["lang"])),
        ("%s h1==1" % path, a["h1"] == 1, "h1=%d" % a["h1"]),
        ("%s main+skip" % path, bool(a["main"] and a["skip"]), "main=%s skip=%s" % (a["main"], a["skip"])),
        ("%s no leftover loading" % path, a["loading"] == 0, "loading=%d" % a["loading"]),
    ]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="https://192.168.4.24:5099")
    ap.add_argument("--settle", type=float, default=4.0)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    host = os.environ.get("CDP_HOST", "127.0.0.1")
    port = os.environ.get("CDP_PORT", "9222")

    try:
        pw = sync_playwright().start()
        b = pw.chromium.connect_over_cdp("http://%s:%s" % (host, port), timeout=15000)
    except Exception as e:
        print("status=SKIP no CDP browser at %s:%s (%s)" % (host, port, str(e)[:80]))
        return 0

    ctx = b.contexts[0]
    results = []

    for path in PAGES:
        pg = ctx.new_page()
        try:
            results += check_page(pg, a.base, path, a.settle)
        except Exception as e:
            results.append(("%s load" % path, False, str(e)[:100]))
        finally:
            pg.close()

    pg = ctx.new_page()
    try:
        pg.goto(a.base + "/explore", wait_until="domcontentloaded", timeout=20000)
        pg.wait_for_timeout(1500)
        hidden = pg.evaluate("document.getElementById('detail-card') && document.getElementById('detail-card').hidden")
        results.append(("/explore empty Session-detail hidden", hidden is True, "hidden=%s" % hidden))
        pg.click("[data-tab='board']")
        pg.wait_for_timeout(max(8000, a.settle * 2000))
        g = pg.evaluate(
            "()=>({svg:document.querySelectorAll('#boardgantt svg').length,"
            "cards:document.querySelectorAll('#kanban .kcard').length})"
        )
        results.append(("board Gantt renders", g["svg"] > 0, "svg=%d" % g["svg"]))
        results.append(("board Kanban renders", g["cards"] > 0, "cards=%d" % g["cards"]))
    except Exception as e:
        results.append(("board interaction", False, str(e)[:100]))
    finally:
        pg.close()

    b.close()
    pw.stop()

    passed = sum(1 for _, ok, _ in results if ok)
    failed = len(results) - passed
    report = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "base": a.base,
        "passed": passed,
        "failed": failed,
        "results": [{"check": n, "ok": ok, "detail": d} for n, ok, d in results],
    }
    try:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(json.dumps(report, indent=2) + "\n")
    except OSError:
        pass

    if a.json:
        print(json.dumps(report, indent=2))
    else:
        print("=== ux-smoke @ %s ===" % a.base)
        for n, ok, d in results:
            print("%-4s %-42s %s" % ("PASS" if ok else "FAIL", n, d))
        print("result: %d pass, %d fail" % (passed, failed))
    return 0 if failed == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
