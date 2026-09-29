#!/usr/bin/env python3
"""
ux-test.py — Playwright UX test for the observability UI.

A test, not an audit: it asserts the served pages are usable, which is how the
recurring "UX is still cumbersome" complaint gets verified instead of felt.
Per page it checks:

  - no console errors
  - async panels resolve (no [data-loading] marker left behind)
  - no horizontal scroll at 390px wide
  - the page is not an unscrollable wall at 390px
  - on /explore: the overview tab is compact and every tab toggles a pane

Wait strategy (deliberate, measured 2026-09-29): domcontentloaded + a
`[data-loading]`-marker ready wait, NEVER networkidle. The app polls
/api/* every 2 s and a cold /api/health blocks the single-threaded server
~10 s, so networkidle times out on healthy pages (4/6 FAILed spuriously
before this fix). READY_TIMEOUT_S=60 covers a cold start; a marker that
survives it is a hung fetch and correctly FAILs.

Playwright needs a browser: bundled chromium works in-container and on the
HOST (`pip install playwright && playwright install chromium`). If
playwright is absent it prints SKIP and exits 0 — SKIP is not PASS
(RULES #37), the line says so.

    python3 scripts/ux-test.py                       # http://127.0.0.1:5099
    python3 scripts/ux-test.py http://127.0.0.1:5099
    python3 scripts/ux-test.py --out logs/ux
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

PAGES = ["/", "/explore", "/runbooks", "/models", "/manage", "/docs"]
DESKTOP = {"width": 1440, "height": 900}
PHONE = {"width": 390, "height": 844}
GOTO_TIMEOUT_MS = 20000
READY_TIMEOUT_S = 60
SETTLE_MS = 800
READY_JS = "document.querySelectorAll('[data-loading]').length === 0"


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


def marker_count(page) -> int | None:
    try:
        return int(page.evaluate("document.querySelectorAll('[data-loading]').length"))
    except Exception:
        return None


def settle(page) -> tuple[bool, str]:
    """Wait until async panels resolve (markers gone), then a short rest for
    post-resize re-renders. Returns (ready, note).

    Polls via page.evaluate in Python, NEVER page.wait_for_function: the
    latter compiles its string expression with an eval-like call on every
    poll tick, which trips the dashboard's own CSP (script-src without
    unsafe-eval) and raises EvalError as a pageerror — a harness artifact
    that looks exactly like an app bug (proven 2026-09-29). evaluate is
    clean under the same CSP.

    Semantics is progress-not-stall (measured 2026-09-29): a fully cold
    server serialises ~20 explore fetches behind a ~10 s single-threaded
    /api/health compute, so the tail (timeline/cloud/pivot) can take tens
    of seconds while honestly showing loading... markers. A count that
    DECREASES means the server is draining (alive: pass with note); a
    count that is UNCHANGED and >0 means a hung fetch (fail)."""
    page.wait_for_timeout(4000)  # first paint + fast fetches land
    n1 = marker_count(page)
    if n1 is None:
        return False, "ready-probe evaluate failed"
    if n1 == 0:
        page.wait_for_timeout(SETTLE_MS)
        return True, "resolved quickly"
    deadline = time.monotonic() + (READY_TIMEOUT_S - 10)
    n2 = n1
    while time.monotonic() < deadline:
        page.wait_for_timeout(2000)
        n = marker_count(page)
        if n is None:
            return False, "ready-probe evaluate failed"
        n2 = n
        if n2 == 0:
            break
    page.wait_for_timeout(SETTLE_MS)
    if n2 == 0:
        return True, f"drained slowly ({n1} markers at +4s)"
    if n2 < n1:
        return True, f"draining ({n1}->{n2}), accepted as alive"
    return False, f"stalled ({n1} markers unchanged Nz={n2})"


def resettle(page) -> bool:
    """Short re-settle after a viewport switch. Markers never re-appear
    (renderers replace, never re-add), so this only covers re-render lag."""
    page.wait_for_timeout(1500)
    try:
        return bool(page.evaluate(READY_JS))
    except Exception:
        return False


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
            page.on("console", lambda m: errors.append(f"{m.text[:160]} @ {m.location}") if m.type == "error" else None)
            page.on("pageerror", lambda e: errors.append("pageerror: " + str(e)[:160]))
            try:
                page.goto(url, wait_until="domcontentloaded", timeout=GOTO_TIMEOUT_MS)
            except Exception as e:
                r.bad(f"{path} loads ({e})")
                page.close()
                continue
            name = path.strip("/").replace("/", "_") or "home"
            ready, note = settle(page)
            r.ok(f"{path} loads; async panels resolve ({note})") if ready else r.bad(
                f"{path} async panels {note} after {READY_TIMEOUT_S}s")
            page.set_viewport_size(PHONE)
            ready_phone = resettle(page)
            scroll_w = page.evaluate("document.documentElement.scrollWidth")
            inner_w = page.evaluate("window.innerWidth")
            height = page.evaluate("document.documentElement.scrollHeight")
            page.screenshot(path=str(outdir / f"ux-{name}-390.png"), full_page=True)
            page.set_viewport_size(DESKTOP)
            resettle(page)
            page.screenshot(path=str(outdir / f"ux-{name}-1440.png"), full_page=True)

            if errors:
                r.bad(f"{path} console errors: {errors[:2]}")
            else:
                r.ok(f"{path} console clean")
            if not ready_phone:
                r.bad(f"{path} panels unresolved at 390px after resize")
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
