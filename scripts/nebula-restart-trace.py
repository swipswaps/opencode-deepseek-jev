#!/usr/bin/env python3
"""nebula-restart-trace.py -- name WHAT issues the external nebula restarts.

Read-only. Sends no signals and kills nothing. Another project's supervisor
restarts nebula (3 PIDs / 10 min observed) and systemd never counts it, so the
only way to name the restarter is the process parent chain: for every nebula
process read /proc/<pid>/stat (ppid) and the parent's comm + cmdline. A parent
that is not PID 1 (systemd/init) is the restarter -- fix the parent, not the
restarts.

  nebula-restart-trace.py                 # one snapshot + verdict
  nebula-restart-trace.py --watch 60      # sample 60s, report births + parents
  nebula-restart-trace.py --interval 1    # sample spacing for --watch
  nebula-restart-trace.py --json          # machine-readable snapshot
  nebula-restart-trace.py --proc-root DIR # seam for the offline self-test
  nebula-restart-trace.py --self-test     # offline fixture, no real /proc

Plain ASCII. No model call. Never writes. Host or container.
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

PROC = Path("/proc")
CLOCK = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100


def read_text(path, limit=8192):
    try:
        with open(path, "rb") as fh:
            return fh.read(limit).decode("utf-8", "replace")
    except OSError:
        return ""


def cmdline(proc_root, pid):
    raw = read_text(proc_root / str(pid) / "cmdline")
    parts = [p for p in raw.split("\x00") if p]
    return " ".join(parts)


def parse_stat(text):
    """Parse /proc/<pid>/stat without trusting comm (may hold spaces/parens)."""
    head, _, tail = text.rpartition(")")
    pid_field = head.split("(", 1)[0].strip()
    comm = head.split("(", 1)[1] if "(" in head else ""
    rest = tail.split()
    try:
        ppid = int(rest[1])
    except (IndexError, ValueError):
        ppid = -1
    try:
        starttime = int(rest[19])
    except (IndexError, ValueError):
        starttime = -1
    return {"pid": int(pid_field) if pid_field.isdigit() else -1,
            "comm": comm, "ppid": ppid, "starttime": starttime}


def boot_time(proc_root):
    for line in read_text(proc_root / "stat").splitlines():
        if line.startswith("btime "):
            try:
                return int(line.split()[1])
            except (IndexError, ValueError):
                return None
    return None


def read_proc(proc_root, pid):
    stat = parse_stat(read_text(proc_root / str(pid) / "stat"))
    comm = read_text(proc_root / str(pid) / "comm").strip() or stat["comm"]
    stat["comm"] = comm
    stat["cmdline"] = cmdline(proc_root, pid)
    return stat


def all_pids(proc_root):
    out = []
    try:
        entries = list(os.scandir(proc_root))
    except OSError:
        return out
    for ent in entries:
        if ent.name.isdigit() and ent.is_dir():
            out.append(int(ent.name))
    return out


def is_nebula(proc):
    exe = os.path.basename((proc["cmdline"].split(" ") or [""])[0])
    return proc["comm"] == "nebula" or exe == "nebula"


def classify_parent(proc_root, ppid, boot):
    if ppid <= 0:
        return {"pid": ppid, "comm": "?", "cmdline": "", "owner": "unknown"}
    par = read_proc(proc_root, ppid)
    owner = "systemd" if ppid == 1 or par["comm"] in ("systemd", "init") else "external"
    return {"pid": ppid, "comm": par["comm"], "cmdline": par["cmdline"], "owner": owner}


def snapshot(proc_root):
    boot = boot_time(proc_root)
    now = time.time()
    rows = []
    for pid in all_pids(proc_root):
        proc = read_proc(proc_root, pid)
        if not is_nebula(proc):
            continue
        parent = classify_parent(proc_root, proc["ppid"], boot)
        start = None
        elapsed = None
        if boot is not None and proc["starttime"] >= 0:
            start = boot + proc["starttime"] / CLOCK
            elapsed = round(now - start, 1)
        rows.append({
            "pid": proc["pid"],
            "comm": proc["comm"],
            "cmdline": proc["cmdline"],
            "ppid": proc["ppid"],
            "parent_comm": parent["comm"],
            "parent_cmdline": parent["cmdline"],
            "owner": parent["owner"],
            "start_epoch": None if start is None else round(start, 1),
            "elapsed_s": elapsed,
        })
    rows.sort(key=lambda r: r["pid"])
    return {"boot_epoch": boot, "nebula": rows, "verdict": verdict(rows)}


def verdict(rows):
    if not rows:
        return {"code": "none", "text": "no nebula process running"}
    external = [r for r in rows if r["owner"] == "external"]
    if external:
        named = []
        for r in external:
            label = "%s(pid %d)" % (r["parent_comm"] or "?", r["ppid"])
            if label not in named:
                named.append(label)
        return {"code": "external",
                "text": "external supervisor restarts nebula: " + ", ".join(named)
                        + " -- this is the restarter, NOT systemd"}
    return {"code": "systemd",
            "text": "all nebula parents are PID 1 -- systemd owns it "
                    "(check: systemctl show nebula -p NRestarts; journalctl -u nebula)"}


def print_snapshot(snap):
    print("=== nebula-restart-trace ===")
    rows = snap["nebula"]
    if not rows:
        print("no nebula process found in /proc")
    for r in rows:
        age = "?" if r["elapsed_s"] is None else "%ss" % r["elapsed_s"]
        print("pid %-7d up=%-8s ppid=%-6d parent=%-10s owner=%s"
              % (r["pid"], age, r["ppid"], r["parent_comm"] or "?", r["owner"]))
        if r["parent_cmdline"]:
            print("    parent cmd: %s" % r["parent_cmdline"])
        if r["cmdline"]:
            print("    nebula cmd: %s" % r["cmdline"])
    print("verdict: %s" % snap["verdict"]["text"])


def watch(proc_root, seconds, interval, as_json):
    if as_json:
        print(json.dumps({"mode": "watch", "seconds": seconds,
                          "interval": interval, "events": []}, indent=2))
        return 0
    print("watching nebula births for %ss (every %ss) -- read-only, no signals"
          % (seconds, interval))
    seen = {}
    births = []
    t0 = time.time()
    while time.time() - t0 < seconds:
        snap = snapshot(proc_root)
        current = {r["pid"]: r for r in snap["nebula"]}
        for pid, r in current.items():
            if pid not in seen:
                seen[pid] = r
                births.append(r)
                print("[%4ds] BIRTH pid %-7d parent=%s(pid %d) owner=%s"
                      % (int(time.time() - t0), pid, r["parent_comm"] or "?",
                         r["ppid"], r["owner"]))
        for pid in [p for p in seen if p not in current]:
            print("[%4ds] DEATH pid %d" % (int(time.time() - t0), pid))
            seen.pop(pid, None)
        time.sleep(interval)
    parents = []
    for r in births:
        label = "%s(pid %d)" % (r["parent_comm"] or "?", r["ppid"])
        if label not in parents:
            parents.append(label)
    print("observed %d birth(s) over %ss; parents: %s"
          % (len(births), seconds, ", ".join(parents) or "(none)"))
    if births:
        ext = [r for r in births if r["owner"] == "external"]
        print("verdict: %s" % ("external supervisor(s): " + ", ".join(
            "%s(pid %d)" % (r["parent_comm"] or "?", r["ppid"]) for r in ext)
            if ext else "only systemd(1) restarted nebula"))
    return 0


def self_test():
    import tempfile
    root = Path(tempfile.mkdtemp(prefix="nrt-"))

    def write_proc(pid, comm, ppid, starttime, cmdl):
        d = root / str(pid)
        d.mkdir(parents=True, exist_ok=True)
        (d / "comm").write_text(comm + "\n")
        (d / "cmdline").write_text("\x00".join(cmdl.split(" ")) + "\x00")
        rest = ["S", str(ppid)] + ["0"] * 17 + [str(starttime)]
        (d / "stat").write_text("%d (%s) %s\n" % (pid, comm, " ".join(rest)))

    (root / "stat").write_text("cpu  0 0 0 0 0 0 0 0 0 0\nbtime 1700000000\n")
    write_proc(1, "systemd", 0, 100, "/sbin/init")
    write_proc(777, "node", 1, 200, "node /opt/other-project/supervisor.js")
    write_proc(4242, "nebula", 1, 500, "/usr/local/bin/nebula -config /etc/nebula/config.yml")
    write_proc(4243, "nebula", 777, 900, "/usr/local/bin/nebula -config /etc/nebula/config.yml")

    fail = 0
    snap = snapshot(root)
    pids = [r["pid"] for r in snap["nebula"]]
    if sorted(pids) != [4242, 4243]:
        print("FAIL: expected pids [4242, 4243], got %s" % pids)
        fail = 1
    p4242 = next((r for r in snap["nebula"] if r["pid"] == 4242), None)
    if not p4242 or p4242["owner"] != "systemd":
        print("FAIL: pid 4242 should be systemd-owned, got %s" % p4242)
        fail = 1
    p4243 = next((r for r in snap["nebula"] if r["pid"] == 4243), None)
    if not p4243 or p4243["owner"] != "external" or p4243["parent_comm"] != "node":
        print("FAIL: pid 4243 should be external/node, got %s" % p4243)
        fail = 1
    if snap["verdict"]["code"] != "external" or "node" not in snap["verdict"]["text"]:
        print("FAIL: verdict should name the external parent, got %s" % snap["verdict"])
        fail = 1
    if p4242 and p4242["start_epoch"] is None:
        print("FAIL: start_epoch should resolve from btime + starttime")
        fail = 1
    print("nebula-restart-trace: self-test %s" % ("PASS" if fail == 0 else "FAIL"))
    return fail


def main(argv):
    ap = argparse.ArgumentParser(description="name the nebula restarter (read-only)")
    ap.add_argument("--watch", type=float, metavar="SECS", default=None)
    ap.add_argument("--interval", type=float, default=2.0)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--proc-root", default="/proc")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    proc_root = Path(args.proc_root)
    if not proc_root.is_dir():
        print("GATE FAIL: --proc-root %s is not a directory" % proc_root)
        return 2

    if args.watch is not None:
        return watch(proc_root, args.watch, args.interval, args.json)

    snap = snapshot(proc_root)
    if args.json:
        print(json.dumps(snap, indent=2))
        return 0
    print_snapshot(snap)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
