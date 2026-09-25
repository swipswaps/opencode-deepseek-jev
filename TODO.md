# TODO — running log

Living backlog so momentum survives a session boundary. **HANDOFF.md** holds
the durable state; **this file holds the queue.** Update the statuses and the
date each session. Legend: `[x]` done · `[~]` in progress · `[ ]` todo.

Last updated: 2026-09-25

## Outstanding issues (audited — resolve or explicitly accept)

- **Guard not loaded yet.** `data/observability/guard.log` stays empty until
  `opencode-web` restarts; the `/explore` guard panel says so. *Action:* restart
  the container once, then confirm a blocked `sed` and a fixed `2>/dev/null`.
- **Model not pinned (user action).** Sessions still run `deepseek-v4-pro`
  (2.9×). `opencode.json` says `deepseek-flash`; a global/UI selection overrides
  it. *Action:* `/models` → `deepseek-flash`, or fix
  `~/.config/opencode/opencode.jsonc`.
- **Word cloud was orphaned** (`renderCloud`/`apiWords`/`/api/words` defined,
  never rendered). *Fixed this session;* hook is now in the charts tab.
- **`session_context_epoch` (0 rows)** and account/credential tables have no
  consumer beyond the DB map — accepted (opencode-owned schema).
- **Laya not deployed** (runbook exists); **LiteLLM `max_budget` not wired**;
  **cache-hit report** missing. See G4/G5.
- **`test-dashboard.sh` ~2.5 min** (it re-runs `lint.sh` + `test-hygiene.sh` +
  the OCR self-test). Accepted: run it alone; `harness.sh --fast` skips it.
- **`logs.sh --source system` needs the host** (no docker in the container).
- **Historical `JEV_API_KEY` rejections** (x8) predate the key rotation;
  `verify-api-keys.sh` now shows jev-review connected. Accepted.
- **`echo` is warn-only** in the guard (RULES #38 is a script rule). Accepted.

## In flight

- [~] **G1 observability UX** — nav/docs/hash tabs/guard panel + design tokens
      (DESIGN.md) landed; next: runbook tag filters, keyboard shortcuts.
- [~] **G2 learning loop** — `issue-solutions.py` landed; next: persist a
      solution library and show a "known fix" hint on `/explore`.
- [~] **harness.sh** — one-command status/gates/telemetry/export landed; next:
      wire `doctor.sh` and an optional `--json`.

## Queue (ranked, top first)

### G3 visualization
- [ ] patterns view (`/api/patterns` + `/explore` tab) — data layer ready
      (`test-patterns.sh`)
- [ ] finos/perspective pivot grid
- [ ] Observable Plot / Vega-Lite declarative charts

### G4 cost
- [ ] pin `deepseek-flash` (user action; `v4-pro` is 2.9×)
- [ ] wire `docker/litellm.config.yaml` `max_budget` into routing
- [ ] prompt cache-hit report (`opencode stats --models`)

### G5 security / ops
- [ ] Laya self-host (runbook exists)
- [ ] embeddings rerank over FTS5 + redaction pass + hard request cap

### G6 quality
- [ ] fuzzy code search (FTS5 + trigram/`difflib` rerank)
- [ ] run `test-patterns.sh`/`test-hygiene.sh` from `doctor.sh --full`

## Done (most recent first)

- [x] audited unused capabilities: word-cloud restored to `/explore ▸ charts`;
      `data-od-id` review hooks on session rows
- [x] `DESIGN.md` design tokens + Material-influenced theme (one accent, 8px
      grid, elevation) injected on every page
- [x] `harness.sh` — one command: all gates + telemetry + cost + todo + `--export`
- [x] `scripts/logs.sh` — telemetry aggregator (guard/error/event/app/system/
      packet); `/api/guard` + guard panel on `/explore`
- [x] guard plugin writes `data/observability/guard.log`; self-test covers the
      hook (block/fix recorded)
- [x] gate telemetry: `ms=` per check + named slowest (`lint`, `test-*`)
- [x] parallel shellcheck (~40s → ~13s)
- [x] blacklist guard plugin (block `sed`/`rm -rf`/`subprocess.run`, fix
      `2>/dev/null`, warn `echo`); 3-layer hygiene
- [x] strict-id headless UI test; fixed dead `#tabs`; nav + `/docs` + hash tabs
- [x] `issue-solutions.py`, `prompt-lint.py`, `audit-tool-calls.py`,
      `test-hygiene.sh`, `test-patterns.sh`
- [x] docs: HANDOFF / README / scripts/README / runbooks
