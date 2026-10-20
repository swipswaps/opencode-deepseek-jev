# PR pack — plans as pull requests

Repo: `swipswaps/opencode-deepseek-jev` · integration branch: `main`
Base for the branches: `main` at `4d24e56` (2026-10-20).

The three plans are **implemented on `main`**. Each PR branch adds a small
status record (`docs/pr/PR-0X-status.md`) so the review/audit trail is
mergeable without rewriting history. `gh` is absent in the container — run the
`gh` commands on the authenticated host.

| PR | Title | Branch | Compare URL | Status |
|---|---|---|---|---|
| 01 | a11y: WCAG basics gate + keyboard-operable chart marks | `pr/01-a11y-hardening` | https://github.com/swipswaps/opencode-deepseek-jev/compare/main...pr/01-a11y-hardening?expand=1 | implemented (`e063e79`, `90fb1e1`); PR = status record |
| 02 | docs/media: refresh README shots for the newest panels | `pr/02-media-refresh` | https://github.com/swipswaps/opencode-deepseek-jev/compare/main...pr/02-media-refresh?expand=1 | implemented (`04c49e4`, `9af9f7b`); PR = status record |
| 03 | durable: arm the background agents in one command | `pr/03-durable-agents` | https://github.com/swipswaps/opencode-deepseek-jev/compare/main...pr/03-durable-agents?expand=1 | implemented (`e063e79`, `0d0b8d8`, `4d24e56`); armed on host 2026-10-20 |

## Open them (host, authenticated)

```bash
gh pr create --repo swipswaps/opencode-deepseek-jev --base main \
  --head pr/01-a11y-hardening \
  --title "a11y: WCAG basics gate + keyboard-operable chart marks" \
  --body-file docs/plans/PR-01-a11y-hardening.md

gh pr create --repo swipswaps/opencode-deepseek-jev --base main \
  --head pr/02-media-refresh \
  --title "docs/media: refresh README shots for the newest panels" \
  --body-file docs/plans/PR-02-media-refresh.md

gh pr create --repo swipswaps/opencode-deepseek-jev --base main \
  --head pr/03-durable-agents \
  --title "durable: arm the background agents in one command" \
  --body-file docs/plans/PR-03-pi-durable-automation.md
```

## Review checklist (all three)

- The body file is the plan/record; the branch diff is the status card only.
- Evidence in the status card matches the current gate: `harness.sh` 4/0,
  `test-dashboard.sh` 134/0, `test-durable.sh` 16/0.
- Media: `panels-tour.py --check` 6/6; `media-budget.sh` green.
- Durability: `durable-agents.sh --self-test` PASS; four host units active.
- No secrets in the diff; no `data/**` files added.

## Follow-up branch recipe (new work)

```bash
git switch -c pr/NN-<slug> main
# make the change + tests
git add -A && git commit -m "<title>"
git push -u origin pr/NN-<slug>
gh pr create --repo swipswaps/opencode-deepseek-jev --base main \
  --head pr/NN-<slug> --title "<title>" --body-file <body.md>
```

## Host-only / residual

- The new dashboard code (FTS disk base + worker pools) is live after the next
  `opencode-web` restart; that restart ends the current agent session.
- Screen-reader certification / axe / Lighthouse are host-only audits; they are
  not container gates.
- Interactive `rotate-api-keys` (browser console steps) stays manual.
