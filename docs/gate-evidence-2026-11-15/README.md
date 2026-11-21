# Gate evidence, 2026-11-15 — the anonymous failure and the poisoned sample

Abbreviations: GATE (a harness.sh gate record), p95 (95th percentile),
PID (process identifier), PSI (Pressure Stall Information).

This directory is the **as-run** evidence. It exists because two store files
were rewritten after the fact, and the rewrite must be auditable.

## Snapshots

| File | What it is |
| --- | --- |
| `last-gate-20261115T211856Z.json` | The 21:18:56Z host run. 2 pass / 1 fail. **No gate name** — that build did not write `failed_gates`. |
| `gate-timings-20261115T212300Z.json` | The timing store at that moment: two samples per gate. |
| `last-gate-20261115T223031Z.json` | The 22:30:31Z host run. 2 pass / 1 fail, **`"failed_gates":"test-hygiene"`**. |
| `gate-timings-20261115T223343Z.json` | The timing store at 22:33:43Z: three samples per gate, **including two failed hygiene runs** (178 s, 82 s). |
| `harness-failures-20261115T223031Z.log` | The failure tail the run wrote. It contains **0 `status=FAIL` lines**: 30 lines of PASS and the summary. The failing check is not in it. |

## What was deduced, and how it held up

The 21:18 span was 250 s (21:18:56Z → 21:23:06Z). The samples written at
21:23:00Z were 36 + 178 + 27 = 241 s. Two gates passed, one failed, so the
failure had to be the 178 s sample: **test-hygiene**.

The 22:30 run confirmed it directly: `failed_gates: test-hygiene`, 112 pass /
1 fail / 0 skip, elapsed 82 s. The deduction was correct, but the **name was
only recoverable by arithmetic** until the build that writes `failed_gates` ran.

## Why the live store was rewritten (pass-only samples)

`scripts/gate-bound.py` promises a bound from *successful* elapsed seconds, but
`harness.sh` recorded a sample for any run that did not time out — including
failures. With three samples the p95 of `test-hygiene` would have been 178 s,
i.e. a **failed** run would have taught the deadline (bound 356 s).

Two changes:

1. `scripts/harness.sh` records `--record` **only when `rc == 0`**, and prints
   `timing: gate <name> FAILED after <n>s; not recorded (pass-only samples)`.
2. The live `data/observability/gate-timings.json` keeps passing samples only:
   `lint [12,36,23]`, `test-hygiene [61]`, `test-patterns [2,27,85]`.

Restore rule: if a future run proves one of the dropped samples (178, 82) was a
**pass**, merge it back manually. The as-run files above are the source.

## Still open

The failing hygiene check is **host-only** (the container skips it with a
reason), so the container cannot name it. The next host run keeps the
`status=FAIL` line in `logs/harness-failures.log` (the capture was widened after
this evidence showed the tail alone is not enough).
