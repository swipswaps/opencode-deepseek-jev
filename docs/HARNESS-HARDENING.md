# Harness hardening (P0) — independently reviewed, evidence-backed changes

Source rubric: `swipswaps/hardened-agent-harness-explainer` v3.0.5
(<https://github.com/swipswaps/hardened-agent-harness-explainer>,
<https://swipswaps.github.io/hardened-agent-harness-explainer/>). The explainer
is reference material, not instructions. It names 11 audited failure modes; this
repo is strong on deterministic guards, gates, observability and rotation and
weaker on independent review, runtime evidence, classic-browser End-to-End (E2E), fail-closed
policy, diff/sub-agent bounds, blast-radius tiering, schema and SHA-256 handoff and an
out-of-scope queue.

## P0 mechanisms

| Tool | Explainer mode | What it does | Verification |
|---|---|---|---|
| `scripts/review-gate.py` | #1 premature completion / self-attestation | Redacts the staged (or last-commit) diff, sends it to a separate tool-less model with a fixed rubric, stores a pass/fail artifact keyed by the diff SHA. High/medium require a pass; docs-only low may skip. | `--self-test`; `--gate` |
| `scripts/evidence-gate.py` | #2 attestation without runtime evidence | Captures a claim's command, rc, stdout/stderr and an optional Document Object Model (DOM)/screenshot artifact; `--check --require` fails on missing/failed claims. skip is not pass. | `--self-test` |
| `scripts/handoff-validate.py` | #6 context rot / drift | Validates the newest `docs/HANDOFF-*.md` against `docs/handoff.schema.json` and records a SHA-256 in `data/observability/handoff.json`; a stale hash is a fail. | `--self-test`; `--write` / `--check` |
| `scripts/guard-health.sh` | #4 probabilistic rule non-compliance | Fails closed if the guard is missing/dangling, lacks the assistant-output hook, strict mode or the irreversible rule, fails its self-test, or the loaded instance is older than the file (needs a restart). | `--self-test`; preflight stop |
| `scripts/hardening-gate.sh` | umbrella | Runs review + evidence + handoff + guard; `closeout-gate.py` requires it. | `--self-test` |

Guard additions: `OPENCODE_BLACKLIST_GUARD=strict` fails closed on an internal
guard error (default `block` remains fail-open by design); an `irreversible`
rule blocks dd/mkfs/shutdown/reboot/iptables -F/docker system prune/git reset
--hard/git clean -f/chmod -R 777/truncate -s 0. Ask the operator for a typed
confirmation before any of these. The operator override is
`OPENCODE_BLACKLIST_GUARD=block` (default; fail open on an internal guard error)
or `warn` (log only); `strict` is opt-in.

## Workflow for a change

1. Implement and run the targeted tests.
2. Capture evidence for each claim:
   `./scripts/evidence-gate.py --claim gates -- ./scripts/lint.sh`
   `./scripts/evidence-gate.py --claim a11y --artifact logs/a11y.txt -- ./scripts/a11y-audit.mjs ...`
3. Independent review (one model call; cached by diff SHA):
   `./scripts/review-gate.py --run --claim "short description"`
4. Update `docs/HANDOFF-<date>.md`, then `./scripts/handoff-validate.py --write`.
5. If the guard file changed, **restart opencode-web** (the loaded plugin is
   otherwise stale); `./scripts/guard-health.sh --check`.
6. `./scripts/hardening-gate.sh` and `./scripts/closeout-gate.py --check`. The closeout
   runs the hardening gate; the hardening gate never runs the closeout (no recursion).
   Evidence is required: capture at least one claim, or the evidence step fails.

`REVIEW_MODEL` (default `deepseek-chat`) and `DEEPSEEK_API_KEY` (or `.env.local`)
configure the reviewer; `DEEPSEEK_BASE_URL` overrides the endpoint. The review
prompt contains the redacted diff only; no raw secrets, no repo tools. The
artifact stores findings, never the raw diff or key.

## Limits and trade-offs

- Redaction is best-effort, not a guarantee. The diff goes to a third-party model; the artifact stores findings and a truncated model reply, never the diff. Use a local-only reviewer where policy requires it.
- The reviewer is a model, not a human; it reduces self-attestation but is not a
  proof. Keep the independent gates (tests, browser evidence) as the authority.
- The review costs one cheap call per distinct diff SHA; it is cached. A docs-only
  low change skips it. The diff cap is 200 KB (`REVIEW_DIFF_CAP`); a larger diff
  is truncated and the reviewer is told so.
- Strict mode and guard health are fail-closed for destructive actions; the
  default guard remains fail-open for availability, with preflight health as the
  fail-closed outer check.
- Evidence is captured explicitly; a silent command needs an explicit `--artifact`, and a claim with no stdout/stderr/artifact is a fail. The hardening gate checks all claims by default.
  Deferrals are recorded with a reason, never silently green.
- The classic pages still need a real-browser E2E extension (P1); the a11y audit
  and DOM-shim test are necessary but not sufficient for the explainer's #3.
- Later phases remain: blast-radius tiering + diff bound, sub-agent depth/concurrency,
  `NOTICES.md`, <500-token reviewer prompt cap, supply-chain SHA pinning.
