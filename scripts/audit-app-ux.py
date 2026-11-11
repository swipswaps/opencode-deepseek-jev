#!/usr/bin/env python3
"""
audit-app-ux.py — Playwright UX/accessibility audit for the MUI /app.

The classic pages have a11y-audit.mjs (11 axes, no browser). The React app is
client-rendered, so it needs a browser to inspect the DOM. This audit checks
each /app view at desktop and mobile widths:

  - one h1 + a sane heading tree (the app currently tops out at h4/h5);
  - accessible names for every button/link/input;
  - first-Tab focus visibility (skip link);
  - tap-target size (<24 px fails WCAG AA; <44 px is the AAA warning);
  - bottom-navigation label truncation on mobile;
  - an aria-current/selected state on the active nav item;
  - skip link + main landmark;
  - console/page errors.

Usage (host browser venv):
    ./scripts/browser-python.sh scripts/audit-app-ux.py
    ./scripts/browser-python.sh scripts/audit-app-ux.py --json
    ./scripts/browser-python.sh scripts/audit-app-ux.py --views settings,usability

Exit 0 = no findings, 1 = findings, 2 = cannot run.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

VIEWS = ["overview", "activity", "sessions", "todos", "usability", "settings"]

JS = r"""() => {
  const vis = el => {
    if (!(el.offsetWidth || el.offsetHeight || el.getClientRects().length)) return false;
    if (el.getAttribute('aria-hidden') === 'true') return false;
    const s = getComputedStyle(el);
    return s.opacity !== '0' && s.pointerEvents !== 'none';
  };
  const nm = el => (el.getAttribute('aria-label') || el.getAttribute('title') ||
    (el.innerText || '').trim() ||
    (el.labels && el.labels[0] && el.labels[0].innerText) || '').trim();
  const heads = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].filter(vis)
    .map(e => ({ tag: e.tagName, text: (e.innerText || '').trim().slice(0, 60) }));
  const ctrls = [...document.querySelectorAll('button,a,input,select,textarea')].filter(vis);
  const unnamed = ctrls.filter(el => !nm(el))
    .map(el => el.tagName + ' ' + String(el.className).slice(0, 70));
  const targets = ctrls.map(el => {
    const r = el.getBoundingClientRect();
    return { tag: el.tagName, name: nm(el).slice(0, 40), w: Math.round(r.width), h: Math.round(r.height) };
  });
  const small = targets.filter(t => t.w < 44 || t.h < 44);
  const tiny = targets.filter(t => t.w < 24 || t.h < 24);
  const labels = [...document.querySelectorAll('.MuiBottomNavigationAction-label')]
    .map(el => ({ text: (el.innerText || '').trim(), truncated: el.scrollWidth > el.clientWidth + 1 }));
  const selected = [...document.querySelectorAll('[aria-current], [aria-selected="true"], .Mui-selected')]
    .map(el => ({ tag: el.tagName, current: el.getAttribute('aria-current'),
                  selected: el.getAttribute('aria-selected'),
                  text: (el.innerText || '').trim().slice(0, 30) }));
  return { title: document.title, h1: heads.filter(h => h.tag === 'H1').length, heads,
           unnamed, small, tiny, labels, selected,
           skip: !!document.querySelector('a[href="#main"]'),
           main: !!document.querySelector('main#main') };
}"""


def focus_probe(page):
    page.keyboard.press("Tab")
    return page.evaluate("""() => {
      const el = document.activeElement; const s = getComputedStyle(el);
      return { tag: el.tagName, text: (el.innerText || el.getAttribute('aria-label') || '').trim().slice(0, 40),
               outline: s.outlineStyle + ' ' + s.outlineWidth, shadow: s.boxShadow,
               visible: !!(el.offsetWidth || el.offsetHeight) };
    }""")


def audit(context, base, view, width):
    page = context.new_page()
    errs = []
    page.on("pageerror", lambda e: errs.append("pageerror: " + str(e)))
    page.on("console", lambda m: errs.append("console: " + m.text) if m.type == "error" else None)
    try:
        page.goto(base.rstrip("/") + "/app/#" + view, wait_until="domcontentloaded", timeout=20000)
        page.locator("h1,h2,h3,h4,h5,h6").first.wait_for(timeout=20000)
        page.wait_for_timeout(400)
        d = page.evaluate(JS)
        d["firstTab"] = focus_probe(page)
        d["errors"] = errs
        d["width"] = width
        return d
    except Exception as e:  # noqa: BLE001
        return {"width": width, "errors": errs + ["exception: " + str(e)]}
    finally:
        try:
            page.close()
        except Exception:  # noqa: BLE001
            pass


def findings(view, mode, d):
    out = []
    if d.get("errors"):
        out.append(("high", view, mode, "console/page errors", "; ".join(d["errors"])[:300]))
    if d.get("h1") != 1:
        top = (d.get("heads") or [{}])[0].get("tag")
        out.append(("high", view, mode, "heading", "h1 count=%s; top heading=%s" % (d.get("h1"), top)))
    if d.get("unnamed"):
        out.append(("high", view, mode, "unnamed controls", str(d["unnamed"][:4])))
    ft = d.get("firstTab") or {}
    if ft and not ft.get("visible"):
        out.append(("high", view, mode, "skip link focus", "first Tab target not visible: %s" % ft))
    if ft and str(ft.get("outline", "")).startswith("none") and ft.get("shadow") in ("none", ""):
        out.append(("high", view, mode, "focus visible", "no outline/box-shadow on first Tab: %s" % ft))
    if mode == "mobile":
        if d.get("tiny"):
            out.append(("high", view, mode, "tap target <24px", str(d["tiny"][:5])))
        elif d.get("small"):
            out.append(("low", view, mode, "tap target <44px (AAA)", "%d controls, e.g. %s" % (len(d["small"]), d["small"][:3])))
        trunc = [x for x in d.get("labels", []) if x.get("truncated")]
        if trunc:
            out.append(("medium", view, mode, "bottom nav labels truncated", str(trunc)))
    sel = d.get("selected") or []
    if not any(s.get("current") for s in sel):
        out.append(("low", view, mode, "active nav not aria-current", "selected=%s" % str(sel[:3])))
    if not d.get("skip"):
        out.append(("medium", view, mode, "skip link missing", ""))
    if not d.get("main"):
        out.append(("high", view, mode, "main landmark missing", ""))
    return out


def main():
    ap = argparse.ArgumentParser(description="Playwright UX/a11y audit for /app")
    ap.add_argument("--base", default=os.environ.get("APP_BASE", "https://localhost:5099"))
    ap.add_argument("--user", default=os.environ.get("APP_USER", "opencode"))
    ap.add_argument("--password", default=os.environ.get("OPENCODE_SERVER_PASSWORD", ""))
    ap.add_argument("--views", default="", help="comma-separated view ids")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    try:
        from playwright.sync_api import sync_playwright
    except Exception as e:  # noqa: BLE001
        print("FAIL: Playwright is not installed (%s)" % e, file=sys.stderr)
        print("  run: ./scripts/browser-python.sh scripts/audit-app-ux.py", file=sys.stderr)
        return 2
    views = [v.strip() for v in a.views.split(",") if v.strip()] or VIEWS
    creds = {"username": a.user, "password": a.password} if a.password else None
    results = {}
    allf = []
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        try:
            for width, height, mode in ((1280, 900, "desktop"), (390, 844, "mobile")):
                context = browser.new_context(
                    ignore_https_errors=True, http_credentials=creds,
                    viewport={"width": width, "height": height}, reduced_motion="reduce",
                )
                try:
                    for view in views:
                        d = audit(context, a.base, view, width)
                        results.setdefault(view, {})[mode] = d
                        allf += findings(view, mode, d)
                finally:
                    try:
                        context.close()
                    except Exception:  # noqa: BLE001
                        pass
        finally:
            try:
                browser.close()
            except Exception:  # noqa: BLE001
                pass
    if a.json:
        print(json.dumps({"base": a.base, "views": results,
                          "findings": [{"sev": s, "view": v, "mode": m, "check": c, "detail": dd}
                                       for s, v, m, c, dd in allf]}, indent=2))
    else:
        for s, v, m, c, dd in allf:
            print("[%s] %s/%s: %s %s" % (s.upper(), v, m, c, dd))
        print("findings: %d" % len(allf))
    return 0 if not allf else 1


if __name__ == "__main__":
    sys.exit(main())
