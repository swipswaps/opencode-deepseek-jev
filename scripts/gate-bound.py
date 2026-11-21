#!/usr/bin/env python3
"""
gate-bound.py — measured per-gate deadline from the harness's own history.

WHY: harness.sh had no per-gate timeout, so a wedged self-test looked exactly
like a slow one (2026-11-15: a 5m42s silent test-hygiene). A blind constant is
the wrong fix (RULES #91: a deadline is telemetry). This stores each gate's
successful elapsed seconds and returns p95*2, with a disclosed ceiling until
three samples exist and GATE_TIMEOUT as the explicit operator override.

    python3 scripts/gate-bound.py --gate test-hygiene
        bound=600 basis=p95*2 n=7
    python3 scripts/gate-bound.py --gate test-hygiene --record 342
        recorded gate=test-hygiene seconds=342 n=4
    python3 scripts/gate-bound.py --self-test

Store: data/observability/gate-timings.json  {gate: [seconds, ...]} (last 30).
Exit 0 always: this is advisory telemetry, never a gate.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import tempfile

FLOOR = 120
CEILING = 1800
KEEP = 30


def repo_root() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    c = here
    while c != "/":
        if os.path.isfile(os.path.join(c, "opencode.json")) and \
                os.path.isdir(os.path.join(c, "docker")):
            return c
        c = os.path.dirname(c)
    return here


def store_path() -> str:
    override = os.environ.get("GATE_TIMINGS")
    if override:
        return override
    return os.path.join(repo_root(), "data", "observability", "gate-timings.json")


def load(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save(path: str, data: dict) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)


def p95(values: list) -> int:
    xs = sorted(int(v) for v in values)
    if not xs:
        return 0
    idx = max(0, min(len(xs) - 1, math.ceil(0.95 * len(xs)) - 1))
    return xs[idx]


def bound_for(gate: str) -> tuple[int, str, int]:
    env = os.environ.get("GATE_TIMEOUT", "")
    if env.isdigit() and int(env) > 0:
        return int(env), "GATE_TIMEOUT", 0
    xs = [int(v) for v in load(store_path()).get(gate, []) if str(v).isdigit()]
    if len(xs) < 3:
        return CEILING, "ceiling(<3)", len(xs)
    return max(FLOOR, int(math.ceil(p95(xs) * 2))), "p95*2", len(xs)


def record(gate: str, seconds: int) -> int:
    path = store_path()
    data = load(path)
    xs = [int(v) for v in data.get(gate, []) if str(v).isdigit()]
    xs.append(max(0, seconds))
    data[gate] = xs[-KEEP:]
    save(path, data)
    return len(data[gate])


def self_test() -> int:
    fails = 0

    def check(cond: bool, label: str) -> None:
        nonlocal fails
        print(("ok " if cond else "NOT OK ") + label)
        if not cond:
            fails += 1

    with tempfile.TemporaryDirectory() as tmp:
        os.environ["GATE_TIMINGS"] = os.path.join(tmp, "gate-timings.json")
        os.environ.pop("GATE_TIMEOUT", None)
        check(bound_for("g")[0] == CEILING, "no samples -> disclosed ceiling")
        for s in (10, 20, 100):
            record("g", s)
        b, basis, n = bound_for("g")
        check(b == 200, f"p95=100 -> 200 (got {b})")
        check("p95" in basis and n == 3, "basis names the measurement")
        for _ in range(3):
            record("low", 10)
        check(bound_for("low")[0] == FLOOR, "p95=10 -> floor 120")
        for _ in range(4):
            record("g", 500)
        b, _, n = bound_for("g")
        check(b == 1000, f"p95=500 -> 1000 (got {b})")
        os.environ["GATE_TIMEOUT"] = "42"
        check(bound_for("g")[0] == 42, "GATE_TIMEOUT overrides")
        os.environ.pop("GATE_TIMEOUT", None)
        for i in range(40):
            record("g", i)
        check(len(load(store_path())["g"]) == KEEP, "history is trimmed")
        del os.environ["GATE_TIMINGS"]
    print(f"self-test: {'PASS' if fails == 0 else 'FAIL'} ({fails} failures)")
    return 0 if fails == 0 else 1


def main(argv: list | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--gate", default="")
    ap.add_argument("--record", default="")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv if argv is not None else sys.argv[1:])
    if args.self_test:
        return self_test()
    if not args.gate:
        print("gate-bound: --gate is required", file=sys.stderr)
        return 2
    if args.record != "":
        if not str(args.record).isdigit():
            print("gate-bound: --record must be integer seconds", file=sys.stderr)
            return 2
        n = record(args.gate, int(args.record))
        print(f"recorded gate={args.gate} seconds={args.record} n={n}")
        return 0
    b, basis, n = bound_for(args.gate)
    if args.json:
        print(json.dumps({"gate": args.gate, "bound": b, "basis": basis, "n": n}))
    else:
        print(f"bound={b} basis={basis} n={n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
