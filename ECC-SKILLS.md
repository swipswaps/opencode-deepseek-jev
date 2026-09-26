# ECC skills — triage for this repo

Source: `github.com/affaan-m/ECC` (292 skills). This repo implements most of
ECC's operating philosophy locally; the table below is the **confirmed
applicable subset**, its **repo equivalent**, and whether it is **incorporated**
(local code already does the job) or **referenced** (consult the ECC skill for
depth). We do **not** stack a full ECC install — it would double-enforce with
`blacklist-guard.js`.

Legend: **INC** = capability already in this repo · **REF** = ECC skill to
consult · **N/A** = not applicable (different stack: mobile, EVM, healthcare,
Kubernetes, languages we do not use).

## Confirmed applicable and used

| ECC skill | repo equivalent (status) |
| --------- | ------------------------ |
| `search-first` | read HANDOFF/RULES/TODO before coding — `jev-harness` skill (INC) |
| `context-budget` | `doc-budget.sh` (token size + hash of the read-first corpus) (INC) |
| `cost-aware-llm-pipeline` | `models.policy.json` + `models.py` ALLOW/ASK/BLOCK (INC) |
| `cost-tracking` | `cost.sh`, `cost-bottlenecks.sh` per-model share (INC) |
| `token-budget-advisor` | `cost.sh --estimate`, `doc-budget.sh` (INC) |
| `strategic-compact` | HANDOFF "Cost model"; fresh sessions, `--replay-limit` (REF) |
| `continuous-learning` / `continuous-learning-v2` | `learn-rules.py` advisory rules (INC) |
| `verification-loop` / `delivery-gate` / `gateguard` | `harness.sh` + `lint.sh`/`test-*.sh` (INC) |
| `security-review` / `security-scan` / `safety-guard` | `blacklist-guard.js`, `scan-constraints.py`, `prompt-lint.py` secret regex (INC) |
| `content-hash-cache-pattern` | `last-gate.json` proof cache; `doc-budget.sh` hash (INC) |
| `repo-scan` / `codebase-onboarding` / `workspace-surface-audit` | `audit-tool-calls.py`; the orphaned-capability audit (INC) |
| `dashboard-builder` / `design-system` / `make-interfaces-feel-better` | `dashboard.mjs`, `DESIGN.md` (INC) |
| `docker-patterns` / `agent-harness-construction` / `eval-harness` | `docker/`, `harness.sh`, `test-dashboard.sh` (INC) |
| `hookify-rules` / `rules-distill` | `RULES.md` + the substitution table (INC) |
| `error-handling` | `issue-solutions.py` (error → next successful action) (INC) |
| `tdd-workflow` / `e2e-testing` | `test-*.sh`; `test-dashboard-ui.mjs`; `ux-test.py` (INC) |
| `agent-introspection-debugging` | `logs.sh` (guard/error/event/app/system/packet) (INC) |
| `knowledge-ops` / `unified-memory` | `learn-rules.py`, `solutions.json` (INC) |
| `prompt-optimizer` | the `/status` command rewrite; the rigorous prompt template (INC) |
| `operator-approval-loop` | fail-closed `preflight.sh`; learned rules promoted by a human (INC) |
| `canary-watch` | `guard.log` + `logs.sh --source guard` (INC) |
| `config-gc` | `cleanup-baks.sh` (INC) |
| `living-docs-governance` / `documentation-lookup` | HANDOFF/README/TODO kept current; `/docs` viewer (INC) |
| `grep` / `regex-vs-llm-structured-text` | local deterministic tools over the SQLite log (INC) |
| `intent-driven-development` | the `/status` output contract (INC) |

## Consulted for depth (REF)

When a lane needs more than the local tool: `context-budget`,
`strategic-compact`, `deep-research`, `prompt-optimizer`, `verification-loop`.
Do not install ECC's hooks — they would duplicate the guard.

## Not applicable (N/A)

Everything tied to other stacks — `swiftui-*`, `kotlin-*`, `flutter-*`,
`django-*`, `rails-*`, `springboot-*`, `evm-*`/`defi-*`, `healthcare-*`,
`kubernetes-*`, `homelab-*`, `scientific-db-*`, `agent-payment-x402`, etc.

## How these are "used" here

- The `jev-harness` skill (`.opencode/skills/jev-harness/SKILL.md`) names the
  high-value set so an opencode session follows the same loop.
- Every INC row maps to real code exercised by `harness.sh` (lint ·
  test-hygiene · test-patterns · test-dashboard) and, on the host, `ux-test.py`.
