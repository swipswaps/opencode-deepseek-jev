#!/usr/bin/env python3
"""panels-tour.py - capture README screenshots + a short demo video of :5099.

Uses Playwright by LAUNCHING its own chromium (not connect_over_cdp: video
recording only works on a launched browser). Writes one PNG per panel and one
.webm tour. Run it where a browser can launch (the host; the sandbox lacks the
system libs). Needs `playwright install chromium` once.

    python3 scripts/panels-tour.py [--base URL] [--out docs/ux] [--no-video]
    python3 scripts/panels-tour.py --self-test        # offline, no browser

Panels (hash routing activates the tab server-side, no clicks needed):
    home      /                    Flags card + sessions + stats
    overview  /explore#overview    search + compact session table
    board     /explore#board       Kanban + Gantt + projected-schedule estimate
    trends    /explore#charts      cost/sessions per day
    signals   /explore#signals     session health + guard
    patterns  /explore#patterns    recurring tool n-grams + known fixes

Light theme is forced (?theme=light) so the shots read.
Every shot is shrunk with png-shrink.mjs (node) to stay under the 150 KiB
media budget.
"""

from __future__ import annotations

import argparse
import pathlib
import subprocess  # Popen only (repo lint bans subprocess.run)
import sys
import time

PANELS = [
    ("home", "/?theme=light"),
    ("overview", "/explore?theme=light#overview"),
    ("board", "/explore?theme=light#board"),
    ("trends", "/explore?theme=light#charts"),
    ("signals", "/explore?theme=light#signals"),
    ("patterns", "/explore?theme=light#patterns"),
]


def shrink(path: str, repo: pathlib.Path) -> None:
    script = repo / "scripts" / "png-shrink.mjs"
    if not script.exists():
        return
    try:
        p = subprocess.Popen(["node", str(script), path, "0.6", "153600"], cwd=str(repo))
        p.communicate(timeout=60)
    except Exception:
        pass


def self_test() -> int:
    need = {"home", "overview", "board", "trends", "signals", "patterns"}
    have = {k for k, _ in PANELS}
    ok = need <= have
    print("panels-tour: self-test PASS" if ok else "panels-tour: self-test FAIL")
    return 0 if ok else 1


def check(out: pathlib.Path) -> int:
    """Report which expected shots are missing; never fail the build on a host gap."""
    expected = ["status-%s.png" % name for name, _ in PANELS]
    missing = [e for e in expected if not (out / e).exists()]
    print("panels-tour: %d/%d expected shots present in %s" % (len(expected) - len(missing), len(expected), out))
    if missing:
        print("missing: " + ", ".join(missing))
    print("capture on the host (needs chromium): python3 scripts/panels-tour.py")
    return 0 if not missing else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="https://127.0.0.1:5099")   # host :5099 is HTTPS (caddy)
    ap.add_argument("--out", default="docs/ux")
    ap.add_argument("--no-video", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if a.check:
        return check(pathlib.Path(a.out))

    from playwright.sync_api import sync_playwright

    repo = pathlib.Path(__file__).resolve().parent.parent
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    tmp_vid = pathlib.Path("/tmp/panels-tour-video")
    tmp_vid.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        try:
            b = p.chromium.launch(headless=True)
        except Exception as e:
            print("FAIL: cannot launch chromium (%s). Run: playwright install chromium" % str(e)[:80])
            return 2
        ctx = b.new_context(viewport={"width": 1280, "height": 860},
                            ignore_https_errors=True,   # self-signed caddy cert
                            record_video_dir=None if a.no_video else str(tmp_vid),
                            record_video_size={"width": 1280, "height": 860} if not a.no_video else None)
        pg = ctx.new_page()
        for name, path in PANELS:
            try:
                pg.goto(a.base + path, wait_until="domcontentloaded", timeout=30000)
                pg.wait_for_timeout(6000)  # let SSE snapshot + charts render
                shot = str(out / ("status-%s.png" % name))
                pg.screenshot(path=shot)
                shrink(shot, repo)
                print("shot", shot)
            except Exception as e:
                print("WARN %s: %s" % (name, str(e)[:80]))
        ctx.close()  # finalizes the video
        b.close()

    if not a.no_video:
        vids = sorted(tmp_vid.glob("*.webm"))
        if vids:
            dst = out / "tour.webm"
            try:
                import shutil
                shutil.copy2(str(vids[0]), str(dst))   # cross-device safe (no rename)
                vids[0].unlink()
                print("video", dst, dst.stat().st_size // 1024, "KiB")
            except OSError as e:
                print("WARN video copy:", str(e)[:80])
    return 0


if __name__ == "__main__":
    sys.exit(main())
