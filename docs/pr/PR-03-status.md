# PR-03 — durable agent arming (status record)

- **Body / plan:** [`docs/plans/PR-03-pi-durable-automation.md`](../plans/PR-03-pi-durable-automation.md)
- **Status:** implemented on `main`; **armed on the host 2026-10-20**.
  This PR is a retrospective record.
- **Commits:** `e063e79` (`durable-agents.sh`), `0d0b8d8` (FTS refresh timer +
  four-agent wiring), `4d24e56` (checkpointed `recover-4096` restart and
  `rotate-server-password`).
- **Host evidence:** all four units `enabled=enabled active=active`; the FTS
  sweep ran at `2026-10-20T12:45Z` and rebuilt `data/search/opencode-index.db`
  (mtime moved, 34 MB). `durable-agents.sh --self-test` PASS (7 templates,
  4 installers); `test-durable.sh` 16/0.
- **Residual:** the interactive `rotate-api-keys` (browser console steps) stays
  manual; `rotate-server-password` and `recover-4096 --recover` are checkpointed
  with `--resume`.
