#!/usr/bin/env python3
"""usability-guided.py - run or import a facilitator-guided usability session.

The automated suite screens the build; this script captures a HUMAN session
against the shared task script (scripts/usability-tasks.json). A facilitator
reads one goal at a time, the participant uses the UI, and the facilitator
records: success, time-on-task, difficulty (1-5), note, then the 10 SUS items.

Modes:
  --tasks                 print the shared task script (no session)
  --interactive           run the session in this terminal (stdin prompts)
  --import FILE           import a session collected by the /usability page
  --list [N]              latest sessions from the observability DB
  --self-test             offline apparatus test (no server, no human)
  --json                  machine-readable output

This script never fabricates human data. A session with no responses is
invalid; use --tasks or --self-test for a dry run.

Scoring: effectiveness = successes / tasks; efficiency = median time-on-task
for successful tasks; satisfaction = SUS (alternating items x 2.5). Rows are
written to usability_guided + data/observability/usability-guided.json.

Plain ASCII. No model calls. No network.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import shutil
import sqlite3
import statistics
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
TASKS = REPO / "scripts" / "usability-tasks.json"
OBS_DB = REPO / "data" / "observability" / "observability.db"
SNAPSHOT = REPO / "data" / "observability" / "usability-guided.json"
SUS_BASELINE = 68.0


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


def load_tasks(path: pathlib.Path = TASKS) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def sus_score(answers: list[int]) -> float | None:
    if not isinstance(answers, list) or len(answers) != 10:
        return None
    total = 0.0
    for i, v in enumerate(answers):
        try:
            v = int(v)
        except Exception:
            return None
        if v < 1 or v > 5:
            return None
        total += (v - 1) if i % 2 == 0 else (5 - v)
    return round(total * 2.5, 1)


def score_session(tasks: list[dict], sus: list[int] | None) -> dict:
    total = len(tasks)
    done = [t for t in tasks if t.get("success") is True]
    failed = [t for t in tasks if t.get("success") is False]
    skipped = [t for t in tasks if t.get("success") is None]
    times = [float(t.get("duration_s")) for t in done if isinstance(t.get("duration_s"), (int, float))]
    effectiveness = (len(done) / total) if total else None
    efficiency = round(statistics.median(times), 3) if times else None
    return {
        "effectiveness": None if effectiveness is None else round(effectiveness, 3),
        "efficiency_s": efficiency,
        "completed": len(done),
        "failed": len(failed),
        "skipped": len(skipped),
        "total": total,
        "satisfaction_sus": sus_score(sus) if sus else None,
        "sus_threshold": SUS_BASELINE,
    }


def validate(payload: dict) -> tuple[dict | None, str]:
    try:
        spec = load_tasks()
    except Exception as e:
        return None, "task script unreadable: " + str(e)
    ids = {t["id"] for t in spec.get("tasks", [])}
    rows = payload.get("tasks")
    if not isinstance(rows, list) or not rows:
        return None, "tasks[] required"
    seen = set()
    clean = []
    for r in rows:
        if not isinstance(r, dict) or r.get("id") not in ids:
            return None, "unknown task id: " + str(r.get("id") if isinstance(r, dict) else r)
        if r["id"] in seen:
            return None, "duplicate task id: " + r["id"]
        seen.add(r["id"])
        success = r.get("success")
        if success not in (True, False, None):
            return None, "success must be true/false/null"
        dur = r.get("duration_s")
        if dur is not None:
            try:
                dur = max(0.0, float(dur))
            except Exception:
                return None, "duration_s must be numeric"
        diff = r.get("difficulty")
        if diff is not None:
            try:
                diff = int(diff)
            except Exception:
                return None, "difficulty must be 1..5"
            if diff < 1 or diff > 5:
                return None, "difficulty must be 1..5"
        clean.append({
            "id": r["id"], "success": success, "duration_s": dur, "difficulty": diff,
            "note": str(r.get("note") or "")[:500],
        })
    sus = payload.get("sus")
    if sus is not None and sus_score(sus) is None:
        return None, "sus must be 10 integers 1..5"
    participant = str(payload.get("participant") or "anonymous")[:60]
    notes = str(payload.get("notes") or "")[:1000]
    return {"tasks": clean, "sus": sus, "participant": participant, "notes": notes}, ""


def persist(session: dict) -> dict:
    out = {"db": False, "json": False, "error": "", "id": None}
    payload = json.dumps({"tasks": session["tasks"], "sus": session.get("sus"),
                          "participant": session["participant"], "notes": session.get("notes", "")})
    try:
        OBS_DB.parent.mkdir(parents=True, exist_ok=True)
        con = sqlite3.connect(str(OBS_DB), timeout=5)
        con.execute("""CREATE TABLE IF NOT EXISTS usability_guided(
          id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, rev TEXT, participant TEXT,
          mode TEXT, effectiveness REAL, efficiency_s REAL, satisfaction_sus REAL,
          completed INTEGER, total INTEGER, notes TEXT, payload TEXT)""")
        cur = con.execute(
            "INSERT INTO usability_guided(ts,rev,participant,mode,effectiveness,efficiency_s,"
            "satisfaction_sus,completed,total,notes,payload) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (session["ts"], session["rev"], session["participant"], session.get("mode", "human-guided"),
             session.get("effectiveness"), session.get("efficiency_s"), session.get("satisfaction_sus"),
             session.get("completed"), session.get("total"), session.get("notes", ""), payload))
        out["id"] = int(cur.lastrowid)
        con.commit()
        con.close()
        out["db"] = True
    except Exception as e:
        out["error"] = type(e).__name__ + ": " + str(e)
    try:
        doc = {"updated": session["ts"], "sessions": []}
        try:
            doc = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
        except Exception:
            pass
        sessions = [s for s in doc.get("sessions", []) if s.get("id") != out["id"]]
        sessions.insert(0, {**session, "id": out["id"]})
        doc["sessions"] = sessions[:50]
        doc["updated"] = session["ts"]
        SNAPSHOT.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(SNAPSHOT.parent), prefix=SNAPSHOT.name + ".", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(doc, f, indent=1)
                f.write("\n")
            os.replace(tmp, SNAPSHOT)
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        out["json"] = True
    except Exception as e:
        out["error"] = (out["error"] + "; " if out["error"] else "") + "json: " + str(e)
    return out


def finalize(payload: dict, mode: str) -> tuple[dict | None, str]:
    clean, err = validate(payload)
    if not clean:
        return None, err
    sc = score_session(clean["tasks"], clean.get("sus"))
    session = {
        "ts": now_iso(), "rev": rev(), "participant": clean["participant"],
        "mode": mode, "notes": clean.get("notes", ""), "sus": clean.get("sus"),
        **sc, "tasks": clean["tasks"],
    }
    session["saved"] = persist(session)
    return session, ""


def list_sessions(limit: int) -> list[dict]:
    try:
        con = sqlite3.connect("file:" + str(OBS_DB) + "?mode=ro", uri=True, timeout=3)
        rows = con.execute(
            "SELECT id,ts,rev,participant,mode,effectiveness,efficiency_s,satisfaction_sus,"
            "completed,total,notes FROM usability_guided ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        con.close()
    except Exception:
        return []
    keys = ("id", "ts", "rev", "participant", "mode", "effectiveness", "efficiency_s",
            "satisfaction_sus", "completed", "total", "notes")
    return [dict(zip(keys, r)) for r in rows]


class Guide:
    """Optional page opener for a guided session: xdg-open, an already-open
    CDP browser, a headed Playwright browser, or Selenium. Any failure falls
    back to printing the URL, so the session never depends on a driver."""

    def __init__(self, opener: str = "auto"):
        self.requested = opener
        self.used = "print"
        self.pw = None
        self.browser = None
        self.page = None
        self.driver = None
        self._choose()

    def _have(self, name: str) -> bool:
        return shutil.which(name) is not None

    def _choose(self) -> None:
        want = self.requested
        if want == "print":
            return
        if want in ("auto", "xdg") and self._have("xdg-open"):
            self.used = "xdg"
            return
        if want in ("auto", "cdp") and self._have("node") and (REPO / "scripts" / "cdp-tab.mjs").is_file():
            self.used = "cdp"
            return
        if want in ("auto", "playwright"):
            try:
                from playwright.sync_api import sync_playwright  # noqa: F401
                self.used = "playwright"
                return
            except Exception:
                if want == "playwright":
                    return
        if want in ("auto", "selenium"):
            try:
                import selenium  # noqa: F401
                self.used = "selenium"
                return
            except Exception:
                if want == "selenium":
                    return

    def open(self, url: str) -> str:
        try:
            if self.used == "xdg":
                p = subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                p.wait(timeout=8)
                return "xdg-open"
            if self.used == "cdp":
                p = subprocess.Popen(["node", str(REPO / "scripts" / "cdp-tab.mjs"), "open", url],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                p.communicate(timeout=15)
                return "cdp-tab"
            if self.used == "playwright":
                if self.pw is None:
                    from playwright.sync_api import sync_playwright
                    self.pw = sync_playwright().start()
                    self.browser = self.pw.chromium.launch(headless=False)
                    self.page = self.browser.new_page()
                self.page.goto(url, wait_until="domcontentloaded", timeout=20000)
                return "playwright"
            if self.used == "selenium":
                if self.driver is None:
                    from selenium import webdriver
                    self.driver = webdriver.Chrome()
                self.driver.get(url)
                return "selenium"
        except Exception as e:
            print("  opener failed (%s); printing the URL instead" % (type(e).__name__ + ": " + str(e)[:80]))
            self.used = "print"
        print("  open: " + url)
        return "print"

    def close(self) -> None:
        try:
            if self.driver is not None:
                self.driver.quit()
        except Exception:
            pass
        try:
            if self.browser is not None:
                self.browser.close()
        except Exception:
            pass
        try:
            if self.pw is not None:
                self.pw.stop()
        except Exception:
            pass


def interactive(spec: dict, participant: str, notes: str, base: str = "",
                opener: str = "", guided: bool = False) -> dict | None:
    print("Guided usability session. Participant: " + participant)
    print("Read each goal; start the timer, let the participant use the UI, stop when done.")
    print("(Ctrl-C aborts; nothing is saved until the end.)\n")
    g = Guide(opener) if guided else None
    if g:
        print("  opener: " + g.used + "\n")
    rows = []
    try:
        for i, t in enumerate(spec.get("tasks", []), 1):
            print("[%d/%d] %s  %s" % (i, len(spec["tasks"]), t["path"], t["title"]))
            print("  GOAL: " + t["instruction"])
            print("  SUCCESS: " + t["success"])
            if g:
                print("  opening: " + g.open((base or "").rstrip("/") + t["path"]))
            try:
                input("  Enter to START the timer... ")
                import time
                t0 = time.monotonic()
                input("  Enter to STOP when the participant finishes... ")
                dur = round(time.monotonic() - t0, 2)
                ans = input("  Success? [y]es / [n]o / [s]kip: ").strip().lower()
                success = True if ans.startswith("y") else (False if ans.startswith("n") else None)
                diff = input("  Difficulty 1 (easy) - 5 (hard), blank = n/a: ").strip()
                diff = int(diff) if diff.isdigit() and 1 <= int(diff) <= 5 else None
                note = input("  Note (optional): ").strip()
            except (EOFError, KeyboardInterrupt):
                print("\naborted; no session saved")
                return None
            rows.append({"id": t["id"], "success": success, "duration_s": dur,
                         "difficulty": diff, "note": note})
            print("")
    finally:
        if g:
            g.close()
    print("SUS: 1 = strongly disagree, 5 = strongly agree")
    sus = []
    for i, item in enumerate(spec.get("sus_items", []), 1):
        try:
            v = input("%2d. %s\n    > " % (i, item)).strip()
            sus.append(int(v))
        except (EOFError, KeyboardInterrupt, ValueError):
            print("invalid SUS response; session not saved")
            return None
    session, err = finalize({"participant": participant, "notes": notes, "tasks": rows, "sus": sus}, "human-guided")
    if not session:
        print("FAIL: " + err)
    return session


def human(session: dict) -> str:
    lines = ["=== guided usability session @ %s (rev %s) ===" % (session["ts"], session.get("rev") or "?")]
    lines.append("participant: %s   mode: %s" % (session.get("participant"), session.get("mode")))
    lines.append("effectiveness: %s (%s/%s)   efficiency: %s   SUS: %s" % (
        session.get("effectiveness"), session.get("completed"), session.get("total"),
        "n/a" if session.get("efficiency_s") is None else str(session.get("efficiency_s")) + "s",
        "n/a" if session.get("satisfaction_sus") is None else session.get("satisfaction_sus")))
    for t in session.get("tasks", []):
        dur = t.get("duration_s")
        lines.append("  %-18s %-6s %8s  difficulty=%s  %s" % (
            t.get("id"), "PASS" if t.get("success") else ("FAIL" if t.get("success") is False else "SKIP"),
            "n/a" if dur is None else str(dur) + "s", t.get("difficulty"), (t.get("note") or "")[:80]))
    saved = session.get("saved") or {}
    if saved.get("error"):
        lines.append("note: persist partial: " + saved["error"])
    return "\n".join(lines)


def self_test() -> int:
    fail = 0
    spec = load_tasks()
    if len(spec.get("tasks", [])) < 5:
        print("FAIL task script too short"); fail = 1
    rows = [
        {"id": spec["tasks"][0]["id"], "success": True, "duration_s": 4.0, "difficulty": 1},
        {"id": spec["tasks"][1]["id"], "success": True, "duration_s": 6.0, "difficulty": 2},
        {"id": spec["tasks"][2]["id"], "success": False, "duration_s": 9.0, "difficulty": 4},
    ]
    sus = [5, 1, 5, 1, 5, 1, 5, 1, 5, 1]
    clean, err = validate({"participant": "p", "tasks": rows, "sus": sus})
    if err:
        print("FAIL validate: " + err); fail = 1
    sc = score_session(clean["tasks"], clean["sus"])
    if sc["effectiveness"] != round(2 / 3, 3) or sc["efficiency_s"] != 5.0:
        print("FAIL score", sc); fail = 1
    if sc["satisfaction_sus"] != 100.0:
        print("FAIL SUS", sc); fail = 1
    bad, err = validate({"tasks": [{"id": "nope", "success": True}]})
    if bad or not err:
        print("FAIL bad task accepted"); fail = 1
    bad2, err2 = validate({"tasks": rows, "sus": [1, 2]})
    if bad2 or not err2:
        print("FAIL bad SUS accepted"); fail = 1
    with tempfile.TemporaryDirectory() as td:
        global OBS_DB, SNAPSHOT
        old_db, old_snap = OBS_DB, SNAPSHOT
        OBS_DB, SNAPSHOT = pathlib.Path(td) / "o.db", pathlib.Path(td) / "g.json"
        session, err = finalize({"participant": "test", "tasks": rows, "sus": sus}, "self-test")
        if err or not session:
            print("FAIL finalize: " + err); fail = 1
        else:
            if not session["saved"]["db"] or not session["saved"]["json"]:
                print("FAIL persist", session["saved"]); fail = 1
            got = list_sessions(5)
            if not got or got[0]["participant"] != "test":
                print("FAIL list", got); fail = 1
        OBS_DB, SNAPSHOT = old_db, old_snap
    print("usability-guided: self-test " + ("PASS" if fail == 0 else "FAIL"))
    return fail


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tasks", action="store_true")
    ap.add_argument("--interactive", action="store_true")
    ap.add_argument("--guide", action="store_true", help="interactive + open each page (xdg/playwright/selenium/cdp)")
    ap.add_argument("--opener", default="auto", choices=["auto", "xdg", "playwright", "selenium", "cdp", "print"])
    ap.add_argument("--base", default=os.environ.get("USABILITY_BASE", "http://127.0.0.1:5099"))
    ap.add_argument("--import", dest="import_file", default="")
    ap.add_argument("--mode", default="import", help="label for an imported session")
    ap.add_argument("--list", nargs="?", type=int, const=10, default=None)
    ap.add_argument("--participant", default="anonymous")
    ap.add_argument("--notes", default="")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    spec = load_tasks()
    if a.tasks:
        if a.json:
            print(json.dumps(spec, indent=1))
        else:
            for i, t in enumerate(spec.get("tasks", []), 1):
                print("%d. [%s] %s" % (i, t["path"], t["title"]))
                print("   goal: " + t["instruction"])
                print("   success: " + t["success"])
        return 0
    if a.list is not None:
        rows = list_sessions(a.list)
        if a.json:
            print(json.dumps(rows, indent=1))
        else:
            for r in rows:
                print("%s %-18s eff=%s exp=%s SUS=%s (%s/%s)" % (
                    r["ts"], r["participant"], r["effectiveness"],
                    "n/a" if r["efficiency_s"] is None else str(r["efficiency_s"]) + "s",
                    "n/a" if r["satisfaction_sus"] is None else r["satisfaction_sus"],
                    r["completed"], r["total"]))
            if not rows:
                print("(no guided sessions yet)")
        return 0
    if a.import_file:
        try:
            doc = json.loads(pathlib.Path(a.import_file).read_text(encoding="utf-8"))
        except Exception as e:
            print("cannot read session: " + str(e), file=sys.stderr)
            return 2
        session, err = finalize(doc, a.mode)
        if not session:
            print("FAIL: " + err, file=sys.stderr)
            return 2
        print(json.dumps(session, indent=1) if a.json else human(session))
        return 0
    if a.interactive or a.guide:
        session = interactive(spec, a.participant, a.notes, a.base, a.opener, a.guide)
        if not session:
            return 2
        print(json.dumps(session, indent=1) if a.json else human(session))
        return 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
