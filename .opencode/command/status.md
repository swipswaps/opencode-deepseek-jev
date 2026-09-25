---
description: List outstanding issues (both senses), implement only the locally-doable queue items in one segment, gate, and defer the rest with a reason and a segmented plan. Use instead of re-pasting the status prompt.
agent: build
---

# /status — outstanding issues, then implement the doable segment

You are in the opencode-deepseek-jev repo. Follow the `jev-harness` skill.
Source of truth: `TODO.md` (queue), `HANDOFF.md` (state), `RULES.md`.

Optional focus: $ARGUMENTS

## 1. List outstanding issues — both senses
- **Unresolved**, each with a disposition (resolved / accepted / deferred +
  why). 
- **Notable (standing)** strengths worth preserving.

## 2. Bound the work (this is the rule that stops ballooning)
A task is **doable now** only if it is local, offline, adds no rich
dependency, and is gateable by `./scripts/harness.sh --fast`. Classify
everything else and **do not attempt it**:
- **A** — local, doable now → implement, in ONE coherent segment.
- **B** — doable but needs a host or a test this container cannot run.
- **C** — doable code, larger → its own session.
- **D** — external / needs a service or a new vendored dep → never batch.

If the request is impossible or ballooning, **say so plainly, name the segment
it belongs to, and stop** — a documented deferral is the correct output, not a
half-finished attempt.

## 3. Implement the next doable segment
Pick the highest-value unblocked item. Use the repo's own tools (do not
reinvent): `learn-rules.py`, `issue-solutions.py`, `models.sh`, `logs.sh`,
`preflight.sh`, `dashboard.mjs`, `doc-budget.sh`. Read-only on
`data/opencode/opencode.db`. Respect the enforced blacklist
(`sed`/`rm -rf`/`subprocess.run` blocked; `2>/dev/null` removed; `echo` warns).

## 4. Gate and record
- `./scripts/harness.sh` must pass (lint · test-hygiene · test-patterns ·
  test-dashboard).
- Update `TODO.md` (move to Done; reason on each deferral), and `HANDOFF.md` /
  `README.txt` / `scripts/README.txt` as needed.

## 5. Output contract (return exactly this)
1. Outstanding issues (both senses).
2. The segment chosen and why it is doable now.
3. What changed + the gate result.
4. Deferrals, each with a segment letter and a reason.
5. `git add … && git commit -m … && git push` commands.

Stop when the locally-doable queue is drained. Do not invent work.
