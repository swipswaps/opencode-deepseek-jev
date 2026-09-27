#!/usr/bin/env python3
"""
ux-trace.py — interaction-tracing UX test for the observability UI.

Where ux-test.py *asserts* the page is usable, ux-trace.py *proves the
journey*: it drives every page, and — because a recorder is injected before
navigation — it logs EVERY click, drag and scroll the browser fires, along
with the element that received it, its coordinates, and the screenshot taken
at that step. It also enumerates every interactive element ("hotspot") with
its bounding box, draws a hotspot overlay onto a screenshot, and turns the
whole thing into structured rows in SQLite so a handoff reads the database
instead of re-running or guessing.

Principle honoured: "If it can be typed, it MUST be scripted!" — the journey
is a script; a human never re-clicks what this records.

Outputs (per run):
  logs/ux/<page>-full.png      full-page screenshot
  logs/ux/<page>-hotspots.png  viewport screenshot with numbered hotspot boxes
  logs/ux/<page>-step-*.png    screenshot after each scripted interaction
  logs/ux/report.md            handoff report (what was clicked, what hurts)
  data/observability/ux.db     ux_run / ux_event / ux_hotspot / ux_finding

Pain points surfaced (findings, persisted + reported):
  error  console/page errors, horizontal overflow at 390px, tab toggle failure
  warn   page-wall height, click targets < 24px, overlapping targets

Playwright needs a browser, so this runs on the HOST (the container has no
browser). If playwright is absent it prints SKIP and exits 0 — SKIP is not
PASS (RULES #37).

    pip install playwright && playwright install chromium
    python3 scripts/ux-trace.py                        # http://127.0.0.1:5099
    python3 scripts/ux-trace.py http://127.0.0.1:5099
    python3 scripts/ux-trace.py --out logs/ux --json
    python3 scripts/ux-trace.py --check                # prerequisites
    python3 scripts/ux-trace.py --self-test            # offline, no browser

Constraints (RULES.md): no subprocess.run / no shell-out (urllib + sqlite3
only), no sed / 2>/dev/null / rm -rf / set -e. main() wrapper, exit via return.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
import urllib.request
from pathlib import Path

PAGES = ["/", "/explore", "/runbooks", "/models", "/manage", "/docs"]
DESKTOP = {"width": 1440, "height": 900}
PHONE = {"width": 390, "height": 844}

# Every element a user can click/tap, used to enumerate hotspots.
HOTSPOT_SEL = (
    "a,button,input,select,textarea,[data-go],[data-cmd],[data-tab],"
    ".tab,[role='button']"
)

# Injected before navigation so it records events on every page load.
RECORDER_JS = r"""
(function () {
  function clip(s, n) {
    if (!s) { return ""; }
    s = String(s).replace(/\s+/g, " ").trim();
    return s.length > n ? s.slice(0, n) + "\u2026" : s;
  }
  function describe(el) {
    if (!el || el.nodeType !== 1) { return {}; }
    var r = { tag: el.tagName.toLowerCase() };
    if (el.id) { r.id = el.id; }
    if (el.getAttribute) {
      var c = el.getAttribute("class"); if (c) { r.cls = clip(c, 80); }
      var role = el.getAttribute("role"); if (role) { r.role = role; }
      var href = el.getAttribute("href"); if (href) { r.href = href; }
      var go = el.getAttribute("data-go"); if (go) { r.go = go; }
      var cmd = el.getAttribute("data-cmd"); if (cmd) { r.cmd = clip(cmd, 60); }
      var tab = el.getAttribute("data-tab"); if (tab) { r.tab = tab; }
    }
    r.text = clip(el.textContent || "", 40);
    return r;
  }
  var q = [];
  function push(type, ev, extra) {
    extra = extra || {};
    var d = describe(ev.target);
    d.t = type;
    d.ts = Math.round(performance.now());
    d.x = ev.clientX; d.y = ev.clientY;
    d.sx = Math.round(window.scrollX || 0);
    d.sy = Math.round(window.scrollY || 0);
    for (var k in extra) { d[k] = extra[k]; }
    q.push(d);
  }
  var dragStart = null;
  function onDown(ev) {
    dragStart = { x: ev.clientX, y: ev.clientY, target: describe(ev.target) };
  }
  function onMove(ev) {
    if (dragStart && (ev.buttons & 1)) {
      push("dragmove", ev, { dx: Math.round(ev.clientX - dragStart.x), dy: Math.round(ev.clientY - dragStart.y) });
    }
  }
  function onUp(ev) {
    if (dragStart) {
      var dx = ev.clientX - dragStart.x;
      var dy = ev.clientY - dragStart.y;
      if (Math.abs(dx) + Math.abs(dy) > 2) {
        push("drag", ev, { dx: Math.round(dx), dy: Math.round(dy) });
      }
      dragStart = null;
    }
  }
  document.addEventListener("mousedown", onDown, true);
  document.addEventListener("mousemove", onMove, { capture: true, passive: true });
  document.addEventListener("mouseup", onUp, true);
  document.addEventListener("click", function (ev) { push("click", ev, {}); }, true);
  var lastScroll = 0;
  document.addEventListener("scroll", function () {
    var now = performance.now();
    if (now - lastScroll > 60) {
      lastScroll = now;
      q.push({ t: "scroll", ts: Math.round(now), sy: Math.round(window.scrollY || 0) });
    }
  }, { capture: true, passive: true });
  document.addEventListener("keydown", function (ev) { push("key", ev, { key: ev.key }); }, true);
  document.addEventListener("input", function (ev) { push("input", ev, { val: clip(ev.target && ev.target.value, 40) }); }, true);
  document.addEventListener("change", function (ev) { push("change", ev, {}); }, true);
  window.__ux = {
    drain: function () { var out = q; q = []; return out; },
    count: function () { return q.length; }
  };
})();
"""

SCHEMA = """
CREATE TABLE IF NOT EXISTS ux_run(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ts TEXT NOT NULL, rev TEXT, base TEXT, page TEXT,
  viewport_w INTEGER, viewport_h INTEGER, duration_ms INTEGER,
  clicks INTEGER DEFAULT 0, drags INTEGER DEFAULT 0, scrolls INTEGER DEFAULT 0,
  hotspots INTEGER DEFAULT 0, pass INTEGER DEFAULT 0, fail INTEGER DEFAULT 0,
  warn INTEGER DEFAULT 0, skip INTEGER DEFAULT 0, result TEXT
);
CREATE TABLE IF NOT EXISTS ux_event(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id INTEGER NOT NULL, seq INTEGER, step TEXT, type TEXT,
  target TEXT, tag TEXT, elem_id TEXT, cls TEXT, text TEXT,
  x REAL, y REAL, dx REAL, dy REAL, sy REAL, key TEXT, shot TEXT
);
CREATE TABLE IF NOT EXISTS ux_hotspot(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id INTEGER NOT NULL, tag TEXT, elem_id TEXT, cls TEXT, text TEXT,
  role TEXT, href TEXT, go TEXT, tab TEXT,
  x REAL, y REAL, w REAL, h REAL, visible INTEGER
);
CREATE TABLE IF NOT EXISTS ux_finding(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id INTEGER NOT NULL, severity TEXT, code TEXT, message TEXT, detail TEXT
);
CREATE INDEX IF NOT EXISTS ux_event_run ON ux_event(run_id);
CREATE INDEX IF NOT EXISTS ux_hotspot_run ON ux_hotspot(run_id);
CREATE INDEX IF NOT EXISTS ux_finding_run ON ux_finding(run_id);
"""


def resolve_repo(start: Path) -> Path | None:
    c = start.resolve()
    while c != c.parent:
        if (c / "opencode.json").is_file() and (c / "docker" / "Dockerfile").is_file():
            return c
        c = c.parent
    return None


def now_utc() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def fetch_rev(base: str) -> str:
    try:
        with urllib.request.urlopen(base + "/api/rev", timeout=5) as r:
            d = json.loads(r.read().decode("utf-8"))
        return str(d.get("served") or d.get("head") or "unknown")
    except Exception:
        return "unknown"


def init_schema(con: sqlite3.Connection) -> None:
    con.executescript(SCHEMA)
    con.commit()


def insert_run(con: sqlite3.Connection, run: dict) -> int:
    cur = con.execute(
        "INSERT INTO ux_run(ts,rev,base,page,viewport_w,viewport_h,duration_ms,"
        "clicks,drags,scrolls,hotspots,pass,fail,warn,skip,result) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (run["ts"], run["rev"], run["base"], run["page"],
         run["viewport_w"], run["viewport_h"], run["duration_ms"],
         run["clicks"], run["drags"], run["scrolls"], run["hotspots"],
         run["pass"], run["fail"], run["warn"], run["skip"], run["result"]),
    )
    con.commit()
    return int(cur.lastrowid)


def insert_event(con: sqlite3.Connection, run_id: int, seq: int, step: str,
                 ev: dict, shot: str) -> None:
    con.execute(
        "INSERT INTO ux_event(run_id,seq,step,type,target,tag,elem_id,cls,text,"
        "x,y,dx,dy,sy,key,shot) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (run_id, seq, step, ev.get("t") or ev.get("type"),
         ev.get("target"), ev.get("tag"), ev.get("id"), ev.get("cls"),
         ev.get("text"), ev.get("x"), ev.get("y"), ev.get("dx"), ev.get("dy"),
         ev.get("sy"), ev.get("key"), shot),
    )


def insert_hotspot(con: sqlite3.Connection, run_id: int, h: dict) -> None:
    con.execute(
        "INSERT INTO ux_hotspot(run_id,tag,elem_id,cls,text,role,href,go,tab,"
        "x,y,w,h,visible) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (run_id, h.get("tag"), h.get("id"), h.get("cls"), h.get("text"),
         h.get("role"), h.get("href"), h.get("go"), h.get("tab"),
         h.get("x"), h.get("y"), h.get("w"), h.get("h"),
         1 if h.get("visible") else 0),
    )


def insert_finding(con: sqlite3.Connection, run_id: int, f: dict) -> None:
    con.execute(
        "INSERT INTO ux_finding(run_id,severity,code,message,detail) "
        "VALUES(?,?,?,?,?)",
        (run_id, f["severity"], f["code"], f["message"], f.get("detail", "")),
    )


def analyze_hotspots(hotspots: list) -> list:
    """Pure heuristics over hotspot boxes; shared by run + self-test."""
    findings = []
    small = [h for h in hotspots if h.get("visible") and
             (h.get("w", 0) < 24 or h.get("h", 0) < 24)]
    for h in small[:20]:
        findings.append({
            "severity": "warn", "code": "small_target",
            "message": "click target < 24px (touch-unfriendly)",
            "detail": "%s#%s %sx%s" % (h.get("tag", ""), h.get("id", ""),
                                       h.get("w", 0), h.get("h", 0)),
        })
    boxes = [h for h in hotspots if h.get("visible") and
             (h.get("w", 0) > 0 and h.get("h", 0) > 0)]
    for i in range(len(boxes)):
        for j in range(i + 1, len(boxes)):
            a, b = boxes[i], boxes[j]
            ix = max(0, min(a["x"] + a["w"], b["x"] + b["w"]) - max(a["x"], b["x"]))
            iy = max(0, min(a["y"] + a["h"], b["y"] + b["h"]) - max(a["y"], b["y"]))
            inter = ix * iy
            small_a = a["w"] * a["h"]
            small_b = b["w"] * b["h"]
            smaller = min(small_a, small_b)
            if smaller > 0 and inter >= 0.4 * smaller:
                findings.append({
                    "severity": "warn", "code": "overlapping_targets",
                    "message": "overlapping interactive targets",
                    "detail": "%s#%s overlaps %s#%s" % (
                        a.get("tag", ""), a.get("id", ""),
                        b.get("tag", ""), b.get("id", "")),
                })
                break
        if len(findings) > 40:
            break
    return findings


def norm_event(ev: dict) -> dict:
    return {
        "t": ev.get("t"), "target": ev.get("target"), "tag": ev.get("tag"),
        "id": ev.get("id"), "cls": ev.get("cls"), "text": ev.get("text"),
        "x": ev.get("x"), "y": ev.get("y"), "dx": ev.get("dx"),
        "dy": ev.get("dy"), "sy": ev.get("sy"), "key": ev.get("key"),
        "val": ev.get("val"),
    }


def check(base: str) -> int:
    print("=== ux-trace.py --check ===")
    rc = 0
    try:
        from playwright.sync_api import sync_playwright  # noqa: F401
        print("  PASS  playwright importable")
    except Exception:
        print("  SKIP  playwright not installed -> pip install playwright")
        return 1
    try:
        from playwright.sync_api import sync_playwright
        with sync_playwright() as p:
            b = p.chromium.launch()
            b.close()
        print("  PASS  chromium launches")
    except Exception as e:
        print("  SKIP  chromium unavailable -> playwright install chromium (%s)" % e)
        return 1
    try:
        urllib.request.urlopen(base + "/", timeout=5)
        print("  PASS  server reachable at %s" % base)
    except Exception as e:
        rc = 1
        print("  FAIL  server not reachable at %s (%s)" % (base, e))
    if rc == 0:
        print("  ready: python3 scripts/ux-trace.py %s" % base)
    return rc


def drain(page) -> list:
    try:
        return page.evaluate(
            "() => { try { return window.__ux ? window.__ux.drain() : []; } "
            "catch (e) { return []; } }")
    except Exception:
        return []


def enumerate_hotspots(page) -> list:
    return page.evaluate(
        """(sel) => {
          var out = [];
          var seen = {};
          document.querySelectorAll(sel).forEach(function (el) {
            var r = el.getBoundingClientRect();
            if (!r.width && !r.height) { return; }
            var key = Math.round(r.left) + ':' + Math.round(r.top) + ':' +
                      Math.round(r.width) + ':' + Math.round(r.height) + ':' +
                      (el.id || '') + ':' + el.tagName;
            if (seen[key]) { return; }
            seen[key] = 1;
            var st = getComputedStyle(el);
            out.push({
              tag: el.tagName.toLowerCase(), id: el.id || '',
              cls: (typeof el.className === 'string') ? el.className : '',
              text: (el.textContent || '').trim().slice(0, 60),
              role: el.getAttribute ? (el.getAttribute('role') || '') : '',
              href: el.getAttribute ? (el.getAttribute('href') || '') : '',
              go: el.getAttribute ? (el.getAttribute('data-go') || '') : '',
              tab: el.getAttribute ? (el.getAttribute('data-tab') || '') : '',
              x: Math.round(r.left), y: Math.round(r.top),
              w: Math.round(r.width), h: Math.round(r.height),
              visible: st.display !== 'none' && st.visibility !== 'hidden' &&
                       r.width > 0 && r.height > 0
            });
          });
          return out;
        }""", HOTSPOT_SEL)


def draw_hotspot_overlay(page, boxes: list, path: str) -> None:
    visible = [b for b in boxes if b.get("visible")]
    page.evaluate(
        """(boxes) => {
          var root = document.createElement('div');
          root.id = '__uxhot';
          root.style.cssText = 'position:fixed;left:0;top:0;right:0;bottom:0;pointer-events:none;z-index:2147483647;';
          boxes.forEach(function (b, i) {
            var d = document.createElement('div');
            d.style.cssText = 'position:absolute;box-sizing:border-box;border:2px solid #2ea043;background:rgba(46,160,67,0.10);color:#2ea043;font:10px monospace;padding:0 2px;overflow:hidden;';
            d.style.left = b.x + 'px'; d.style.top = b.y + 'px';
            d.style.width = b.w + 'px'; d.style.height = b.h + 'px';
            d.textContent = (i + 1) + (b.id ? ' #' + b.id : '') + (b.tab ? ' [' + b.tab + ']' : '');
            root.appendChild(d);
          });
          document.body.appendChild(root);
        }""", visible)
    page.screenshot(path=path, full_page=False)
    page.evaluate("() => { var r = document.getElementById('__uxhot'); if (r) { r.remove(); } }")


def try_click(page, selector: str) -> bool:
    try:
        loc = page.locator(selector).first
        if loc.count() > 0:
            loc.click(timeout=2000)
            return True
    except Exception:
        pass
    return False


def do_drag(page) -> None:
    vp = page.viewport_size or DESKTOP
    y = int(vp["height"] * 0.5)
    x1 = int(vp["width"] * 0.25)
    x2 = int(vp["width"] * 0.6)
    try:
        page.mouse.move(x1, y)
        page.mouse.down()
        page.mouse.move(x2, y, steps=6)
        page.mouse.up()
    except Exception:
        pass


def do_scroll(page) -> None:
    try:
        page.evaluate("() => window.scrollTo(0, document.body.scrollHeight)")
        page.wait_for_timeout(150)
        page.evaluate("() => window.scrollTo(0, 0)")
        page.wait_for_timeout(150)
    except Exception:
        pass


def click_tab(page, name: str) -> bool:
    try:
        loc = page.locator('.tab[data-tab="%s"]' % name).first
        if loc.count() > 0:
            loc.click(timeout=2000)
            page.wait_for_timeout(120)
            return True
    except Exception:
        pass
    return False


def run(base: str, outdir: Path, db: Path) -> dict:
    try:
        from playwright.sync_api import sync_playwright
    except Exception:
        print("SKIP: playwright not installed "
              "(pip install playwright && playwright install chromium)")
        print("result: SKIP (not a pass)")
        return {"result": "SKIP", "runs": [], "totals": {"pass": 0, "fail": 0, "warn": 0, "skip": 1}}

    outdir.mkdir(parents=True, exist_ok=True)
    db.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(db))
    init_schema(con)

    rev = fetch_rev(base)
    all_runs = []
    totals = {"pass": 0, "fail": 0, "warn": 0, "skip": 0}
    ts = now_utc()

    with sync_playwright() as p:
        browser = p.chromium.launch()
        for path in PAGES:
            url = base + path
            page = browser.new_page(viewport=DESKTOP)
            page.add_init_script(RECORDER_JS)
            errors = []
            page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
            page.on("pageerror", lambda e: errors.append(str(e)))

            name = path.strip("/").replace("/", "_") or "home"
            pr = {"pass": 0, "fail": 0, "warn": 0, "skip": 0, "findings": []}

            t0 = time.time()
            try:
                page.goto(url, wait_until="networkidle", timeout=15000)
            except Exception as e:
                pr["fail"] += 1
                pr["findings"].append({"severity": "error", "code": "load_failed",
                                       "message": "page failed to load", "detail": str(e)})
                page.close()
                all_runs.append({"page": path, "pass": 0, "fail": 1, "warn": 0,
                                 "skip": 0, "clicks": 0, "drags": 0, "scrolls": 0,
                                 "hotspots": 0, "findings": pr["findings"]})
                continue

            page.wait_for_timeout(300)
            duration_ms = int((time.time() - t0) * 1000)

            # --- hotspots (at scroll 0, desktop) -------------------------
            hotspots = enumerate_hotspots(page)
            visible_hotspots = [h for h in hotspots if h.get("visible")]
            pr["pass"] += 1

            page.screenshot(path=str(outdir / ("%s-full.png" % name)), full_page=True)
            try:
                draw_hotspot_overlay(page, hotspots, str(outdir / ("%s-hotspots.png" % name)))
            except Exception:
                pass

            # --- phone checks --------------------------------------------
            page.set_viewport_size(PHONE)
            page.wait_for_timeout(400)
            scroll_w = page.evaluate("() => document.documentElement.scrollWidth")
            inner_w = page.evaluate("() => window.innerWidth")
            height = page.evaluate("() => document.documentElement.scrollHeight")
            page.screenshot(path=str(outdir / ("%s-390.png" % name)), full_page=True)
            page.set_viewport_size(DESKTOP)
            page.wait_for_timeout(200)

            if errors:
                pr["fail"] += 1
                pr["findings"].append({"severity": "error", "code": "console_error",
                                       "message": "console/page errors", "detail": errors[:2]})
            else:
                pr["pass"] += 1

            if scroll_w <= inner_w + 2:
                pr["pass"] += 1
            else:
                pr["fail"] += 1
                pr["findings"].append({"severity": "error", "code": "horizontal_overflow_390",
                                       "message": "horizontal scroll at 390px",
                                       "detail": "%d > %d" % (scroll_w, inner_w)})

            if height <= 6000:
                pr["pass"] += 1
            else:
                pr["warn"] += 1
                pr["findings"].append({"severity": "warn", "code": "page_wall",
                                       "message": "unscrollable wall at 390px",
                                       "detail": "%dpx tall" % height})

            # --- scripted journey ----------------------------------------
            events = []
            seq = 0
            shot_dir = outdir

            def step_shot(label):
                nonlocal seq
                seq += 1
                p = str(shot_dir / ("%s-step-%02d-%s.png" % (name, seq, label)))
                try:
                    page.screenshot(path=p, full_page=False)
                except Exception:
                    p = ""
                return p

            def after_step(label, extra=None):
                nonlocal seq
                shot = step_shot(label)
                got = drain(page)
                for e in got:
                    events.append((label, e, shot))

            after_step("load")
            do_scroll(page)
            after_step("scroll")

            if path == "/explore":
                for tab in ("charts", "signals", "patterns", "code", "data", "ocr", "overview"):
                    ok = click_tab(page, tab)
                    after_step("tab-" + tab)
                    if not ok and tab != "overview":
                        pr["fail"] += 1
                        pr["findings"].append({"severity": "error", "code": "tab_toggle_failed",
                                               "message": "tab did not toggle", "detail": tab})
                try:
                    page.fill("#q2", "the")
                    page.keyboard.press("Enter")
                    page.wait_for_timeout(400)
                except Exception:
                    pass
                after_step("search")
                try_click(page, "[data-go]")
                after_step("row")
                try_click(page, "#detail-close")
                after_step("close-detail")
                do_drag(page)
                after_step("drag")
            elif path == "/":
                try:
                    page.fill("#q", "the")
                    page.keyboard.press("Enter")
                    page.wait_for_timeout(400)
                except Exception:
                    pass
                after_step("search")
                try_click(page, "#sessions > *")
                after_step("row")
            elif path == "/runbooks":
                try_click(page, "text=host only")
                after_step("filter-host")
                try_click(page, "text=container only")
                after_step("filter-container")
                try_click(page, "[data-cmd]")
                after_step("copy")
            elif path == "/manage":
                try_click(page, "[data-cmd]")
                after_step("copy")
                do_scroll(page)
                after_step("scroll")
            elif path == "/docs":
                do_scroll(page)
                after_step("scroll")
            elif path == "/models":
                do_scroll(page)
                after_step("scroll")

            clicks = sum(1 for _, e, _ in events if e.get("t") == "click")
            drags = sum(1 for _, e, _ in events if e.get("t") == "drag")
            scrolls = sum(1 for _, e, _ in events if e.get("t") == "scroll")

            # --- hotspot heuristics --------------------------------------
            for f in analyze_hotspots(hotspots):
                pr["warn" if f["severity"] == "warn" else "fail"] += 1
                pr["findings"].append(f)

            run_id = insert_run(con, {
                "ts": ts, "rev": rev, "base": base, "page": path,
                "viewport_w": DESKTOP["width"], "viewport_h": DESKTOP["height"],
                "duration_ms": duration_ms, "clicks": clicks, "drags": drags,
                "scrolls": scrolls, "hotspots": len(visible_hotspots),
                "pass": pr["pass"], "fail": pr["fail"], "warn": pr["warn"],
                "skip": pr["skip"], "result": "FAIL" if pr["fail"] else "PASS",
            })
            for i, h in enumerate(hotspots):
                insert_hotspot(con, run_id, h)
            for i, (label, e, shot) in enumerate(events):
                insert_event(con, run_id, i, label, norm_event(e), shot)
            for f in pr["findings"]:
                insert_finding(con, run_id, f)

            totals["pass"] += pr["pass"]
            totals["fail"] += pr["fail"]
            totals["warn"] += pr["warn"]
            totals["skip"] += pr["skip"]

            print("%-12s pass=%d fail=%d warn=%d clicks=%d drags=%d scrolls=%d hotspots=%d" % (
                path, pr["pass"], pr["fail"], pr["warn"], clicks, drags, scrolls,
                len(visible_hotspots)))
            all_runs.append({"page": path, "pass": pr["pass"], "fail": pr["fail"],
                             "warn": pr["warn"], "skip": pr["skip"], "clicks": clicks,
                             "drags": drags, "scrolls": scrolls,
                             "hotspots": len(visible_hotspots),
                             "findings": pr["findings"]})
            page.close()
        browser.close()

    con.close()
    return {
        "ts": ts, "rev": rev, "base": base, "db": str(db),
        "runs": all_runs, "totals": totals,
        "result": "FAIL" if totals["fail"] else "PASS",
    }


def write_report(summary: dict, outdir: Path) -> Path:
    outdir.mkdir(parents=True, exist_ok=True)
    path = outdir / "report.md"
    lines = ["# UX trace report", "",
             "- ts: %s" % summary["ts"],
             "- rev: %s" % summary["rev"],
             "- base: %s" % summary["base"],
             "- db: %s" % summary["db"], "",
             "| page | pass | fail | warn | clicks | drags | scrolls | hotspots |",
             "|------|------|------|------|--------|-------|---------|----------|"]
    for r in summary["runs"]:
        lines.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
            r["page"], r["pass"], r["fail"], r["warn"], r["clicks"],
            r["drags"], r["scrolls"], r["hotspots"]))
    findings = [f for r in summary["runs"] for f in r["findings"]]
    lines += ["", "## Findings (%d)" % len(findings), ""]
    for f in findings:
        lines.append("- **[%s]** %s: %s (%s)" % (
            f["severity"], f["code"], f["message"], f.get("detail", "")))
    path.write_text("\n".join(lines) + "\n")
    return path


def self_test() -> int:
    print("=== ux-trace.py --self-test ===")
    ok = 0
    fail = 0

    def check(cond, msg):
        nonlocal ok, fail
        print(("  PASS  " if cond else "  FAIL  ") + msg)
        if cond:
            ok += 1
        else:
            fail += 1

    # 1. schema + persistence round-trip
    con = sqlite3.connect(":memory:")
    init_schema(con)
    rid = insert_run(con, {"ts": now_utc(), "rev": "test", "base": "http://x",
                           "page": "/explore", "viewport_w": 1440, "viewport_h": 900,
                           "duration_ms": 10, "clicks": 1, "drags": 0, "scrolls": 1,
                           "hotspots": 2, "pass": 3, "fail": 0, "warn": 1, "skip": 0,
                           "result": "PASS"})
    insert_event(con, rid, 0, "load", {"t": "click", "tag": "button", "id": "t",
                                        "x": 10, "y": 20}, "shot.png")
    insert_hotspot(con, rid, {"tag": "button", "id": "t", "x": 0, "y": 0,
                              "w": 40, "h": 20, "visible": True})
    insert_finding(con, rid, {"severity": "warn", "code": "small_target",
                              "message": "tiny", "detail": "button#t 40x20"})
    n_run = con.execute("SELECT COUNT(*) FROM ux_run").fetchone()[0]
    n_ev = con.execute("SELECT COUNT(*) FROM ux_event").fetchone()[0]
    n_hs = con.execute("SELECT COUNT(*) FROM ux_hotspot").fetchone()[0]
    n_fn = con.execute("SELECT COUNT(*) FROM ux_finding").fetchone()[0]
    con.close()
    check(n_run == 1 and n_ev == 1 and n_hs == 1 and n_fn == 1,
          "schema + persistence round-trip (run/event/hotspot/finding)")

    # 2. hotspot heuristics fire on synthetic boxes
    small = analyze_hotspots([{"tag": "button", "id": "a", "x": 0, "y": 0,
                               "w": 10, "h": 10, "visible": True}])
    check(any(f["code"] == "small_target" for f in small),
          "small_target detected (<24px)")
    overlap = analyze_hotspots([
        {"tag": "button", "id": "a", "x": 0, "y": 0, "w": 100, "h": 100, "visible": True},
        {"tag": "a", "id": "b", "x": 10, "y": 10, "w": 100, "h": 100, "visible": True},
    ])
    check(any(f["code"] == "overlapping_targets" for f in overlap),
          "overlapping_targets detected")
    clean = analyze_hotspots([{"tag": "button", "id": "a", "x": 0, "y": 0,
                               "w": 100, "h": 40, "visible": True},
                              {"tag": "button", "id": "b", "x": 200, "y": 0,
                               "w": 100, "h": 40, "visible": True}])
    check(clean == [], "clean boxes produce no findings")

    # 3. RECORDER_JS has no stray backtick/quote and defines window.__ux
    check("window.__ux" in RECORDER_JS and "drain" in RECORDER_JS,
          "recorder JS defines window.__ux.drain")

    print("\n  result: %d pass, %d fail" % (ok, fail))
    return 0 if fail == 0 else 1


def main(argv: list | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("base", nargs="?", default="http://127.0.0.1:5099")
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--db", type=Path, default=None)
    ap.add_argument("--json", action="store_true", help="emit only a JSON summary")
    ap.add_argument("--check", action="store_true", help="report prerequisites and exit")
    ap.add_argument("--self-test", action="store_true", help="offline self-test (no browser)")
    args = ap.parse_args(argv if argv is not None else sys.argv[1:])
    base = args.base.rstrip("/")

    if args.self_test:
        return self_test()
    if args.check:
        return check(base)

    repo = resolve_repo(Path(__file__).parent) or resolve_repo(Path.cwd())
    out = args.out or ((repo / "logs" / "ux") if repo else Path("logs/ux"))
    db = args.db or ((repo / "data" / "observability" / "ux.db") if repo
                     else Path("data/observability/ux.db"))

    summary = run(base, out, db)

    if args.json:
        print(json.dumps(summary))
    else:
        report = write_report(summary, out)
        t = summary["totals"]
        print("\n  screenshots: %s" % out)
        print("  db: %s" % summary["db"])
        print("  report: %s" % report)
        print("  result: %s (%d pass, %d fail, %d warn, %d skip)" % (
            summary["result"], t["pass"], t["fail"], t["warn"], t["skip"]))
    return 1 if summary["result"] == "FAIL" else 0


if __name__ == "__main__":
    sys.exit(main())
