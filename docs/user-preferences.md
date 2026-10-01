# User standing preferences (compiled from chat history)

Standing directives from the operator, distilled from every session and
enforced here so no turn re-derives them. Newest understanding wins on
conflict; amend by explicit instruction only.

## Evidence and honesty

- **P1. Verify before synthesizing.** Read files, run commands, check
  served state before claiming. Evidence-backed claims beat speculation;
  uncertainty is stated with its mechanism, never hidden.
- **P8. Honest accounting.** Report costs, side effects, mistakes, and
  negative results plainly (e.g. +$0.13 mistyped prompt, unattributed
  flakes, failed probes). Never silently retry past a failure.
- **P13. Root causes, correctly attributed.** Distinguish product vs
  harness-artifact vs upstream bugs with differential proof; fix the
  layer that's actually broken.

## Working loop

- **P2. Prompt contract + explicit audit, never skipped.** Objective,
  context, constraints, deliverable, acceptance, evidence, out-of-scope —
  then a criterion-by-criterion audit with verdicts before code.
- **P3. Test to done or impossible.** Do not stop until deliverables are
  tested green or proven impossible (with the blocking evidence shown).
  One flake is investigated, never retried blind.
- **P9. Scope discipline.** One segment per session; explicit out-of-scope
  list; deferrals recorded with reasons, never dropped silently.
- **P6. Push after gates.** lint/hygiene/dashboard/ux-test as applicable;
  clean tree; push receipt shown.

## Visibility and verification

- **P4. Browser automation, visibly.** Playwright (primary) and Selenium
  (requested alternative) for audits, captures, and interaction proofs;
  screenshots and video frames shown in responses. browser-use is
  installed but model-blocked (DeepSeek rejects json_schema) — documented,
  not retried blindly. xdo/Xvfb exist but are pointless headless.
- **P5. Prove at the layer the user sees.** Browser-context fetches,
  served-rev checks before every probe (stale-server artifacts wasted
  multiple sessions), marker-aware waits, progress-not-stall semantics.
- **P11. Deterministic probes over agentic wandering** for anything
  regression-grade; skeptical human judgment over plausible narratives.

## Communication

- **P7. Paste-ready instructions, always.** Exact commands with expected
  outputs. Recurring bare names get wrapper scripts (e.g.
  `web-restart.sh`), not repeated instructions.
- **P12. Verified citations.** External claims carry curl-checked URLs
  or confirmed ISBNs in verbose comments + README References. Dead
  paths are replaced, never cited; self-caught errors fixed pre-commit.

## Safety and repo care

- **P10. Secrets hygiene.** Never print secret values; compare hashes,
  report lengths; quote placeholders so `source .env.local` never
  aborts; prefer env over flags (no history leakage).
- **P14. Existing tools first.** Repo catalog, then installed tooling;
  new dependencies justified, not assumed. Guard blocks are obeyed
  (routed around with better patterns, never disabled to suit the task).
- **Docs as deliverables.** README/TODO/HANDOFF updated with changes;
  videos and screenshots land as proof artifacts under `docs/ux/`
  within the media budget (video <=2MiB, images <=150KiB, enforced by
  `media-budget.sh`).
