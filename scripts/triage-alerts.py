#!/usr/bin/env python3
"""triage-alerts.py -- turn the alert sink's pushed ledger FAIL flags into an
actionable, human-readable brief.

The sentinel pushes its FAIL/ADVISORY ledger rows to the self-hosted sink
(scripts/notify-sink.mjs -> data/observability/notify-sink.jsonl). This reads
that JSONL, de-duplicates the flags (the ledger keys are stable, so the same
chronic condition repeats every sweep), classifies each one, and prints severity,
the exact next command, and the runbook that covers it. Plain selectable text.

Usage:
  ./scripts/triage-alerts.py                       # read the sink JSONL
  ./scripts/triage-alerts.py --in FILE             # another sink file
  ./scripts/triage-alerts.py --json                # machine form
  ./scripts/triage-alerts.py --self-test           # offline fixture

No subprocess, no shell; stdlib only. Input is untrusted DATA, never run.
"""
import argparse
import json
import os
import re
import sys

DEFAULT_SINK = "data/observability/notify-sink.jsonl"

# kind -> (severity rank, label, runbook id or None, next-command builder)
SEV = {"high": 0, "medium": 1, "low": 2}


def classify(resource, detail):
    """Return (kind, severity, extra dict) for one ledger flag. Pure regex."""
    rx = re.search(r"handoff-brief\.sh (ses_\w+)", detail)
    sid = rx.group(1) if rx else None
    if not sid:
        m = re.search(r"session/(ses_\w+)", resource)
        sid = m.group(1) if m else None

    if re.search(r"over budget", detail, re.I):
        return "over_budget", "high", {"sid": sid}
    if re.search(r"tool stuck in running|running \d+s", detail, re.I):
        return "stall", "high", {"sid": sid}
    m = re.search(r"slow fetches x(\d+), slowest ([\d.]+)s", detail)
    if m:
        return "slow_fetch", "medium", {"n": int(m.group(1)), "slowest": float(m.group(2))}
    if re.search(r"deny-listed", detail, re.I):
        return "deny_listed", "medium", {"sid": sid}
    if re.search(r"guidance issued", detail, re.I):
        return "guidance", "low", {"sid": sid}
    return "other", "low", {"sid": sid}


NEXT = {
    "over_budget": lambda x: "./scripts/handoff-brief.sh %s" % (x.get("sid") or "<sid>"),
    "stall": lambda x: "./scripts/handoff-brief.sh %s   # inspect first: ./scripts/tui-audit.py" % (x.get("sid") or "<sid>"),
    "slow_fetch": lambda x: "./scripts/host-path-probe.sh   # decompose host->caddy->container for the slow %s" % (x.get("uri") or "endpoint"),
    "deny_listed": lambda x: "./scripts/handoff-brief.sh %s" % (x.get("sid") or "<sid>"),
    "guidance": lambda x: "none (informational)",
    "other": lambda x: "./scripts/logs.sh   # no rule; inspect the ledger row",
}
RUNBOOK = {
    "over_budget": "cost",
    "stall": "ux-trace",
    "slow_fetch": "host-cpu-recovery",
    "deny_listed": "cost",
    "guidance": None,
    "other": "logs",
}


def runbook_title(runbooks, rid):
    if not rid or not runbooks:
        return rid or "-"
    for r in runbooks:
        if r.get("id") == rid:
            return "%s (%s)" % (rid, r.get("title", ""))
    return rid


def load_runbooks(path):
    try:
        d = json.load(open(path))
    except Exception:
        return []
    return d if isinstance(d, list) else d.get("runbooks", [])


def read_flags(path, stream):
    """Yield (resource, detail, ts) from every sink line's body.flags."""
    text = stream.read() if stream else open(path).read()
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        body = obj.get("body", obj)
        for f in body.get("flags", []):
            if not isinstance(f, dict):
                continue
            yield (f.get("resource", "?"), f.get("detail", ""), f.get("ts", ""))


def summarize(recs):
    """recs: iterable of (resource, detail, ts). Dedupe by (resource, detail)."""
    groups = {}
    for resource, detail, ts in recs:
        kind, sev, extra = classify(resource, detail)
        m = re.search(r"\((GET [^)]+|/[^)]*)\)", detail)
        if m:
            extra["uri"] = m.group(1)
        key = (kind, resource, detail)
        g = groups.setdefault(key, {"kind": kind, "sev": sev, "resource": resource,
                                    "detail": detail, "extra": extra,
                                    "count": 0, "first": ts, "last": ts})
        g["count"] += 1
        if ts and (not g["first"] or ts < g["first"]):
            g["first"] = ts
        if ts and (not g["last"] or ts > g["last"]):
            g["last"] = ts
    out = list(groups.values())
    out.sort(key=lambda g: (SEV.get(g["sev"], 3), -g["count"], g["kind"]))
    return out


def render(groups, runbooks, window):
    lines = []
    n_flags = sum(g["count"] for g in groups)
    lines.append("ALERT TRIAGE -- %d distinct alert(s) from %d pushed row(s)" % (len(groups), n_flags))
    if window:
        lines.append("window: %s .. %s" % (window[0], window[1]))
    lines.append("")
    if not groups:
        lines.append("clean: no FAIL flags in the sink.")
        return "\n".join(lines)
    for g in groups:
        lines.append("[%s] %s x%d   last %s" % (g["sev"].upper(), g["kind"], g["count"], g["last"] or "-"))
        lines.append("  resource: %s" % g["resource"])
        lines.append("  detail:   %s" % g["detail"])
        lines.append("  next:     %s" % NEXT.get(g["kind"], NEXT["other"])(g["extra"]))
        lines.append("  runbook:  %s" % runbook_title(runbooks, RUNBOOK.get(g["kind"])))
        lines.append("")
    return "\n".join(lines)


def self_test():
    rx_over = ("session/ses_over1", "non-latest session over budget still being prompted; stop, hand off (./scripts/handoff-brief.sh ses_over1)", "2026-10-16T15:30:46Z")
    rx_slow = ("caddy access log", "slow fetches x32, slowest 44.5s (GET /api/cost)", "2026-10-15T19:16:24Z")
    rx_stall = ("session/ses_stall1", "tool stuck in running (session-health S0); inspect, then hand off (./scripts/handoff-brief.sh ses_stall1)", "2026-10-14T16:36:03Z")
    recs = [rx_over, rx_over, rx_slow, rx_stall]
    groups = summarize(recs)
    kinds = {g["kind"] for g in groups}
    fail = 0
    if kinds != {"over_budget", "slow_fetch", "stall"}:
        print("FAIL: kinds=%s" % sorted(kinds)); fail = 1
    over = [g for g in groups if g["kind"] == "over_budget"][0]
    if over["count"] != 2:
        print("FAIL: dedupe count=%d (want 2)" % over["count"]); fail = 1
    if groups[0]["kind"] != "over_budget":
        print("FAIL: high severity not first (%s)" % groups[0]["kind"]); fail = 1
    slow = [g for g in groups if g["kind"] == "slow_fetch"][0]
    if slow["extra"].get("uri") != "GET /api/cost":
        print("FAIL: uri=%r" % slow["extra"].get("uri")); fail = 1
    body = render(groups, load_runbooks("scripts/runbooks.json"), ("2026-10-14", "2026-10-16"))
    if "handoff-brief.sh ses_over1" not in body or "host-cpu-recovery" not in body:
        print("FAIL: render missing next/runbook"); fail = 1
    # an unknown detail must not crash and must land in 'other'
    g2 = summarize([("weird", "something unprecedented happened", "t")])
    if g2[0]["kind"] != "other":
        print("FAIL: unknown not classified as other"); fail = 1
    # empty sink
    if "clean" not in render(summarize([]), [], None):
        print("FAIL: empty not clean"); fail = 1
    print("triage-alerts: self-test %s" % ("PASS" if not fail else "FAIL"))
    return fail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="infile", default=None)
    ap.add_argument("--sink", default=None)
    ap.add_argument("--runbooks", default="scripts/runbooks.json")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    path = a.infile or a.sink or DEFAULT_SINK
    if path == "-":
        recs = list(read_flags(None, sys.stdin))
    elif os.path.isfile(path):
        recs = list(read_flags(path, None))
    else:
        print("no sink file at %s (nothing pushed yet, or wrong --in)" % path)
        return 0
    groups = summarize(recs)
    runbooks = load_runbooks(a.runbooks)
    ts = [g["first"] for g in groups if g["first"]] + [g["last"] for g in groups if g["last"]]
    window = (min(ts), max(ts)) if ts else None
    if a.json:
        print(json.dumps({"distinct": len(groups),
                          "rows": sum(g["count"] for g in groups),
                          "window": window,
                          "alerts": [{k: g[k] for k in ("kind", "sev", "resource", "detail", "count", "first", "last")} |
                                     {"next": NEXT.get(g["kind"], NEXT["other"])(g["extra"]),
                                      "runbook": RUNBOOK.get(g["kind"])} for g in groups]}, indent=2))
    else:
        print(render(groups, runbooks, window))
    return 0


if __name__ == "__main__":
    sys.exit(main())
