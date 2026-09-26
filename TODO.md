# TODO — running log

Living backlog so momentum survives a session boundary. **HANDOFF.md** holds
the durable state; **this file holds the queue.** Update the statuses and the
date each session. Legend: `[x]` done · `[~]` in progress · `[ ]` todo.

Last updated: 2026-09-25

## Outstanding issues (audited — resolve or explicitly accept)

- **Dashboard reloads only on restart (resolved).** 5099 serves whatever
  `dashboard.mjs` was loaded when `web-entrypoint.sh` started it; edits need
  `docker compose -f docker/docker-compose.yml restart opencode-web`. The first
  host `ux-test.py` run's `/models` 404, `/docs` 404 and old-`/explore`
  failures were stale code; restarting fixed them (ux-test 10/7 → 15/2).
- **Guard loaded, awaiting a trigger.** After the restart the plugin is live;
  `guard.log` is empty only because no blacklisted command has run since. *Action:* restart
  the container once, then confirm a blocked `sed` and a fixed `2>/dev/null`.
- **Model pinning — resolved 2026-09-25.** `opencode.json` and the last
  session both show `deepseek-flash`; balance topped up to $10.64. `preflight.sh`
  now fails closed if a non-flash model reappears.
- **Word cloud was orphaned** (`renderCloud`/`apiWords`/`/api/words` defined,
  never rendered). *Fixed this session;* hook is now in the charts tab.
- **`session_context_epoch` (0 rows)** and account/credential tables have no
  consumer beyond the DB map — accepted (opencode-owned schema).
- **External / host-only work is deferred** with the reason on each queue item
  below: Laya, embeddings rerank, LiteLLM `max_budget`, Blockly, n8n, the
  perspective / Plot libs. None is doable in-container without network or a
  rich dependency.
- **Cache-hit report** is now in `cost-bottlenecks.sh` (overall 99.0%);
  **patterns view** is now built. Resolved.
- **`test-dashboard.sh` ~2.5 min** (it re-runs `lint.sh` + `test-hygiene.sh` +
  the OCR self-test). Accepted: run it alone; `harness.sh --fast` skips it.
- **`logs.sh --source system` needs the host** (no docker in the container).
- **Historical `JEV_API_KEY` rejections** (x8) predate the key rotation;
  `verify-api-keys.sh` now shows jev-review connected. Accepted.
- **`echo` is warn-only** in the guard (RULES #38 is a script rule). Accepted.

## In flight

- (none — the locally-doable queue is drained; everything left is B/C/D below)

## Segmented plan (do not balloon)

- **Segment A — local, doable now:** **drained.** Learning loop closed,
  patterns view, cache report, `harness --json`, `/status` command.
- **Segment B — needs a host/test this container cannot run:** the `doctor.sh`
  Tier 10 edit has landed and is lint-gated; its *functional* proof needs a
  host (doctor's Tier 0/1/5 call `docker`). Run `./scripts/doctor.sh --full`
  on the host once to confirm Tier 10.
- **Segment C — drained:** fuzzy code search landed
  (`fuzzy-search.py` + `semantic-search.sh --fuzzy`, typo-tolerant over the
  FTS5 index). Remaining code work is larger and best in its own session.
- **Segment D — external / host / new deps (not doable in-container):**
  perspective WASM, Plot/Vega-Lite libs, LiteLLM `max_budget` (proxy up),
  Laya, embeddings rerank, Blockly, n8n. Each is its own session; do not batch.

## Queue (ranked, top first)

### G3 visualization
- [ ] finos/perspective pivot grid — deferred: needs the WASM bundle vendored
- [ ] Observable Plot / Vega-Lite charts — deferred: needs the libs vendored

### G4 cost
- [ ] wire `docker/litellm.config.yaml` `max_budget` into routing — deferred:
      needs the proxy running (host/docker); config + runbook already exist

### G7 visual tooling (authoring surface over the JSON config)
- [ ] Blockly (vendored, offline) to author guard rules / runbooks -> emit the
      same JSON the guard and dashboard read — deferred: new vendored dep
- [ ] n8n on the host for scheduled jobs (harness, learn-rules) + alerts —
      deferred: host service + port/auth

### G5 security / ops
- [ ] Laya self-host (runbook exists) — deferred: external model server; it
      cuts Jev calls only (~11), not DeepSeek
- [ ] embeddings rerank over FTS5 + redaction pass + hard request cap —
      deferred: needs an embedding model (Jev/Laya/API)

### G6 quality
- [x] fuzzy code search (FTS5 + `difflib` rerank) — `fuzzy-search.py` +
      `semantic-search.sh --fuzzy`

## Done (most recent first)

- [x] fuzzy code search: `fuzzy-search.py` (typo-tolerant; `edti` → `edit`) +
      `semantic-search.sh --fuzzy`; self-test gated; Segment C drained
- [x] fixed the two real bugs the host `ux-test.py` surfaced: the treemap called
      `d3.treemapResquarify()` as a layout (throws `_squarify`) → correct
      `d3.treemap().tile(d3.treemapResquarify)`; the `/models` table overflowed
      at 390px → `#cat{overflow-x:auto}`. Both gated (functional d3 check +
      structure check).
- [x] responsive fixes found by the host `ux-test.py` run: `<meta name="viewport">`
      on every page (fixes 390px overflow) + `/favicon.ico` 204 (kills the
      console 404). Gated.
- [x] UX test is one-step runnable: `ux-test.py --check` (readiness +
      install commands) and a host `ux-test` runbook (17 runbooks total)
- [x] UX: split `/explore` overview (6 → 2 sections); moved duplicates/
      integrations/A-B/database-map to a new `data` tab; sticky tab bar.
      Verified: `/explore` was 40 KB / 18 `<h2>`; gated structurally
- [x] `ux-test.py` — host-side Playwright UX test with assertions (console,
      390px overflow, tab toggles, compact overview); SKIPs without a browser
- [x] `test-tooling.sh` — contract test for every `--json` tool's keys;
      wired into `test-hygiene.sh` (no recursion)
- [x] `doctor.sh --full` Tier 10 runs `test-hygiene` + `test-patterns`
      (lint-gated; functional proof needs the host)
- [x] `harness.sh --json` — pure `{ts,rev,passed,failed,gates[]}` for wrappers
      (closes the last in-flight item)
- [x] the recurring status prompt is now an artifact: `/status`
      (`.opencode/command/status.md`) — both-senses issues, A–D bounding,
      one doable segment, gate, output contract. Stop re-pasting it.
- [x] solution library: `issue-solutions.py --write` → data/observability/solutions.json;
      `/api/solutions` + a "known fixes" list on `/explore ▸ patterns`
- [x] patterns view: `/api/patterns` + `/explore ▸ patterns` tab (bigrams +
      error tools), gated
- [x] prompt cache-hit report in `cost-bottlenecks.sh` (99.0% overall)
- [x] runbooks "manual only" filter; `/` focuses search on `/explore`
- [x] doc audit + `doc-budget.sh` (token size + content-hash proof cache);
      fixed stale balance/model-mix figures and merged the duplicated Laya sections
- [x] ECC audit + project skill `.opencode/skills/jev-harness/SKILL.md`
      (search-first → gate → guard → learn → document; don't stack a full ECC install)
- [x] model cost policy: `models.policy.json` + `models.py`/`models.sh` +
      `/models` UI page; verdict ALLOW/ASK/BLOCK replaces "flash or STOP"
      (7 free Zen models surfaced)
- [x] `learn-rules.py` contrastive corpus rules + guard advisory
- [x] `preflight.sh` — fail-closed spend gate (keys, last gate result, balance,
      model); `harness.sh` records `data/observability/last-gate.json`
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
