# PR: enforce WCAG basics on the served dashboard

Status: **implemented in this tree** (keep this file as the PR body/record).

## Why

The dashboard is a served web app, so accessibility is a gate, not a taste
call. A prior session explicitly deferred "Lighthouse/axe/clinic" and
"screen-reader certification, reduced-motion, contrast redesign, treemap/sankey
keyboard inspection" as out of scope. The audit below closes the deterministic
part of that gap without adding a browser or network dependency.

## Changes

- `scripts/a11y-audit.mjs` (new): offline audit of served HTML for
  `html[lang]`, title, viewport, exactly one `h1` with no skipped levels, a
  skip link whose target has `tabindex="-1"`, a named `nav` landmark, image
  `alt`, accessible names for buttons/inputs/`role=button|link`, a visible
  `:focus-visible` outline (and no stray `outline:none`), `prefers-reduced-motion`
  when motion CSS exists, and WCAG contrast for the dark/light theme tokens.
  Inputs: files or `--url`; `--json`; `--self-test` (good + bad fixture).
- `scripts/dashboard.mjs`: `<main id="main" tabindex="-1">`; `nav` gains
  `aria-label="Primary"`; removed `outline:none` from the command-palette input;
  the Gantt drill rectangles gain `aria-label` and Enter/Space activation
  (they already had `role=link` + `tabindex=0` + click).
- `scripts/test-dashboard.sh`: runs the audit against the scratch build, so a
  regression is a red gate.
- `scripts/tools.json` + `scripts/README.txt`: catalog the new tool (the
  script-catalog hygiene gate requires it).

## Acceptance / test plan

    node scripts/a11y-audit.mjs --self-test          # 11 checks, PASS
    ./scripts/test-dashboard.sh                       # a11y line PASS
    ./scripts/harness.sh                              # 4/0

Falsified: the served pages before the fix fail `skip link` and
`landmark names` for all six routes; after the fix the scratch build passes
22 checks over home + explore.

## Risks / limits

- Regex-based markup checks are intentionally shallow; they do not prove
  screen-reader behaviour. That needs a host browser + axe/Lighthouse, which is
  a separate budgeted decision (see `TOOL-AUDIT.md`).
- Contrast is checked from the theme tokens, not every computed element.
- No new runtime dependency; no network in the gate.

## Rollback

Revert the commit; the audit is additive and the dashboard edits are
declarative attributes.
