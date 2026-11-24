# Handoff — blacklist-guard dedupe fix and self-test contract (2026-11-23)

Status: fixed, restarted, and verified. Changes are uncommitted. This session is
4.0x over its context budget and its tool-call contract is failing (historical
stderr-suppressing/sed calls). Start a fresh session; do not fork.

## Root cause

- `.opencode/plugins/blacklist-guard.js` had a process-global dedupe: the first
  load set `globalThis.__opencodeBlacklistGuardRegistered`; every later load
  returned `{}`. The web server loads plugins per project/session in one
  long-lived process, so only the first session received hooks.
- Evidence: the last `loaded` marker was 2026-11-22T13:19:06Z; the last `hook`
  was 2026-11-22T10:12:02Z. No hook followed the load.
- `scripts/guard-health.sh` checked only the loaded hash and mtime, never that
  `tool.execute.before` fired. Its `self_test()` was never called by `main`, so
  the stale/no-hook cases were dead code.
- Post-hoc audit of this session: 9 `sed`, 18 stderr-suppressing redirects, 1
  recursive delete, 32 `echo`; the new-hits ratchet failed 60 vs baseline 12.

## Changes (uncommitted)

- `.opencode/plugins/blacklist-guard.js:393` — removed the process-global dedupe;
  every plugin load registers hooks again.
- `scripts/blacklist-guard-self-test.mjs:223` — a later session must still get a
  blocking hook.
- `scripts/guard-health.sh:104` — requires a `hook` marker at or after the newest
  `loaded`; `main` now calls `self_test()` (`:183`). Added stale, no-hook, and
  hook-before-load cases.
- New `scripts/self-test-contract.py` — `--check` (static: defined test must be
  called in code, non-empty body) and `--trace` with a script name (`bash -x` proves the
  entrypoint executed and asserted). It catches the historical guard-health file
  both ways:
  - `dead: self_test() is defined but never called`
  - `not-executed: --self-test exited 0 but bash -x never entered self_test`
- Wired: `scripts/test-hygiene.sh:184`, `scripts/hardening-gate.sh:57,85,86`,
  `scripts/capabilities.json:127`, `scripts/tools.json:1938`,
  `scripts/README.txt`.
- Global guard copy updated and verified: container
  `/home/node/.config/opencode/plugins/blacklist-guard.js`; the entrypoint
  re-copies it from the repo on container start.

## Verification after restart

```text
loaded 2026-11-23T22:31:07Z sha=0f5da2329d54a52a53b149aac6d3bcb767d2c462f253834dc3ef596b62edfa3f
hook   2026-11-23T22:45:04Z
PASS loaded instance is current and its hook fired
guard-health: PASS  rc=0
```

Both the repo plugin and the global copy hash to the same value. The guard now
blocks blacklisted commands again.

## Remaining work

1. Runtime script-body inspection is not implemented. The guard still checks only
   the command line; `bash script.sh` can hide banned constructs in the file.
   Next unit: extract local script targets in the `tool.execute.before` hook,
   read them with a size limit, strip comments and quoted strings, inspect the
   body, and block with the script path and line. Add self-tests for: banned
   construct in a body blocks; comment-only mention allows; unreachable helper
   does not.
2. Foil host/admin items remain (see `/workspace/docs/HANDOFF-2026-11-23-foil-tailnet.md`):
   - `sudo tailscale up`, then
     `bash "$HOME/.config/opencode/skills/agent-host-ops/secure-tailnet-backend.sh" --apply --with-app`
   - live tailnet end-to-end run:
     `TAILNET_APP_URL="http://$(tailscale ip -4 | head -1):4174/" npx playwright test tests/e2e/tailnet.spec.ts --project=desktop-chrome`
   - narrow the Tailscale Access Control List in the admin console.
3. Commit only when the operator asks. Nothing was committed in this session.
4. This session's tool-call contract is FAIL; a fresh session reseeds it.

## Start here

Open a fresh session and read this file:

`/workspace/docs/HANDOFF-2026-11-23-guard-dedupe.md`

Do not use `--fork` or `--continue` on ses_df74d782affeIwIuFEb0EG6Zkb.
