---
name: guard-self-improvement
description: Use when improving enforcement (blacklist guard, lint, gates), when a rule keeps being evaded, or when the operator says recursive self improvement, learn from mistakes and wins, mine the chat database, or build a skill from history. Turns the session database into evidence, codifies the fix in the guard, proves it, and records what changed.
---

# guard-self-improvement

Loop: mine the session database -> find the class of failure or the win ->
codify it in `.opencode/plugins/blacklist-guard.js` -> prove it -> record it.
The corpus supplies evidence; the harness enforces; a person decides.

- Resolve the store with `./scripts/db-path.sh`; pass `--db` to the learning
  tools (the sandbox path is not the repo path).
- Enforce convention and stderr-redirect rules on the command line only; a
  script body gets the destructive set. Never block an unreachable helper.
- Prove with the guard self-test, `guard-health.sh --self-test`, and
  `test-hygiene.sh`; add the allow cases too.
- Sync the global copy and compare it; a running session is stale until restart.
- Never advance a red gate's cursor to make it green.

Exact commands and the false-positive set are in `reference.md`.
