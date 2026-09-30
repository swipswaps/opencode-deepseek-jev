# TODO — running log

Living backlog so momentum survives a session boundary. **HANDOFF.md** holds
the durable state; **this file holds the queue.** Update the statuses and the
date each session. Legend: `[x]` done · `[~]` in progress · `[ ]` todo.

Last updated: 2026-09-30

## Outstanding issues (audited — resolve or explicitly accept)

- **Guard runtime was silently inert (root-caused + fixed).** Web sessions boot
  at `$HOME/.opencode`, so the project-scoped `{plugin,plugins}/*.{ts,js}` glob
  never found the guard; `web-entrypoint.sh` now links it into the **global**
  plugin dir (`~/.config/opencode/plugins/`). Verified: `guard.log` shows
  `loaded` + `hook` and a live `sed` was blocked (`logs.sh --source guard`).
- **Rotation bricked startup (fixed).** `rotate-api-keys.sh` wrote a 2-line
  `.env.local`, dropping `OPENCODE_SERVER_PASSWORD`/`GEMINI_API_KEY`, so the
  entrypoint refused to start unsecured and R6 timed out (`http=000`). It now
  rewrites only the rotated lines. *Action (host):* re-run if the keys must
  change; DeepSeek/JEV are currently **unrotated**.
- **Secret exposure — accept local, no rotation.** `tr '\0' '\n' </proc/1/environ`
  printed `JEV_API_KEY` + `OPENCODE_SERVER_PASSWORD` into a tool result.
  `data/**` is gitignored and 4096 is loopback-only, so it is contained, and
  session **exports are redacted** (`scripts/redact.mjs`). Rotate only if 4096
  is widened to the LAN (see HANDOFF "Exposing 4096 to the LAN").
- **/explore overview height.** Fixed at the source
  (`#stable{max-height:58vh;overflow:auto}`), gated structurally; host
  `ux-audit.py` confirmed PASS (1.0x).
- **Session blindness (P1 done).** `scripts/session-health.mjs` (+ `/api/health`,
  `/explore ▸ signals`) detects stalled/blank turns without a browser; the naive
  long-gap signal is rejected as ~100% user-idle. The SPA freeze is upstream
  (#48623/#46419) — the panel is the route-around.
- **P3 downscale-before-attach — deferred (D, upstream/frontend).** `#46419` is
  client-side; the only server hook runs after the SPA renders the inline image,
  so a repo transform cannot prevent the black page. Guidance only.
- **Resolved / accepted (full detail in `git log`).** Dashboard reloads only on
  restart; guard firing; model pinned to `deepseek-flash` (preflight fails closed
  otherwise); orphaned word cloud restored; cache-hit report + patterns view
  built; `session_context_epoch`/credential tables unused (opencode-owned);
  historical `JEV_API_KEY` rejections pre-rotation; `echo` warn-only;
  `logs.sh --source system` needs the host; `test-dashboard.sh` ~2.5 min (run
  alone; `harness --fast` skips it).

## Segmented plan (do not balloon — one segment per session)

- **A — local, doable now:** doc trim (`scripts/README.txt`), `quirks` fuzzy
  precision on real data, `ensure-env.sh` password-regen review.
- **B — needs a host/test this container cannot run:** `doctor.sh --full` Tier 10,
  `ux-audit.py`/`ux-test.py`, `test-sidebar-streaming.sh`, `rotate-api-keys.sh`
  end-to-end.
- **C — larger code (own session):** per-model adaptation (not just the ledger),
  auto-handoff **action**, client-vs-agent stall, Plot migration, G1 UX
  residuals, embeddings rerank.
- **D — external / new deps (never batch):** upstream SPA, LiteLLM `max_budget`
  routing, finos/perspective, Laya, Blockly/n8n.

## Queue (ranked, top first)

- [x] G3: hand-rolled d3 charts migrated to Plot specs — scatter
  (`Plot.dot`), gantt (`Plot.barX`), timeline (`Plot.rect` lane
  strip), burn last as Plot+d3-brush hybrid (drag->FILTER->4 views
  proven 42->3->42); treemap/sankey/cloud stay d3 (no Plot marks).
  README.txt->README.md (history preserved) with step-by-step usage
  guide embedding 7 docs/ux shots (Playwright-captured, <=100KB);
  whitelist/corpus/registry refs updated. Gates: lint 110, hygiene
  37, dashboard 116, ux-test 26/0.
- [ ] G4: wire `docker/litellm.config.yaml` `max_budget` into routing (needs proxy)
- [ ] G5: Laya self-host (cuts Jev only, ~11 calls); embeddings rerank over FTS5
      + redaction + hard request cap
- [ ] G6: run `doctor.sh --full` from a host
- [ ] G7: Blockly (vendored) rule/runbook authoring; n8n scheduled jobs (host)

## Done (most recent first)

- [x] usage-tour presentation (E2E session). Restarted opencode-web
      (serves 4e78fcf, stale:false; panel adjudicated live, 0 errors).
      browser-use uninstallable here (pip deps timeout) and wrong tool
      for a deterministic tour (LLM-driven, non-repeatable) — used
      scripted Playwright + ffmpeg 7.1 instead. 11-step captioned tour
      (dashboard, search, overview, charts, live brush-filter,
      signals, patterns, runbooks, models, loading skeleton, docs),
      1280x720, 2 s/frame, 22 s H.264 (`docs/ux/usage-tour.mp4`,
      760KB); referenced from README.md guide header.
- [x] litellm crash-loop fixed (restart-count 4396, ~30s cycle). Root
      cause: the image update added boot-time master-key enforcement
      (`UnsafeMasterKeyError`: neither general_settings.master_key nor
      LITELLM_MASTER_KEY set). Fix: generated
      `LITELLM_MASTER_KEY=sk-<rand>` appended to .env.local (mode 0600
      kept, value never displayed), removed the stale same-named
      container blocking recreate, `up -d` on
      docker-compose.litellm.yml. Proof: restart-count 0, Up 5+ min,
      proxy initialized with deepseek-flash, /health 401 without key
      (auth enforced). Note: image is main-latest (new boot
      requirements can recur); routing the agent through :4000 (G4)
      still a separate decision.
- [x] event ledger with writers + patterns bound (E2E-UX-audit follow-ups).
      ledger.py (stdlib+sqlite3): ledger table in observability.db;
      record (UNIQUE(source,source_key) idempotent), ingest-guard
      (offset-tracked), backfill (guard.log + last-gate.json + harness
      exports; +76 then +0 proven), show (--tail/--since/--type/--grep/
      --json), --self-test 6/6. harness.sh emits GATE_START+GATE
      (guarded non-fatal; LEDGER_DB seam — an env-clobber bug + an
      unwritable-path gap were both caught by the negative test and
      fixed). logs.sh --source ledger. tools.json 20th entry + README.
      apiPatterns bound to recent-40 (5.5s->2.5s; output identical on
      this DB; semantic note in code). Pivot CSS-text leak: no
      reproduction on current code (stale-only/transient) — no change
      shipped without reproduction. Gates: lint 110, hygiene 37,
      dashboard 116, ux-test 26/0; e2e sweep 20/21 (1 fixed-wait
      artifact, product verified draining + adjudicated).
- [x] harvest (LifeOS §15 pattern, repo-native code — no LifeOS code was
      imported; the text contained none). scripts/harvest.py: URL ->
      normalize -> sha256 -> staged candidate under logs/harvest-<ts>/
      (raw.bin, meta.json, candidate.md with UNTRUSTED banner + review
      checklist); structurally incapable of writing docs. Proven:
      --self-test 15/15 offline, local-fixture hash match, 404->2,
      non-html/oversize->3, real-URL E3 (example.com). tools.json (19th
      entry) + scripts/README.txt registered; lint 109, test-dashboard
      116 (api/tools valid).
- [x] backend overload resolved (best-practice pass, measured E3).
      Disease: single-threaded server + multi-second sync aggregation =
      head-of-line blocking (cold /api/health ~10s; trivial /api/rev
      measured 4.8-6.1s during recomputes). Fixes, each proven: (1) S1
      blank-tail query rewritten 80 correlated scans -> 1 grouped pass
      (healthReport 4.9s->1.2s; self-test PASS; real-DB output identical);
      a ledger subquery rewrite was REVERTED (identical output, no
      measured gain — unproven optimisations don't ship). (2)
      Stale-while-revalidate + singleflight on ttlCached and apiHealth:
      post-TTL serves stale instantly + one background refresh; validity
      measured from landing time (an entry-time `at` birthed
      already-expired entries -> permanent recompute storm — root-caused
      live via age time-series). (3) boot pre-warm of apiHealth (first
      view 0.2s cached vs 7.2s cold; listen still ~2.5s). (4) poll
      endpoints cached (activity 1.47s->0.01s, cost 0.25s->0.02s, 10s
      TTL) with array-shape preservation (Object.assign on arrays
      corrupts JSON shape — caught by probing). (5) uncached
      aggregations wrapped (patterns, words). (6) signals pane
      re-renders on tab activation (a load racing a live-unavailable
      window painted tombstones with no later correction — caught by
      panel-vs-curl divergence, proven to self-heal). Result: rev
      during recomputes 0.07s (was 4.8s). Remaining: sync refreshes
      still freeze the loop ~seconds (worker-thread cure = own segment);
      failure-only gate forensics added (a blacklisted `2>/dev/null`
      of mine was caught by the guard mid-work — fixed per RULES #8).
- [x] UX loading states + deterministic UX gates (P2 slice): every async
      container on `/`, `/explore`, `/runbooks`, `/models` now carries a
      `data-loading` skeleton (replaced on render; `data-error` on failure
      only if still pristine, so 2s polls never clobber good data);
      runbooks gained an empty-filter state, models a try/catch error
      state, home calls `refreshConfig()` at boot (was 30s-stale marker).
      `ux-test.py`/`ux-audit.py` dropped `networkidle` (timeouts on
      healthy polling pages) for domcontentloaded + marker polling, with
      progress-not-stall semantics and post-resize re-settle. Proven:
      ux-test 26/0 x3, ux-audit PASS x2, throttled-fetch probe
      (`loading...` through a 4s stall -> 19 cards,
      `logs/ux/loading-runbooks.png`), lint 108, test-dashboard 116/0
      x5 (+1 unidentified cold-start flake in 6 runs, failing line lost
      to log overwrite). Two artifacts killed on the way:
      `wait_for_function(string)` trips the dashboard CSP as a pageerror
      (poll via `evaluate` instead); cold `/api/health` ~10s blocks the
      single-threaded loop, serialising ~20 explore fetches to ~18s tails
      (markers honest throughout). Follow-ups: boot pre-warm for cold
      health, d3 `new Function` (csvParse path) vs CSP if ever used,
      per-run gate logs.
- [x] dashboard now adjudicates (the gap from cc85d95): `apiHealth` is async and
      awaits `liveStatus()` + `applyLiveAdjudication()`, so `/api/health` and the
      signals panel carry real `dead_tool`/`dead_blank` (panel: `running 0 ·
      blank 0 · dead 3 · dead-blank 6`). Fixed the flakiness the Playwright
      panel exposed: `liveStatus` timeout 3s→8s (`opts.timeoutMs`) and a **5s**
      cache TTL when live is unavailable, so a single timeout no longer poisons
      the 15s window with unadjudicated data. Playwright-confirmed
      (`logs/ux/signals-fixed.png`, 0 page errors).
- [x] dead **blank** adjudication + in-container Playwright proof. `--live` now
      reclassifies old blank tails whose session is idle/absent as `dead_blank`
      (out of `blank_tails`, like `dead_tool`), fail-safe without live data; CLI
      + dashboard render branches added. Kicked off **Playwright in-container**
      (chromium headless + locally-extracted system libs, no root): all 7 pages
      render, **0 console/page errors**, screenshots in `logs/ux/progress*.png`.
      **Known gap:** the *dashboard*'s `/api/health` does **not** adjudicate
      (CLI-only; it would need async live status) — the panel still lists
      tombstones. Next session.
- [x] `/api/semantic` FTS debounce: `FTS_MIN_REBUILD_MS` (default 30s) — the
      in-memory index was rebuilt (~3s) on nearly every search because the agent
      keeps writing the DB and advancing `sourceMax`; now results are at most
      30s stale instead. call1 3.09s (build) → call2 0.90s (no rebuild).
- [x] `monitor-snapshot.sh` finished + gated (was untracked, non-executable,
      broken self-test): the arg parser used `for a in "$@"` with `shift`, so
      `--db PATH` set `db` to the wrong token and the self-test's fixture DB was
      never used ("FAIL json shape"). Rewritten as a `while`/`case` parser,
      chmod +x, self-test PASS, wired into test-hygiene, documented.
- [x] dashboard latency: `/api/health` is now TTL-cached (`HEALTH_TTL_MS`,
      default 15s) with `cached`/`age_ms` surfaced — measured **6.8s → 0.011s**
      on repeat. Root cause: ~7s of synchronous aggregation (healthReport 4.7s +
      modelLedger 2.1s) on a single-threaded Node blocks *every* request (a
      trivial `/api/rev` measured 4.8s during a health compute). Also bounded
      the running-tool scan to recent sessions. Gated (second call must be
      `cached:true`). Host-level contention (litellm crash-loop, load ~14) is
      separate and not ours.
- [x] `watch.sh` — the missing live monitor (repeatedly requested; only
      `thinking.sh`/`session-health` existed). Read-only, cursor-based: reports
      the gate + session-health verdicts + only NEW guard actions and NEW app
      ERROR/WARN lines. The first sweep initialises the cursor at EOF so
      historical lines are never echoed as live — fixing the exact
      archival-as-alarm failure that confused the TUI. 7 self-test assertions;
      gated in test-hygiene.
- [x] session-health dead-tool adjudication: a running tool older than 6h whose
      session is idle/absent in live `/session/status` becomes `dead_tool`
      (excluded from stalls, rendered apart); with no live data it stays a
      stall (fail-safe). Live: the three tombstones adjudicated dead (running
      3→0). RULES: pasted telemetry carries ISO date + age (archival vs live).
- [x] capability registry + evidence levels (from the attached LifeOS
      methodology; all these concepts existed only in `notes/6ab95225-…089.txt`):
      `scripts/capabilities.json` + `capabilities.mjs` check the four links that
      can silently diverge — implementation / registration / test / evidence —
      and emit GREEN / DEGRADED / MISSING with an evidence level. `RULES.md`
      gains "Evidence levels" (E0–E5; nothing confirmed below E3). The
      falsifiable case is the guard incident: it is GREEN now and would be
      DEGRADED if its global symlink were absent. A checker bug (`expand(~)`
      applied after rooting the path) was caught by running it against reality.
- [x] held-out validation of the matcher (the honest counterweight to Step 3):
      added an out-of-sample `heldout` block to `quirks-eval.json` and measured
      it. Result: **recall 40% / FPR 20%** — so the frozen-set "FPR 0%" was
      **in-sample** (the map was tuned on the same 9 cases it was scored on).
      Production `/api/health` is unaffected (it correlates synthetic
      `symptomText` that fires via regex); the weakness is free-text paraphrase
      recall. Rule encoded: `cases` = train (ok to tune), `heldout` = report-only.
- [x] `quirks` threshold tuned: `matchIssues` default 0.15 → **0.5** (the sweep
      knee — 0.5 and 1.0 predict identically), cutting frozen-set free-text FPR
      67% → 44% while every production synthetic symptom still fires via regex
      (≥1.0); honest typo test (combination form) + a `levenshtein === 1`
      primitive assertion + a `real FPR ≤ 44%` gate. Residual 4/9 FPs are
      regex-driven → next session = keyword/regex surgery (its own segment).
- [x] `ensure-env.sh` backup names now carry microseconds — the behavior test
      exposed a real same-second collision that silently dropped a backup
      (flake → bug). 18/18, stable across reruns.
- [x] `ensure-env.sh` made safe to run unattended: a no-change rerun is a
      strict no-op (no write/backup/password); `OPENCODE_SERVER_PASSWORD`
      regenerates only when missing/empty or `--rotate` (short-but-present now
      warns, never replaces); atomic temp+rename write; preserves unknown
      keys/comments; `PASSWORD_ROTATED` marker surfaced by `web.sh` as a
      "re-login" notice. New gated behavior test `scripts/test-ensure-env.sh`
      (15/15, in `test-hygiene.sh`). Drive-by: HANDOFF documented the
      non-existent `verify-password-drift.sh` (never in this repo) — stale row
      removed.
- [x] `quirks` fuzzy precision measured on a frozen labeled set
      (`scripts/quirks-eval.json`): constructive recall 100%, decoy FPR 0%
      (asserted invariants); on 9 real redacted samples the free-text matcher
      over-fires — FPR 67% at the default threshold 0.15, 44% at 0.5 (sweep
      reported). Caught + fixed a real bug (`report` ~ `import` at edit-distance
      2; the `d===2` fuzzy bonus was removed). This session measures; the next
      tunes the threshold armed with the sweep. Note: production `/api/health`
      correlates *synthetic* symptom strings (which match correctly); the FPR
      applies to the free-text/`--query` path.
- [x] recurring `edit` failure root-caused from the DB (13/13 `edit` errors are
      `oldString` mismatch; 15 `Aborted` turns in `opencode.log`) and resolved
      deterministically: the guard pre-checks `oldString` against the file and
      records an `advisory` when absent (gated), plus a `jev-harness` rule to
      re-read before editing.
- [x] handoff advice surfaced (was dead code): `handoffAdvice()` → `/api/health`,
      `/explore ▸ signals`, `cost-bottlenecks.sh`, `session-health` CLI; gated.
- [x] A-items proven from the DB/logs: `--live` tested + live (`available:true`);
      `quirks --check-issues`; redacted export (0 secret hits, 91 `[REDACTED]`).
- [x] A1/A2/A3: `scripts/redact.mjs` (egress redaction), guard dedupe, global
      skill link.
- [x] P0–P4: 4096 loopback, session-health, quirks/known-issues, per-model
      ledger; guard observability (heartbeat); Plot pivot; doc trim.
- [x] Earlier (condensed — full detail in `git log`): OCR read-back + `ux-trace`
      (clicks/hotspots/`--ocr`), sub-24px touch-target fix, repo code index,
      `prompt-lint` dedupe, Gemini provider/picker, `/manage`, ECC security-review
      (interpreter-wrapper + pipe-to-shell), strategic-compact, fuzzy search,
      treemap/390px fixes, viewport + favicon, ux-test runbook, `/explore` tabs,
      test-tooling, doctor Tier 10, `harness --json`, `/status`, solution library,
      patterns view, cache-hit report, runbook filter, `doc-budget`, ECC audit +
      skill, model cost policy, `learn-rules`, `preflight`, `DESIGN.md`,
      `harness.sh`, `logs.sh`, guard plugin/log, gate telemetry, parallel
      shellcheck, strict-id headless UI test, docs.
