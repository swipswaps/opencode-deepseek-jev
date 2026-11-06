---
description: Run the completion gate, answer the blocking questions with evidence, and do not declare done until it passes or a deferral is recorded.
agent: build
---

# /closeout — answer the completion questions before saying "done"

Follow `RULES.md` #93. The gate is `scripts/closeout-gate.py`.

1. Run:
   ```
   ./scripts/closeout-gate.py --check
   ```
   Use `--base https://10.100.0.24:5099` for the host, or the local base.

2. If BLOCKED, resolve each FAIL with evidence:
   - `built` / `served`: `./scripts/web-build-restart.sh` (builds in `web/`,
     restarts from the repo root, verifies `/app/`, `/api/rev`, and the asset
     hash). Never `cd web && ./scripts/web-restart.sh`.
   - `gates`: `./scripts/harness.sh --fast`
   - `retest`: open `/app/#usability` or `/usability` and submit a NEW guided
     session; or `./scripts/usability-guide.sh --opener xdg`.
   - `tracked`: `git add` the referenced scripts (RULES #54).
   - `citations`: restore `docs/USABILITY-TESTING.md` §8 Verification log.
   - `host`: run the build/restart on the host and confirm `served==HEAD`.

3. If a BLOCK cannot be resolved now, record an explicit deferral with a
   reason (never silently):
   ```
   ./scripts/closeout-gate.py --answer retest=defer --reason "waiting for the operator's retest"
   ./scripts/closeout-gate.py --check
   ```

4. Only report completion when the gate prints `verdict: PASS`. Paste the
   closeout output (or the deferral + reason) as proof.
