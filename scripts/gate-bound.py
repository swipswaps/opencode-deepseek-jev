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

Store: data/observability/gate-timings.json  {gate: {env: [seconds, ...]}}
(last 30 per env). Envs are "host" and "sandbox"; a container run is much
slower than the host, so its samples must not teach the host's deadline.
Untagged legacy lists are ignored (they mixed both and inflated the bound).
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


ENVS = ("host", "sandbox")


def sample_env(raw: str) -> str:
    return raw if raw in ENVS else "host"


def by_env(value) -> dict:
    out = {env: [] for env in ENVS}
    if isinstance(value, dict):
        for env in ENVS:
            out[env] = [int(v) for v in value.get(env, []) if str(v).isdigit()]
    return out


def bound_for(gate: str, env: str = "host") -> tuple[int, str, int]:
    override = os.environ.get("GATE_TIMEOUT", "")
    if override.isdigit() and int(override) > 0:
        return int(override), "GATE_TIMEOUT", 0
    xs = by_env(load(store_path()).get(gate))[sample_env(env)]
    if len(xs) < 3:
        return CEILING, "ceiling(<3)", len(xs)
    return max(FLOOR, int(math.ceil(p95(xs) * 2))), "p95*2", len(xs)


def record(gate: str, seconds: int, env: str = "host") -> int:
    path = store_path()
    data = load(path)
    env = sample_env(env)
    samples = by_env(data.get(gate))
    samples[env] = (samples[env] + [max(0, seconds)])[-KEEP:]
    data[gate] = samples
    save(path, data)
    return len(samples[env])


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
        for _ in range(3):
            record("g", 700, "sandbox")
        check(bound_for("g", "host")[0] == 1000, "sandbox samples do not move the host bound")
        check(bound_for("g", "sandbox")[0] == 1400, "sandbox is bounded by its own samples")
        os.environ["GATE_TIMEOUT"] = "42"
        check(bound_for("g")[0] == 42, "GATE_TIMEOUT overrides")
        os.environ.pop("GATE_TIMEOUT", None)
        path = store_path()
        data = load(path)
        data["legacy"] = [61, 286, 700]
        save(path, data)
        b, basis, n = bound_for("legacy")
        check(b == CEILING and n == 0, f"untagged legacy samples are ignored (got {b}/{n})")
        for i in range(40):
            record("g", i)
        check(len(load(store_path())["g"]["host"]) == KEEP, "history is trimmed per env")
        del os.environ["GATE_TIMINGS"]
    print(f"self-test: {'PASS' if fails == 0 else 'FAIL'} ({fails} failures)")
    return 0 if fails == 0 else 1


def main(argv: list | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--gate", default="")
    ap.add_argument("--record", default="")
    ap.add_argument("--env", default="host")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv if argv is not None else sys.argv[1:])
    if args.self_test:
        return self_test()
    if not args.gate:
        print("gate-bound: --gate is required", file=sys.stderr)
        return 2
    env = sample_env(args.env)
    if args.record != "":
        if not str(args.record).isdigit():
            print("gate-bound: --record must be integer seconds", file=sys.stderr)
            return 2
        n = record(args.gate, int(args.record), env)
        print(f"recorded gate={args.gate} env={env} seconds={args.record} n={n}")
        return 0
    b, basis, n = bound_for(args.gate, env)
    if args.json:
        print(json.dumps({"gate": args.gate, "env": env, "bound": b, "basis": basis, "n": n}))
    else:
        print(f"bound={b} basis={basis} n={n} env={env}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
