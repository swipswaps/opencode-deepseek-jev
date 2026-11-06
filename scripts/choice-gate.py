#!/usr/bin/env python3
"""choice-gate.py - turn a blocking human decision into an explicit choice.

Most turns that looked like they needed a person only needed a decision:
revoke now or later, open the tabs or print them, accept a residual or rescan.
This script makes those decisions first-class and auditable:

  - every choice has a recommended option and the reason it exists
  - script/auto options can be executed here (bounded, local)
  - human options print the exact commands; selecting one records the intent
  - the selection (id, option, ts, note) persists in data/observability/choices.json
    and one DECISION row goes to the ledger

Usage:
  ./scripts/choice-gate.py                 # pending choices + buttons
  ./scripts/choice-gate.py --all           # include decided choices
  ./scripts/choice-gate.py --json
  ./scripts/choice-gate.py --apply browser-tabs=open-tabs
  ./scripts/choice-gate.py --apply chat-db-residual=rescan --note "..."
  ./scripts/choice-gate.py --auto          # apply every auto option not yet decided
  ./scripts/choice-gate.py --self-test

Never edits the session store. No model calls. No network.
Exit 0 ok, 1 a chosen script failed, 2 usage/config error.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import pathlib
import subprocess
import sys
import tempfile

SCRIPT = "choice-gate.py"
REPO = pathlib.Path(__file__).resolve().parent.parent
CONFIG = REPO / "scripts" / "choices.json"
STATE = REPO / "data" / "observability" / "choices.json"
ENABLE_LEDGER = True


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load(path: pathlib.Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save(path: pathlib.Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(doc, f, indent=1)
            f.write("\n")
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def ledger(choice_id: str, option: str, note: str) -> None:
    if not ENABLE_LEDGER:
        return
    script = REPO / "scripts" / "ledger.py"
    if not script.is_file():
        return
    cmd = [sys.executable, str(script), "record", "--type", "DECISION",
           "--actor", "choice-gate", "--tool", "choice-gate",
           "--resource", "choice/" + choice_id, "--verdict", option,
           "--detail", (note or ("selected " + option))[:300],
           "--source", "choice-gate", "--key", "choice-%s-%s-%s" % (choice_id, option, now_iso())]
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=str(REPO))
        p.communicate(timeout=10)
    except Exception:
        return


def run_commands(commands: list[str], timeout: int = 120) -> list[dict]:
    out = []
    for c in commands:
        try:
            p = subprocess.Popen(c, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True, cwd=str(REPO))
            try:
                so, se = p.communicate(timeout=timeout)
                rc = p.returncode
                timed = False
            except subprocess.TimeoutExpired:
                p.kill()
                so, se = p.communicate()
                rc, timed = 124, True
            out.append({"command": c, "rc": rc, "timeout": timed,
                        "out": so[-2000:], "err": se[-1000:]})
        except Exception as e:
            out.append({"command": c, "rc": 127, "timeout": False, "out": "",
                        "err": type(e).__name__ + ": " + str(e)})
    return out


def option_of(choice: dict, oid: str) -> dict | None:
    for o in choice.get("options", []):
        if o.get("id") == oid:
            return o
    return None


def apply_choice(cfg: dict, state: dict, cid: str, oid: str, note: str, execute: bool) -> dict:
    choice = next((c for c in cfg.get("choices", []) if c.get("id") == cid), None)
    if not choice:
        return {"ok": False, "error": "unknown choice: " + cid}
    opt = option_of(choice, oid)
    if not opt:
        return {"ok": False, "error": "unknown option %s for %s" % (oid, cid)}
    kind = opt.get("kind", "human")
    commands = opt.get("commands") or []
    result = {"ok": True, "id": cid, "option": oid, "label": opt.get("label"),
              "kind": kind, "commands": commands, "ran": []}
    if execute and kind in ("script", "accept", "defer") and commands and opt.get("auto"):
        result["ran"] = run_commands(commands)
        result["ok"] = all(r["rc"] == 0 for r in result["ran"])
    elif execute and kind == "human":
        result["instruction"] = "run the printed command(s) yourself; the decision is still recorded"
    status = {"script": "done", "accept": "accepted", "defer": "deferred"}.get(kind, "pending-human")
    state.setdefault("choices", {})[cid] = {
        "selected": oid, "label": opt.get("label"), "status": status,
        "at": now_iso(), "note": note or "",
    }
    state["updated"] = now_iso()
    state["version"] = 1
    save(STATE, state)
    ledger(cid, oid, note)
    return result


def pending(cfg: dict, state: dict) -> list[dict]:
    decided = state.get("choices") or {}
    out = []
    for c in cfg.get("choices", []):
        rec = decided.get(c.get("id")) or {}
        out.append({
            "id": c.get("id"),
            "question": c.get("question"),
            "why": c.get("why"),
            "recommended": c.get("recommended"),
            "selected": rec.get("selected"),
            "status": rec.get("status", "pending"),
            "at": rec.get("at"),
            "options": c.get("options", []),
        })
    return out


def render(rows: list[dict], show_all: bool) -> str:
    lines = ["=== choice-gate ==="]
    n = 0
    for r in rows:
        if not show_all and r.get("selected"):
            continue
        n += 1
        lines.append("[%s] %s" % (r["id"], r.get("question")))
        lines.append("     why: %s" % r.get("why"))
        lines.append("     recommended: %s" % r.get("recommended"))
        for o in r.get("options", []):
            mark = "*" if o.get("id") == r.get("recommended") else " "
            auto = " (auto)" if o.get("auto") else ""
            lines.append("       %s %-12s %s%s" % (mark, o.get("id"), o.get("label"), auto))
            for cmd in o.get("commands") or []:
                lines.append("           $ %s" % cmd)
        if r.get("selected"):
            lines.append("     decided: %s at %s (%s)" % (r["selected"], r.get("at"), r.get("status")))
        lines.append("     apply: ./scripts/choice-gate.py --apply %s=<option>" % r["id"])
        lines.append("")
    if n == 0:
        lines.append("(nothing pending)")
    return "\n".join(lines)


def self_test() -> int:
    global CONFIG, STATE, ENABLE_LEDGER
    fail = 0
    with tempfile.TemporaryDirectory() as td:
        root = pathlib.Path(td)
        cfgp = root / "choices.json"
        cfgp.write_text(json.dumps({
            "choices": [{
                "id": "x", "question": "q", "why": "w", "recommended": "go",
                "options": [
                    {"id": "go", "label": "run", "kind": "script", "auto": True,
                     "commands": ["printf ok"]},
                    {"id": "human", "label": "do it", "kind": "human", "commands": ["printf manual"]},
                ],
            }]
        }))
        old_c, old_s, old_l = CONFIG, STATE, ENABLE_LEDGER
        CONFIG, STATE, ENABLE_LEDGER = cfgp, root / "state.json", False
        cfg = load(CONFIG)
        st = {}
        r = apply_choice(cfg, st, "x", "go", "test", execute=True)
        if not r["ok"] or not r["ran"] or r["ran"][0]["rc"] != 0:
            print("FAIL script option"); fail = 1
        if (load(STATE).get("choices") or {}).get("x", {}).get("selected") != "go":
            print("FAIL state persisted"); fail = 1
        r2 = apply_choice(cfg, load(STATE), "x", "human", "manual", execute=True)
        if not r2["ok"] or r2.get("ran"):
            print("FAIL human option must not auto-run"); fail = 1
        rows = pending(cfg, load(STATE))
        if rows[0]["status"] != "pending-human":
            print("FAIL pending status", rows); fail = 1
        CONFIG, STATE, ENABLE_LEDGER = old_c, old_s, old_l
    print("choice-gate: self-test " + ("PASS" if fail == 0 else "FAIL"))
    return fail


def main() -> int:
    global CONFIG, STATE
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=str(CONFIG))
    ap.add_argument("--state", default=str(STATE))
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--apply", default="")
    ap.add_argument("--note", default="")
    ap.add_argument("--auto", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()

    CONFIG, STATE = pathlib.Path(a.config), pathlib.Path(a.state)
    cfg = load(CONFIG)
    if not cfg.get("choices"):
        print("choice-gate: cannot read choices from " + str(CONFIG), file=sys.stderr)
        return 2
    state = load(STATE)

    if a.apply:
        if "=" not in a.apply:
            print("use --apply <choice>=<option>", file=sys.stderr)
            return 2
        cid, oid = a.apply.split("=", 1)
        res = apply_choice(cfg, state, cid.strip(), oid.strip(), a.note, execute=True)
        if a.json:
            print(json.dumps(res, indent=1))
        else:
            print(json.dumps(res, indent=1))
        return 0 if res.get("ok") else 1

    if a.auto:
        results = []
        decided = state.get("choices") or {}
        for c in cfg.get("choices", []):
            if c.get("id") in decided:
                continue
            oid = c.get("recommended")
            opt = option_of(c, oid) or {}
            if opt.get("auto"):
                results.append(apply_choice(cfg, state, c["id"], oid, "auto", execute=True))
        if a.json:
            print(json.dumps(results, indent=1))
        else:
            for r in results:
                print("%-24s %-12s %s" % (r.get("id"), r.get("option"), "ok" if r.get("ok") else "FAILED"))
            if not results:
                print("(no auto-eligible pending choices)")
        return 0 if all(r.get("ok") for r in results) else 1

    rows = pending(cfg, state)
    if a.json:
        print(json.dumps({"updated": state.get("updated"), "choices": rows}, indent=1))
    else:
        print(render(rows, a.all))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
