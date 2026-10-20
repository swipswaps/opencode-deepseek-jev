# PR-01 — accessibility hardening (status record)

- **Body / plan:** [`docs/plans/PR-01-a11y-hardening.md`](../plans/PR-01-a11y-hardening.md)
- **Status:** implemented on `main` (this PR is a retrospective record).
- **Commits:** `e063e79` (WCAG gate + dashboard fixes), `90fb1e1` (treemap/sankey
  keyboard + names).
- **Evidence:** `a11y-audit.mjs --self-test` 11/11; `test-dashboard.sh` 134/0
  (a11y line + chart-mark contract); `harness.sh` 4/0.
- **Files:** `scripts/a11y-audit.mjs`, `scripts/dashboard.mjs`,
  `scripts/test-dashboard.sh`, catalogs.
- **Residual:** screen-reader certification and axe/Lighthouse are host-only and
  remain a separate, non-blocking audit (no browser in the container).
