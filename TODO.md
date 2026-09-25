# TODO — running log

Living backlog so momentum survives a session boundary. **HANDOFF.md** holds
the durable state; **this file holds the queue.** Update the statuses and the
date each session. Legend: `[x]` done · `[~]` in progress · `[ ]` todo.

Last updated: 2026-09-25

## In flight

- [~] **G1 observability UX** — shared sticky nav, linkable hash tabs, in-UI
      `/docs`, guard panel all landed; next: runbook tag filters, keyboard
      shortcuts, landing card grid.
- [~] **G2 learning loop** — `issue-solutions.py` landed; next: persist a
      solution library and show a "known fix" hint on `/explore`.

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
