#!/usr/bin/env python3
"""pulse.py - one screen that answers: what is true, what needs me, what is
happening next. It is the abstraction layer over next-action, the issue
benchmark, and the choice gate; it does not replace them.

  ./scripts/pulse.py                 # human summary + writes pulse.json
  ./scripts/pulse.py --json
  ./scripts/pulse.py --open          # also open the dashboard /graph page
  ./scripts/pulse.py --refresh       # re-run the benchmark probes first
  ./scripts/pulse.py --self-test

No model calls, no network. Read-only except data/observability/pulse.json.
The dashboard serves the same document at /api/pulse.
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
import webbrowser

REPO = pathlib.Path(__file__).resolve().parent.parent


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_json(path: pathlib.Path, default=None):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


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


def run_json(cmd: list[str], timeout: int, env=None):
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, env=env, cwd=str(REPO))
        try:
            out, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            p.communicate()
            return None, "timeout after %ds" % timeout
        try:
            return json.loads(out), ""
        except Exception:
            return None, (err or out or "invalid json")[-300:]
    except Exception as e:
        return None, type(e).__name__ + ": " + str(e)


def build(root: pathlib.Path, refresh: bool) -> dict:
    notes = []
    na, err = run_json(["bash", str(root / "scripts" / "next-action.sh"), "--json"], 40)
    if na is None:
        notes.append("next-action: " + err)

    if refresh:
        b, berr = run_json([sys.executable, str(root / "scripts" / "issue-benchmark.py"), "--run", "--json"], 300)
        if b is None:
            notes.append("benchmark: " + berr)
    else:
        b = read_json(root / "data" / "observability" / "benchmark.json", None)
        if b is None:
            b, berr = run_json([sys.executable, str(root / "scripts" / "issue-benchmark.py"), "--json"], 120)
            if b is None:
                notes.append("benchmark: " + berr)

    ch, cerr = run_json([sys.executable, str(root / "scripts" / "choice-gate.py"), "--json"], 30)
    if ch is None:
        notes.append("choices: " + cerr)
        choices = []
    else:
        choices = ch.get("choices") or []

    us = read_json(root / "data" / "observability" / "usability.json", None) or {}
    gdoc = read_json(root / "data" / "observability" / "usability-guided.json", None) or {}
    guided = (gdoc.get("sessions") or [None])[0]
    metrics = (b or {}).get("metrics") or []
    bench_age_s = None
    try:
        bts = (b or {}).get("ts") or ""
        if bts:
            t0 = dt.datetime.strptime(bts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
            bench_age_s = int((dt.datetime.now(dt.timezone.utc) - t0).total_seconds())
            if bench_age_s > 3600:
                notes.append("benchmark is %dm old; run ./scripts/pulse.py --refresh" % (bench_age_s // 60))
    except Exception:
        bench_age_s = None
    attention = []
    for m in metrics:
        if m.get("verdict") in ("FAIL", "WARN"):
            attention.append({
                "kind": "metric", "area": m.get("area"), "id": m.get("metric"),
                "level": m.get("verdict"), "value": m.get("value"),
                "detail": m.get("detail", ""),
            })
    if guided:
        if guided.get("effectiveness") is not None and guided.get("effectiveness") < 0.9:
            attention.append({"kind": "metric", "area": "usability-guided", "id": "effectiveness",
                              "level": "FAIL", "value": guided.get("effectiveness"),
                              "detail": "guided session %s: %s/%s tasks" % (
                                  guided.get("id"), guided.get("completed"), guided.get("total"))})
        if guided.get("satisfaction_sus") is not None and guided.get("satisfaction_sus") < 68:
            attention.append({"kind": "metric", "area": "usability-guided", "id": "sus",
                              "level": "WARN", "value": guided.get("satisfaction_sus"),
                              "detail": "guided session %s SUS below the 68 average" % guided.get("id")})
    for f in (us.get("failures") or [])[:6]:
        attention.append({
            "kind": "metric", "area": "usability", "id": f.get("axis", "?") + "/" + f.get("metric", "?"),
            "level": "FAIL", "value": 0, "detail": f.get("detail", ""),
        })
    pending = [c for c in choices if not c.get("selected")]
    for c in pending:
        attention.append({
            "kind": "choice", "id": c.get("id"), "level": "DECIDE",
            "question": c.get("question"), "recommended": c.get("recommended"),
            "apply": "./scripts/choice-gate.py --apply %s=%s" % (c.get("id"), c.get("recommended")),
        })

    fails = [m for m in metrics if m.get("verdict") == "FAIL"]
    warns = [m for m in metrics if m.get("verdict") == "WARN"]
    if us.get("verdict") == "FAIL":
        fails = list(fails) + [{"area": "usability", "metric": "run", "value": us.get("fail_count", 0)}]
    if guided and guided.get("effectiveness") is not None and guided.get("effectiveness") < 0.9:
        fails = list(fails) + [{"area": "usability-guided", "metric": "effectiveness",
                                "value": guided.get("effectiveness")}]
    if fails:
        headline = "Attention: %d measured failure(s) - %s" % (
            len(fails), ", ".join("%s=%s" % (m["area"] + "/" + m["metric"], m["value"]) for m in fails[:3]))
    elif warns:
        headline = "Steady with residuals: %d warning(s), %d decision(s) pending" % (len(warns), len(pending))
    else:
        headline = "No measured failure; %d decision(s) pending" % len(pending)

    gate = (na or {}).get("last_gate") or {}
    docs = (na or {}).get("docs") or {}
    nxt = ((na or {}).get("next") or {}).get("text") or ""
    ext = (na or {}).get("external") or []
    tasks = (na or {}).get("tasks") or []

    auto = []
    for c in pending:
        rec = next((o for o in (c.get("options") or []) if o.get("id") == c.get("recommended")), {})
        if rec.get("auto"):
            auto.append({"choice": c.get("id"), "option": rec.get("id"),
                         "command": "./scripts/choice-gate.py --apply %s=%s" % (c.get("id"), rec.get("id"))})
    if nxt:
        auto.append({"choice": "queue", "option": "next-unit", "command": nxt[:240]})
    if ext:
        auto.append({"choice": "external", "option": "poll",
                     "command": "./scripts/issue-bridge.py poll --repo %s --number %s --gh" % (
                         ext[0].get("resource", "?").split("#")[0], ext[0].get("resource", "?").split("#")[-1])})

    return {
        "ts": now_iso(),
        "rev": (na or {}).get("rev", ""),
        "headline": headline,
        "gate": gate,
        "docs": docs,
        "since_gate": (na or {}).get("since_gate") or {},
        "next": nxt,
        "external": ext,
        "tasks": tasks,
        "blockers": (na or {}).get("blockers") or [],
        "scores": (b or {}).get("score") or {},
        "guided": {
            "id": guided.get("id"), "ts": guided.get("ts"), "participant": guided.get("participant"),
            "effectiveness": guided.get("effectiveness"), "efficiency_s": guided.get("efficiency_s"),
            "satisfaction_sus": guided.get("satisfaction_sus"),
            "completed": guided.get("completed"), "total": guided.get("total"),
        } if guided else None,
        "usability": {
            "verdict": us.get("verdict"), "mode": us.get("mode"), "ts": us.get("ts"),
            "effectiveness": us.get("effectiveness"), "efficiency_s": us.get("efficiency_s"),
            "satisfaction_sus": us.get("satisfaction_sus"),
            "fail_count": us.get("fail_count"), "skip_count": us.get("skip_count"),
            "axes": us.get("axes") or {}, "caveat": us.get("caveat") or "",
        } if us else None,
        "benchmark_ts": (b or {}).get("ts"),
        "benchmark_age_s": bench_age_s,
        "metrics": metrics,
        "skips": (b or {}).get("skips") or [],
        "attention": attention,
        "pending_choices": len(pending),
        "next_auto": auto,
        "links": {
            "dashboard": "http://127.0.0.1:5099/",
            "graph": "http://127.0.0.1:5099/graph",
            "explore": "http://127.0.0.1:5099/explore",
        },
        "notes": notes,
    }


def human(p: dict) -> str:
    g = p.get("gate") or {}
    d = p.get("docs") or {}
    lines = [
        "=== PROJECT PULSE @ %s ===" % p["ts"],
        "rev %s   gate %s/%s   docs %s/%s   ahead? see since-gate" % (
            p.get("rev") or "?", g.get("passed", "?"), g.get("failed", "?"),
            d.get("tier1_tokens", "?"), d.get("budget", "?")),
        "HEADLINE: " + p.get("headline", ""),
    ]
    sc = p.get("scores") or {}
    if sc:
        parts = []
        for area in ("security", "stalls", "tunnel"):
            if sc.get(area) is not None:
                parts.append("%s=%s" % (area, sc[area]))
        if parts:
            lines.append("SCORES: " + "  ".join(parts))
    us = p.get("usability") or {}
    if us:
        eff = us.get("efficiency_s")
        lines.append("USABILITY: %s (mode=%s, effectiveness=%s, efficiency=%s, failures=%s) %s" % (
            us.get("verdict"), us.get("mode"),
            "n/a" if us.get("effectiveness") is None else us.get("effectiveness"),
            "n/a" if eff is None else str(eff) + "s",
            us.get("fail_count"), (us.get("ts") or "")))
    gd = p.get("guided") or {}
    if gd:
        lines.append("GUIDED: session %s (%s) effectiveness=%s efficiency=%s SUS=%s" % (
            gd.get("id"), gd.get("ts"), gd.get("effectiveness"),
            "n/a" if gd.get("efficiency_s") is None else str(gd.get("efficiency_s")) + "s",
            "n/a" if gd.get("satisfaction_sus") is None else gd.get("satisfaction_sus")))
    nxt = p.get("next")
    if nxt:
        lines.append("NEXT UNIT: " + nxt[:220])
    att = p.get("attention") or []
    if att:
        lines.append("-- needs attention (%d) --" % len(att))
        for a in att[:8]:
            if a["kind"] == "choice":
                lines.append("  DECIDE %-22s %s" % (a["id"], a.get("question")))
                lines.append("         recommended: %s -> %s" % (a.get("recommended"), a.get("apply")))
            else:
                lines.append("  %-5s %-22s %s" % (a.get("level"), a.get("id"), a.get("detail", "")[:120]))
    auto = p.get("next_auto") or []
    if auto:
        lines.append("-- next automatic --")
        for a in auto[:5]:
            lines.append("  %s" % a.get("command"))
    for n in p.get("notes") or []:
        lines.append("note: " + n)
    return "\n".join(lines)


def self_test() -> int:
    fail = 0
    with tempfile.TemporaryDirectory() as td:
        root = pathlib.Path(td)
        (root / "scripts").mkdir()
        (root / "data" / "observability").mkdir(parents=True)
        (root / "scripts" / "next-action.sh").write_text(
            "printf '%s' '{\"rev\":\"abc123\",\"last_gate\":{\"passed\":4,\"failed\":0},"
            "\"docs\":{\"tier1_tokens\":1,\"budget\":2},\"next\":{\"text\":\"unit\"},"
            "\"external\":[],\"tasks\":[],\"blockers\":[]}'\n")
        (root / "data" / "observability" / "benchmark.json").write_text(json.dumps({
            "metrics": [{"area": "stalls", "metric": "running_tools", "value": 2, "verdict": "FAIL", "detail": "x"}],
            "score": {"stalls": 0.0}, "skips": []}))
        (root / "scripts" / "choice-gate.py").write_text(
            "import json,sys\nprint(json.dumps({'choices':[{'id':'c','question':'q','recommended':'go',"
            "'selected':None,'options':[{'id':'go','auto':True}]}]}))\n")
        p = build(root, refresh=False)
        if p["rev"] != "abc123":
            print("FAIL rev"); fail = 1
        if not p["attention"]:
            print("FAIL attention"); fail = 1
        if p["pending_choices"] != 1:
            print("FAIL pending"); fail = 1
        if "Attention" not in p["headline"]:
            print("FAIL headline", p["headline"]); fail = 1
        path = root / "data" / "observability" / "pulse.json"
        atomic_write(path, json.dumps(p, indent=1) + "\n")
        if not path.is_file():
            print("FAIL pulse not written"); fail = 1
    print("pulse: self-test " + ("PASS" if fail == 0 else "FAIL"))
    return fail


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.environ.get("PULSE_ROOT", str(REPO)))
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--refresh", action="store_true")
    ap.add_argument("--open", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    root = pathlib.Path(a.root).resolve()
    p = build(root, a.refresh)
    try:
        atomic_write(root / "data" / "observability" / "pulse.json", json.dumps(p, indent=1) + "\n")
    except Exception as e:
        p.setdefault("notes", []).append("pulse.json: " + type(e).__name__ + ": " + str(e))
    if a.json:
        print(json.dumps(p, indent=1))
    else:
        print(human(p))
    if a.open:
        try:
            webbrowser.open(p["links"]["graph"])
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
