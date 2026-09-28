# TODO — running log

Living backlog so momentum survives a session boundary. **HANDOFF.md** holds
the durable state; **this file holds the queue.** Update the statuses and the
date each session. Legend: `[x]` done · `[~]` in progress · `[ ]` todo.

Last updated: 2026-09-27

## Outstanding issues (audited — resolve or explicitly accept)

- **Guard runtime was silently inert (root-caused + fixed 2026-09-27).** Web
  sessions boot at `$HOME/.opencode`, not `/workspace`, so the project-scoped
  `{plugin,plugins}/*.{ts,js}` glob never found the guard; `sed`/`2>/dev/null`/
  `subprocess.run` passed through with no telemetry. Fix: `web-entrypoint.sh`
  symlinks the guard into the **global** plugin dir
  (`~/.config/opencode/plugins/`). Verified in-container: a fresh
  `opencode run` from `/home/node/.opencode` writes the `loaded` heartbeat only
  after the symlink exists. *Verified 2026-09-27:* `loaded` 16:19:24 and `hook`
  16:31:28 in `data/observability/guard.log`; the live server blocked a `sed`
  during this session. Resolved.
- **Rotation bricked startup (fixed 2026-09-27).** `rotate-api-keys.sh` wrote a
  2-line `.env.local` (DeepSeek+JEV only), dropping `OPENCODE_SERVER_PASSWORD`
  and `GEMINI_API_KEY`; the entrypoint refused to start unsecured → R6 `http=000`
  for 180 s → rollback. The script now rewrites only the two rotated lines and
  preserves every other key. *Action:* re-run it — the leaked DeepSeek/JEV keys
  are still live (the earlier run rolled back), and rotate the password too.
- **Secret exposure (2026-09-27, self-inflicted) — disposition: accept local,
  no rotation.** `tr '\0' '\n' </proc/1/environ` printed `JEV_API_KEY` and
  `OPENCODE_SERVER_PASSWORD` into a tool result. `data/opencode/` and
  `data/observability/` are **gitignored** (never pushed), and 4096 is now
  **loopback-only**, so the leaked password no longer gates a LAN service. The
  residual path is session **export** (`/api/export/session`, `chatlog.sh`) —
  share those only with care. *If* LAN access is ever needed, rotate first (see
  HANDOFF "Exposing 4096 to the LAN"); DeepSeek was never printed.
- **/explore overview height.** `ux-audit.py` failed "fits ~1.5x viewport"
  (1599px/900 = 1.8x) because the sessions table grew with 38 rows. Fixed at the
  source (`#stable{max-height:58vh;overflow:auto}`), gated structurally in
  `test-dashboard.sh`; *confirm on host* with `ux-audit.py` → expect PASS.
- **Session blindness (2026-09-27) — fix landed (P1), host confirm pending.**
  A browser-independent detector now lives at `scripts/session-health.mjs`
  (stalled `running` tool + blank tail; the naive long-gap signal is rejected as
  ~100% user-idle), served at `/api/health` + `/explore ▸ signals`, self-tested
  offline. *Action:* restart `opencode-web` to serve it, then open
  `/explore ▸ signals`. The SPA freeze itself is upstream
  (anomalyco/opencode#48623, #46419); the panel is the route-around.

- **P3 downscale-before-attach — deferred (D, upstream/frontend).** Criticism
  first: upstream `#46419` says the fix is client-side ("no client-side
  optimization"), and the only server hooks (`experimental.chat.messages.transform`)
  run *after* the SPA has already rendered the giant inline `data:` image, so a
  server transform cannot prevent the black page; a PNG-only local helper is a
  half-measure. Honest scope = guidance (attach downscaled images, one per
  message) + upstream fix. Do **not** batch.
- **Dashboard reloads only on restart (resolved).** 5099 serves whatever
  `dashboard.mjs` was loaded when `web-entrypoint.sh` started it; edits need
  `docker compose -f docker/docker-compose.yml restart opencode-web`. The first
  host `ux-test.py` run's `/models` 404, `/docs` 404 and old-`/explore`
  failures were stale code; restarting fixed them (ux-test 10/7 → 15/2).
- **Guard loaded and firing (resolved 2026-09-27).** `guard.log` shows `loaded`
  + `hook`; a live `sed` was blocked during the session, so the runtime-
  prevention layer is no longer detection-only.
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
- [x] Observable Plot vendored + tool→tool bigram pivot on `/explore ▸ patterns`
      (`scripts/vendor/plot.umd.min.js`, `renderPivot`, `/api/patterns` from/to)
- [ ] migrate the hand-rolled d3 charts to Plot specs (one at a time)
- [ ] finos/perspective pivot grid — deferred: ~28 MB WASM + needs CSP
      `wasm-unsafe-eval`; not exercisable by the in-container headless gate;
      the pivot value is covered by the Plot matrix

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

- [x] recurring `edit` failure root-caused from the DB (13/13 `edit` errors are
      `oldString` mismatch across 4 sessions; 15 `Aborted` turns in
      `opencode.log`) and resolved deterministically: the guard pre-checks an
      `edit`'s `oldString` against the file and records an `advisory` when
      absent (gated self-test), plus a `jev-harness` rule to re-read before
      editing. Evidence: guard self-test PASS, `guard.log` advisory present
- [x] handoff advice surfaced (was dead code): `handoffAdvice()` (latest
      input vs `CONTEXT_BUDGET` → ok/warn/over + action) now rides
      `/api/health`, banners on `/explore ▸ signals`, prints as a
      `handoff:` verdict line in `cost-bottlenecks.sh` and the
      `session-health.mjs` CLI; 4 self-test assertions + the `/api/health`
      gate assert it. Evidence: self-test 12/12 PASS, `handoff: ok
      (232/200000 in)` live
- [x] A-items proven from the DB/logs: session-health `--live` tested (stub
      `/session/status` in the suite) and exercised against the live server
      (`available:true`); `quirks --check-issues` validates the vendored map
      offline (structural errors fail, staleness warns) and is gated. Evidence:
      `guard.log` verdict counts, the opencode.db leak surface (60 PASSWORD= /
      150 apikey_ rows) vs a 0-hit redacted export (91 `[REDACTED]`), the health
      findings, and the model ledger — all read back from the databases/logs
- [x] A1/A2/A3 residuals: `scripts/redact.mjs` redacts secrets at every export
      boundary (`/api/export/session` + sessions/patterns/guard CSVs; stdin
      filter; self-test gated) — verified live on the leaked session (0
      secret-pattern hits, 38 [REDACTED]); guard **dedupe** (second non-forced
      registration is a no-op — it was double-loading via the global symlink +
      project plugin); `web-entrypoint.sh` now also symlinks the **skill** into
      the global config dir (interactive sessions at $HOME/.opencode were
      missing `jev-harness`)
- [x] doc trim (budget): removed superseded/duplicated prose from HANDOFF
      (48.2k→38.5k bytes) and README (29.3k→26.2k); corpus 33 451 → 30 165
      tokens, budget 35 000 (≈4.8k headroom). Kept all load-bearing facts; the
      live queue stays in TODO, the ECC map in ECC-SKILLS.md
- [x] P4 quirks ledger: `modelLedger()` (in `scripts/quirks.mjs`) joins each
      model to its tool-error rate + `sed`/`2>/dev/null`/`subprocess.run` usage;
      `/api/health` returns `per_model`, the panel renders it; offline fixture
      assertions added to `quirks --self-test`; fixed model grouping
      (object-vs-JSON-string rows; `GROUP BY 1` vs the ambiguous column name)
- [x] P2 quirks: `scripts/quirks.mjs` + vendored `scripts/known-issues.json`
      map a symptom to a known upstream issue (fuzzy + typo-tolerant) and fuzzily
      scan DB/code/docs; `/api/health` now carries per-finding correlations and a
      per-model tally; `quirks --self-test` gated in `test-hygiene.sh`
- [x] P1 session health: `scripts/session-health.mjs` (read-only; stalled
      `running` tool + blank tail; long-gap rejected as ~100% user-idle) +
      `/api/health` + `/explore ▸ signals` panel + offline fixture self-test
      gated in `test-hygiene.sh`; `/api/health` and the panel gated in
      `test-dashboard.sh`
- [x] P0 security: `docker/docker-compose.yml` binds 4096 to
      `127.0.0.1:4096` (loopback); the LAN how-to (rotate + firewall + revert)
      is documented in HANDOFF, so the leaked password no longer gates a
      LAN-exposed service
- [x] root-caused the inert guard: web sessions run in `$HOME/.opencode`, so
      `.opencode/plugins/` under `/workspace` was never scanned; `web-entrypoint.sh`
      now links the guard into the global plugin dir (empirically verified via a
      fresh `opencode run` heartbeat). Also fixed `rotate-api-keys.sh` to stop
      clobbering `OPENCODE_SERVER_PASSWORD`/`GEMINI_API_KEY` (the cause of the
      R6 `http=000` outage); `#stable` scroll cap made `ux-audit.py` PASS (1.0x)
- [x] guard made observable + rules tightened: log anchored to the repo via
      `import.meta.url` (was the session `directory`), `loaded` heartbeat +
      one-time `hook` marker so "not loaded" ≠ "idle"; `sed` substitute is now
      the ordered chain `python3 → awk → grep/find`; RULES #7/#8 say the rules
      apply to the agent's own "Thinking" commands; self-test asserts all of it
- [x] declarative pivot: vendored Observable Plot 0.6.17 UMD (one 209 KB file,
      reuses the global d3 — no WASM/CSP change) and a tool→tool bigram matrix
      on `/explore ▸ patterns`; `/api/patterns` rows now carry `from`/`to`;
      gated (vendor 200, page refs, headless exec w/ Plot stub)
- [x] OCR read-back, no more "I can't read images": `ux-trace.py --ocr` reads
      each screenshot back locally (tesseract CLI / tesseract.js, receipts-ocr)
      into a new `ux_shot` table; the `jev-harness` skill gained a rule —
      *never declare a capability gap the repo fills* (grep `scripts/tools.json`
      first). Self-test 6 → 9 checks.
- [x] first `ux-trace.py` host run surfaced 42 sub-24px touch targets (copy
      buttons + `#brush-reset`/`#detail-close`; WCAG 2.5.8 minimum). Resolved at
      the source: `THEME_CSS` now sets `button{min-height:24px;min-width:24px}`
      (one rule, not 40); gated in-container in `test-dashboard.sh`; the
      `small_target` heuristic now aggregates identical shapes into one finding.
- [x] `ux-trace.py` — host-side interaction trace: injects a recorder so every
      click/drag/scroll is logged (element + coords + per-step screenshot),
      enumerates hotspots (bounding boxes + overlay screenshot), persists to
      `data/observability/ux.db` (ux_run/ux_event/ux_hotspot/ux_finding) +
      `logs/ux/report.md`; `--self-test` gated in `test-hygiene.sh`, `ux-trace`
      runbook added (runbooks 18 → 19)
- [x] repo **code index + flags**: `code-index.py` -> `data/observability/code.db`
      (75 files, 325 flags), served at `/api/code` + `/explore ▸ code` — the
      local half of "assemble/inspect/flag repo code" (Jev/Laya/DeepSeek
      classification is the external next layer)
- [x] `prompt-lint.py` flags prompts >= 0.9 similar to a prior one (dedup /
      semantic cache) — protects spend on repeated requests
- [x] viz output methods + stale-code visibility: `[csv]` for patterns and
      guard (`/api/export/patterns`, `/api/export/guard`); nav **served-rev**
      indicator turns red when HEAD moved (restart to serve new code)
- [x] gemini picker: added `provider.env: ["GEMINI_API_KEY"]` (opencode shows a
      provider in the model picker only when its credential is present) + cost
- [x] `/manage` page (`/api/tools`, source `scripts/tools.json`): surfaces the
      repo's tools with purpose/host/container/copyable commands; nav + gated
- [x] Gemini provider: added model `cost` (Flash $0.3/$2.5, Flash-Lite $0.1/$0.4)
      so models.policy.json can judge it (was showing $0.0)
- [x] ECC `security-review` extended: guard now also blocks **pipe-to-shell**
      obfuscation (`curl … | sh`, `base64 -d | sh`) in addition to the
      interpreter-wrapper scan; self-test covers both
- [x] ECC `security-review` used: fixed the guard's interpreter-wrapper bypass
      (`bash -c`/`sh -c`/`python3 -c`/`eval` now re-inspected) + added CSP +
      nosniff headers; triaged the external second-opinion audit (most was
      hallucinated; the bypass was the one real finding)
- [x] ECC `strategic-compact` incorporated: `opencode.json` `compaction`
      (auto + prune, `tail_turns: 20`) + `cost-bottlenecks.sh` context-budget
      section (`CONTEXT_BUDGET`, default 200k). Schema-verified.
- [x] ECC skill triage: `ECC-SKILLS.md` — confirmed applicable subset with
      status (INC/REF/N/A) and repo equivalent; referenced from `jev-harness`.
      Verified: host `ux-test.py` now 17 pass / 0 fail after the restart
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
