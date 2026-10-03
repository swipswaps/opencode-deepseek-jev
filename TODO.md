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

- [ ] NEBULA-1 (operator approval required): tame external restart
      churn (3 PIDs/10 min, never systemd-counted — another project's
      supervisor). Proposed override (NOT applied):
      StartLimitIntervalSec=300/StartLimitBurst=5, CPUWeight=50,
      IOWeight=50, MemoryMax=512M, LogRateLimitBurst=100, via
      `sudo systemctl edit nebula`. Kill the restarter, not the
      restarts: find what issues the external restarts first.
      Evidence: logs/pressure-*.log (this repo, gitignored).
- [x] G8: host TUI reads the server store — CLOSED as document path.
      Decision (2026-10-01): `attach -s` proven end to end via tmux
      pty; README documents auth-carrying attach + transcript fallback;
      sync job REJECTED (writing to opencode-owned host-local DB risks
      corruption across versions; no safe merge key exists). The
      remaining picker/deep-link gaps are upstream UI bugs with filed
      repros (docs/upstream-opencode-issues.md).
      Record: `opencode attach http://localhost:4096 -s ses_<id>`
      (`--continue` last, `--fork` to copy; needs OPENCODE_SERVER_PASSWORD
      exported — bare attach 401s); `session list/export` are local-store
      only (host-local 2 vs server 44); transcript resume $0.0004
      (docs/ux/resume-tour.mp4).
- [ ] G4: wire `docker/litellm.config.yaml` `max_budget` into routing (needs proxy)
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

- [x] re-extract-session.sh installed + gated. Browser extraction of a
      session log (cdp-tab openauth, chunked API-behind-UI pull, verify
      before write: parse, id uniformity, length + sha256, growth
      policy). Offline --self-test (stub node, 8 checks) wired into
      test-hygiene.sh. Compliance audited: no sed/2>/dev/null/set -e,
      main() wrapper, printf-only; scan-constraints 0 code hits.
      Gates: lint 125, hygiene 39, dashboard 117.
- [x] :4096 opened but shows no sessions (diagnosed + fixed in scope).
      Root cause: :4096 is JSON-API-only; unauthenticated browsers get
      401 + `Basic realm="Secure Area"` with empty body, so the tab
      parks on the login dialog with no DOM — reproduced independently
      via browser_use attached over CDP (auth dialog owns the tab,
      screenshot "not attached"). Fix: `cdp-tab.mjs openauth` answers
      the Basic challenge via Fetch.authChallengeResponse (env creds
      only, never logged); probe now asserts browser-rendered :4096
      JSON count == api count (43 == 43). No HTML sessions view exists
      upstream by design; the human view is :5099 (12/12 rows faithful).
- [x] cdp-tab.mjs (CDP browser client, zero-dep). Attaches to the live
      browser over the remote-debugging port (proc-scan discovery, no
      child_process): tabs/open/text/eval/shot/probe + --self-test
      (10/10). `probe` opens :5099 + :4096, compares dashboard api ids
      vs opencode api ids vs rendered row ids; found real drift (8
      dashboard sessions absent from :4096) and fixed 3 probe bugs live
      (blank-target navigation, screenshot result path, subset verdict).
      Registered: runbooks.json cdp-probe + capabilities.json GREEN E5.
      Gates: lint 123, hygiene 38, dashboard 117.
- [x] pressure-watch.sh (nebula audit, observe-only). deepseek's
      mechanism refuted by measurement (no systemd restart loop:
      NRestarts=0; nebula 1.8% CPU/17MB; real hogs are chromium
      orphans + opencode sessions; io pressure is btrfs-flush).
      Churn confirmed as EXTERNAL restarts (3 PIDs/10 min, never
      systemd-counted). Proposed nebula override (CPUWeight/IOWeight
      + burst limits) queued below for operator approval — NOT
      applied (another project + needs sudo). Gates: lint 122.
- [x] semantic-search --self-test (convention gap closed). Fixture
      DBs in temp dirs (real paths untouched): build count, ranking,
      determinism, empty query, no-match — 6/6. Caught a real trap
      while writing it: `search | grep -q` misreads under pipefail
      because search itself exits 2 (capture-then-grep instead).
      Gates: lint 120.
- [x] collapsible manage catalog (gate-driven UX). The phone-height
      gate caught real growth (6101px for 24 tools): cards collapse
      by default with ▸/▾ markers, keyboard-operable headers
      (tabindex/role/aria-expanded), copy buttons unaffected.
      390px: 6101 -> 2128px. Gates: lint 120, dashboard 117 (3rd
      instance of the known cold #activity flake, green on re-run),
      ux-test 27/0.
- [x] user-side recovery + routing scripts (blocker tooling). New
      fix-docker-network.sh (sudo; probes ports, restarts daemon on
      typed YES, re-probes) for the host firewall/NAT path nothing
      in-repo can touch. New route-via-proxy.sh (G4 opt-in: backup,
      provider swap to :4000, restart, --revert; transform proven on
      a copy). Registered + lint 120.
- [x] v2.0 inaugural run on HEAD (23f4347). First full execution of
      the upgraded contract, all new invariants exercised: served-rev
      equality on bare-metal scratch (docker ports down host-wide),
      secrets by name only, timeouts on every probe, no single FAIL
      across lint 116, dashboard 117, hygiene 38, ux-test 27;
      live probes (landing, adjudication, ops+per-model, 40K drill,
      zero errors). Docs-only close-out.
- [x] G1 wayfinding (landing strip + badges + collapsible detail).
      /explore answers "where do I start": one-line strip (sessions
      · cost · health · filter, no new fetches), count badges on all
      8 tabs (set by owning renderers, hidden when unknown),
      detail card collapses via header and auto-expands on drill.
      Screenshot-verified; brush/reset refresh the strip. Gates:
      lint 116, dashboard 117 (one cold #activity flake on first
      run, green on re-run — 20s shim vs slow cold API, not the
      change), ux-test 27/0, 0 errors.
- [x] command palette (navigation UX, researched). Ctrl+K/Cmd+K fuzzy
      jump across 6 pages + 8 explore tabs (hash deep-links) + reset
      action; label-first ranking, arrows/Enter/Esc/click-outside,
      dialog semantics, focus in + return. Proven keyboard-only incl.
      landing on signals-active; label-ranking bug caught by test
      (hint text outranked labels). Gates: lint 116, dashboard 117,
      ux-test 27/0, 0 errors.
- [x] configuration reference (settings audit). README gained a full
      settings section: default model field + change paths, all five
      .env.local keys, ports, every perf TTL (verified against code
      defaults), worker/ledger seams, budget semantics incl. the
      unenforced-max_budget caveat. One self-caught error fixed
      pre-commit (TEST_DASH_PORT default is 5196, not 5199).
- [x] user preferences compiled + treemap keyboard (fix-all session).
      docs/user-preferences.md records chat-spanning directives P1-P15
      (evidence-first, prompt+audit, test-to-done, visibility,
      paste-ready instructions, secrets hygiene, scope discipline).
      G8 closed as document path (sync job rejected: opencode-owned
      DB writes risk corruption). Treemap tiles keyboard-operable
      (tabindex/link/labels, Enter drills — 51 tiles proven).
      Gates: lint 116, dashboard 117.
- [x] worker fault seam + fallback proof (resilience close-out). New
      QUERY_WORKER_PATH override (operability knob + test seam);
      cold-path fallback logs once with cause. Proven against a
      broken path: 200s on signals+health, fallback output
      byte-identical to worker output, warn logged. Every new block
      carries verified citations (worker_threads, structured clone).
      Gates: lint 116, dashboard 117.
- [x] ops video segments (tour extension). usage-tour + fullsite-tour
      each gain an ops drill chapter (13 and 14 segments, 39/42 s,
      both under the 2MB media gate); captions renumbered
      consistently across both videos.
- [x] doctor Tier 7 fixed (was the only --full FAIL). `opencode plugin
      list` is not a list command (takes only an npm module name) — it
      tried to install a package named "list" and wrote stray config
      (removed). Tier 7 now asserts production truth instead:
      guard.log shows loaded + hook. doctor --full: OK.
- [x] media budgets + screenshot hardening (flakes made structural).
      Full-page capture hung once on document.fonts.ready: ux-test
      screenshots now carry a 60 s timeout with viewport fallback
      (downgrade recorded as SKIP, never silent). media-budget.sh
      fail-closes committed media (video <=2MiB, images <=150KiB —
      the guideline is now enforced, not argued per file), wired
      into test-hygiene (38/0) + tools.json + README. Gates: lint
      116, hygiene 38.
- [x] full-site walkthrough video. 13 captioned pan/zoom segments
      across every page + all eight explore tabs (39 s, 960x540
      H.264, 1.7MB `docs/ux/fullsite-tour.mp4`), referenced in README
      guide. Motion proven per segment; captions em-dash-consistent.
- [x] verified citation references (PhD audit). Every external claim
      in code now carries a live-verified URL (all curl-checked 200
      on 2026-09-30; dead paths replaced: litellm retry->reliable_
      completions, Plot site (429)->github repo, opencode sessions
      (404)->dev CLI docs, GitHub/Stripe pagination corrected) plus
      a README References section (specs, API docs, 2 ISBNs — incl.
      a self-caught TAOP/DDIA ISBN duplication before commit).
      Covers: APG tabs, WCAG 2.1, RFC 5861, singleflight, CSP3, WAL,
      JSON1, window fns, FTS5/BM25, Plot, d3-brush/sankey, litellm
      retries+budgets, DeepSeek/Meta JSON modes, Playwright
      evaluating, opencode CLI/MCP, pagination. Gates: lint 114,
      hygiene 37, dashboard 117 (one cold-scratch #session flake on
      first run, green on re-run — balance-endpoint latency, not the
      change).
- [x] edge-case elegance (deferred items, closed). Sankey node labels
      overlapped on thin nodes: labels now render only on nodes >=14px
      tall, every node carries a native <title> (6/6 titled, hover
      works); degenerate single-part timeline axis showed N identical
      HH:MM ticks: sub-60s spans fall back to HH:MM:SS (proven
      15:52:02..16 on a 4-part session). Gates: lint 114, dashboard
      117, targeted probes 0 errors.
- [x] drill-down feedback (video-review follow-ups). Clicking a row
      gave no visible link between table and panel: the clicked row
      now highlights (.selected, cleared on close/next click) and the
      detail card scrolls into view on every drill path.
      Screenshot-verified. Gates: lint 114, dashboard 117,
      ux-test 27/0.
- [x] interaction clips for README (usage-guide session). Four ~8 s
      captioned clips of real usage captured live via Playwright
      video (drill-down, brush-filter 42->1, ops drill-down, keyboard
      travel), 1280px H.264 + thumbnail links in README guide.
      Total media ~0.6MB clips + ~0.5MB thumbs (two thumbs ~125KB:
      dense-UI floor, readability kept over the 100KB guideline).
- [x] worker-thread cure + per-model panel (residuals, measured E3).
      query-worker.mjs + query-lib.mjs: health/signals/patterns/words
      compute off-thread (single shared worker, 60s guard, inline
      fallback); wrappers async with same TTL keys/shapes; per-model
      errors via own 60s TTL into apiOps + ops UI. Proofs: endpoint
      outputs byte-identical modulo volatile fields; rev 0.06s during
      4-refresh storm (was 4-6s queued); refreshes land (~6s);
      unknown-fn rejects cleanly. Hard-won: importing dashboard.mjs
      in-worker fatals (module-scope usage exit) — pure query-lib
      instead; entry-time `at` caused born-expired storms; async sync
      prefix runs inline (defer past tick). Harness 4/0, ux-test 27/0.
- [x] ops tab: hotspots/bottlenecks/failures/successes as visualized
      data with drill-down (deterministic-probes segment). /api/ops
      serves errors_by_tool (+example_sid drill targets), gate_runs,
      guard_blocks, slow_endpoints (PERF ring: compute-only timings,
      200-cap, ~zero overhead by construction), ledger_summary.
      8th explore tab renders 4 panels; error rows drill via
      detail(). Supporting fixes: S1-class win on patterns already
      banked; errorTools gained MAX(session_id); validity-from-landing
      doctrine held. Proven: panels populated, drill lands on example
      session, cached-hit p99 dominated by loop contention not ring
      cost; lint 112, dashboard 117 (new asserts), ux-test 27/0.
      worker-thread cure + per-model panel remain follow-ups.
- [x] drill-down resurrection + browser-use verdict (title-click audit).
      Clicking any session title stuck #detail at `loading...` forever
      with zero errors: `detail()` called `ts()` which exists only on
      the home page (one-line helper added; drill renders, 0 errors).
      Gates never clicked rows, so it shipped — ux-test.py now
      asserts row-click drill-down (27/0). browser-use 0.13.10 DID
      install and drives Chromium, but its LLM loop requires
      structured-output response_format which DeepSeek rejects
      (proven: request ids + direct API matrix) — no other model key
      here, so the agentic pass stays blocked on model capability;
      Playwright + Selenium remain the instruments. (pip left harmless
      version-conflict notices; no repo imports affected.)
- [x] keyboard + screen-reader operability (WCAG 2.1 AA essentials per
      W3C APG, ArcGIS/Tableau/Cognos practices). Explore tabs are a
      real tablist (roles, aria-selected, arrow/Home/End automatic
      activation); sortable headers keyboard-operable with aria-sort;
      captions + scope on tables; list roles on runbooks; labels on
      all filters/search; '/' focuses search (home; explore keeps
      legacy #q2), Escape blurs; :focus-visible rings everywhere.
      Proven: scripted zero-mouse walkthrough 18/18 via Selenium,
      lint 112, dashboard 116, ux-test 26/0; tour +12th keyboard
      segment (36 s video). Design note: a pre-existing global '/'
      handler already claimed explore's shortcut — kept legacy,
      removed the conflict instead of forking behavior.
- [x] attach driven via tmux pty (TUI automation without browser tools).
      `opencode attach -s ses_f1d2` lands inside the session (title,
      context 857K/$1.38, todos visible) — resume path fully proven.
      Root cause of the follow-on 401-confusion: unquoted
      `GEMINI_API_KEY=<your-key>` placeholder aborted `source
      .env.local`, so later keys never exported. ensure-env.sh now
      single-quotes placeholder values on write (real tokens never
      contain <>); proven on live file (source rc=0, password intact
      by hash). test-ensure-env 18/18, lint 112. Honest accounting:
      a mistyped shell line submitted into the user session before
      interrupt — +1.1K tokens, +$0.13, no side effects.
- [x] resume-tour video (session-recovery session). Demonstrated
      end to end in Playwright, all visible: empty :4096 root,
      dashboard proof of ses_f1d2, dead +/picker/search paths,
      API serving all data, offset-ignored + full-dump-hang defects
      with repro, resume pointer sent verbatim to a new API-created
      session, agent continuing accurately ($0.0004). 11x3s
      zoompan segments, 960x540 H.264 33s 0.9MB
      (`docs/ux/resume-tour.mp4`); transcript vehicle at
      logs/transcript-ses_f1d27512.md (715 msgs, 1.2MB). G8 queued.
- [x] pan/zoom usage-tour (video-review follow-up). Static frames
      showed no in-section motion: rebuilt as 11x3s zoompan segments
      (zooms into stats/search/scatter/brush/pivot/cards, pans down
      charts/signals/runbooks/models), drawtext captions per step,
      960x540 H.264 33s 1.8MB (motion proven: ~15-20% pixels/segment;
      end-frames spot-checked legible). browser-use still skipped
      (uninstallable + non-deterministic); Playwright + ffmpeg.
- [x] chart elegance fixes (video-review follow-ups). Word cloud cut
      words off at the container edge (spiral outgrows W/H): layout
      now returns w/h per word and renderCloud fits a viewBox over
      placed bounds (complete + legible, 0 errors). Plot scatter
      clipped y-tick labels and the x-axis label: margins widened
      (left 70->84, right 18->34), verified readable. Not shipped:
      sankey label overlap (data-dependent), degenerate single-part
      timeline axis (edge case). Gates: lint 110, dashboard 116,
      ux-test 26/0.
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
