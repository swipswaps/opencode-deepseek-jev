#!/usr/bin/env python3
"""closeout-gate.py - do not declare "done" until the completion questions are
answered with evidence.

The recurring failure is not a missing feature; it is a confident completion
claim while a build, restart, retest, or path is still wrong. This gate makes
the pre-completion questions explicit and evidence-backed:

  1. root      build/restart were run from the repo root (or via
               scripts/web-build-restart.sh)
  2. built     if web/src changed, web/dist is newer than the sources
  3. served    the live server is reachable, served==HEAD, /api/usability/tasks is 200
  4. gates     the last gate passed and is newer than the change
  5. retest    if the UI changed, a NEW guided session exists after the change
  6. tracked   every script referenced by tools/runbooks is git-tracked
  7. citations docs/USABILITY-TESTING.md still carries the verification log
  8. host      the host checkout/service was synced and restarted (manual)

Usage:
  ./scripts/closeout-gate.py --check [--base URL]
  ./scripts/closeout-gate.py --ask          # prompt unresolved questions
  ./scripts/closeout-gate.py --answer retest=defer --reason "..." 
  ./scripts/closeout-gate.py --json
  ./scripts/closeout-gate.py --self-test

Exit: 0 all PASS (or accepted deferrals with reasons), 1 BLOCKED, 2 usage.
SKIP is not PASS. A deferral is recorded, never silently green.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import re
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent
OBS_DB = REPO / "data" / "observability" / "observability.db"
STATE = REPO / "data" / "observability" / "closeout.json"
LAST_GATE = REPO / "data" / "observability" / "last-gate.json"
DOC = REPO / "docs" / "USABILITY-TESTING.md"
BASE_DEFAULT = os.environ.get("CLOSEOUT_BASE", "http://127.0.0.1:5099")


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_json(path: pathlib.Path, default=None):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def git(*args: str) -> str:
    try:
        p = subprocess.Popen(["git", "-C", str(REPO), *args],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out, _ = p.communicate(timeout=10)
        return out
    except Exception:
        return ""


def changed_paths() -> list[str]:
    out = git("status", "--porcelain=v1")
    paths = []
    for line in out.splitlines():
        if len(line) < 4:
            continue
        p = line[3:].strip()
        if " -> " in p:
            p = p.split(" -> ", 1)[1]
        paths.append(p)
    return paths


def newest_mtime(paths: list[str]) -> float:
    best = 0.0
    for rel in paths:
        p = REPO / rel
        try:
            if p.is_dir():
                for f in p.rglob("*"):
                    if f.is_file():
                        best = max(best, f.stat().st_mtime)
            elif p.is_file():
                best = max(best, p.stat().st_mtime)
        except OSError:
            continue
    return best


def parse_gate_ts(ts: str) -> float:
    try:
        return dt.datetime.strptime(ts, "%Y%m%dT%H%M%SZ").replace(tzinfo=dt.timezone.utc).timestamp()
    except Exception:
        return 0.0


def iso_to_epoch(ts: str) -> float:
    try:
        return dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp()
    except Exception:
        return 0.0


def http_status(url: str) -> int:
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            return int(r.status)
    except urllib.error.HTTPError as e:
        return int(e.code)
    except Exception:
        return 0


def served_rev(base: str) -> tuple[str, str, int]:
    try:
        with urllib.request.urlopen(base.rstrip("/") + "/api/rev", timeout=5) as r:
            d = json.loads(r.read().decode())
        return str(d.get("served", "")), str(d.get("head", "")), 200
    except Exception:
        return "", "", 0


def latest_guided() -> dict | None:
    if not OBS_DB.is_file():
        return None
    try:
        con = sqlite3.connect("file:" + str(OBS_DB) + "?mode=ro", uri=True, timeout=3)
        row = con.execute(
            "SELECT id,ts,mode,participant FROM usability_guided ORDER BY id DESC LIMIT 1").fetchone()
        con.close()
    except Exception:
        return None
    if not row:
        return None
    return {"id": row[0], "ts": row[1], "mode": row[2], "participant": row[3]}


def tracked_missing() -> list[str]:
    refs = set()
    pat = re.compile(r"scripts/[A-Za-z0-9_./-]+\.(?:sh|py|mjs)")
    for name in ("tools.json", "runbooks.json"):
        try:
            doc = json.loads((REPO / "scripts" / name).read_text(encoding="utf-8"))
        except Exception:
            continue
        items = doc if isinstance(doc, list) else doc.get("tools", doc.get("runbooks", []))
        for it in items:
            for key in ("commands", "command", "cmd"):
                v = it.get(key)
                vals = v if isinstance(v, list) else ([v] if isinstance(v, str) else [])
                for cmd in vals:
                    if isinstance(cmd, str):
                        refs.update(pat.findall(cmd))
    missing = []
    for ref in sorted(refs):
        rel = ref[2:] if ref.startswith("./") else ref
        p = subprocess.Popen(["git", "-C", str(REPO), "ls-files", "--error-unmatch", rel],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            p.communicate(timeout=5)
        except Exception:
            pass
        if p.returncode != 0:
            missing.append(ref)
    return missing


def evaluate(base: str) -> dict:
    status_paths = changed_paths()
    commit_ts = 0
    commit_paths = []
    try:
        commit_ts = int(git("log", "-1", "--format=%ct").strip() or 0)
        commit_paths = [x for x in git("show", "--name-only", "--format=", "HEAD").splitlines() if x.strip()]
    except Exception:
        commit_ts, commit_paths = 0, []
    paths = sorted(set(status_paths) | set(commit_paths))
    ui_paths = [p for p in paths if p.startswith("web/src/") or p == "scripts/dashboard.mjs"
                or p.startswith("scripts/usability-")]
    all_change_mtime = max(newest_mtime(status_paths), commit_ts if commit_paths else 0.0)
    ui_status = [p for p in status_paths if p in ui_paths]
    ui_change_mtime = max(newest_mtime(ui_status),
                          commit_ts if any(p in ui_paths for p in commit_paths) else 0.0)
    web_changed = any(p.startswith("web/src/") for p in paths)
    dist_js = list((REPO / "web" / "dist" / "assets").glob("*.js")) if (REPO / "web" / "dist").is_dir() else []
    dist_mtime = max([f.stat().st_mtime for f in dist_js], default=0.0)
    src_status = [p for p in status_paths if p.startswith("web/src/")]
    src_mtime = max(newest_mtime(src_status),
                    commit_ts if any(p.startswith("web/src/") for p in commit_paths) else 0.0) if web_changed else 0.0
    built_ok = (not web_changed) or (dist_mtime >= src_mtime and dist_mtime > 0)
    served, head, rev_code = served_rev(base)
    tasks_code = http_status(base.rstrip("/") + "/api/usability/tasks")
    gate = read_json(LAST_GATE, {}) or {}
    gate_ts = parse_gate_ts(str(gate.get("ts", "")))
    gate_ok = int(gate.get("failed", 1)) == 0 and int(gate.get("passed", 0)) > 0
    gate_fresh = gate_ts >= all_change_mtime if all_change_mtime else True
    guided = latest_guided()
    guided_ts = iso_to_epoch(guided["ts"]) if guided else 0.0
    retest_required = bool(ui_paths)
    retest_ok = (not retest_required) or (guided_ts >= ui_change_mtime and guided_ts > 0)
    human_ok = bool(guided) and str(guided.get("mode")) not in ("dry-run", "apparatus", "self-test")
    missing = tracked_missing()
    citations_ok = DOC.is_file() and "Verification log" in DOC.read_text(encoding="utf-8", errors="replace") \
        and DOC.read_text(encoding="utf-8", errors="replace").count("https://") >= 5
    root_ok = pathlib.Path.cwd().resolve() == REPO.resolve()

    items = [
        {"id": "root", "question": "Were build/restart commands run from the repo root (or via scripts/web-build-restart.sh)?",
         "status": "PASS" if root_ok else "WARN",
         "evidence": "cwd=" + str(pathlib.Path.cwd()) + " repo=" + str(REPO),
         "next": "run ./scripts/web-build-restart.sh from anywhere, or cd to the repo root"},
        {"id": "built", "question": "If web/src changed, is web/dist newer than the sources?",
         "status": "PASS" if built_ok else "FAIL",
         "evidence": "web_changed=%s dist_mtime=%s src_mtime=%s" % (
             web_changed, int(dist_mtime), int(src_mtime)),
         "next": "cd web && npm run build  (or ./scripts/web-build-restart.sh)"},
        {"id": "served", "question": "Is the live server reachable with served==HEAD and /api/usability/tasks 200?",
         "status": "PASS" if (rev_code == 200 and tasks_code == 200 and (not head or served == head)) else "FAIL",
         "evidence": "base=%s rev=%s served=%s head=%s tasks=%s" % (base, rev_code, served, head, tasks_code),
         "next": "./scripts/web-restart.sh && curl -s %s/api/rev" % base},
        {"id": "gates", "question": "Did the last gate pass, and is it newer than the change?",
         "status": "PASS" if (gate_ok and gate_fresh) else "FAIL",
         "evidence": "last-gate=%s passed=%s failed=%s fresh=%s" % (
             gate.get("ts"), gate.get("passed"), gate.get("failed"), gate_fresh),
         "next": "./scripts/harness.sh --fast"},
        {"id": "retest", "question": "If the UI changed, is there a NEW guided human session after the change?",
         "status": "PASS" if (retest_ok and human_ok) else ("FAIL" if retest_required else "SKIP"),
         "evidence": "ui_change_ts=%s latest_guided=%s mode=%s" % (
             int(ui_change_mtime), guided.get("ts") if guided else None,
             guided.get("mode") if guided else None),
         "next": "open /app/#usability or /usability and submit a session, or ./scripts/usability-guide.sh"},
        {"id": "tracked", "question": "Is every script referenced by tools/runbooks git-tracked?",
         "status": "PASS" if not missing else "FAIL",
         "evidence": ("missing: " + ", ".join(missing)) if missing else "all referenced scripts tracked",
         "next": "git add the missing scripts (RULES #54)"},
        {"id": "citations", "question": "Does the usability method still carry the verified citation log?",
         "status": "PASS" if citations_ok else "FAIL",
         "evidence": str(DOC),
         "next": "restore docs/USABILITY-TESTING.md §8 Verification log"},
        {"id": "host", "question": "Was the host checkout synced, rebuilt, and restarted?",
         "status": "WARN",
         "evidence": "host-specific; the sandbox cannot see /home/owner/...",
         "next": "git pull, cd web && npm run build, ./scripts/web-restart.sh on the host"},
    ]
    blocking = [i for i in items if i["status"] == "FAIL"]
    warns = [i for i in items if i["status"] == "WARN"]
    return {"ts": now_iso(), "rev": git("rev-parse", "--short", "HEAD").strip(),
            "base": base, "items": items, "blocking": len(blocking), "warn": len(warns),
            "verdict": "PASS" if not blocking else "BLOCKED"}


def apply_answers(doc: dict, answers: dict) -> dict:
    for it in doc["items"]:
        a = answers.get(it["id"])
        if not a:
            continue
        if a.get("answer") == "defer" and a.get("reason"):
            it["status"] = "DEFER"
            it["evidence"] = (it.get("evidence", "") + " | deferred: " + a["reason"])[:600]
        elif a.get("answer") == "yes":
            it["status"] = "PASS"
        elif a.get("answer") == "no":
            it["status"] = "FAIL"
    doc["blocking"] = len([i for i in doc["items"] if i["status"] == "FAIL"])
    doc["defer"] = len([i for i in doc["items"] if i["status"] == "DEFER"])
    doc["verdict"] = "PASS" if doc["blocking"] == 0 else "BLOCKED"
    return doc


def save_answers(answers: dict) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    doc = read_json(STATE, {}) or {}
    doc["updated"] = now_iso()
    doc["answers"] = {**(doc.get("answers") or {}), **answers}
    STATE.write_text(json.dumps(doc, indent=1) + "\n", encoding="utf-8")


def render(doc: dict) -> str:
    lines = ["=== closeout-gate @ %s (rev %s) ===" % (doc["ts"], doc.get("rev") or "?")]
    for it in doc["items"]:
        lines.append("%-5s %-10s %s" % (it["status"], it["id"], it["question"]))
        lines.append("      evidence: " + str(it.get("evidence", ""))[:180])
        if it["status"] in ("FAIL", "WARN", "DEFER"):
            lines.append("      next: " + it.get("next", ""))
    lines.append("verdict: %s (blocking=%d warn=%d)" % (doc["verdict"], doc["blocking"], doc.get("warn", 0)))
    if doc["verdict"] != "PASS":
        lines.append("DO NOT DECLARE COMPLETE. Answer the blocking questions with evidence, or defer with a reason.")
    return "\n".join(lines)


def ask(doc: dict) -> dict:
    answers = {}
    for it in doc["items"]:
        if it["status"] == "PASS":
            continue
        print("\n[%s] %s" % (it["id"], it["question"]))
        print("  evidence: " + str(it.get("evidence", "")))
        print("  next: " + it.get("next", ""))
        try:
            ans = input("  answer [y]es / [n]o / [d]efer, blank = leave: ").strip().lower()
            if ans not in ("y", "n", "d"):
                continue
            reason = ""
            if ans == "d":
                reason = input("  reason (required): ").strip()
                if not reason:
                    print("  deferral needs a reason; left unresolved")
                    continue
            answers[it["id"]] = {"answer": {"y": "yes", "n": "no", "d": "defer"}[ans], "reason": reason}
        except (EOFError, KeyboardInterrupt):
            print("\nno answer; unresolved")
            break
    if answers:
        save_answers(answers)
        apply_answers(doc, answers)
    return doc


def self_test() -> int:
    fail = 0
    # synthetic evidence via evaluate() is environment-heavy; test the decision
    # helpers and answer override deterministically.
    if parse_gate_ts("20261106T131019Z") <= 0:
        print("FAIL gate ts"); fail = 1
    if iso_to_epoch("2026-11-06T15:38:56Z") <= 0:
        print("FAIL guided ts"); fail = 1
    doc = {"ts": now_iso(), "items": [
        {"id": "a", "question": "q", "status": "FAIL", "evidence": "", "next": ""},
        {"id": "b", "question": "q", "status": "WARN", "evidence": "", "next": ""},
    ], "blocking": 1, "warn": 1, "verdict": "BLOCKED"}
    apply_answers(doc, {"a": {"answer": "defer", "reason": "waiting on host"}})
    if doc["verdict"] != "PASS" or doc["items"][0]["status"] != "DEFER":
        print("FAIL defer", doc); fail = 1
    doc2 = json.loads(json.dumps(doc))
    apply_answers(doc2, {"a": {"answer": "yes"}})
    if doc2["items"][0]["status"] != "PASS":
        print("FAIL yes override"); fail = 1
    print("closeout-gate: self-test " + ("PASS" if fail == 0 else "FAIL"))
    return fail


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=BASE_DEFAULT)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--ask", action="store_true")
    ap.add_argument("--answer", default="", help="id=yes|no|defer")
    ap.add_argument("--reason", default="")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if a.answer:
        if "=" not in a.answer:
            print("use --answer id=yes|no|defer", file=sys.stderr)
            return 2
        k, v = a.answer.split("=", 1)
        if v not in ("yes", "no", "defer"):
            print("answer must be yes|no|defer", file=sys.stderr)
            return 2
        if v == "defer" and not a.reason:
            print("defer requires --reason", file=sys.stderr)
            return 2
        save_answers({k.strip(): {"answer": v, "reason": a.reason}})
        print("answer saved: %s=%s" % (k.strip(), v))
    doc = evaluate(a.base.rstrip("/"))
    saved = read_json(STATE, {}) or {}
    if saved.get("answers"):
        doc = apply_answers(doc, saved["answers"])
    if a.ask:
        doc = ask(doc)
    if a.json:
        print(json.dumps(doc, indent=1))
    else:
        print(render(doc))
    return 0 if doc["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
