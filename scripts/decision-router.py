#!/usr/bin/env python3
"""decision-router.py - redundant System One router with telemetry-based choice.

Laya, SubQ and Jev all speak POST /v1/systemone. jev-guard accepts one
JEV_BASE_URL, so this process is that URL: it chooses a backend from measured
availability, reliability and cost, forwards the request, fails over, and
records every attempt in the observability DB.

Policy (scripts/decision_providers.json):
  - eligible = enabled, circuit closed, rolling reliability >= min_reliability
    once a provider has at least cold_samples attempts
  - order by (cost_per_m_input, -reliability, p95_latency); local wins ties
  - on failure/timeout, try the next; open a circuit after N consecutive
    failures for circuit_seconds
  - if nothing is eligible, still try the least-bad enabled provider

  ./scripts/decision-router.py --serve --host 172.28.0.1 --port 8010
  ./scripts/decision-router.py --explain
  ./scripts/decision-router.py --self-test
  GET /healthz  -> stats + circuits + order
  GET /stats    -> same (JSON)
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import socket
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = REPO / "scripts" / "decision_providers.json"
DEFAULT_DB = REPO / "data" / "observability" / "observability.db"


def now() -> float:
    return time.time()


def load_config(path: pathlib.Path) -> dict:
    with open(path) as f:
        cfg = json.load(f)
    for p in cfg.get("providers", []):
        env_url = p.get("url_env")
        if env_url and os.environ.get(env_url):
            p["url"] = os.environ[env_url]
    return cfg


def open_db(path: pathlib.Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(path), timeout=2.0)
    con.execute(
        "CREATE TABLE IF NOT EXISTS decision_route("
        "id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, provider TEXT, model TEXT, "
        "ok INTEGER, status INTEGER, latency_ms REAL, cost_usd REAL, "
        "tokens_in INTEGER, error TEXT)"
    )
    con.execute("CREATE INDEX IF NOT EXISTS decision_route_pid ON decision_route(provider, id)")
    con.commit()
    return con


class Circuits:
    def __init__(self, failures: int, seconds: float):
        self.failures = failures
        self.seconds = seconds
        self.lock = threading.Lock()
        self.state: dict[str, dict] = {}

    def open_for(self, pid: str) -> float:
        with self.lock:
            s = self.state.get(pid) or {}
            return max(0.0, float(s.get("open_until", 0)) - now())

    def ok(self, pid: str) -> None:
        with self.lock:
            self.state[pid] = {"fails": 0, "open_until": 0.0}

    def fail(self, pid: str) -> None:
        with self.lock:
            s = self.state.setdefault(pid, {"fails": 0, "open_until": 0.0})
            s["fails"] = int(s.get("fails", 0)) + 1
            if s["fails"] >= self.failures:
                s["open_until"] = now() + self.seconds
                s["fails"] = 0

    def snapshot(self) -> dict:
        with self.lock:
            return {k: dict(v) for k, v in self.state.items()}


def p95(values: list[float]) -> float:
    if not values:
        return 0.0
    v = sorted(values)
    return v[min(len(v) - 1, int(round(0.95 * (len(v) - 1))))]


def stats(con: sqlite3.Connection, pid: str, window: int) -> dict:
    rows = con.execute(
        "SELECT ok, latency_ms FROM decision_route WHERE provider=? ORDER BY id DESC LIMIT ?",
        (pid, window),
    ).fetchall()
    n = len(rows)
    ok = sum(1 for r in rows if r[0])
    lat = [float(r[1] or 0) for r in rows]
    return {
        "n": n,
        "ok": ok,
        "reliability": (ok / n) if n else 1.0,
        "p95_ms": round(p95(lat), 1),
    }


def choose(cfg: dict, con: sqlite3.Connection, circuits: Circuits) -> list[dict]:
    pol = cfg.get("policy", {})
    window = int(pol.get("window", 50))
    cold = int(pol.get("cold_samples", 5))
    min_rel = float(pol.get("min_reliability", 0.9))
    out = []
    for p in cfg.get("providers", []):
        if not p.get("enabled", True):
            continue
        st = stats(con, p["id"], window)
        remaining = circuits.open_for(p["id"])
        eligible = remaining <= 0 and (st["n"] < cold or st["reliability"] >= min_rel)
        out.append(
            {
                **p,
                **st,
                "circuit_s": round(remaining, 1),
                "eligible": eligible,
            }
        )
    good = [p for p in out if p["eligible"]]
    bad = [p for p in out if not p["eligible"]]
    key = lambda p: (
        float(p.get("cost_per_m_input", 0)),
        0 if p.get("local") else 1,
        -float(p["reliability"]),
        float(p["p95_ms"]),
        p["id"],
    )
    good.sort(key=key)
    bad.sort(key=lambda p: (-float(p["reliability"]), float(p.get("cost_per_m_input", 0))))
    return good + bad


def record(con: sqlite3.Connection, pid: str, model: str, ok: bool, status: int,
           ms: float, cost: float, tokens: int, error: str) -> None:
    con.execute(
        "INSERT INTO decision_route(ts,provider,model,ok,status,latency_ms,cost_usd,tokens_in,error) "
        "VALUES(?,?,?,?,?,?,?,?,?)",
        (now(), pid, model, int(ok), int(status), ms, cost, tokens, error[:300]),
    )
    con.commit()


def forward(p: dict, body: bytes, timeout_s: float) -> tuple[bool, int, bytes, str]:
    headers = {"content-type": "application/json"}
    key = os.environ.get(p.get("key_env", ""), "") if p.get("key_env") else ""
    if key:
        headers["authorization"] = "Bearer " + key
    req = urllib.request.Request(p["url"], data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as r:
            return True, int(r.status), r.read(), ""
    except urllib.error.HTTPError as e:
        return False, int(e.code), e.read(), "http %s" % e.code
    except (urllib.error.URLError, socket.timeout, TimeoutError, OSError) as e:
        return False, 0, b"", type(e).__name__ + ": " + str(e)[:200]


def route(cfg: dict, con: sqlite3.Connection, circuits: Circuits, body: bytes) -> tuple[int, bytes, str]:
    order = choose(cfg, con, circuits)
    if not order:
        return 502, b'{"error":"no providers enabled"}', "none"
    try:
        doc = json.loads(body.decode("utf-8"))
    except Exception:
        doc = None
    tokens = max(1, len(body) // 4)
    last = (502, b'{"error":"all providers failed"}', "none")
    # Prefer eligible providers; only fall back to open-circuit/low-reliability
    # ones when no eligible provider remains.
    candidates = [p for p in order if p["eligible"]] or order
    for p in candidates:
        payload = body
        if doc is not None and p.get("model"):
            d = dict(doc)
            d["model"] = p["model"]
            payload = json.dumps(d).encode("utf-8")
        ms = float(p.get("timeout_ms", 1800)) / 1000.0
        t0 = now()
        ok, status, data, err = forward(p, payload, ms)
        elapsed = (now() - t0) * 1000.0
        cost = (tokens / 1_000_000.0) * float(p.get("cost_per_m_input", 0))
        # 4xx means the backend is REACHABLE but the request is bad; it is not
        # an availability failure and must not open the circuit (probes send an
        # empty questions list). 5xx/network failures fail over.
        reachable = ok and 200 <= status < 500
        record(con, p["id"], p.get("model", ""), reachable, status, elapsed, cost, tokens, err)
        if reachable:
            circuits.ok(p["id"])
            return status, data, p["id"]
        circuits.fail(p["id"])
        last = (status or 502, data or b'{"error":"backend failed"}', p["id"])
    return last


def explain(cfg: dict, con: sqlite3.Connection, circuits: Circuits) -> int:
    order = choose(cfg, con, circuits)
    print("provider  cost/M  n   rel    p95ms  circuit  eligible")
    for p in order:
        print("%-8s  %6.3f  %-3d %5.2f  %6.1f  %6.1fs  %s" % (
            p["id"], float(p.get("cost_per_m_input", 0)), p["n"], p["reliability"],
            p["p95_ms"], p["circuit_s"], "yes" if p["eligible"] else "no"))
    print("order: " + " -> ".join(p["id"] for p in order))
    return 0


def make_handler(cfg: dict, con: sqlite3.Connection, circuits: Circuits):
    class H(BaseHTTPRequestHandler):
        server_version = "decision-router/1"

        def _send(self, code: int, body: bytes, ctype: str = "application/json") -> None:
            self.send_response(code)
            self.send_header("content-type", ctype)
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            if self.path.split("?")[0] in ("/healthz", "/stats", "/"):
                order = choose(cfg, con, circuits)
                doc = {"ts": now(), "order": [p["id"] for p in order], "providers": [
                    {k: p.get(k) for k in ("id", "eligible", "n", "reliability", "p95_ms",
                                           "cost_per_m_input", "circuit_s", "local")}
                    for p in order]}
                self._send(200, json.dumps(doc).encode())
            else:
                self._send(404, b'{"error":"not found"}')

        def do_POST(self) -> None:
            if self.path.split("?")[0] != "/v1/systemone":
                self._send(404, b'{"error":"not found"}')
                return
            n = int(self.headers.get("content-length", "0") or 0)
            body = self.rfile.read(n)
            code, data, provider = route(cfg, con, circuits, body)
            self._send(code, data)
            sys.stderr.write("[router] %s %s %s %d\n" % (
                time.strftime("%H:%M:%S"), provider, self.path, code))

        def log_message(self, fmt, *args) -> None:
            return

    return H


def self_test() -> int:
    import tempfile

    class Fake(BaseHTTPRequestHandler):
        code = 200

        def do_POST(self) -> None:
            self.rfile.read(int(self.headers.get("content-length", "0") or 0))
            self.send_response(Fake.code)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"answers":{"ok":{"noul":1.0}}}')

        def log_message(self, fmt, *args) -> None:
            return

    srv = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = srv.server_address[1]
    work = pathlib.Path(tempfile.mkdtemp())
    cfg = {"policy": {"window": 10, "cold_samples": 1, "min_reliability": 0.5,
                      "circuit_failures": 2, "circuit_seconds": 30},
           "providers": [
               {"id": "bad", "url": "http://127.0.0.1:%d/v1/systemone" % port, "model": "m",
                "cost_per_m_input": 0.0, "local": True, "enabled": True, "timeout_ms": 500},
               {"id": "good", "url": "http://127.0.0.1:%d/v1/systemone" % port, "model": "m",
                "cost_per_m_input": 0.05, "local": False, "enabled": True, "timeout_ms": 500}]}
    # bad first: make it fail via a closed port by rewriting its URL.
    cfg["providers"][0]["url"] = "http://127.0.0.1:1/v1/systemone"
    con = open_db(work / "t.db")
    circuits = Circuits(2, 30)
    body = b'{"state":"x","questions":[]}'
    code, data, provider = route(cfg, con, circuits, body)
    fail = 0
    if code != 200 or provider != "good":
        print("FAIL failover: %s %s" % (code, provider)); fail = 1
    rows = con.execute("SELECT provider, ok FROM decision_route ORDER BY id").fetchall()
    if len(rows) != 2 or rows[0][0] != "bad" or rows[1][1] != 1:
        print("FAIL telemetry: %s" % (rows,)); fail = 1
    cfg["policy"]["min_reliability"] = 0.9
    order = choose(cfg, con, circuits)
    if any(p["id"] == "bad" and p["eligible"] for p in order):
        print("FAIL reliability demotion"); fail = 1
    cfg["policy"]["min_reliability"] = 0.0
    for _ in range(2):
        route(cfg, con, circuits, body)
    if circuits.open_for("bad") <= 0:
        print("FAIL circuit did not open"); fail = 1
    srv.shutdown()
    print("decision-router: self-test PASS" if fail == 0 else "decision-router: self-test FAIL")
    return fail


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--serve", action="store_true")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8010)
    ap.add_argument("--config", default=str(DEFAULT_CONFIG))
    ap.add_argument("--db", default=str(DEFAULT_DB))
    ap.add_argument("--explain", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    cfg = load_config(pathlib.Path(a.config))
    con = open_db(pathlib.Path(a.db))
    circuits = Circuits(int(cfg.get("policy", {}).get("circuit_failures", 3)),
                        float(cfg.get("policy", {}).get("circuit_seconds", 60)))
    if a.explain:
        return explain(cfg, con, circuits)
    if not a.serve:
        ap.print_help()
        return 0
    srv = ThreadingHTTPServer((a.host, a.port), make_handler(cfg, con, circuits))
    print("[router] listening on %s:%d (order: %s)" % (
        a.host, a.port, ", ".join(p["id"] for p in choose(cfg, con, circuits))))
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
