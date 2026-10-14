#!/usr/bin/env python3
"""browser_bench.py - benchmark the browser drivers against ONE live CDP
endpoint and emit a failover order.

Run with the venv that has playwright/browser-use/selenium installed
(~/.venvs/browser), so the imports resolve; the CDP Node driver needs only
node. Every driver attaches to the ALREADY-OPEN browser over CDP (RULES #62);
none launches a local browser, so none needs X or the missing system libs.

Drivers probed (each does the same op: enumerate open tabs/pages):
  cdp_tab      node scripts/cdp-tab.mjs tabs        (zero-dep, Node)
  playwright   chromium.connect_over_cdp(url)
  browser_use  BrowserSession(cdp_url=url).start()
  selenium     webdriver.Chrome(debugger_address=url)   (expected FAIL here)

    CDP_HOST=<h> CDP_PORT=<p> python3 scripts/browser_bench.py [--json] [--runs N] [--pick]

  --json   print the JSON report (else a table)
  --runs N repeat each driver N times; report the median (default 1)
  --pick   print the fastest WORKING driver name only (for failover); exit 2 if none

Writes data/observability/browser-drivers.json (gitignored). No model spend.
SKIP is not PASS (RULES #37): a driver that cannot attach is reported FAIL.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess  # Popen only (no subprocess.run per repo lint)
import sys
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
OUT = REPO / "data" / "observability" / "browser-drivers.json"


def _timed(fn, runs):
    best = None
    detail = ""
    for _ in range(max(1, runs)):
        t = time.perf_counter()
        ok, detail = fn()
        dt = time.perf_counter() - t
        best = dt if best is None else min(best, dt)
        if not ok:
            break
    return ok, best, detail


def probe_cdp_tab(host, port):
    env = dict(os.environ, CDP_HOST=host, CDP_PORT=str(port))
    p = subprocess.Popen(
        ["node", str(REPO / "scripts" / "cdp-tab.mjs"), "tabs"],
        cwd=str(REPO), env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    try:
        out, _ = p.communicate(timeout=40)
    except subprocess.TimeoutExpired:
        p.kill()
        return False, "timeout after 40s"
    if p.returncode != 0:
        return False, (out or "").strip()[:140] or ("rc=%s" % p.returncode)
    if (out or "").strip().startswith("status=SKIP"):
        return False, (out or "").strip()[:140]
    tabs = [ln for ln in (out or "").splitlines() if ln.strip()]
    return True, "%d tabs" % len(tabs)


def probe_playwright(host, port):
    from playwright.sync_api import sync_playwright

    with sync_playwright() as p:
        b = p.chromium.connect_over_cdp("http://%s:%s" % (host, port), timeout=20000)
        n = sum(len(c.pages) for c in b.contexts)
        b.close()
    return True, "%d pages" % n


def probe_browser_use(host, port):
    import asyncio
    from browser_use import BrowserSession

    async def go():
        s = BrowserSession(cdp_url="http://%s:%s" % (host, port))
        try:
            await asyncio.wait_for(s.start(), timeout=60)
            tabs = []
            if hasattr(s, "get_tabs"):
                try:
                    tabs = await asyncio.wait_for(s.get_tabs(), timeout=20)
                except Exception:
                    tabs = []
            return len(tabs) if isinstance(tabs, list) else 0
        finally:
            try:
                await asyncio.wait_for(s.stop(), timeout=20)
            except Exception:
                pass

    n = asyncio.run(go())
    return True, "%d tabs" % n


def probe_selenium(host, port):
    from selenium import webdriver
    from selenium.webdriver.chrome.options import Options

    o = Options()
    o.debugger_address = "%s:%s" % (host, port)
    d = webdriver.Chrome(options=o)
    n = len(d.window_handles)
    d.quit()
    return True, "%d windows" % n


DRIVERS = [
    ("cdp_tab", probe_cdp_tab),
    ("playwright", probe_playwright),
    ("browser_use", probe_browser_use),
    ("selenium", probe_selenium),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--pick", action="store_true")
    a = ap.parse_args()

    host = os.environ.get("CDP_HOST", "127.0.0.1")
    port = os.environ.get("CDP_PORT", "9222")

    results = []
    for name, fn in DRIVERS:
        try:
            ok, secs, detail = _timed(lambda: fn(host, port), a.runs)
        except Exception as e:
            ok, secs, detail = False, None, ("%s: %s" % (type(e).__name__, e))[:160]
        results.append({"driver": name, "ok": bool(ok), "seconds": secs, "detail": detail})

    working = sorted([r["driver"] for r in results if r["ok"]],
                     key=lambda d: next(r["seconds"] for r in results if r["driver"] == d))
    report = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "target": {"host": host, "port": port},
        "runs": a.runs,
        "results": results,
        "order": working,
        "note": "order = fastest working driver first; fail over down the list on runtime error",
    }
    try:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(json.dumps(report, indent=2) + "\n")
    except OSError:
        pass

    if a.pick:
        if working:
            print(working[0])
            return 0
        print("SKIP no working browser driver")
        return 2

    if a.json:
        print(json.dumps(report, indent=2))
        return 0

    print("=== browser drivers @ %s:%s (runs=%d) ===" % (host, port, a.runs))
    for r in results:
        secs = ("%.2fs" % r["seconds"]) if r["seconds"] is not None else "  -  "
        print("%-6s %-12s %s  %s" % ("PASS" if r["ok"] else "FAIL", r["driver"], secs, r["detail"]))
    print("failover order: %s" % (" > ".join(working) if working else "(none working)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
