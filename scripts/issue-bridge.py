#!/usr/bin/env python3
"""
issue-bridge.py — external-state bridge for issue hand-offs (E2).

WHY: `gh` is absent in-container, so `nebula-systemd-override.sh --handoff`
produces a body-file the operator files by hand — with no read-back. The filed
issue's state never returns to the durable store, so the loop cannot close an
external unit (TUNNEL-1 -> swipswaps/proxmox-dual-plane-mesh#5).

WHAT: a round-trip over the same append-only ledger triage/next-action read:

    link    record a filed issue (repo#number) as an OPEN external unit
    poll    read the issue's current state and record it (idempotent)
    status  print the latest known state per issue (read-only)

The state comes from `gh issue view --json ...` on the host (`--gh`), from a
host-written JSON file (`--in`, default data/observability/issue-state.json),
or straight from GitHub's REST API for a PUBLIC repo (`--api`, stdlib only, no
gh and no token required). Rows are de-duped by (source,source_key), so a
re-poll is a no-op.

Usage:
    python3 scripts/issue-bridge.py link --repo OWNER/NAME --number N [--url U]
    python3 scripts/issue-bridge.py poll --in issue-state.json
    python3 scripts/issue-bridge.py poll --gh --repo OWNER/NAME --number N
    python3 scripts/issue-bridge.py poll --api --repo OWNER/NAME --number N
    python3 scripts/issue-bridge.py status [--json]
    python3 scripts/issue-bridge.py --self-test

Host bridge (no gh in-container): run `gh issue list --json ...` (or one
`gh issue view`) on the host, write the JSON to data/observability/, then in the
container run `poll --in` — the ledger now carries the external state. For a
public repo `poll --api` does the same read from the container; set
GITHUB_TOKEN to avoid the anonymous rate limit (never printed).

Env: LEDGER_DB (test seam; same as ledger.py), GITHUB_API_BASE (test seam),
GITHUB_TOKEN/GH_TOKEN (optional rate-limit credential; never printed). Stdlib
only.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ledger  # noqa: E402 — shared schema/insert, one ledger


def default_in() -> str:
    return os.path.join(ledger.repo_root(), "data", "observability", "issue-state.json")


def normalize(obj) -> dict | None:
    """Accept gh (`state,updatedAt,url`) and snake_case host variants."""
    if not isinstance(obj, dict):
        return None
    repo = obj.get("repo") or obj.get("repository")
    number = obj.get("number") or obj.get("issue") or obj.get("id")
    state = obj.get("state") or obj.get("status")
    if repo is None or number is None or state is None:
        return None
    updated = obj.get("updatedAt") or obj.get("updated_at") or obj.get("updated") or ""
    url = obj.get("html_url") or obj.get("url") or ""
    return {"repo": str(repo), "number": str(number).lstrip("#"),
            "state": str(state).upper(), "updated": str(updated).strip(),
            "url": str(url).strip()}


def read_state_file(path: str) -> list[dict] | None:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except OSError as e:
        print("issue-bridge: cannot read %s (%s)" % (path, e), file=sys.stderr)
        return None
    except json.JSONDecodeError as e:
        print("issue-bridge: bad JSON in %s (%s)" % (path, e), file=sys.stderr)
        return None
    if isinstance(data, dict) and isinstance(data.get("issues"), list):
        data = data["issues"]
    items = data if isinstance(data, list) else [data]
    out = []
    for it in items:
        n = normalize(it)
        if n:
            out.append(n)
        else:
            print("issue-bridge: skipped a row (needs repo+number+state)", file=sys.stderr)
    return out


def gh_state(repo: str, number: str) -> dict | None:
    exe = shutil.which("gh")
    if not exe:
        print("issue-bridge: gh not found — run on the host, or write the state "
              "JSON and use `poll --in FILE`", file=sys.stderr)
        return None
    cmd = [exe, "issue", "view", str(number), "--repo", repo,
           "--json", "state,updatedAt,url"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True)
    out, err = proc.communicate()
    if proc.returncode != 0:
        print("issue-bridge: gh failed (%s)" % ((err or out).strip(),), file=sys.stderr)
        return None
    try:
        data = json.loads(out)
    except json.JSONDecodeError as e:
        print("issue-bridge: gh returned bad JSON (%s)" % (e,), file=sys.stderr)
        return None
    data.setdefault("repo", repo)
    data.setdefault("number", number)
    return normalize(data)


def api_base() -> str:
    return os.environ.get("GITHUB_API_BASE", "https://api.github.com").rstrip("/")


def api_state(repo: str, number: str) -> dict | None:
    """Read a PUBLIC issue from the GitHub REST API (no gh, no token needed).

    GITHUB_API_BASE is a test seam (a local fixture server). GITHUB_TOKEN, when
    present, is sent as a bearer credential for the rate limit only; it is never
    printed. Never log the request headers.
    """
    url = "%s/repos/%s/issues/%s" % (api_base(), repo, str(number).lstrip("#"))
    headers = {"User-Agent": "opencode-issue-bridge",
               "Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.load(resp)
    except (urllib.error.URLError, urllib.error.HTTPError, OSError,
            json.JSONDecodeError) as e:
        print("issue-bridge: API read failed for %s#%s (%s)"
              % (repo, str(number).lstrip("#"), e), file=sys.stderr)
        return None
    if not isinstance(data, dict):
        print("issue-bridge: API returned a non-object", file=sys.stderr)
        return None
    data.setdefault("repo", repo)
    data.setdefault("number", number)
    return normalize(data)


def record(con, item: dict, source: str) -> bool:
    res = "%s#%s" % (item["repo"], item["number"])
    key = "state:%s@%s:%s" % (res, item["updated"] or "-", item["state"])
    detail = (item["updated"] + " " + item["url"]).strip()
    tool = ("gh" if source == "issue-bridge.gh"
            else "api" if source == "issue-bridge.api" else "bridge")
    new = ledger.insert(con, {"type": "ISSUE_STATE", "actor": "issue-bridge",
                              "tool": tool,
                              "resource": res, "verdict": item["state"],
                              "detail": detail, "source": source,
                              "source_key": key})
    print("issue-bridge: %s %s %s" % ("recorded" if new else "duplicate-skipped",
                                      res, item["state"]))
    return new


def cmd_link(args: argparse.Namespace) -> int:
    if not args.repo or not args.number:
        print("issue-bridge link: --repo and --number are required", file=sys.stderr)
        return 2
    res = "%s#%s" % (args.repo, str(args.number).lstrip("#"))
    con = ledger.connect(ledger.db_path())
    new = ledger.insert(con, {"type": "ISSUE", "actor": "issue-bridge",
                              "tool": "link", "resource": res, "verdict": "OPEN",
                              "detail": args.url or "", "source": "issue-bridge.link",
                              "source_key": "link:" + res})
    con.close()
    print("issue-bridge: %s %s" % ("linked" if new else "duplicate-skipped", res))
    return 0


def cmd_poll(args: argparse.Namespace) -> int:
    items: list[dict] = []
    if args.gh or args.api:
        if not args.repo or not args.number:
            flag = "--gh" if args.gh else "--api"
            print("issue-bridge poll %s: --repo and --number are required"
                  % (flag,), file=sys.stderr)
            return 2
        if args.gh:
            one = gh_state(args.repo, str(args.number).lstrip("#"))
        else:
            one = api_state(args.repo, str(args.number).lstrip("#"))
        if one is None:
            return 1
        items = [one]
    else:
        path = args.infile or default_in()
        if not os.path.exists(path):
            if args.infile:
                print("issue-bridge: state file not found: %s" % (path,), file=sys.stderr)
                return 1
            print("issue-bridge: no state source (pass --in FILE or --gh); nothing to poll")
            return 0
        got = read_state_file(path)
        if got is None:
            return 1
        items = got
    if not items:
        print("issue-bridge: no usable issue rows")
        return 1
    con = ledger.connect(ledger.db_path())
    source = ("issue-bridge.gh" if args.gh
              else "issue-bridge.api" if args.api
              else "issue-bridge.poll")
    added = sum(1 for item in items if record(con, item, source))
    con.close()
    print("issue-bridge: poll +%d row(s)" % (added,))
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    con = ledger.connect(ledger.db_path())
    latest: dict[str, tuple] = {}
    try:
        for typ in ("ISSUE_STATE", "ISSUE"):
            for res, verdict, detail, ts in con.execute(
                    "SELECT resource,verdict,detail,ts FROM ledger "
                    "WHERE type=? ORDER BY id", (typ,)).fetchall():
                latest.setdefault(res, (verdict, detail, ts))
        # Newest state wins over the link, even if the link was inserted later.
        for res, verdict, detail, ts in con.execute(
                "SELECT resource,verdict,detail,ts FROM ledger "
                "WHERE type='ISSUE_STATE' ORDER BY id").fetchall():
            latest[res] = (verdict, detail, ts)
    finally:
        con.close()
    if args.json:
        print(json.dumps([{"resource": r, "state": v[0], "detail": v[1],
                           "ts": v[2]} for r, v in latest.items()], indent=1))
        return 0
    if not latest:
        print("issue-bridge: no issues tracked")
        return 0
    for res in sorted(latest):
        state, detail, ts = latest[res]
        line = "%-48s %-8s %s" % (res, state or "?", ts or "")
        if detail:
            line += " — " + detail[:80]
        print(line)
    return 0


def self_test() -> int:
    import tempfile
    fails = 0

    def check(cond: bool, label: str) -> None:
        nonlocal fails
        print(("ok " if cond else "NOT OK ") + label)
        if not cond:
            fails += 1

    with tempfile.TemporaryDirectory() as tmp:
        os.environ["LEDGER_DB"] = os.path.join(tmp, "obs.db")
        try:
            fixture = os.path.join(tmp, "state.json")
            with open(fixture, "w", encoding="utf-8") as fh:
                json.dump({"issues": [{
                    "repository": "swipswaps/proxmox-dual-plane-mesh",
                    "number": 5, "state": "open",
                    "updated_at": "2026-10-18T00:00:00Z",
                    "url": "https://example.invalid/5"}]}, fh)

            ns = argparse.Namespace(gh=False, api=False, infile=fixture,
                                    repo="", number="")
            check(cmd_poll(ns) == 0, "poll ingests a host JSON file")
            con = ledger.connect(ledger.db_path())
            n1 = con.execute("SELECT COUNT(*) FROM ledger WHERE type='ISSUE_STATE'").fetchone()[0]
            con.close()
            check(n1 == 1, "one ISSUE_STATE row")

            check(cmd_poll(ns) == 0, "re-poll exits 0")
            con = ledger.connect(ledger.db_path())
            n2 = con.execute("SELECT COUNT(*) FROM ledger WHERE type='ISSUE_STATE'").fetchone()[0]
            con.close()
            check(n2 == 1, "re-poll inserts 0 (idempotent)")

            with open(fixture, "w", encoding="utf-8") as fh:
                json.dump([{"repo": "swipswaps/proxmox-dual-plane-mesh",
                            "number": "#5", "state": "closed",
                            "updatedAt": "2026-10-19T00:00:00Z"}], fh)
            check(cmd_poll(ns) == 0, "poll accepts a bare list + state change")
            con = ledger.connect(ledger.db_path())
            rows = con.execute("SELECT verdict FROM ledger WHERE type='ISSUE_STATE' "
                               "ORDER BY id").fetchall()
            con.close()
            check([r[0] for r in rows] == ["OPEN", "CLOSED"], "state change recorded")

            link = argparse.Namespace(repo="swipswaps/proxmox-dual-plane-mesh",
                                      number="5", url="https://example.invalid/5")
            check(cmd_link(link) == 0, "link records the filed issue")
            check(cmd_link(link) == 0, "link is idempotent")
            con = ledger.connect(ledger.db_path())
            nl = con.execute("SELECT COUNT(*) FROM ledger WHERE type='ISSUE'").fetchone()[0]
            con.close()
            check(nl == 1, "one ISSUE row")

            # --api: read a PUBLIC issue with no gh and no token, against a local
            # fixture server (offline; GITHUB_API_BASE is the test seam).
            import http.server
            import threading

            main_db = os.environ["LEDGER_DB"]
            os.environ["LEDGER_DB"] = os.path.join(tmp, "api.db")
            body = json.dumps({"number": 5, "state": "open",
                               "updated_at": "2026-10-18T11:47:59Z",
                               "html_url": "https://example.invalid/5"}).encode()

            class Handler(http.server.BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

                def log_message(self, *args):
                    pass

            srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            os.environ["GITHUB_API_BASE"] = (
                "http://127.0.0.1:%d" % (srv.server_address[1],))
            try:
                api_ns = argparse.Namespace(
                    gh=False, api=True, infile="",
                    repo="swipswaps/proxmox-dual-plane-mesh", number="5")
                check(cmd_poll(api_ns) == 0, "poll --api reads a public issue")
                con = ledger.connect(ledger.db_path())
                na = con.execute("SELECT COUNT(*) FROM ledger WHERE type='ISSUE_STATE' "
                                 "AND tool='api'").fetchone()[0]
                con.close()
                check(na == 1, "api read recorded (tool=api)")
                check(cmd_poll(api_ns) == 0, "api re-poll exits 0")
                con = ledger.connect(ledger.db_path())
                na2 = con.execute("SELECT COUNT(*) FROM ledger WHERE type='ISSUE_STATE'").fetchone()[0]
                con.close()
                check(na2 == 1, "api re-poll inserts 0 (idempotent)")
            finally:
                srv.shutdown()
                srv.server_close()
                del os.environ["GITHUB_API_BASE"]
                os.environ["LEDGER_DB"] = main_db

            class Capture:
                def __init__(self) -> None:
                    self.buf = []

                def __call__(self, *parts, **kw) -> None:
                    self.buf.append(" ".join(str(p) for p in parts))

            cap = Capture()
            real = print
            import builtins
            builtins.print = cap
            try:
                cmd_status(argparse.Namespace(json=False))
            finally:
                builtins.print = real
            text = "\n".join(cap.buf)
            check("swipswaps/proxmox-dual-plane-mesh#5" in text, "status names the issue")
            check("CLOSED" in text, "status shows the latest state")
        finally:
            del os.environ["LEDGER_DB"]
    print("self-test: %s (%d failures)" % ("PASS" if fails == 0 else "FAIL", fails))
    return 0 if fails == 0 else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    sub = ap.add_subparsers(dest="cmd")
    lk = sub.add_parser("link")
    lk.add_argument("--repo", default="")
    lk.add_argument("--number", default="")
    lk.add_argument("--url", default="")
    pl = sub.add_parser("poll")
    pl.add_argument("--gh", action="store_true")
    pl.add_argument("--api", action="store_true")
    pl.add_argument("--repo", default="")
    pl.add_argument("--number", default="")
    pl.add_argument("--in", dest="infile", default="")
    st = sub.add_parser("status")
    st.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv if argv is not None else sys.argv[1:])
    if args.self_test:
        return self_test()
    if args.cmd == "link":
        return cmd_link(args)
    if args.cmd == "poll":
        return cmd_poll(args)
    if args.cmd == "status":
        return cmd_status(args)
    ap.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
