#!/usr/bin/env python3
"""triage-alerts.py -- turn the alert sink's pushed ledger FAIL flags into an
actionable, human-readable brief.

The sentinel records FAIL/ADVISORY rows in the DURABLE ledger
(data/observability/observability.db) and also pushes them to a delivery log
(the self-hosted sink, scripts/notify-sink.mjs -> notify-sink.jsonl). This reads
the DURABLE ledger first -- the source of truth -- so an alert that failed to
POST is still triaged; --in reads the delivery log instead. It de-duplicates the
stable-key rows (one chronic condition = one row per sweep), classifies each, and
prints severity, the exact next command, and the runbook. Plain selectable text.

Usage:
  ./scripts/triage-alerts.py                       # DURABLE ledger (source of truth)
  ./scripts/triage-alerts.py --in FILE             # a delivery-log (sink) file
  ./scripts/triage-alerts.py --ledger DB --last N  # another ledger
  ./scripts/triage-alerts.py --out FILE            # also write the brief (durable)
  ./scripts/triage-alerts.py --json                # machine form
  ./scripts/triage-alerts.py --self-test           # offline fixture

No subprocess, no shell; stdlib only. Input is untrusted DATA, never run.
"""
import argparse
import json
import os
import re
import sqlite3
import sys

DEFAULT_SINK = "data/observability/notify-sink.jsonl"
# The DURABLE source of truth (pi-durable: "a new process opens the same storage
# and continues"). The sink is only the *delivery log*; a dropped POST would
# silently lose an alert, so triage reads the ledger first.
DEFAULT_LEDGER = "data/observability/observability.db"

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
    if re.search(r"tunnel flap", detail, re.I):
        m = re.search(r"nebula/tunnel/(\S+)", resource)
        return "tunnel_flap", "medium", {"peer": m.group(1) if m else "?"}
    if re.search(r"guidance issued", detail, re.I):
        return "guidance", "low", {"sid": sid}
    return "other", "low", {"sid": sid}


NEXT = {
    "over_budget": lambda x: "./scripts/handoff-brief.sh %s" % (x.get("sid") or "<sid>"),
    "stall": lambda x: "./scripts/handoff-brief.sh %s   # inspect first: ./scripts/tui-audit.py" % (x.get("sid") or "<sid>"),
    "slow_fetch": lambda x: "./scripts/host-path-probe.sh   # decompose host->caddy->container for the slow %s" % (x.get("uri") or "endpoint"),
    "deny_listed": lambda x: "./scripts/handoff-brief.sh %s" % (x.get("sid") or "<sid>"),
    "tunnel_flap": lambda x: "./scripts/nebula-systemd-override.sh --diagnose   # classify + count the flap to %s" % (x.get("peer") or "peer"),
    "guidance": lambda x: "none (informational)",
    "other": lambda x: "./scripts/logs.sh   # no rule; inspect the ledger row",
}
RUNBOOK = {
    "over_budget": "cost",
    "stall": "ux-trace",
    "slow_fetch": "slow-fetch",
    "deny_listed": "cost",
    "tunnel_flap": "tunnel-flap",
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


def read_ledger(path, limit):
    """Yield (resource, detail, ts) from the DURABLE ledger (source of truth).

    Same rows notify.sh pushes, but read from storage rather than the delivery
    log -- so an alert that failed to POST is still triaged. Read-only.
    """
    con = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    try:
        rows = list(con.execute(
            "SELECT ts,resource,detail FROM ledger WHERE type='ADVISORY' "
            "AND verdict='FAIL' ORDER BY ts DESC LIMIT ?", (limit,)))
    except sqlite3.Error:
        rows = []
    finally:
        con.close()
    for ts, resource, detail in rows:
        yield (resource or "?", detail or "", ts or "")


def summarize(recs):
    """recs: iterable of (resource, detail, ts). Dedupe by a stable identity.

    The identity must be the *condition*, not the exact text: a chronic
    slow-fetch to one endpoint repeats with a slightly different `slowest` each
    time, so keying on `detail` never collapses it (the live 2026-10-17 ledger:
    130 distinct alerts from 200 rows, nearly all GET /provider). So
    slow_fetch groups by URI and tunnel_flap by resource; everything else keeps
    the full (kind, resource, detail) identity.
    """
    groups = {}
    for resource, detail, ts in recs:
        kind, sev, extra = classify(resource, detail)
        m = re.search(r"\((GET [^)]+|/[^)]*)\)", detail)
        if m:
            extra["uri"] = m.group(1)
        if kind == "slow_fetch" and extra.get("uri"):
            key = (kind, extra["uri"])
        elif kind == "tunnel_flap":
            key = (kind, resource)
        else:
            key = (kind, resource, detail)
        g = groups.setdefault(key, {"kind": kind, "sev": sev, "resource": resource,
                                    "detail": detail, "extra": extra,
                                    "count": 0, "first": ts, "last": ts})
        g["count"] += 1
        if kind == "slow_fetch":
            mm = re.search(r"slowest ([\d.]+)s", detail)
            if mm:
                g["extra"]["slowest_max"] = max(g["extra"].get("slowest_max", 0.0),
                                                float(mm.group(1)))
        if ts and (not g["first"] or ts < g["first"]):
            g["first"] = ts
        if ts and (not g["last"] or ts > g["last"]):
            g["last"] = ts
    out = list(groups.values())
    # A merged slow_fetch row keeps the worst case, not the first row's seconds.
    for g in out:
        if g["kind"] == "slow_fetch":
            g["detail"] = "%d slow-fetch row(s) to %s (slowest %.1fs)" % (
                g["count"], g["extra"].get("uri", "?"), g["extra"].get("slowest_max", 0.0))
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
    if "handoff-brief.sh ses_over1" not in body or "slow-fetch" not in body:
        print("FAIL: render missing next/runbook"); fail = 1
    # an unknown detail must not crash and must land in 'other'
    g2 = summarize([("weird", "something unprecedented happened", "t")])
    if g2[0]["kind"] != "other":
        print("FAIL: unknown not classified as other"); fail = 1
    # T8 tunnel-flap: names the peer + points at the classifier/runbook
    tf = summarize([("nebula/tunnel/10.100.0.1",
                     "tunnel flap: 6 teardown/re-handshake event(s); nebula process healthy (not a restart) — fix the peer/lighthouse link",
                     "t")])
    if tf[0]["kind"] != "tunnel_flap" or tf[0]["extra"].get("peer") != "10.100.0.1":
        print("FAIL: tunnel_flap classify (%r)" % tf); fail = 1
    if not any(r.get("id") == "tunnel-flap" for r in load_runbooks("scripts/runbooks.json")):
        print("FAIL: tunnel-flap runbook missing"); fail = 1
    # chronic slow-fetch de-dupes by URI, not by the varying `slowest` seconds
    # (the live 2026-10-17 ledger: 130 distinct alerts, nearly all GET /provider).
    sf = summarize([
        ("caddy access log", "slow fetches x7, slowest 29.2s (GET /provider)", "t1"),
        ("caddy access log", "slow fetches x8, slowest 137.0s (GET /provider)", "t2"),
        ("caddy access log", "slow fetches x5, slowest 30.0s (GET /api/cost)", "t3"),
    ])
    sfp = [g for g in sf if g["extra"].get("uri") == "GET /provider"]
    if len(sf) != 2 or not sfp or sfp[0]["count"] != 2:
        print("FAIL: slow_fetch not grouped by uri (%r)"
              % [(g["kind"], g["extra"].get("uri"), g["count"]) for g in sf])
        fail = 1
    # empty sink
    if "clean" not in render(summarize([]), [], None):
        print("FAIL: empty not clean"); fail = 1
    # durable ledger reader (source of truth), independent of the delivery log
    import tempfile
    d = tempfile.mkdtemp()
    lp = os.path.join(d, "o.db")
    c = sqlite3.connect(lp)
    c.execute("CREATE TABLE ledger(id INTEGER PRIMARY KEY, ts TEXT, resource TEXT, "
              "detail TEXT, type TEXT, verdict TEXT)")
    c.execute("INSERT INTO ledger(ts,resource,detail,type,verdict) VALUES"
              "('2026-01-01T00:00:00Z','caddy access log',"
              "'slow fetches x5, slowest 20.0s (GET /provider)','ADVISORY','FAIL')")
    c.commit(); c.close()
    lrecs = list(read_ledger(lp, 10))
    if len(lrecs) != 1 or "slow fetches" not in lrecs[0][1]:
        print("FAIL: read_ledger (%r)" % lrecs); fail = 1
    print("triage-alerts: self-test %s" % ("PASS" if not fail else "FAIL"))
    return fail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="infile", default=None)
    ap.add_argument("--sink", default=None)
    ap.add_argument("--ledger", default=None)
    ap.add_argument("--last", type=int, default=200)
    ap.add_argument("--runbooks", default="scripts/runbooks.json")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--out", default=None)
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if a.infile or a.sink:
        path = a.infile or a.sink
        if path == "-":
            recs = list(read_flags(None, sys.stdin))
        elif os.path.isfile(path):
            recs = list(read_flags(path, None))
        else:
            print("no sink file at %s (nothing pushed yet, or wrong --in)" % path)
            return 0
    else:
        led = a.ledger or DEFAULT_LEDGER
        if os.path.isfile(led):
            recs = list(read_ledger(led, a.last))
        elif os.path.isfile(DEFAULT_SINK):
            recs = list(read_flags(DEFAULT_SINK, None))
        else:
            print("no ledger (%s) or sink (%s) found" % (led, DEFAULT_SINK))
            return 0
    groups = summarize(recs)
    runbooks = load_runbooks(a.runbooks)
    ts = [g["first"] for g in groups if g["first"]] + [g["last"] for g in groups if g["last"]]
    window = (min(ts), max(ts)) if ts else None
    human = render(groups, runbooks, window)
    if a.out:
        d = os.path.dirname(a.out)
        if d:
            os.makedirs(d, exist_ok=True)
        open(a.out, "w").write(human + "\n")
        print("wrote %s" % a.out)
    if a.json:
        print(json.dumps({"distinct": len(groups),
                          "rows": sum(g["count"] for g in groups),
                          "window": window,
                          "alerts": [{k: g[k] for k in ("kind", "sev", "resource", "detail", "count", "first", "last")} |
                                     {"next": NEXT.get(g["kind"], NEXT["other"])(g["extra"]),
                                      "runbook": RUNBOOK.get(g["kind"])} for g in groups]}, indent=2))
    else:
        print(human)
    return 0


if __name__ == "__main__":
    sys.exit(main())
