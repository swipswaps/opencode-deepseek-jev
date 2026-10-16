---
name: ux-verify
description: Use when the user asks to verify dashboard UX changes end to end in a real browser, or to prove promoted/moved scripts resolve in the served UI. Encodes the close-out verification loop so every UI-affecting change is proven in Chrome, screenshotted, and recorded in the ledger before handoff.
---

# ux-verify

Prove UI-affecting changes in real `google-chrome-stable` via Playwright,
then record the evidence where any project session can query it.

## 1. Test in real Chrome (never headless-only for the verdict shot)

- Launch with `channel='chrome'` so the real browser (real cert store,
  real flags) renders the page, not just the bundled shell.
- The dashboard serves TLS-only: use `https://127.0.0.1:5099` with
  `ignore_https_errors=True` in the test context and state the bypass
  in the report. Plain `http://` returns the Go TLS error string, which
  is itself a valid assertion target (proves TLS-only serving).
- Assert on rendered DOM (`page.content()`), not just HTTP status:
  new paths present, old paths absent, zero `pageerror` events.
- Save screenshots to `logs/ux-closeout/` and view them with the Read
  tool before claiming anything — an 8KB shot is a blank page, not a pass.

## 2. Prove the API layer matches the files

- `curl -sk https://127.0.0.1:5099/api/runbooks` must serve the same
  paths the worktree holds; `curl -sk .../api/rev` must carry the
  expected `runbooksStale` semantics (false when unchanged).
- Remember the serving process loads `runbooks.json` at startup: file
  edits need a container restart to go live, and the restart blips the
  dashboard and ends agent sessions — state that, don't surprise.

## 3. Record where sessions can find it

- Append rows to `observability.db:ledger` (`source='chat'`, unique
  `source_key` per claim so re-runs are idempotent): what was verified,
  verdict, and the evidence path (screenshot file, API output hash).
- Never print secret values; lengths and hashes only.
