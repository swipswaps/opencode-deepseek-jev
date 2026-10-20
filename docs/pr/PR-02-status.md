# PR-02 — README media refresh (status record)

- **Body / plan:** [`docs/plans/PR-02-media-refresh.md`](../plans/PR-02-media-refresh.md)
- **Status:** implemented on `main` + captured on the host (2026-10-19/20).
  This PR is a retrospective record.
- **Commits:** `04c49e4` (adaptive shrink + short 960x540 video), `9af9f7b`
  (six shots + tour embedded), `a627a88` (plan status).
- **Evidence:** `panels-tour.py --check` 6/6; `media-budget.sh` green
  (images 52-139 KiB, `tour.webm` 717 KiB); README embeds home, overview, board,
  trends, signals, patterns + the tour.
- **Files:** `docs/ux/status-*.png`, `docs/ux/tour.webm`, `README.md`,
  `scripts/panels-tour.py`.
- **Residual:** none. (The new dashboard code that consumes the FTS base goes
  live on the next `opencode-web` restart; that is operational, not media.)
