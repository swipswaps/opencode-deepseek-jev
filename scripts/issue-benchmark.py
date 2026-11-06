#!/usr/bin/env python3
"""issue-benchmark.py - one real, repeatable measurement of the issues we
said were handled: security posture, agent stalls, and the external tunnel.

The point is not another green check. It is a HISTORY: every run records the
same named metrics, with the verdict and the evidence path, so a regression
is a number that moved instead of a feeling. The dashboard exposes the same
snapshot at /api/benchmark and draws it in /graph and the home pulse.

Sources (all local, read-only except this script's own observability rows):
  security  scripts/security-posture.sh --offline (optional --run), guard.log
            verdict counts, injection tripwires
  stalls    session-health.mjs --json (optional --run) or health-cache.json,
            over-budget sessions from the same report
  tunnel    newest logs/tunnel-link-*.log (flaps, loss, MTU), ledger evidence

Usage:
  ./scripts/issue-benchmark.py                  # cached sources, human table
  ./scripts/issue-benchmark.py --run            # also run the live probes
  ./scripts/issue-benchmark.py --json
  ./scripts/issue-benchmark.py --history [N]
  ./scripts/issue-benchmark.py --self-test

Exit: 0 all measured areas PASS, 1 an area FAILs, 2 usage/IO error.
A source that cannot be read is SKIP, never PASS (RULES: SKIP != PASS).
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
import tempfile
import time

SCRIPT = "issue-benchmark.py"
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


def run_cmd(cmd: list[str], timeout: int, env=None) -> dict:
    """Bounded probe. Returns rc/out/err/ms; a timeout is named, never hidden."""
    t0 = time.time()
    try:
        p = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            cwd=str(REPO),
        )
        try:
            out, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            out, err = p.communicate()
            return {"rc": 124, "out": out or "", "err": err or "", "ms": int((time.time() - t0) * 1000),
                    "timeout": True, "cmd": " ".join(cmd)}
        return {"rc": p.returncode, "out": out or "", "err": err or "", "ms": int((time.time() - t0) * 1000),
                "timeout": False, "cmd": " ".join(cmd)}
    except Exception as e:
        return {"rc": 127, "out": "", "err": type(e).__name__ + ": " + str(e),
                "ms": int((time.time() - t0) * 1000), "timeout": False, "cmd": " ".join(cmd)}


def parse_status_lines(text: str) -> dict:
    """Count '  PASS  ' / '  FAIL  ' lines from security-posture.sh."""
    passed = failed = 0
    fails = []
    for line in text.splitlines():
        m = re.match(r"\s*(PASS|FAIL)\s+(.*)", line)
        if not m:
            continue
        if m.group(1) == "PASS":
            passed += 1
        else:
            failed += 1
            fails.append(m.group(2).strip()[:180])
    return {"pass": passed, "fail": failed, "fails": fails}


def bench_security(root: pathlib.Path, run: bool) -> tuple[list[dict], list[dict]]:
    metrics, skips = [], []
    script = root / "scripts" / "security-posture.sh"
    if run:
        if script.is_file():
            r = run_cmd(["bash", str(script), "--offline"], timeout=180)
            parsed = parse_status_lines(r["out"])
            total = parsed["pass"] + parsed["fail"]
            verdict = "PASS" if r["rc"] == 0 and parsed["fail"] == 0 and total else "FAIL"
            metrics.append({
                "area": "security", "metric": "posture", "value": parsed["pass"],
                "unit": "checks", "verdict": verdict,
                "detail": "security-posture.sh --offline: %d pass / %d fail in %dms%s" % (
                    parsed["pass"], parsed["fail"], r["ms"],
                    ("; first fail: " + parsed["fails"][0]) if parsed["fails"] else ""),
            })
            metrics.append({
                "area": "security", "metric": "posture_fail", "value": parsed["fail"],
                "unit": "checks", "verdict": "PASS" if parsed["fail"] == 0 else "FAIL",
                "detail": "; ".join(parsed["fails"][:3]) or "no failing posture check",
            })
            if r["timeout"]:
                skips.append({"area": "security", "reason": "security-posture timed out (%dms)" % r["ms"]})
        else:
            skips.append({"area": "security", "reason": "scripts/security-posture.sh missing"})
    else:
        skips.append({"area": "security", "reason": "posture probe not run (use --run); cached evidence only"})

    guard = root / "data" / "observability" / "guard.log"
    counts = {"block": 0, "injection": 0, "learned": 0, "advisory": 0}
    if guard.is_file():
        cutoff = time.time() - 7 * 86400
        n = 0
        for line in guard.read_text(encoding="utf-8", errors="replace").splitlines():
            try:
                row = json.loads(line)
            except Exception:
                continue
            ts = str(row.get("ts", ""))
            try:
                when = dt.datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=dt.timezone.utc).timestamp()
            except Exception:
                when = 0
            if when < cutoff:
                continue
            v = str(row.get("verdict", "")).lower()
            if v in counts:
                counts[v] += 1
                n += 1
        metrics.append({
            "area": "security", "metric": "guard_blocks_7d", "value": counts["block"],
            "unit": "actions", "verdict": "PASS" if counts["injection"] == 0 else "WARN",
            "scored": False,
            "detail": "guard verdicts over 7d: block=%d injection=%d learned=%d advisory=%d (%d rows)" % (
                counts["block"], counts["injection"], counts["learned"], counts["advisory"], n),
        })
        metrics.append({
            "area": "security", "metric": "injection_tripwires_7d", "value": counts["injection"],
            "unit": "events", "verdict": "PASS" if counts["injection"] == 0 else "WARN",
            "scored": False,
            "detail": "prompt-injection tripwires are logged as data; a non-zero count is a residual to review",
        })
    else:
        skips.append({"area": "security", "reason": "guard.log missing"})
    return metrics, skips


def health_from_cache(root: pathlib.Path) -> dict | None:
    doc = read_json(root / "data" / "observability" / "health-cache.json", {})
    if isinstance(doc, dict) and isinstance(doc.get("value"), dict):
        return doc["value"]
    return doc if isinstance(doc, dict) and "counts" in doc else None


def health_live(root: pathlib.Path) -> dict | None:
    script = root / "scripts" / "session-health.mjs"
    db = root / "data" / "opencode" / "opencode.db"
    if not script.is_file() or not db.is_file():
        return None
    r = run_cmd(["node", "--experimental-sqlite", str(script), str(db), "--json"], timeout=90)
    if r["rc"] != 0:
        return None
    try:
        return json.loads(r["out"])
    except Exception:
        return None


def bench_stalls(root: pathlib.Path, run: bool) -> tuple[list[dict], list[dict]]:
    metrics, skips = [], []
    live = health_live(root) if run else None
    health = live or health_from_cache(root)
    source = "session-health.mjs --json (live)" if live else "health-cache.json (last computed report)"
    if not health:
        skips.append({"area": "stalls", "reason": "no session-health report and no live DB"})
        return metrics, skips

    c = health.get("counts") or {}
    running = int(c.get("running_tools", 0) or 0)
    blank = int(c.get("blank_tails", 0) or 0)
    findings_n = int(c.get("findings", len(health.get("findings") or [])) or 0)
    scanned = int(c.get("sessions_scanned", 0) or 0)
    findings = health.get("findings") or []
    running_f = [f for f in findings if f.get("kind") == "running_tool"]
    blank_f = [f for f in findings if f.get("kind") == "blank_tail"]
    dead_after = int(health.get("thresholds", {}).get("dead_after_s", 21600) or 21600)
    fresh_run = [f for f in running_f if int(f.get("age_s", 0) or 0) <= dead_after]
    oldest = max([int(f.get("age_s", 0) or 0) for f in running_f], default=0)
    run_verdict = "PASS" if running == 0 else ("FAIL" if fresh_run else "WARN")
    first = running_f[0] if running_f else {}
    metrics.append({
        "area": "stalls", "metric": "running_tools", "value": running, "unit": "tools",
        "verdict": run_verdict,
        "detail": "%s; %d session(s) scanned; %d fresh (<=%dh) / %d older (offline: not exonerated)%s" % (
            source, scanned, len(fresh_run), dead_after // 3600, running - len(fresh_run),
            ("; oldest %.1fh in %s (%s)" % (oldest / 3600.0, first.get("session", "?"),
             str(first.get("command", "")).splitlines()[0][:70])) if first else ""),
    })
    metrics.append({
        "area": "stalls", "metric": "blank_tails", "value": blank, "unit": "sessions",
        "verdict": "PASS" if blank == 0 else "WARN",
        "detail": "last part is a tool and no text followed (no-answer fingerprint)" +
                  (("; first %s age %ss" % (blank_f[0].get("session", "?"), blank_f[0].get("age_s", "?"))) if blank_f else ""),
    })
    metrics.append({
        "area": "stalls", "metric": "findings", "value": findings_n, "unit": "findings",
        "verdict": "PASS" if findings_n == 0 else "WARN",
        "detail": "session-health findings; inspect with /explore#signals or session-health.mjs",
    })
    risks = health.get("risks") or {}
    over = risks.get("over") or []
    denied = risks.get("denied") or []
    metrics.append({
        "area": "stalls", "metric": "over_budget_sessions", "value": len(over), "unit": "sessions",
        "verdict": "PASS" if len(over) == 0 else "WARN",
        "detail": "over CONTEXT_BUDGET; each turn re-sends its context (handoff, do not --fork)",
    })
    metrics.append({
        "area": "stalls", "metric": "denied_model_sessions", "value": len(denied), "unit": "sessions",
        "verdict": "PASS" if len(denied) == 0 else "WARN",
        "detail": "sessions on a deny-listed/free-tier model from models.policy.json",
    })
    live_doc = health.get("live") or {}
    if live_doc:
        metrics.append({
            "area": "stalls", "metric": "live_status", "value": 1 if live_doc.get("available") else 0,
            "unit": "bool", "verdict": "PASS" if live_doc.get("available") else "SKIP",
            "scored": False,
            "detail": "GET /session/status: " + str(live_doc.get("reason") or "available"),
        })
    return metrics, skips


def parse_tunnel(text: str) -> dict:
    out = {}
    for key in ("teardowns", "NRestarts", "overlay_loss_pct", "mtu_ok", "route_mtu", "tunnel-events"):
        m = re.search(r"\b" + key + r"=([0-9.]+)", text)
        if m:
            out[key] = float(m.group(1)) if "." in m.group(1) else int(m.group(1))
    m = re.search(r"verdict:\s*(.+)", text)
    if m:
        out["verdict_text"] = m.group(1).strip()[:240]
    return out


def bench_tunnel(root: pathlib.Path) -> tuple[list[dict], list[dict]]:
    metrics, skips = [], []
    logs = sorted((root / "logs").glob("tunnel-link-*.log"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not logs:
        skips.append({"area": "tunnel", "reason": "no logs/tunnel-link-*.log evidence"})
        return metrics, skips
    p = logs[0]
    doc = parse_tunnel(p.read_text(encoding="utf-8", errors="replace"))
    flaps = int(doc.get("NRestarts", doc.get("teardowns", 0)) or 0)
    loss = float(doc.get("overlay_loss_pct", 0) or 0)
    mtu = int(doc.get("mtu_ok", 0) or 0)
    metrics.append({
        "area": "tunnel", "metric": "restarts", "value": flaps, "unit": "flaps",
        "verdict": "PASS" if flaps == 0 else "FAIL",
        "detail": "newest evidence %s; %s" % (p.name, doc.get("verdict_text", "")[:140]),
    })
    metrics.append({
        "area": "tunnel", "metric": "overlay_loss_pct", "value": loss, "unit": "percent",
        "verdict": "PASS" if loss == 0 else "WARN",
        "detail": "overlay ping loss from the probe window",
    })
    metrics.append({
        "area": "tunnel", "metric": "mtu_ok", "value": mtu, "unit": "bytes",
        "verdict": "PASS" if mtu >= 1200 else "WARN",
        "detail": "largest DF payload that passed; overlay route MTU=%s" % doc.get("route_mtu", "?"),
    })
    return metrics, skips


def score(metrics: list[dict]) -> dict:
    out = {}
    for area in ("security", "stalls", "tunnel"):
        rows = [m for m in metrics if m["area"] == area
                and m["verdict"] in ("PASS", "FAIL", "WARN") and m.get("scored", True)]
        if not rows:
            out[area] = None
            continue
        good = sum(1 for m in rows if m["verdict"] == "PASS")
        warn = sum(1 for m in rows if m["verdict"] == "WARN")
        final = sum(1 for m in rows if m["verdict"] == "FAIL")
        out[area] = round(100.0 * (good + 0.5 * warn) / len(rows), 1) if rows else None
        out[area + "_n"] = {"pass": good, "warn": warn, "fail": final}
    return out


def ledger_summary(root: pathlib.Path, since_hours: int = 24) -> dict:
    db = root / "data" / "observability" / "observability.db"
    if not db.is_file():
        return {"available": False, "reason": "observability.db missing"}
    cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=since_hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        con = sqlite3.connect("file:" + str(db) + "?mode=ro", uri=True, timeout=3)
        rows = con.execute(
            "SELECT type, verdict, COUNT(*) FROM ledger WHERE ts >= ? GROUP BY type, verdict ORDER BY 3 DESC",
            (cutoff,),
        ).fetchall()
        con.close()
    except Exception as e:
        return {"available": False, "reason": type(e).__name__ + ": " + str(e)}
    return {
        "available": True,
        "window_h": since_hours,
        "rows": [{"type": r[0], "verdict": r[1], "n": r[2]} for r in rows],
        "n": sum(r[2] for r in rows),
    }


def persist(root: pathlib.Path, snap: dict) -> dict:
    db = root / "data" / "observability" / "observability.db"
    saved = {"db": False, "json": False, "error": ""}
    try:
        con = sqlite3.connect(str(db), timeout=5)
        con.execute(
            "CREATE TABLE IF NOT EXISTS issue_bench("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, rev TEXT, area TEXT, "
            "metric TEXT, value REAL, unit TEXT, verdict TEXT, detail TEXT)"
        )
        con.execute("CREATE INDEX IF NOT EXISTS issue_bench_area ON issue_bench(area, id)")
        for m in snap["metrics"]:
            con.execute(
                "INSERT INTO issue_bench(ts,rev,area,metric,value,unit,verdict,detail) VALUES(?,?,?,?,?,?,?,?)",
                (snap["ts"], snap.get("rev", ""), m["area"], m["metric"], float(m["value"]),
                 m["unit"], m["verdict"], m["detail"][:400]),
            )
        con.commit()
        con.close()
        saved["db"] = True
    except Exception as e:
        saved["error"] = type(e).__name__ + ": " + str(e)
    try:
        atomic_write(root / "data" / "observability" / "benchmark.json", json.dumps(snap, indent=1) + "\n")
        saved["json"] = True
    except Exception as e:
        saved["error"] = (saved["error"] + "; " if saved["error"] else "") + "json: " + str(e)
    return saved


def history(root: pathlib.Path, limit: int) -> list[dict]:
    db = root / "data" / "observability" / "observability.db"
    if not db.is_file():
        return []
    try:
        con = sqlite3.connect("file:" + str(db) + "?mode=ro", uri=True, timeout=3)
        rows = con.execute(
            "SELECT ts,rev,area,metric,value,unit,verdict FROM issue_bench ORDER BY id DESC LIMIT ?",
            (limit,),
        ).fetchall()
        con.close()
        return [dict(zip(("ts", "rev", "area", "metric", "value", "unit", "verdict"), r)) for r in rows]
    except Exception:
        return []


def build(root: pathlib.Path, run: bool) -> dict:
    metrics, skips = [], []
    for fn, args in ((bench_security, (root, run)), (bench_stalls, (root, run)), (bench_tunnel, (root,))):
        m, s = fn(*args)
        metrics += m
        skips += s
    rev = ""
    try:
        p = subprocess.Popen(["git", "-C", str(root), "rev-parse", "--short", "HEAD"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        rev, _ = p.communicate(timeout=5)
        rev = rev.strip()
    except Exception:
        rev = ""
    snap = {
        "ts": now_iso(),
        "rev": rev,
        "run": bool(run),
        "metrics": metrics,
        "skips": skips,
        "score": score(metrics),
        "ledger": ledger_summary(root),
    }
    snap["saved"] = persist(root, snap)
    return snap


def human(snap: dict) -> str:
    lines = ["=== issue-benchmark @ %s (rev %s) ===" % (snap["ts"], snap.get("rev") or "?")]
    for area in ("security", "stalls", "tunnel"):
        rows = [m for m in snap["metrics"] if m["area"] == area]
        sc = snap["score"].get(area)
        lines.append("-- %s  score=%s" % (area, "n/a" if sc is None else str(sc)))
        if not rows:
            lines.append("   (no measured metric)")
        for m in rows:
            lines.append("   %-5s %-26s %-10s %s" % (m["verdict"], m["metric"], m["value"], m["detail"]))
    for s in snap["skips"]:
        lines.append("   SKIP  %-26s %s" % (s["area"], s["reason"]))
    led = snap.get("ledger") or {}
    if led.get("available"):
        lines.append("-- ledger (24h): %d rows" % led["n"])
        for r in led["rows"][:6]:
            lines.append("   %-10s %-8s %d" % (r["type"], r["verdict"], r["n"]))
    saved = snap.get("saved") or {}
    if saved.get("error"):
        lines.append("note: persist partial: " + saved["error"])
    return "\n".join(lines)


def self_test() -> int:
    fail = 0
    with tempfile.TemporaryDirectory() as td:
        root = pathlib.Path(td)
        (root / "data" / "observability").mkdir(parents=True)
        (root / "logs").mkdir()
        (root / "scripts").mkdir()
        (root / "data" / "observability" / "health-cache.json").write_text(json.dumps({
            "value": {
                "counts": {"sessions_scanned": 10, "running_tools": 0, "blank_tails": 0, "findings": 0},
                "findings": [], "risks": {"over": [], "denied": []},
                "live": {"available": False, "reason": "no password"},
            }
        }))
        (root / "data" / "observability" / "guard.log").write_text(
            json.dumps({"ts": now_iso(), "verdict": "block", "message": "sed"}) + "\n" +
            json.dumps({"ts": now_iso(), "verdict": "warn", "message": "echo"}) + "\n")
        (root / "logs" / "tunnel-link-20260101T000000Z.log").write_text(
            "  NRestarts=0  teardowns=0\n  overlay_loss_pct=0  mtu_ok=1272  route_mtu=1300\n"
            "  verdict:  NO EVIDENCE in this window\n")
        con = sqlite3.connect(root / "data" / "observability" / "observability.db")
        con.execute("CREATE TABLE ledger(id INTEGER PRIMARY KEY, ts TEXT, type TEXT, verdict TEXT)")
        con.execute("INSERT INTO ledger(ts,type,verdict) VALUES(?,?,?)", (now_iso(), "ADVISORY", "PASS"))
        con.commit()
        con.close()
        snap = build(root, run=False)
        got = {(m["area"], m["metric"]): m for m in snap["metrics"]}
        if got[("stalls", "running_tools")]["verdict"] != "PASS":
            print("FAIL stalls pass"); fail = 1
        if got[("tunnel", "restarts")]["verdict"] != "PASS":
            print("FAIL tunnel clean"); fail = 1
        if got[("security", "guard_blocks_7d")]["value"] != 1:
            print("FAIL guard count"); fail = 1
        if snap["score"]["stalls"] != 100.0:
            print("FAIL stall score", snap["score"]); fail = 1
        if not snap["saved"]["db"] or not snap["saved"]["json"]:
            print("FAIL persist", snap["saved"]); fail = 1
        hist = history(root, 20)
        if not hist:
            print("FAIL history rows"); fail = 1
        # A stall must FAIL, not be silently green.
        (root / "data" / "observability" / "health-cache.json").write_text(json.dumps({
            "value": {"counts": {"sessions_scanned": 10, "running_tools": 2, "blank_tails": 1, "findings": 2},
                      "findings": [
                          {"kind": "running_tool", "session": "s", "tool": "bash", "age_s": 100, "command": "sleep"},
                          {"kind": "blank_tail", "session": "b", "model": "m", "age_s": 200},
                      ],
                      "risks": {"over": [], "denied": []}, "live": {"available": False}}
        }))
        snap2 = build(root, run=False)
        got2 = {(m["area"], m["metric"]): m for m in snap2["metrics"]}
        if got2[("stalls", "running_tools")]["verdict"] != "FAIL":
            print("FAIL stall detection"); fail = 1
    print("issue-benchmark: self-test " + ("PASS" if fail == 0 else "FAIL"))
    return fail


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.environ.get("BENCH_ROOT", str(REPO)))
    ap.add_argument("--run", action="store_true", help="also execute the bounded live probes")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--history", nargs="?", type=int, const=20, default=None)
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    root = pathlib.Path(a.root).resolve()
    if a.history is not None:
        rows = history(root, a.history)
        if a.json:
            print(json.dumps(rows, indent=1))
        else:
            for r in rows:
                print("%s %-8s %-10s %-24s %s %s" % (r["ts"], r["area"], r["verdict"], r["metric"], r["value"], r["unit"]))
        return 0
    snap = build(root, a.run)
    if a.json:
        print(json.dumps(snap, indent=1))
    else:
        print(human(snap))
    return 0 if not any(m["verdict"] == "FAIL" for m in snap["metrics"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
