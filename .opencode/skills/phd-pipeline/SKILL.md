---
name: phd-pipeline
description: Use when the user asks in "PhD terms" for audit/deduce/prompt work, or invokes the audit → deduce → write → audit → upgrade → implement → explain loop (including "//re:" follow-ups and "do not skip this step"). Grounds every claim in repo/DB evidence and makes each step checkable without re-reading the chat.
---

The user's stable interaction contract, measured over 1286 user turns
(audit 298, //re: 180, deduce 164, prove/proof 161, handoff 128,
"phd terms" 92): evidence before synthesis, falsifiable outcomes, raw
output pasted back, no summary-only claims.

## The loop (never skip the audit step)

1. **Deduce.** Order candidate next steps by expected gain per unit of
   irreversible risk, citing DB/repo evidence (counts, costs, session ids).
   State the decision rule and the losing option with its reason.
2. **Write (prompt v1).** Follow the repo's prompt contract (HANDOFF.md
   "Writing the next prompt"): Objective / Context / Constraints /
   Deliverable / Acceptance criteria / Evidence / Out of scope.
3. **Audit (v1 defects).** Critique v1 in writing: unfalsifiable verbs,
   duplicated coverage, missing first-run/cursor doctrine, portability
   traps, contract changes (--json, gates), fixture determinism, vague
   docs, safety scope (advisory vs enforcement). Number each finding.
4. **Upgrade (prompt v2).** Reissue the prompt with every finding
   incorporated. This step is mandatory even when v1 looks clean.
5. **Implement (execute v2).** Build it, then prove it: self-tests,
   gate runs, second-sweep/cursor checks. The verification loop catches
   what review misses — report what it caught.
6. **Explain.** Deduction recap, v1 → audit → v2 trail, what was built,
   the evidence, and what remains explicitly out of scope.

## Conventions honored here

- `//re: "<claim>"` (180 turns): reply to that specific prior claim with
  evidence; never answer a different question.
- "prove it / with playwright mcp if needed": run the check, paste raw
  output; a passing assertion quoted from memory is not proof.
- "type ok" / "proceed": continue the agreed plan, no re-derivation.
- Prompts are interface contracts: a prompt a fresh session cannot
  execute blindly is a draft, not a deliverable.
