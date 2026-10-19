# PR: refresh README screenshots and the .webm tour for the newest panels

Status: **capture script extended; pixels require a host browser.**

## Why

`docs/ux/status-{home,board,trends}.png` were captured 2026-10-16. Since then
the UX gained drill-down on the health, patterns, pivot and word-cloud panels
(2026-10-19), but `panels-tour.py` only captured home/board/trends. The README
therefore omits the newest surfaces.

## Blocker (measured, not assumed)

The container has no browser: `google-chrome`/`chromium` are absent,
Playwright is not installed, and no CDP endpoint answers on `:9222`
(`cdp-tab.mjs tabs` -> SKIP). `panels-tour.py` launches its own chromium, so it
must run on the host.

## Changes

- `scripts/panels-tour.py`: capture six panels (`home`, `overview`, `board`,
  `trends`, `signals`, `patterns`); `--check` reports which expected
  `status-<panel>.png` are missing; `--self-test` asserts the panel set.
- `README.md`: list the six expected shots, document `--check`, and state that
  signals/patterns shots need the host capture before they are embedded.
- (Proposed, not done) `test-hygiene.sh`: assert every README `![](...)` media
  path exists, so a missing/renamed shot fails the gate.

## Host run (one command)

    python3 scripts/panels-tour.py            # needs: playwright install chromium
    python3 scripts/panels-tour.py --check    # 6/6 expected shots present

Then commit the new `docs/ux/status-{overview,signals,patterns}.png` and the
refreshed `tour.webm`, and embed the two new panels in README.md.

## Acceptance

- `--check` reports 6/6 and exits 0.
- Each PNG is under the 150 KiB media budget (`media-budget.sh`).
- The `.webm` stays short (the tour visits six panels).
- `test-hygiene.sh` is green (README media paths resolve).

## Risks

- Capturing against a scratch build is fine (test-dashboard already does);
  capture against `:5099` to match the served product. Do not include secrets
  or session text beyond what the current shots already show.
