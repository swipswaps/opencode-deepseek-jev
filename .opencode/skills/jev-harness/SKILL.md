---
name: jev-harness
description: Use when working in the opencode-deepseek-jev repo (or any session where the user says harness, gate, preflight, blacklist, guard, cost, model policy, HANDOFF, TODO, learn-rules, issue-solutions, or observability). Codifies the search-first -> gate -> guard -> learn -> document loop so cost stays on policy and every change is proven before push.
---

# jev-harness

The working process for this repo, adapted from the ECC agent-harness pattern
(`plan -> test -> implement -> review -> verify -> remember -> improve`).
Follow it instead of re-deriving the workflow each session.

## 1. Search first (before writing anything)

1. Read `HANDOFF.md` (durable state), `RULES.md` (constraints), `TODO.md` (queue).
2. Run `./scripts/preflight.sh`. If it prints **STOP**, fix that cause first —
   it is fail-closed on missing keys, a red last-gate marker, balance below
   `MIN_BALANCE`, or a model outside `models.policy.json`.
3. Run `./scripts/harness.sh --fast` for the current state (gates + telemetry +
   cost + TODO) without the slow dashboard gate.

## 2. Constraints that are enforced, not advised

- `.opencode/plugins/blacklist-guard.js` runs on **your own tool calls** during
  Thinking: `sed`, `rm -rf`, `subprocess.run` are blocked; `2>/dev/null` is
  **removed** (stderr is the proof — never hide it); `echo` warns.
- Use `awk` / `grep` / `python3` instead of `sed`; `printf '%s\n'` instead of
  `echo`; `subprocess.Popen(..., PIPE)` instead of `subprocess.run`. See
  `RULES.md` "Substitutions for the blacklist".
- `data/opencode/opencode.db` is **read-only**. Never write it.
- `RULES.md` #61: a served page's inline `<script>` must both parse
  (`node --check`) and execute headlessly (`test-dashboard-ui.mjs`). No inline
  handlers; use `data-*` + delegated listeners.

## 3. Cost and model policy

- `./scripts/models.sh` shows the catalog and the ALLOW / ASK / BLOCK verdict
  from `models.policy.json`. Prefer free models or `deepseek-flash`; `v4-pro`
  is deny-listed (2.9x).
- Keep sessions short (context is the cost driver) and check
  `./scripts/cost-bottlenecks.sh` "model mix" after anything unusual.
- The interactive chooser is the `/models` page on the observer UI.

## 4. Deliver gate (before every push)

    ./scripts/harness.sh          # lint + test-hygiene + test-patterns + test-dashboard

A failing gate is reported and the run continues; fix it, do not raise a
timeout. Every check line carries `ms=` and the slowest is named — use that,
not a deadline.

## 5. Learning loop (remember -> improve)

- `./scripts/learn-rules.py --since-days 30 --write` — contrastive
  (state, action, outcome) rules; advisory avoid/prefer/recovery.
- `./scripts/issue-solutions.py` — recurring errors and the action that fixed
  each, proven by the logs.
- `./scripts/logs.sh --source signal` — guard actions + tool errors + traces.
- Promote a confirmed rule into `RULES.md` / the guard blacklist to make it
  deterministic; the corpus supplies evidence, the harness enforces, a person
  decides.

## 6. Done means

- All gates green (`harness.sh`), inline scripts parse AND run.
- Docs updated: `HANDOFF.md` (state), `TODO.md` (queue), `README.txt`, and
  `scripts/README.txt` for any new script.
- `guard.log` shows no new unexpected `block`/`learned` for the work done.

## ECC lineage

This repo implements much of ECC's philosophy locally. The **confirmed
applicable subset** (with its repo equivalent and status) is `ECC-SKILLS.md`.
The high-value set to keep in mind: `search-first`, `cost-aware-llm-pipeline`,
`context-budget`, `content-hash-cache-pattern`, `continuous-learning`,
`verification-loop`/`delivery-gate`, `security-review`, `dashboard-builder`,
`design-system`, `error-handling`, `agent-introspection-debugging`. Consult
the ECC skill for depth; do **not** stack a second install (it would duplicate
`blacklist-guard.js`). Prefer the repo's own tools first.
