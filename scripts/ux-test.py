#!/usr/bin/env python3
"""
ux-test.py — Playwright UX test for the observability UI.

A test, not an audit: it asserts the served pages are usable, which is how the
recurring "UX is still cumbersome" complaint gets verified instead of felt.
Per page it checks:

  - no console errors
  - no horizontal scroll at 390px wide
  - the page is not an unscrollable wall at 390px
  - on /explore: the overview tab is compact and every tab toggles a pane

Playwright needs a browser, so this runs on the HOST, not in the container
(the container has no browser). If playwright is absent it prints SKIP and
exits 0 — SKIP is not PASS (RULES #37), the line says so.

    pip install playwright && playwright install chromium
    python3 scripts/ux-test.py                       # http://127.0.0.1:5099
    python3 scripts/ux-test.py http://127.0.0.1:5099
    python3 scripts/ux-test.py --out logs/ux
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

PAGES = ["/", "/explore", "/runbooks", "/models", "/docs"]
DESKTOP = {"width": 1440, "height": 900}
PHONE = {"width": 390, "height": 844}


def resolve_repo(start: Path) -> Path | None:
    c = start.resolve()
    while c != c.parent:
        if (c / "opencode.json").is_file() and (c / "docker" / "Dockerfile").is_file():
            return c
        c = c.parent
    return None


class Result:
    def __init__(self) -> None:
        self.pass_n = 0
        self.fail_n = 0
        self.skip_n = 0

    def ok(self, msg: str) -> None:
        self.pass_n += 1
        print("  PASS  " + msg)

    def bad(self, msg: str) -> None:
        self.fail_n += 1
        print("  FAIL  " + msg)

    def skip(self, msg: str) -> None:
        self.skip_n += 1
        print("  SKIP  " + msg)


def run(base: str, outdir: Path) -> int:
    try:
        from playwright.sync_api import sync_playwright
    except Exception:
        print("SKIP: playwright not installed (pip install playwright && playwright install chromium)")
        print("result: SKIP (not a pass)")
        return 0

    r = Result()
    outdir.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for path in PAGES:
            url = base + path
            page = browser.new_page(viewport=DESKTOP)
            errors: list[str] = []
            page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
            page.on("pageerror", lambda e: errors.append(str(e)))
            try:
                page.goto(url, wait_until="networkidle", timeout=15000)
            except Exception as e:
                r.bad(f"{path} loads ({e})")
                page.close()
                continue
            name = path.strip("/").replace("/", "_") or "home"
            page.set_viewport_size(PHONE)
            page.wait_for_timeout(400)
            scroll_w = page.evaluate("document.documentElement.scrollWidth")
            inner_w = page.evaluate("window.innerWidth")
            height = page.evaluate("document.documentElement.scrollHeight")
            page.screenshot(path=str(outdir / f"ux-{name}-390.png"), full_page=True)
            page.set_viewport_size(DESKTOP)
            page.wait_for_timeout(200)
            page.screenshot(path=str(outdir / f"ux-{name}-1440.png"), full_page=True)

            r.ok(f"{path} console clean") if not errors else r.bad(f"{path} console errors: {errors[:2]}")
            r.ok(f"{path} no horizontal scroll at 390px") if scroll_w <= inner_w + 2 else r.bad(
                f"{path} horizontal scroll at 390px ({scroll_w} > {inner_w})")
            r.ok(f"{path} phone height {height}px") if height <= 6000 else r.bad(
                f"{path} is a wall at 390px ({height}px tall)")

            if path == "/explore":
                # every tab toggles a pane; overview stays compact
                tabs = page.query_selector_all(".tab")
                toggle_ok = True
                for t in tabs:
                    data_tab = t.get_attribute("data-tab")
                    t.click()
                    page.wait_for_timeout(120)
                    visible = page.eval_on_selector(
                        f'.pane[data-pane="{data_tab}"]',
                        "el => getComputedStyle(el).display !== 'none'")
                    if not visible:
                        toggle_ok = False
                r.ok("explore: every tab toggles its pane") if toggle_ok else r.bad(
                    "explore: a tab did not toggle its pane")
                ov_h2 = page.eval_on_selector_all(
                    '.pane[data-pane="overview"] h2', "els => els.length")
                r.ok(f"explore: overview compact ({ov_h2} sections)") if ov_h2 <= 3 else r.bad(
                    f"explore: overview is a wall ({ov_h2} sections)")
            page.close()
        browser.close()

    print(f"\n  screenshots: {outdir}")
    print(f"  result: {r.pass_n} pass, {r.fail_n} fail, {r.skip_n} skip")
    return 1 if r.fail_n else 0


def check(base: str) -> int:
    """Report prerequisites so 'user can test now' has a yes/no answer."""
    print("=== ux-test.py --check ===")
    rc = 0
    try:
        from playwright.sync_api import sync_playwright
        print("  PASS  playwright importable")
    except Exception:
        print("  SKIP  playwright not installed -> pip install playwright")
        return 1
    try:
        with sync_playwright() as p:
            b = p.chromium.launch()
            b.close()
        print("  PASS  chromium launches")
    except Exception as e:
        print(f"  SKIP  chromium unavailable -> playwright install chromium ({e})")
        return 1
    import urllib.request
    try:
        urllib.request.urlopen(base + "/", timeout=5)
        print(f"  PASS  server reachable at {base}")
    except Exception as e:
        rc = 1
        print(f"  FAIL  server not reachable at {base} ({e}) — start it (./scripts/web.sh or dashboard.sh)")
    if rc == 0:
        print("  ready: python3 scripts/ux-test.py " + base)
    return rc


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("base", nargs="?", default="http://127.0.0.1:5099")
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--check", action="store_true", help="report prerequisites and exit")
    args = ap.parse_args(argv if argv is not None else sys.argv[1:])
    base = args.base.rstrip("/")
    if args.check:
        return check(base)
    repo = resolve_repo(Path(__file__).parent) or resolve_repo(Path.cwd())
    out = args.out or ((repo / "logs" / "ux") if repo else Path("logs/ux"))
    return run(base, out)


if __name__ == "__main__":
    sys.exit(main())
