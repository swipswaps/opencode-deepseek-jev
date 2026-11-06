# Usability testing: protocol, code, and evidence

This document states what `scripts/usability-suite.py` measures, why each
threshold exists, what it cannot measure, and the sources behind it. The
guiding rule is falsifiability: every check has an operational definition and
a pre-registered pass condition in code; a failing observation is a
counterexample, not an opinion.

## 1. Research question and constructs

**Question.** Does the served UI meet a reproducible set of task, accessibility,
and experience criteria for the *current revision*?

Usability is defined as the extent to which specified users can use a system
to achieve specified goals with **effectiveness, efficiency, and satisfaction**
in a specified context of use (ISO 9241-11:2018). The suite operationalises
those constructs as follows:

| Construct | Operational definition | Threshold | Source |
|-----------|------------------------|-----------|--------|
| Effectiveness | proportion of scripted tasks completed correctly in one run | `>= 0.90` | ISO 9241-11 |
| Efficiency | median time-on-task for successful tasks | `<= 10 s` | ISO 9241-11 + Nielsen's 10-second limit |
| Satisfaction | System Usability Scale (10 items, 1–5) | `>= 68` when supplied | Brooke 1996; Lewis 2018 |
| Accessibility | automated WCAG 2.2 A/AA subset failures | `0` | W3C WCAG 2.2 |
| Touch/pointer targets | non-inline targets below 24×24 CSS px | `0` | WCAG 2.2 SC 2.5.8 |
| Reflow | no horizontal scrolling at a 320 CSS px viewport | `0` overflow | WCAG 2.2 SC 1.4.10 |
| Loading | Largest Contentful Paint (lab) | `<= 2500 ms` | web.dev Core Web Vitals |
| Visual stability | Cumulative Layout Shift (lab) | `<= 0.1` | web.dev Core Web Vitals |
| Interactivity | Interaction to Next Paint | field-only | web.dev Core Web Vitals |
| Feedback | async `[data-loading]` markers resolve | all cleared | Nielsen heuristics #1 |
| Keyboard | first Tab reaches the skip link; focus is visible | `0` failures | WCAG 2.2 |
| Motion | moving elements under `prefers-reduced-motion: reduce` | `0` | MDN media feature |

The "satisfaction" axis is **not invented** from automated data. If no SUS
responses are supplied (`--sus` or `--sus-file`), the axis is SKIP. This is a
deliberate refusal to equate a passing build with user satisfaction.

## 2. Method

1. **Static layer (always available).** Fetch every served route; assert HTTP
   200; run the repo's `a11y-audit.mjs` (language, title, viewport, skip link,
   landmarks, image alt, heading tree, control names, focus visibility,
   reduced-motion guard, theme contrast). This layer needs no browser and is
   suitable for a 30-minute timer.
2. **Browser layer (Playwright).** For each route: wait for async markers,
   collect console/page errors, measure LCP/CLS with `PerformanceObserver`
   (buffered), count undersized targets, run a 10-stop keyboard tab probe,
   test reflow at 320 px, and (optionally) run axe-core with WCAG A/AA tags.
3. **Task layer.** Seven scripted tasks (one per route): search sessions, select
   a graph node, switch to Explore signals, filter runbooks, read the model
   catalog, filter managed tools, read `RULES.md`. Success is a binary
   observation; elapse time is recorded for successful tasks.
4. **Scoring.** Per-axis pass/fail/skip counts and a pass ratio; the run verdict
   is FAIL if any hard check fails. SKIP is never counted as PASS.
5. **Persistence.** `usability_run` + `usability_result` rows in
   `data/observability/observability.db`, plus
   `data/observability/usability.json`. Each row carries its threshold and
   citation so the evidence survives the session.

A task is attempted once per run. Repeated runs across revisions create a
longitudinal series; a single run is a screen, not a human-subject study.

## 3. Why these tools and patterns

- **axe-core** is the rules engine behind most automated accessibility
  scanners. Its own documentation is explicit that it finds on average ~57% of
  WCAG issues and that "incomplete" results need manual review. We therefore
  use it as a *screen*, not a conformance claim.
- **Playwright** is used with `page.evaluate`, never a string predicate in
  `wait_for_function`. The dashboard sends a strict CSP without
  `unsafe-eval`; string predicates are compiled in-page and fail with
  `EvalError` (reproduced in Playwright issues #7395 and #16357). `evaluate`
  is CSP-clean, which is why the task/poll helpers use it.
- **web-vitals** is the reference implementation for LCP/CLS/INP measurement.
  Our lab probe re-implements the public PerformanceObserver parts only; it is
  not a substitute for the field P75.
- **SUS** is scored with the standard alternating-item formula
  (`odd: score-1`, `even: 5-score`, sum × 2.5). Lewis (2018) reviews its
  reliability and the conventional 68-point average.

## 4. Validity and threats (why a green run is not "usable")

| Threat | Effect | Mitigation in this repo |
|--------|--------|--------------------------|
| Construct validity | lab CWV ≠ field P75; automation ≠ disabled-user experience | CWV rows say "lab probe"; WCAG caveat on every snapshot; manual/SUS path |
| Internal validity | cold dashboard, host load, first-run cache | repeated timer runs; timestamps + revision in every row; bounded waits with named evidence |
| External validity | one browser engine, 1440/390/320 px, no screen reader | state the limits; run axe/manual review separately |
| Statistical conclusion validity | one observation per task, no participant sample; no p-values | no significance claims; effectiveness is descriptive; SUS is optional human data |
| Automation bias | a green badge is over-trusted | SKIP ≠ PASS; citations in every row; `caveat` field; automation-bias source |
| Goodhart's law | optimizing the scripted task, not the user goal | tasks are goal-shaped (find, filter, read) and reviewed when the UI changes |

Automation is a **guardrail**, not a verdict on user experience. The relevant
failure mode is *misuse* of automation (Parasuraman & Riley, 1997): treating a
screening instrument as a substitute for judgement.

## 5. Running it

```bash
# offline grader test (no server, no browser)
./scripts/usability-suite.py --self-test

# cheap, no browser (HTTP + WCAG automated subset)
./scripts/usability-suite.py --static-only --base http://127.0.0.1:5099

# full layer when Playwright is installed; --axe when axe-core is installed
python3 -m pip install playwright && python3 -m playwright install chromium
npm install --no-save axe-core
./scripts/usability-suite.py --browser --axe

# human satisfaction (optional): 10 integers 1..5, or a JSON file
./scripts/usability-suite.py --sus
./scripts/usability-suite.py --sus-file logs/sus.json

# history / machine output
./scripts/usability-suite.py --json
```

`--watch SEC` runs continuously with an exclusive lock (no overlapping
browsers); `--runs N` bounds it for a test. The lock is the guard against
automation stacking.

## 6. Guided human test (in-app and terminal)

The automated layer cannot judge whether a person understood a goal. The guided
layer records that judgement without fabricating it.

- **In the app:** open `/usability` (classic) or the **Usability** view in the
  MUI app (`/app/#usability`). The page shows the automated evidence, then a
  guided runner: one goal at a time, a live timer, Done/Failed/Skip, difficulty
  1-5, a note, and the 10 SUS items. Submitting writes a human session through
  `POST /api/usability/guided`; the history table shows effectiveness, median
  time, SUS, and completion. The MUI Overview also carries the **Project
  pulse** card, so status and decisions are visible where the user starts.
- **In the terminal:** `./scripts/usability-guided.py --interactive` walks the
  same `scripts/usability-tasks.json`; `--import` ingests the JSON the app
  submits; `--list` reads history.
- **Facilitator with page automation:** `./scripts/usability-guide.sh
  --opener auto` (xdg-open, already-open CDP browser, headed Playwright, or
  Selenium; fallback print). This is the optional "how to guide" for a host
  with a browser; the in-app runner needs no driver.
- **Data:** `usability_guided` rows + `data/observability/usability-guided.json`.
  This is deliberately separate from `usability_run` so a green automated
  screen is never mistaken for a human result.
- **Task script:** seven goals (pulse, search, graph selection, explore
  signals, runbook filter, model policy, rules doc), each with a success
  criterion. Change the JSON once; the app and CLI both follow it.

Scoring: effectiveness = successes / tasks; efficiency = median time-on-task
for successful tasks; satisfaction = SUS (alternating items x 2.5). A task
marked skip is excluded from success but stays in the denominator and is
reported, so partial sessions cannot look complete.

### First guided session (2026-11-06, baseline)

The first real session was chat-guided on the MUI app, rev `56fd53d`:
effectiveness **0/7**. The participant reported no Project pulse card in
`/app/`, and `/app/explore`, `/app/runbooks`, `/app/models`, `/app/docs`
returned "not found"; the graph task failed. Those findings drove three fixes:
the MUI Project pulse card, the MUI Usability view (this runner), and a server
redirect from `/app/<legacy>` to `/<legacy>`. The session is stored as
`chat-guided` in `usability_guided`; the raw record is
[`docs/evidence/usability-guided-20261106.json`](evidence/usability-guided-20261106.json).
It is the baseline for the retest, not a claim that the current build passes.

### Closeout: do not say "done" before the gate

RULES #93 and `scripts/closeout-gate.py` make the completion questions
explicit. The gate checks root, build freshness, `served==HEAD`, the last gate,
a **new** guided session after the UI change, tracked script references, and
the citation log.

```bash
./scripts/closeout-gate.py --check
./scripts/web-build-restart.sh     # build in web/, restart from the repo root
```

`cd web && ./scripts/web-restart.sh` fails with "No such file or directory"
because the second path is relative to `web/`; use the wrapper or `cd ..`.
A blocking item can be deferred only with a recorded reason:

```bash
./scripts/closeout-gate.py --answer retest=defer --reason "waiting on operator retest"
```

## 7. Always be testing

- **Timer (host, no sudo):** `./scripts/usability-install.sh` installs a
  user-level `opencode-usability.timer` that runs the static layer every 30
  minutes. `--full` bakes the browser layer instead; it falls back to static
  when Playwright is absent.
- **CI:** `.github/workflows/usability.yml` runs the static screen on every
  push/PR and the Playwright + axe layer nightly and on demand. The fixture DB
  is generated with `test-fixture-db.sh`, so no secret or live store is needed.
- **Gate:** `test-hygiene.sh` runs `usability-suite.py --self-test`; the
  dashboard test already asserts the pages and `/graph` execute headlessly.

## 8. References (verified 2026-11-06)

Standards and official documentation:

1. ISO 9241-11:2018, *Ergonomics of human-system interaction — Part 11:
   Usability: Definitions and concepts*.
   https://www.iso.org/standard/63500.html
2. ISO 9241-210:2019, *Human-centred design for interactive systems*.
   https://www.iso.org/standard/77520.html
3. W3C, *Web Content Accessibility Guidelines (WCAG) 2.2*, Recommendation
   12 December 2024. https://www.w3.org/TR/WCAG22/
4. W3C WAI, *Understanding SC 2.5.8: Target Size (Minimum)*.
   https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html
5. W3C WAI, *Understanding SC 1.4.10: Reflow*.
   https://www.w3.org/WAI/WCAG22/Understanding/reflow.html
6. MDN, *prefers-reduced-motion*.
   https://developer.mozilla.org/en-US/docs/Web/CSS/@media/prefers-reduced-motion
7. Playwright, *Accessibility testing*.
   https://playwright.dev/docs/accessibility-testing
8. Playwright, *Frame.evaluate*.
   https://playwright.dev/python/docs/api/class-frame
9. Google, *Web Vitals* (LCP ≤ 2.5 s, INP ≤ 200 ms, CLS ≤ 0.1; P75).
   https://web.dev/articles/vitals

Popular open-source implementations:

10. Deque, *axe-core* (MPL-2.0).
    https://github.com/dequelabs/axe-core
11. GoogleChrome, *web-vitals* (Apache-2.0).
    https://github.com/GoogleChrome/web-vitals

Peer-reviewed / books:

12. Nielsen, J. (1993). *Usability Engineering*. Morgan Kaufmann.
    ISBN 978-0-12-518406-9 (ISBN-10 0-12-518406-9).
13. Lewis, J. R. (2018). The System Usability Scale: Past, Present, and
    Future. *International Journal of Human–Computer Interaction*, 34(7),
    577–590. https://doi.org/10.1080/10447318.2018.1455307
14. Parasuraman, R., & Riley, V. (1997). Humans and Automation: Use, Misuse,
    Disuse, Abuse. *Human Factors*, 39(2), 230–253.
    https://doi.org/10.1518/001872097778543886
15. Brooke, J. (1996). SUS: A "quick and dirty" usability scale. In
    *Usability Evaluation in Industry*. The open, verifiable route to the
    instrument and its scoring is Lewis (2018), DOI above.

Reputable forum / issue threads (engineering practice, not standards):

16. microsoft/playwright issue #7395, `waitForFunction` and CSP `unsafe-eval`.
    https://github.com/microsoft/playwright/issues/7395
17. microsoft/playwright issue #16357, CSP `unsafe-eval` during waits.
    https://github.com/microsoft/playwright/issues/16357
18. Nielsen Norman Group, *10 Usability Heuristics for User Interface Design*
    (1994, reviewed 2024).
    https://www.nngroup.com/articles/ten-usability-heuristics/

### Verification log

Fetched on 2026-11-06 (HTTP 200 unless noted):

| Reference | What was checked |
|-----------|------------------|
| iso.org/standard/63500.html · 77520.html | title, edition, published status |
| w3.org/TR/WCAG22/ | W3C Recommendation 12 Dec 2024 |
| w3.org/WAI/WCAG22/Understanding/{target-size-minimum,reflow}.html | normative thresholds 24 px and 320 px |
| playwright.dev/docs/accessibility-testing | axe-core examples + automated-testing disclaimer |
| web.dev/articles/vitals | LCP 2.5 s, INP 200 ms, CLS 0.1, P75 |
| github.com/dequelabs/axe-core · GoogleChrome/web-vitals | rule engine and metric implementation |
| doi.org/10.1080/10447318.2018.1455307 · 10.1518/001872097778543886 | DOI resolves to the cited articles |
| openlibrary.org/books/OL9283004M.json | ISBN-10 0125184069 / ISBN-13 9780125184069 |
| github.com/microsoft/playwright/issues/7395 · 16357 | CSP `unsafe-eval` reproductions |
| developer.mozilla.org/.../prefers-reduced-motion | feature semantics |

A source that could not be verified is not cited. Stack Overflow was searched
for the axe/WCAG-tag question but returned HTTP 403 to the automated check, so
it is not included; the GitHub issue threads above are the engineering-practice
citations instead.

## 9. Known limits

- axe-core covers only a subset of WCAG; manual keyboard/screen-reader review
  and testing with disabled users remain required.
- The single-run LCP/CLS probe is diagnostic; Core Web Vitals compliance is a
  field P75 property.
- INP is not measured in the lab; the suite records a SKIP with that reason.
- SUS requires real respondents; the suite never fabricates a satisfaction
  score.
- The scripted tasks are a proxy for user goals, not a substitute for
  moderated task observation.
