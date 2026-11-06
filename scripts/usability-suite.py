#!/usr/bin/env python3
"""usability-suite.py - a rigorous, cited usability test for the served app.

Three layers, each with an explicit operational definition and a source:

  1. Task effectiveness + efficiency (ISO 9241-11): scripted tasks, success
     rate and median time-to-completion. A task is the unit of analysis.
  2. Accessibility conformance (WCAG 2.2 A/AA automated subset): the repo's
     a11y-audit.mjs, plus axe-core when Playwright and axe-core are present.
  3. Experience mechanics: Core Web Vitals lab proxies (LCP/CLS), reflow at
     320 CSS px, target size (24x24), keyboard bypass/focus, reduced motion.

Citations live in docs/USABILITY-TESTING.md and in each result row. Automated
checks are a screening instrument, not a substitute for disabled users or
moderated testing (WCAG 2.2; Playwright accessibility docs).

Modes:
  --static-only   HTTP + a11y-audit.mjs (no browser). Task/CWV axis = SKIP.
  default         Playwright if importable; otherwise static with a named SKIP.
  --watch SEC     run forever (lock-protected); --runs N bounds it.
  --sus-file F    10 SUS responses (1..5) -> satisfaction score.
  --axe           run axe-core if node_modules/axe-core/axe.min.js exists.

Never edits the app or the session store. Writes observability DB rows +
data/observability/usability.json. No model calls.

Usage:
  ./scripts/usability-suite.py --check
  ./scripts/usability-suite.py --static-only
  ./scripts/usability-suite.py --base http://127.0.0.1:5099
  ./scripts/usability-suite.py --watch 900 --static-only
  ./scripts/usability-suite.py --sus-file logs/sus.json
  ./scripts/usability-suite.py --self-test

Exit: 0 no hard FAIL, 1 a hard FAIL, 2 usage/config. SKIP is not PASS.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import re
import shutil
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

try:
    import fcntl
except Exception:  # non-POSIX: watch mode still runs, without the lock
    fcntl = None

REPO = pathlib.Path(__file__).resolve().parent.parent
OBS_DB = REPO / "data" / "observability" / "observability.db"
SNAPSHOT = REPO / "data" / "observability" / "usability.json"
AXE_PATH = REPO / "node_modules" / "axe-core" / "axe.min.js"

PAGES = ["/", "/usability", "/graph", "/explore", "/runbooks", "/models", "/manage", "/docs"]
DESKTOP = {"width": 1440, "height": 900}
PHONE = {"width": 390, "height": 844}
REFLOW = {"width": 320, "height": 800}

# Core Web Vitals "good" thresholds: https://web.dev/articles/vitals
LCP_MS = 2500
INP_MS = 200
CLS_MAX = 0.1
TASK_EFFECTIVENESS = 0.90       # ISO 9241-11 effectiveness, operationalised
TASK_EFFICIENCY_S = 10.0        # Nielsen's 10-second limit (response times)
TARGET_PX = 24                  # WCAG 2.2 SC 2.5.8 (minimum, AA)
SUS_BASELINE = 68.0             # Lewis (2018): 68 is the average SUS score
DEAD_AFTER_S = 21600

CITE = {
    "iso11": "ISO 9241-11:2018 https://www.iso.org/standard/63500.html",
    "iso210": "ISO 9241-210:2019 https://www.iso.org/standard/77520.html",
    "wcag22": "W3C WCAG 2.2 (2024) https://www.w3.org/TR/WCAG22/",
    "target": "W3C SC 2.5.8 https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html",
    "reflow": "W3C SC 1.4.10 (reflow, 320 CSS px) https://www.w3.org/WAI/WCAG22/Understanding/reflow.html",
    "axe": "Deque axe-core https://github.com/dequelabs/axe-core",
    "axe_pw": "Playwright accessibility testing https://playwright.dev/docs/accessibility-testing",
    "vitals": "Google web.dev Core Web Vitals https://web.dev/articles/vitals",
    "webvitals": "GoogleChrome/web-vitals https://github.com/GoogleChrome/web-vitals",
    "nng": "Nielsen 10 heuristics https://www.nngroup.com/articles/ten-usability-heuristics/",
    "nielsen": "Nielsen 1993 Usability Engineering ISBN 978-0-12-518406-9",
    "sus": "Lewis 2018 SUS https://doi.org/10.1080/10447318.2018.1455307",
    "bias": "Parasuraman & Riley 1997 https://doi.org/10.1518/001872097778543886",
    "motion": "MDN prefers-reduced-motion https://developer.mozilla.org/en-US/docs/Web/CSS/@media/prefers-reduced-motion",
    "pw_csp": "Playwright #7395 https://github.com/microsoft/playwright/issues/7395",
    "pw_csp2": "Playwright #16357 https://github.com/microsoft/playwright/issues/16357",
    "pw_frame": "Playwright Frame.evaluate https://playwright.dev/python/docs/api/class-frame",
}


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def rev() -> str:
    try:
        p = subprocess.Popen(["git", "-C", str(REPO), "rev-parse", "--short", "HEAD"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out, _ = p.communicate(timeout=5)
        return out.strip()
    except Exception:
        return ""


def atomic_write(path: pathlib.Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def run_cmd(cmd: list[str], timeout: int) -> tuple[int, str, str, int]:
    t0 = time.time()
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, cwd=str(REPO))
        try:
            out, err = p.communicate(timeout=timeout)
            rc = p.returncode
        except subprocess.TimeoutExpired:
            p.kill()
            out, err = p.communicate()
            rc = 124
        return rc, out or "", err or "", int((time.time() - t0) * 1000)
    except Exception as e:
        return 127, "", type(e).__name__ + ": " + str(e), int((time.time() - t0) * 1000)


def http_status(url: str, timeout: float = 10.0) -> tuple[int, int, str]:
    try:
        req = urllib.request.Request(url, headers={"user-agent": "usability-suite/1"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read(2_000_000)
            return int(r.status), len(body), ""
    except urllib.error.HTTPError as e:
        return int(e.code), 0, "http " + str(e.code)
    except Exception as e:
        return 0, 0, type(e).__name__ + ": " + str(e)[:160]


def first_json(text: str):
    i = text.find("{")
    if i < 0:
        return None
    try:
        return json.JSONDecoder().raw_decode(text[i:])[0]
    except Exception:
        return None


class Suite:
    def __init__(self, base: str, mode: str):
        self.base = base.rstrip("/")
        self.mode = mode
        self.rows: list[dict] = []
        self.notes: list[str] = []
        self.started = now_iso()

    def add(self, axis: str, metric: str, value, unit: str, verdict: str,
            threshold: str, citation: str, detail: str = "") -> None:
        self.rows.append({
            "axis": axis, "metric": metric, "value": value, "unit": unit,
            "verdict": verdict, "threshold": threshold, "citation": citation,
            "detail": detail[:500],
        })

    def fail(self, axis: str, metric: str, detail: str, citation: str, threshold: str = "0") -> None:
        self.add(axis, metric, 0, "count", "FAIL", threshold, citation, detail)

    def skip(self, axis: str, metric: str, detail: str, citation: str) -> None:
        self.add(axis, metric, None, "", "SKIP", "n/a", citation, detail)


# --- static layer ---------------------------------------------------------

def static_layer(s: Suite) -> None:
    node = shutil.which("node")
    audit = REPO / "scripts" / "a11y-audit.mjs"
    for path in PAGES:
        url = s.base + path
        status, size, err = http_status(url)
        s.add("reachability", "http_" + (path.strip("/") or "home"), status, "status",
              "PASS" if status == 200 else "FAIL", "200", CITE["iso11"],
              ("%d bytes" % size) if status == 200 else err)
        if status != 200:
            continue
        if not node or not audit.is_file():
            s.skip("accessibility", "a11y_" + (path.strip("/") or "home"),
                   "node or a11y-audit.mjs missing", CITE["wcag22"])
            continue
        rc, out, errtext, ms = run_cmd([node, str(audit), "--url", url, "--json"], 60)
        doc = first_json(out)
        if not isinstance(doc, dict) or "rows" not in doc:
            s.add("accessibility", "a11y_" + (path.strip("/") or "home"), None, "",
                  "FAIL", "0 failures", CITE["wcag22"],
                  "a11y-audit did not return JSON: " + (errtext or out)[:200])
            continue
        failed = [r for r in doc.get("rows", []) if not r.get("ok")]
        s.add("accessibility", "a11y_" + (path.strip("/") or "home") + "_fail",
              len(failed), "checks", "PASS" if not failed else "FAIL", "0 failures",
              CITE["wcag22"],
              ("; ".join("%s: %s" % (r.get("check"), r.get("detail")) for r in failed[:4])
               if failed else "%d checks passed in %dms" % (doc.get("total", 0), ms)))
    s.skip("task", "effectiveness", "static mode: no browser, tasks not executed", CITE["iso11"])
    s.skip("task", "efficiency", "static mode: no browser, time-on-task not measured", CITE["iso11"])
    s.skip("cwv", "lcp", "static mode: no browser; LCP needs layout/paint", CITE["vitals"])
    s.skip("cwv", "cls", "static mode: no browser; CLS needs layout", CITE["vitals"])
    s.skip("cwv", "inp", "field-only metric; lab proxy required", CITE["vitals"])
    s.skip("keyboard", "focus", "static mode: no DOM focus", CITE["wcag22"])
    s.skip("reflow", "320px", "static mode: no layout", CITE["reflow"])


# --- browser layer --------------------------------------------------------

def axe_available() -> bool:
    return AXE_PATH.is_file() and shutil.which("node") is not None


def poll(page, expr: str, timeout_s: float = 15.0, interval: float = 0.25) -> bool:
    end = time.monotonic() + timeout_s
    while time.monotonic() < end:
        try:
            if page.evaluate("() => (" + expr + ")"):
                return True
        except Exception:
            pass
        time.sleep(interval)
    return False


def wait_markers(page, timeout_s: float = 40.0) -> bool:
    end = time.monotonic() + timeout_s
    last = None
    while time.monotonic() < end:
        try:
            n = int(page.evaluate("document.querySelectorAll('[data-loading]').length"))
        except Exception:
            return False
        if n == 0:
            return True
        if last is not None and n < last:
            last = n
        elif last is None:
            last = n
        time.sleep(1.0)
    return False


def cwv_probe(page) -> dict:
    try:
        return page.evaluate("""() => new Promise((resolve) => {
          const out = {lcp: 0, cls: 0};
          try { new PerformanceObserver((l) => { for (const e of l.getEntries()) {
            if ((e.startTime || 0) > out.lcp) out.lcp = e.startTime; } })
            .observe({type: 'largest-contentful-paint', buffered: true}); } catch (e) {}
          try { new PerformanceObserver((l) => { for (const e of l.getEntries()) {
            if (!e.hadRecentInput) out.cls += e.value; } })
            .observe({type: 'layout-shift', buffered: true}); } catch (e) {}
          setTimeout(() => resolve(out), 1500);
        })""")
    except Exception:
        return {"lcp": 0, "cls": 0}


def target_probe(page) -> dict:
    try:
        return page.evaluate("""() => {
          const sel = 'a[href],button,input:not([type=hidden]),select,textarea,[role=button],[tabindex]:not([tabindex="-1"])';
          const out = {total: 0, small: 0, examples: []};
          for (const el of document.querySelectorAll(sel)) {
            if (!el.offsetParent && getComputedStyle(el).position !== 'fixed') continue;
            const r = el.getBoundingClientRect();
            if (r.width <= 0 || r.height <= 0) continue;
            const inlineLink = el.tagName === 'A' && getComputedStyle(el).display === 'inline'
              && el.parentElement && (el.parentElement.innerText || '').trim().length > 40;
            if (inlineLink) continue;
            out.total++;
            if (r.width < 24 || r.height < 24) {
              out.small++;
              if (out.examples.length < 5) out.examples.push(
                (el.id ? '#' + el.id : el.tagName.toLowerCase()) + ' ' + Math.round(r.width) + 'x' + Math.round(r.height));
            }
          }
          return out;
        }""")
    except Exception:
        return {"total": 0, "small": 0, "examples": []}


def keyboard_probe(page) -> dict:
    out = {"first": "", "skip_ok": False, "focus_ok": True, "sequence": []}
    try:
        page.evaluate("() => { if (document.activeElement && document.activeElement.blur) document.activeElement.blur(); document.body.focus(); }")
        for i in range(10):
            page.keyboard.press("Tab")
            info = page.evaluate("""() => { const a = document.activeElement; if (!a) return null;
              const s = getComputedStyle(a);
              return {tag: a.tagName, id: a.id, cls: String(a.className || ''),
                      outline: s.outlineStyle + ' ' + s.outlineWidth,
                      shadow: s.boxShadow, text: (a.innerText || a.getAttribute('aria-label') || '').slice(0, 40)};
            }""")
            if not info:
                break
            if i == 0:
                out["first"] = info.get("tag", "") + "#" + info.get("id", "")
                out["skip_ok"] = "skip-link" in (info.get("cls") or "")
            if i < 8 and not (info.get("outline") not in ("none 0px", "none 0px 0px") or info.get("shadow") not in ("none", "")):
                out["focus_ok"] = False
            out["sequence"].append(info.get("tag", "") + "#" + info.get("id", ""))
        page.keyboard.press("Enter")
        time.sleep(0.2)
        out["skip_target"] = page.evaluate("() => location.hash")
    except Exception as e:
        out["error"] = str(e)[:160]
    return out


def reduced_motion_probe(browser, base: str) -> dict:
    try:
        ctx = browser.new_context(viewport=DESKTOP, reduced_motion="reduce")
        page = ctx.new_page()
        page.goto(base + "/", wait_until="domcontentloaded", timeout=20000)
        time.sleep(0.8)
        n = int(page.evaluate("""() => { let n = 0;
          for (const el of document.querySelectorAll('*')) {
            const s = getComputedStyle(el);
            const dur = parseFloat(s.animationDuration) || 0;
            const tr = parseFloat(s.transitionDuration) || 0;
            if ((dur > 0.01 || tr > 0.01) && (el.offsetWidth || el.offsetHeight)) n++;
          } return n; }"""))
        ctx.close()
        return {"motion_elements": n}
    except Exception as e:
        return {"error": str(e)[:160]}


def axe_probe(page) -> dict:
    if not axe_available():
        return {"available": False, "reason": "axe-core not installed (npm install axe-core)"}
    try:
        page.add_script_tag(path=str(AXE_PATH))
        res = page.evaluate("""(tags) => axe.run(document, {runOnly: {type: 'tag', values: tags}})
          .then(r => ({violations: r.violations.map(v => ({id: v.id, impact: v.impact, nodes: v.nodes.length})),
                        incomplete: r.incomplete.length}))
          .catch(e => ({error: String(e)}))""",
                            ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
        return {"available": True, **res}
    except Exception as e:
        return {"available": True, "error": str(e)[:200]}


def run_task(page, base: str, path: str, timeout_s: float = 20.0) -> tuple[bool, float, str]:
    t0 = time.monotonic()
    try:
        page.goto(base + path, wait_until="domcontentloaded", timeout=int(timeout_s * 1000))
    except Exception as e:
        return False, time.monotonic() - t0, "goto: " + str(e)[:120]
    ok = False
    note = ""
    if path == "/":
        ok = poll(page, "document.getElementById('q') !== null", 8)
        if ok:
            page.fill("#q", "session")
            ok = poll(page, "(document.getElementById('searchres')||{}).innerText.length > 20", 15)
            if not ok:
                note = "search results did not render"
            else:
                pulse_ok = poll(page, "(document.getElementById('pulse')||{}).innerText.length > 20", 8)
                if not pulse_ok:
                    ok = False
                    note = "pulse did not render"
        else:
            note = "search box missing"
    elif path == "/graph":
        ok = poll(page, "document.getElementById('status') && /nodes/.test(document.getElementById('status').innerText)", 20)
        if ok:
            ids = page.evaluate("() => (window.__projectGraph ? window.__projectGraph.ids() : [])")
            if ids:
                selected = page.evaluate("(id) => window.__projectGraph.select(id)", ids[0])
                ok = bool(selected) and poll(page, "document.getElementById('side-title') && document.getElementById('side-title').innerText !== 'Select a node'", 5)
                note = "selected %d node(s)" % len(ids)
            else:
                ok = False
                note = "graph has no nodes"
        else:
            note = "graph load status not reached"
    elif path == "/explore":
        ok = poll(page, "document.querySelector('.tab[data-tab=\"signals\"]') !== null", 10)
        if ok:
            page.click('.tab[data-tab="signals"]')
            ok = poll(page, "document.querySelector('.pane[data-pane=\"signals\"]') && getComputedStyle(document.querySelector('.pane[data-pane=\"signals\"]')).display !== 'none'", 8)
        else:
            note = "tabs missing"
    elif path == "/runbooks":
        ok = poll(page, "document.getElementById('f') && document.getElementById('list') !== null", 10)
        if ok:
            page.select_option("#f", "container")
            ok = poll(page, "document.getElementById('list').innerText.length > 20", 8)
        else:
            note = "filter/list missing"
    elif path == "/models":
        ok = poll(page, "(document.getElementById('cat')||{}).innerText.length > 20", 15)
        if not ok:
            note = "model catalog did not populate"
    elif path == "/manage":
        ok = poll(page, "document.getElementById('f') && document.getElementById('list') !== null", 10)
        if ok:
            page.select_option("#f", "container")
            ok = poll(page, "document.getElementById('list').innerText.length > 20", 8)
        else:
            note = "filter/list missing"
    elif path == "/docs":
        ok = poll(page, "document.querySelectorAll('#docsel option').length > 1", 10)
        if ok:
            page.select_option("#docsel", "RULES.md")
            ok = poll(page, "(document.getElementById('docbody')||{}).innerText.length > 500", 10)
        else:
            note = "document selector did not populate"
    return bool(ok), time.monotonic() - t0, note


def browser_layer(s: Suite, use_axe: bool) -> None:
    try:
        from playwright.sync_api import sync_playwright
    except Exception:
        s.skip("task", "effectiveness", "playwright not installed; run --static-only or install it", CITE["iso11"])
        s.skip("task", "efficiency", "playwright not installed", CITE["iso11"])
        s.skip("cwv", "lcp", "playwright not installed", CITE["vitals"])
        s.skip("cwv", "cls", "playwright not installed", CITE["vitals"])
        s.skip("cwv", "inp", "playwright not installed", CITE["vitals"])
        s.skip("keyboard", "focus", "playwright not installed", CITE["wcag22"])
        s.skip("reflow", "320px", "playwright not installed", CITE["reflow"])
        return

    task_success = 0
    task_times: list[float] = []
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for path in PAGES:
            page = browser.new_page(viewport=DESKTOP)
            errors: list[str] = []
            page.on("console", lambda m: errors.append(m.text[:160]) if m.type == "error" else None)
            page.on("pageerror", lambda e: errors.append("pageerror: " + str(e)[:160]))
            try:
                page.goto(s.base + path, wait_until="domcontentloaded", timeout=20000)
                ready = wait_markers(page, 40)
                s.add("feedback", "async_resolved_" + (path.strip("/") or "home"), 1 if ready else 0,
                      "bool", "PASS" if ready else "FAIL", "1", CITE["nng"],
                      ("console errors: " + "; ".join(errors[:2])) if errors else "no console errors")
                if errors:
                    s.add("quality", "console_errors_" + (path.strip("/") or "home"), len(errors),
                          "errors", "FAIL", "0", CITE["nng"], "; ".join(errors[:3]))
                cwv = cwv_probe(page)
                s.add("cwv", "lcp_" + (path.strip("/") or "home"), round(float(cwv.get("lcp", 0))), "ms",
                      "PASS" if float(cwv.get("lcp", 0)) <= LCP_MS else "FAIL",
                      "<= %d ms" % LCP_MS, CITE["vitals"], "lab probe, single load (field P75 is authoritative)")
                s.add("cwv", "cls_" + (path.strip("/") or "home"), round(float(cwv.get("cls", 0)), 4), "score",
                      "PASS" if float(cwv.get("cls", 0)) <= CLS_MAX else "FAIL",
                      "<= %.1f" % CLS_MAX, CITE["vitals"], "lab probe over the first 1.5s")
                tp = target_probe(page)
                s.add("heuristics", "undersized_targets_" + (path.strip("/") or "home"),
                      int(tp.get("small", 0)), "targets",
                      "PASS" if int(tp.get("small", 0)) == 0 else "FAIL",
                      "0 < %dpx" % TARGET_PX, CITE["target"],
                      "; ".join(tp.get("examples", [])) or ("%d targets checked" % int(tp.get("total", 0))))
                kb = keyboard_probe(page)
                s.add("keyboard", "skip_link_" + (path.strip("/") or "home"), 1 if kb.get("skip_ok") else 0,
                      "bool", "PASS" if kb.get("skip_ok") else "FAIL", "1", CITE["wcag22"],
                      "first Tab -> " + str(kb.get("first")) + "; hash=" + str(kb.get("skip_target")))
                s.add("keyboard", "focus_visible_" + (path.strip("/") or "home"), 1 if kb.get("focus_ok") else 0,
                      "bool", "PASS" if kb.get("focus_ok") else "FAIL", "1", CITE["wcag22"],
                      "tab sequence: " + " -> ".join(kb.get("sequence", [])[:8]))
                page.set_viewport_size(REFLOW)
                time.sleep(0.6)
                sw = page.evaluate("document.documentElement.scrollWidth")
                iw = page.evaluate("window.innerWidth")
                s.add("reflow", "hscroll_" + (path.strip("/") or "home"), int(sw), "px",
                      "PASS" if int(sw) <= int(iw) + 2 else "FAIL", "<= %dpx" % int(iw), CITE["reflow"],
                      "scrollWidth at %dpx viewport" % iw)
                if use_axe and path in ("/", "/explore"):
                    ar = axe_probe(page)
                    if not ar.get("available"):
                        s.skip("accessibility", "axe_" + (path.strip("/") or "home"), ar.get("reason", ""), CITE["axe"])
                    elif "error" in ar:
                        s.skip("accessibility", "axe_" + (path.strip("/") or "home"), ar["error"], CITE["axe"])
                    else:
                        v = ar.get("violations", [])
                        s.add("accessibility", "axe_" + (path.strip("/") or "home"), len(v), "violations",
                              "PASS" if not v else "FAIL", "0", CITE["axe"],
                              "; ".join("%s(%s)x%s" % (x.get("id"), x.get("impact"), x.get("nodes")) for x in v[:6]))
                page.set_viewport_size(DESKTOP)
            except Exception as e:
                s.add("reachability", "browser_" + (path.strip("/") or "home"), 0, "bool", "FAIL", "1",
                      CITE["iso11"], "browser error: " + str(e)[:200])
            finally:
                page.close()

            ok, secs, note = run_task(browser, s.base, path)
            task_success += 1 if ok else 0
            if ok:
                task_times.append(secs)
            s.add("task", "task_" + (path.strip("/") or "home"), 1 if ok else 0, "bool",
                  "PASS" if ok else "FAIL", "1", CITE["iso11"],
                  ("%.2fs" % secs) + (" " + note if note else ""))
            s.add("task", "time_" + (path.strip("/") or "home"), round(secs, 3), "s",
                  "PASS" if ok and secs <= TASK_EFFICIENCY_S else ("FAIL" if ok else "SKIP"),
                  "<= %.0fs" % TASK_EFFICIENCY_S, CITE["nielsen"],
                  ("successful" if ok else "task failed") + (" " + note if note else ""))

        total = len(PAGES)
        rate = task_success / total if total else 0.0
        s.add("task", "effectiveness", round(rate, 3), "ratio",
              "PASS" if rate >= TASK_EFFECTIVENESS else "FAIL",
              ">= %.2f" % TASK_EFFECTIVENESS, CITE["iso11"],
              "%d/%d scripted tasks succeeded" % (task_success, total))
        med = statistics.median(task_times) if task_times else None
        s.add("task", "efficiency", None if med is None else round(med, 3), "s",
              "SKIP" if med is None else ("PASS" if med <= TASK_EFFICIENCY_S else "FAIL"),
              "<= %.0fs" % TASK_EFFICIENCY_S, CITE["iso11"],
              "median time-on-task for successful tasks")
        s.skip("cwv", "inp", "field-only metric; no user input distribution in a lab run", CITE["vitals"])

        rm = reduced_motion_probe(browser, s.base)
        if "error" in rm:
            s.skip("heuristics", "reduced_motion", rm["error"], CITE["motion"])
        else:
            n = int(rm.get("motion_elements", 0))
            s.add("heuristics", "reduced_motion", n, "elements",
                  "PASS" if n == 0 else "FAIL", "0 moving elements", CITE["motion"],
                  "computed animation/transition > 0.01s under prefers-reduced-motion")
        browser.close()


# --- scoring + persistence ------------------------------------------------

def aggregate(s: Suite, sus: float | None) -> dict:
    def vals(axis: str, verdict: str | None = None):
        return [r for r in s.rows if r["axis"] == axis and (verdict is None or r["verdict"] == verdict)]
    fails = [r for r in s.rows if r["verdict"] == "FAIL"]
    skips = [r for r in s.rows if r["verdict"] == "SKIP"]
    effectiveness = next((r["value"] for r in s.rows if r["axis"] == "task" and r["metric"] == "effectiveness"), None)
    efficiency = next((r["value"] for r in s.rows if r["axis"] == "task" and r["metric"] == "efficiency"), None)
    axes = {}
    for axis in ("reachability", "task", "accessibility", "cwv", "keyboard", "reflow", "heuristics", "feedback", "quality"):
        rows = vals(axis)
        if not rows:
            continue
        p = sum(1 for r in rows if r["verdict"] == "PASS")
        f = sum(1 for r in rows if r["verdict"] == "FAIL")
        k = sum(1 for r in rows if r["verdict"] == "SKIP")
        axes[axis] = {"pass": p, "fail": f, "skip": k,
                      "score": round(100.0 * p / (p + f), 1) if (p + f) else None}
    verdict = "PASS" if not fails else "FAIL"
    if s.mode != "browser":
        verdict = "PASS" if verdict == "PASS" else "FAIL"
    return {
        "ts": s.started, "rev": rev(), "base": s.base, "mode": s.mode,
        "verdict": verdict, "effectiveness": effectiveness, "efficiency_s": efficiency,
        "satisfaction_sus": sus, "sus_threshold": SUS_BASELINE,
        "axes": axes, "fail_count": len(fails), "skip_count": len(skips),
        "failures": [{"axis": r["axis"], "metric": r["metric"], "detail": r["detail"]} for r in fails[:20]],
        "skips": [{"axis": r["axis"], "metric": r["metric"], "detail": r["detail"]} for r in skips[:20]],
        "rows": s.rows, "notes": s.notes,
        "caveat": "Automated checks screen for common issues; WCAG requires manual and disabled-user testing.",
        "citations": CITE,
    }


def persist(snap: dict) -> dict:
    out = {"db": False, "json": False, "error": ""}
    try:
        OBS_DB.parent.mkdir(parents=True, exist_ok=True)
        con = sqlite3.connect(str(OBS_DB), timeout=5)
        con.execute("""CREATE TABLE IF NOT EXISTS usability_run(
          id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, rev TEXT, base TEXT, mode TEXT,
          verdict TEXT, effectiveness REAL, efficiency_s REAL, satisfaction_sus REAL,
          fail_count INTEGER, skip_count INTEGER, detail TEXT)""")
        con.execute("""CREATE TABLE IF NOT EXISTS usability_result(
          id INTEGER PRIMARY KEY AUTOINCREMENT, run_id INTEGER, axis TEXT, metric TEXT,
          value TEXT, unit TEXT, verdict TEXT, threshold TEXT, citation TEXT, detail TEXT)""")
        cur = con.execute(
            "INSERT INTO usability_run(ts,rev,base,mode,verdict,effectiveness,efficiency_s,"
            "satisfaction_sus,fail_count,skip_count,detail) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (snap["ts"], snap["rev"], snap["base"], snap["mode"], snap["verdict"],
             snap.get("effectiveness"), snap.get("efficiency_s"), snap.get("satisfaction_sus"),
             snap.get("fail_count", 0), snap.get("skip_count", 0),
             json.dumps(snap.get("axes", {}))[:1000]))
        run_id = int(cur.lastrowid)
        for r in snap.get("rows", []):
            con.execute(
                "INSERT INTO usability_result(run_id,axis,metric,value,unit,verdict,threshold,citation,detail) "
                "VALUES(?,?,?,?,?,?,?,?,?)",
                (run_id, r["axis"], r["metric"], str(r["value"]), r["unit"], r["verdict"],
                 r["threshold"], r["citation"], r["detail"]))
        con.execute("DELETE FROM usability_result WHERE run_id NOT IN "
                    "(SELECT id FROM usability_run ORDER BY id DESC LIMIT 200)")
        con.execute("DELETE FROM usability_run WHERE id NOT IN "
                    "(SELECT id FROM usability_run ORDER BY id DESC LIMIT 200)")
        con.commit()
        con.close()
        out["db"] = True
    except Exception as e:
        out["error"] = type(e).__name__ + ": " + str(e)
    try:
        atomic_write(SNAPSHOT, json.dumps(snap, indent=1) + "\n")
        out["json"] = True
    except Exception as e:
        out["error"] = (out["error"] + "; " if out["error"] else "") + "json: " + str(e)
    return out


def sus_from_file(path: str) -> float | None:
    try:
        vals = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
        if not isinstance(vals, list) or len(vals) != 10:
            return None
        out = 0.0
        for i, v in enumerate(vals):
            v = int(v)
            if v < 1 or v > 5:
                return None
            out += (v - 1) if i % 2 == 0 else (5 - v)
        return round(out * 2.5, 1)
    except Exception:
        return None


def sus_interactive() -> float | None:
    print("SUS (1=strongly disagree, 5=strongly agree). Enter 10 integers.")
    vals = []
    for i in range(10):
        try:
            vals.append(int(input("%2d> " % (i + 1))))
        except Exception:
            return None
    out = 0.0
    for i, v in enumerate(vals):
        if v < 1 or v > 5:
            return None
        out += (v - 1) if i % 2 == 0 else (5 - v)
    return round(out * 2.5, 1)


def human(snap: dict) -> str:
    lines = ["=== usability-suite @ %s (rev %s, mode=%s) ===" % (
        snap["ts"], snap.get("rev") or "?", snap["mode"])]
    eff = snap.get("efficiency_s")
    lines.append("verdict: %s   effectiveness=%s   efficiency=%s   SUS=%s" % (
        snap["verdict"], "n/a" if snap.get("effectiveness") is None else snap.get("effectiveness"),
        "n/a" if eff is None else str(eff) + "s",
        "n/a" if snap.get("satisfaction_sus") is None else snap.get("satisfaction_sus")))
    for axis, d in snap.get("axes", {}).items():
        lines.append("  %-14s pass=%d fail=%d skip=%d score=%s" % (
            axis, d["pass"], d["fail"], d["skip"], d["score"]))
    for f in snap.get("failures", [])[:10]:
        lines.append("  FAIL %-14s %-28s %s" % (f["axis"], f["metric"], f["detail"][:140]))
    for k in snap.get("skips", [])[:8]:
        lines.append("  SKIP %-14s %-28s %s" % (k["axis"], k["metric"], k["detail"][:140]))
    lines.append("  caveat: " + snap["caveat"])
    saved = snap.get("saved") or {}
    if saved.get("error"):
        lines.append("  note: persist partial: " + saved["error"])
    return "\n".join(lines)


def self_test() -> int:
    fail = 0
    s = Suite("http://example.invalid", "browser")
    s.add("task", "task_home", 1, "bool", "PASS", "1", CITE["iso11"])
    s.add("task", "task_graph", 1, "bool", "PASS", "1", CITE["iso11"])
    s.add("task", "effectiveness", 1.0, "ratio", "PASS", ">= 0.90", CITE["iso11"])
    s.add("task", "efficiency", 2.5, "s", "PASS", "<= 10s", CITE["iso11"])
    s.add("cwv", "lcp_home", 2200, "ms", "PASS", "<= 2500", CITE["vitals"])
    s.add("heuristics", "reduced_motion", 0, "elements", "PASS", "0", CITE["motion"])
    snap = aggregate(s, 72.5)
    if snap["verdict"] != "PASS" or snap["effectiveness"] != 1.0:
        print("FAIL aggregate pass"); fail = 1
    if snap["axes"]["task"]["score"] != 100.0:
        print("FAIL axis score", snap["axes"]); fail = 1
    s2 = Suite("http://example.invalid", "browser")
    s2.add("heuristics", "undersized_targets_home", 3, "targets", "FAIL", "0", CITE["target"])
    snap2 = aggregate(s2, None)
    if snap2["verdict"] != "FAIL" or not snap2["failures"]:
        print("FAIL fail detection"); fail = 1
    # SUS: alternating 5/1 is the maximum (100), all 3 is 50.
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump([5, 1, 5, 1, 5, 1, 5, 1, 5, 1], f)
        name = f.name
    if sus_from_file(name) != 100.0:
        print("FAIL SUS max"); fail = 1
    os.unlink(name)
    with tempfile.TemporaryDirectory() as td:
        global OBS_DB, SNAPSHOT
        old_db, old_snap = OBS_DB, SNAPSHOT
        OBS_DB, SNAPSHOT = pathlib.Path(td) / "o.db", pathlib.Path(td) / "u.json"
        snap3 = aggregate(s, 72.5)
        saved = persist(snap3)
        if not saved["db"] or not saved["json"]:
            print("FAIL persist", saved); fail = 1
        con = sqlite3.connect(OBS_DB)
        if con.execute("SELECT COUNT(*) FROM usability_run").fetchone()[0] != 1:
            print("FAIL run row"); fail = 1
        if con.execute("SELECT COUNT(*) FROM usability_result").fetchone()[0] != len(s.rows):
            print("FAIL result rows"); fail = 1
        con.close()
        OBS_DB, SNAPSHOT = old_db, old_snap
    # A static-mode suite must SKIP browser axes, never silently PASS them.
    s3 = Suite("http://example.invalid", "static")
    s3.skip("task", "effectiveness", "static", CITE["iso11"])
    snap4 = aggregate(s3, None)
    if snap4["skips"][0]["metric"] != "effectiveness":
        print("FAIL skip accounting"); fail = 1
    print("usability-suite: self-test " + ("PASS" if fail == 0 else "FAIL"))
    return fail


def run_once(args, mode: str, sus: float | None) -> int:
    s = Suite(args.base, mode)
    static_layer(s)
    if mode == "browser":
        browser_layer(s, args.axe)
    snap = aggregate(s, sus)
    snap["saved"] = persist(snap)
    if args.json:
        print(json.dumps(snap, indent=1))
    else:
        print(human(snap))
    return 0 if snap["verdict"] == "PASS" else 1


def acquire_lock(path: pathlib.Path):
    if fcntl is None:
        return None
    path.parent.mkdir(parents=True, exist_ok=True)
    fh = open(path, "w")
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        fh.write(str(os.getpid()))
        fh.flush()
        return fh
    except OSError:
        fh.close()
        return False


def check(base: str) -> int:
    print("=== usability-suite --check ===")
    rc = 0
    status, _, err = http_status(base + "/")
    if status == 200:
        print("  PASS  server reachable at " + base)
    else:
        print("  FAIL  server not reachable at %s (%s)" % (base, err))
        rc = 1
    try:
        import playwright  # noqa: F401
        print("  PASS  playwright importable")
    except Exception:
        print("  SKIP  playwright not installed (pip install playwright && playwright install chromium)")
    if shutil.which("node") and (REPO / "scripts" / "a11y-audit.mjs").is_file():
        print("  PASS  a11y-audit.mjs available")
    else:
        print("  FAIL  node/a11y-audit.mjs missing")
        rc = 1
    print("  axe-core: " + ("available" if axe_available() else "SKIP (npm install axe-core)"))
    return rc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=os.environ.get("USABILITY_BASE", "http://127.0.0.1:5099"))
    ap.add_argument("--static-only", action="store_true")
    ap.add_argument("--browser", action="store_true", help="force browser mode")
    ap.add_argument("--axe", action="store_true", help="run axe-core when installed")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--watch", type=int, default=0, help="repeat every N seconds")
    ap.add_argument("--runs", type=int, default=0, help="with --watch, stop after N runs")
    ap.add_argument("--sus", action="store_true")
    ap.add_argument("--sus-file", default="")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if a.check:
        return check(a.base.rstrip("/"))
    sus = sus_from_file(a.sus_file) if a.sus_file else (sus_interactive() if a.sus else None)
    mode = "static" if a.static_only else ("browser" if a.browser else "auto")
    if mode == "auto":
        try:
            import playwright  # noqa: F401
            mode = "browser"
        except Exception:
            mode = "static"
    if not a.watch:
        return run_once(a, mode, sus)
    lock = acquire_lock(REPO / "data" / "observability" / "usability.lock")
    if lock is False:
        print("usability-suite: another run holds the lock; skipping this tick")
        return 0
    n = 0
    try:
        while True:
            n += 1
            rc = run_once(a, mode, sus)
            print("[%s] run %d verdict=%s" % (now_iso(), n, "PASS" if rc == 0 else "FAIL"))
            if a.runs and n >= a.runs:
                return rc
            time.sleep(max(30, a.watch))
    finally:
        if lock:
            lock.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
