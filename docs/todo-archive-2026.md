# TODO archive — 2026 (older Done entries)

Moved out of `TODO.md`'s Done log on 2026-10-17, and a second batch on
2026-10-18, to hold the read-first doc budget (the corpus is read at every
session start, so its size is context cost — see `./scripts/doc-budget.sh`).
Newest-first. `TODO.md` keeps the queue plus recent Done; durable state lives
in `HANDOFF.md`. Git history is unchanged.

- [x] **Kill the gate double-run + fixture the semantic leg.** `harness.sh` runs
      lint + test-hygiene, and `test-dashboard.sh` re-ran BOTH inside itself —
      the real reason test-dashboard was >9 min. Under harness it now sets
      `GATES_RUN_BY_PARENT=1` and skips the nested pair (standalone still runs
      them); its served dashboard keeps the live store (data-dependent checks
      stay valid) while the semantic index rebuild uses the fixture store
      (~90s→~17s). `semantic-search.sh`/`cost-bottlenecks.sh` gained `--db`.
      test-dashboard under harness 473s→196s (120/0).

- [x] **Fixture-DB for the contract tests (gates faster still).** New
      `test-fixture-db.sh` seeds a few-KB opencode.db (session/message/part/
      todo); `test-tooling.sh` and `test-hygiene.sh` now run the DB-reading
      contracts (audit-tool-calls, prompt-lint, issue-solutions, learn-rules,
      sentinel, session-guard) against it instead of the live 626 MB store —
      each drops from 7–16s to <1s. test-tooling 42s→16s; test-hygiene
      202s→149s (from 243s at session start). Same checks, 0 fail; the live-DB
      presence is still asserted.

- [x] **Gate speedups (so review cycles can be frequent).** `test-tooling.sh`
      now launches its independent contracts **in parallel** (79s→42s; the
      626MB-DB scans overlap instead of summing). `sentinel.sh` self-test no
      longer emits digests on `--no-log` (was: needless node + writing into the
      *real* digests dir from a `--no-log` run) and honors `SENTINEL_ACCESSLOG`
      regardless of `SENTINEL_NODOCKER` (offline-robust); its self-test 43s→34s.
      test-hygiene 243s→~186s. Same checks, 0 fail.

- [x] **`loop-state.sh` — checkpoint the in-flight loop segment (#80).** The
      dev loop now records its current segment durably (on `durable-run.sh`'s
      job store, job `dev-loop`): `--begin UNIT` (unit + rev), `--end UNIT`
      (gate green/red; `--red`), `--show`. A fresh session **resumes or skips**
      the segment instead of re-deriving "where was I"; `next-action.sh`
      surfaces the in-flight unit. Wired into `tools.json` + `test-tooling` +
      `scripts/README.txt`. Gate: self-test PASS, test-tooling 16/0, lint 259/0.

- [x] **`progress-review.sh` — the loop reviews itself on a timer (#79).**
      Sentinel sibling for pi-durable's other half: a 15-min sweep reads
      `next-action` and records a durable PASS row on a rev/gate advance or a
      FAIL row when the loop stalls (no advance for `PROGRESS_STALL_TICKS`
      sweeps; stable keys, only news trips). `--once/--json/--no-log/--self-test`
      + `progress-review-install.sh` + systemd units. Wired into `tools.json` +
      `test-tooling` + `scripts/README.txt`. Gate: both self-tests PASS.
      A `progress-timer` runbook (host) makes the enable step copy-paste; this
      sandbox has no systemd (`pid1=opencode`), so it installs on ws24.

- [x] **`next-action.sh` — the durable next-action / progress consumer (#78).**
      pi-durable's "a new process opens the same storage and continues" was
      missing its consumer for the dev loop. This reads git state +
      `last-gate.json` + the ledger + TODO's queue + `docs.json` and prints the
      exact next unit and what changed since the last gate, with zero
      re-derivation. `--json`, `--self-test`, `NEXT_ACTION_REPO`/`LEDGER_DB`
      seams; wired into `tools.json` + `test-tooling.sh` + `/status` step 0.
      Gate: self-test PASS, scan-constraints PASS, lint 251/0.

- [x] **test-dashboard: derive the runbook count from source.** The gate
      hard-coded `count=20` while `scripts/runbooks.json` grew to 26 — a brittle
      magic number that failed the dashboard gate. It now compares the served
      count to `len(runbooks.json)`. (Found while verifying the doc-budget
      change; observed `runbooks count=26 (matches runbooks.json)` PASS.)

- [x] **Doc-budget tiering (#77) + doc trim.** `doc-budget.sh` now charges only
      the session-start set (HANDOFF/RULES/TODO + `skills/*`) to the budget and
      **reports** README/DESIGN/scripts-README as on-demand — the WARN was
      permanently red by scoping, not just size (cry-wolf). Trimmed
      `scripts/README.txt` (−21%), archived TODO's old Done to
      `docs/todo-archive-2026.md`, condensed README history/references. Tier-1
      ~31.4k < 35k (was ~65k total). +`--self-test`; gate: lint 251/0.

- [x] **Queue reconciliation (2026-10-17, fresh session).** Re-audited the
      handoff brief against live state: every `scripts/sentinel.sh` change prior
      sessions suggested is applied and pushed — T4 `SENTINEL_ACCESSLOG` guard
      (`have docker || [ -n "$SENTINEL_ACCESSLOG" ]`), T5 non-latest denied, T6
      non-latest over-budget, T7 stalled tool, and the stable per-incident
      ledger key — and the deduced option (`preflight` budget watch) is now a
      **hard STOP** (#76). Closed the stale **Telemetry-console `[~]`**:
      clickable **Gantt** (`GANTT_WIRED` + `drill()`) and the **Flags panel**
      (`#flags-card` = bottlenecks · cost · slowdowns · stalls, click-to-drill
      via `data-go`) are shipped; residual plan items (3) drill-down on the
      remaining sections and (4) Grafana+SQLite (host) remain. Evidence:
      `ffind --self-test` PASS · `quirks --self-test` PASS · `preflight` READY
      · lint 251/0 · `ahead=0`.

- [x] **Durable pass (pi-durable): checkpoint · rebuild · attach.** Three mechanisms
      the *Pi Durable* post names, now scripts with self-tests. (1)
      `scripts/durable-run.sh` — every step stores a durable checkpoint
      (`data/observability/jobs/<job>.jsonl`); a re-run **skips** done steps
      (adopter `caddy-reload.sh`: validate→restart→verify). (2)
      `scripts/rebuild-derived.sh` — regenerates the alert brief + digest from
      storage **alone** (proves "storage is the source of truth"). (3)
      `scripts/grafana-up.sh` — the non-bespoke ops client (read-only stores) +
      runbook `grafana`. Plus **#73** (triage reads the durable ledger, not the
      delivery log: **124 vs 21** alerts) and **#72** (`duration` = time-in-system).
      Durability audit vs the post in `docs/pi-durable-mapping.md`. RULES
      #72/#73/#74; tools.json 60 · runbooks 25.

- [x] **Triage-all + slow-fetch root cause (durable).** Ran the full sink triage in
      the sandbox (the repo `data/` is bind-mounted): **21 distinct alerts / 200 pushed
      rows**, dominated by `caddy access log` slow fetches. The URI histogram proved
      the model: `/provider` **x188** (worst 137s, per-page-load), `/api/balance` x13
      (307s), `/api/cost` 365s, `/api/schema` 112s, `/assets/*` x23, `/favicon` x46.
      **RULES #72:** a measured `duration` is *time-in-system*, not handler cost — both
      servers are single-threaded Node, so one blocking handler inflates every queued
      request (M/M/1); `/api/balance` already carries a 10s timeout + 60s cache, so the
      multi-minute durations are **queue wait**. Fixes: (1) sentinel **T4 now excludes
      SSE** (`/global/event` 1422s = connection lifetime — a cry-wolf), with a self-test
      that fails if a stream is counted; (2) `docker/Caddyfile` gains **immutable
      Cache-Control** for content-hashed `/assets/*` (+ a 1-day TTL for `/favicon*`) to
      kill the re-fetch storms; (3) new runbook **`slow-fetch`** documenting the
      queueing model + drain order. `triage-alerts.py --out` writes a **durable report**
      (`data/observability/triage-<date>.md`).

- [x] **P4b self-hosted alerting + triage (closes detect→push→act).** No
      third-party webhook needed: `scripts/notify-sink.mjs` (zero-dep node) takes
      `POST /hook` → `data/observability/notify-sink.jsonl`; `notify-selfhost.sh`
      writes + enables a systemd USER unit (bakes the **absolute node path** — the
      `/usr/bin/env node` form failed under the systemd-user `PATH`), sets
      `NOTIFY_WEBHOOK=http://127.0.0.1:8788/hook` (loopback http now allowed by
      `notify-setup.sh`), and polls `/health`. **Proven live on the host:** `sink
      healthy: ok`, probe `http 200`, and the timer **pushed a real trip** (20 flags)
      into the sink. `scripts/triage-alerts.py` then reads the sink, de-dupes the
      stable-key ledger flags, classifies each (over_budget/stall/slow_fetch), and
      prints severity + the **exact next command** + the runbook (plain selectable
      text; `--in/--json/--self-test`). **RULES #70** (operator-facing text must be
      selectable — a11y + copy/paste) + **#71** (an alert is not *actioned* until it
      carries severity + runbook + next command). tools.json + scripts/README.txt
      updated (notify-sink / notify / notify-selfhost / triage-alerts).

- [x] **Ops hardening + README refresh + capture tooling.** (3)
      `web-restart.sh` now kills **all** dashboard pids, waits, then relaunches
      one — fixes the `:5099` down-race (proven `PASS`). (4)
      `systemd/opencode-sentinel.service` gains `EnvironmentFile=-.env.local` so
      **NOTIFY_WEBHOOK** (alerting) + `SUBQ_API_KEY` reach the sweep (self-test
      PASS). (6/#7) README Status refreshed to current + **capture tooled**:
      `scripts/panels-tour.py` (per-panel PNGs + a `.webm` tour via a launched
      chromium; self-test PASS) and `host-path-probe.sh`. **Host-only remaining:**
      run the capture, wire the host browser venv (`/home/owner/.venvs/browser`),
      stand up Grafana.

- [x] OCR/vision + **gated** Claude (per the user's order). (1) **PaddleOCR**
      (the receipts-ocr stack) installs but its pipeline needs system libs /
      openCV-contrib the sandbox lacks → **host-only** (that is how receipts-ocr
      runs it); `ocr-image.sh`'s engine seam stays. (2) **(a) Gemini 2.5 Flash**
      vision: `scripts/vision-ask.py` built + self-tests, **but `GEMINI_API_KEY`
      is a placeholder** → needs a real key to run live. (3) **(b)
      `scripts/ask-claude.py`**: gated reviewer — refuses unless `--reason` **and**
      `--yes` (consult first), `--dry-run` + cost estimate; `ANTHROPIC_API_KEY`
      added to `.env.local` (gated, never auto-used); **RULES #68** +
      `models.policy.json` `$anthropic` + LiteLLM `claude-sonnet` entry;
      surfaced in tools.json. Next: give Gemini a real key to finish (a).
- [x] **Flagged panel (B)** — the incumbent patterns, in-repo. (1) A prominent
      home **Flags** card (bottlenecks · cost · slowdowns · stalls) built from
      the existing endpoints (`/api/cost`, `/api/ops`, `/api/health`), each
      flag a **count + clickable examples → `drill()`** (trace drill + rollups,
      a la Langfuse/Phoenix). (2) **Ledger annotations on the Gantt**: `ruleX`
      at every milestone ts, with hover. Proven: Flags renders (2 ≥ $0.10,
      20 over-budget · 21 deny-listed, slow endpoints); Gantt = 86 bars + 204
      annotation lines; test-dashboard-ui home+explore PASS. Option A
      (hosted-grade Langfuse/Grafana) stays README step 4.
- [x] **Clickable Gantt** (telemetry step 1). Each board Gantt bar is now
      `role=link` + `tabindex=0`, carries hover telemetry (`title`: model · $ ·
      in · duration), and a click/Enter handler → in-page `detail()` (session
      timeline) — the same drill contract as the treemap/table rows. Proven:
      86 bars; clicking one reveals `#detail-card` and calls `detail()`.
      Board heading now says "(click a bar to drill in)".
- [x] **Offload `/api/board`** off the event loop (telemetry step 4). Ported
      `apiBoardFresh` into `query-lib.mjs` + `query-worker.mjs`; `apiBoard()` is
      now `asyncCached` with an inline fallback. Proven: `/` stayed ~10 ms while
      the cold board computed; `/api/board` shape PASS. Fixes the "long delays".

- [x] **Semantic layer in `blacklist-guard.js`.** After the fixed pattern rules,
      the guard now calls `scripts/guard-classify.py` (SubQ) and **blocks
      irreversible/destructive commands**, fail-open (unreachable → runs),
      **memoized** (a repeat is free), disabled with `OPENCODE_SEMANTIC_GUARD=off`.
      `semanticVerdict` exported. Proven: `rm -rf /data/opencode` →
      `{block:true}` (SubQ noul memoized), `ls -la` → `{block:false}`;
      `blacklist-guard-self-test.mjs` PASS. Takes effect on the next opencode
      restart (plugins load at startup).
- [x] **(5) durable-pi wholesale adoption plan** — `docs/durable-pi-adoption.md`:
      what it adds (durable checkpoints, device-owned agents, multiplayer,
      proactive classifier, compaction/`reset`/`search_history`), why it is a
      **parallel service, not a migration** (opencode sessions are not
      importable into pi-durable), the exact host steps (Node 24 + OpenRouter +
      `just net up local` …), a decision gate, and their own "still can fail"
      caveats. **Not installed** (host-only). → **All six durable-pi answers are
      now addressed:** (6) mapping + RULE #69; (1) `search-history.sh`;
      (3) `guard-classify.py`; (4) `harden-services.sh`; (2) SSE; (5) this plan.
- [x] **(2) Dashboard snapshot→deltas SSE** (durable-pi pattern).
      `/api/stream` sends `event: snapshot` on connect then `event: delta` every
      5 s from **one server-side broadcast loop** to all clients; the client
      renders from the event payload (`renderCost`/`renderActivity`/`renderTodos`)
      and **falls back to polling** if `EventSource` is absent. Replaces
      per-client polling (the single-thread contention P1). Proven:
      `event: snapshot` returns the payload; test-dashboard-ui home+explore PASS.
- [x] **pi-durable / durable-pi mapping + 4 durable-pattern tools.** *Recorded
      first:* `docs/pi-durable-mapping.md` + **RULE #69** (layered decisions;
      handoff = curate + reset-note + **search-history**; snapshot→deltas;
      **memoized beforeTool guard**; checkpointed/supervised jobs). *Then:*
      **(1)** `scripts/search-history.sh` — search the stored history after a
      handoff (durable `search_history`); self-test PASS, live 3 matches.
      **(3)** `scripts/guard-classify.py` — the `jev-damage-control` analog:
      SubQ classifier + **durable memo**; proven `rm -rf /data/opencode` →
      **BLOCK (p=0.98)**, `ls -la` → ALLOW, repeat → memoized; self-test PASS.
      **(4)** `scripts/harden-services.sh` — systemd `Restart`/`StartLimitBurst`/
      `CPUQuota` drop-in for the crash-looping `deepseek-harness.service` (+ the
      compose `cpus` note); `--print`/`--apply`/`--self-test`. **Remaining:**
      (2) dashboard **snapshot→deltas SSE**; (5) durable-pi **wholesale**
      adoption (host/docs).
- [x] **Scripted items 1–3 + 6 as a host runbook** → `host-cpu-recovery` in
      `scripts/runbooks.json` (served at `/runbooks`): **(1)** `sudo systemctl
      enable --now docker`; **(2)** stop/disable the crash-looping
      `deepseek-harness.service` (or `CPUQuota=25%`); **(3)** reduce co-tenants
      (no TUI + `:4096` web + dsh + Chrome-heavy at once); **(6)** the stale
      `docker-proxy` `ss -ltnp` / `systemctl restart docker` sequence — with the
      exact `systemctl`/`ss`/`curl` commands. **New symptom covered:** after the
      user ran the TUI's fix, `web.sh` reported **HTTP 502** (caddy up,
      `opencode-web` still booting under contention) — the runbook says retry
      (~25 s pre-warm) + `web-logs.sh`. 21 runbooks total.
- [x] Fixed **`pressure-watch.sh`** (the side-finding in today's TUI lockup
      audit): the `printf '--- X ---'` headers were parsed by bash as options
      (`printf: --: invalid option`); all 7 are now `printf '%s\n' '--- X ---'`.
      Proven: header renders clean, `bash -n` OK, scan-constraints PASS. (The
      host tools `free`/`ps` are absent in-sandbox, so only the host runs it
      fully — it is a host monitor.)
- [x] **Pivot to the TUI instance + read-only causal audit.** The open TUI
      session (`ses_ec86dd329ffe…` *"Prompt loop audit for sentinel.sh"*, dir
      `/home/owner/…/repo`): **56 msgs · 247 parts · 85 tool calls** (bash 54 ·
      read 20 · grep 5 · MCP 5) · **1 issue · 0 stuck**. The issue's CAUSE:
      **`sed -n '1,60p' TODO.md` blocked by the blacklist guard (rule #7)**.
      Largest "gap" 228982 s = **overnight idle, not a stall** (session-health
      rejects >1 h gaps). New **read-only** `scripts/tui-audit.py` names the
      cause per issue (blacklist / permission / gateway / edit-match /
      missing-path / timeout); picks the TUI session automatically. Proven:
      self-test PASS; live audit found the sed cause + command. Surfaced in
      tools.json; a **PIN** block added to HANDOFF.md.
- [x] **P3 drill-down pass.** Wired the last session-bearing aggregates:
      **duplicate groups** (`/api/duplicates[].ids[0]`) and **patterns
      errorTools** (`example_sid`) now carry `data-go` → `detail()`. Most charts
      already drilled (table rows, treemap, scatter, sankey, signals, ops,
      flags); the rest are true aggregates with no session to open (pivot tool
      pairs, pattern bigrams, code files, OCR images, burn cumulative line).
      `test-dashboard-ui explore` PASS.
- [x] **P4 alerting sink.** `scripts/notify.sh` — the alerting the incumbents
      have and this stack lacked: reads `observability.db` ledger
      (ADVISORY/FAIL), builds JSON, POSTs to `$NOTIFY_WEBHOOK`; no webhook →
      prints payload + SKIPs (exit 0). `--dry-run`, offline `--self-test`.
      Proven: dry-run built 2 real flags; self-test PASS; scan-constraints PASS.
- [x] **P5 Option A — Grafana + SQLite ops view (scaffolded).**
      `docker/docker-compose.observability.yml` runs Grafana (plugin
      `frser-sqlite-datasource`) with the two SQLite stores mounted **read-only**
      and `docker/grafana/provisioning/datasources/sqlite.yaml` provisioning
      them. Host runs it: `docker compose -f docker/docker-compose.observability.yml
      up -d` → `http://127.0.0.1:3000`. Gives metrics, **alerting**,
      **annotations**, **saved views** without bespoke panels (RULE #67). README
      updated. Host-only (no docker in-sandbox) — verify plugin id/schema on
      first run.
- [x] **P1 host-path contention + P2 span drill** (from the "implement all"
      triage). **P1:** measuring showed the wire is only ~150–400 ms
      (TLS-dominated) and the host Chrome has just 3 tabs — the 20 s stalls were
      **single-threaded dashboard contention under the gate's own multi-page
      polling**. Fix: cut client poll load (cost/activity 5→8 s, todos 15 s,
      flags 30 s, balance/config 60 s). **P2 span drill:** `detail()` now shows
      **per-part duration (+ms)** and a span summary — proven
      `spans: 60 · total 536262ms · slowest 175440ms`. test-dashboard-ui
      home+explore PASS.
- [x] **Estimate Gantt + OCR crop** (per user). (1) Board **"Projected schedule
      — outstanding tasks"** Gantt: one bar per pending/in_progress card,
      projected from now, sized by the median realized session (heuristic,
      labelled; db cards use real spans); clickable to `detail()`. Renders
      **31 bars**. (2) `ux-smoke --vision` now **crops to the heading strip**
      (fast + focused; the answer to "crop to the affected area") and adds
      **goto retries** (the host path flakes). (3) **Finding:** the CONTAINER
      serves every page/API in **≤25 ms** — the slowness is the **HOST→Caddy
      path**, so the gate is flaky there. **Outstanding:** localize/fix the host
      path (or run `ux-smoke` on the host). PaddleOCR verdict: **host-only**
      (pipeline needs libs the sandbox lacks) — receipts-ocr runs it on the host.

- [x] **Light theme so local OCR can read** (RULES #66) — step 1 of
      "theme → offload → read". `html.light` overrides the CSS variables
      (`--bg/--fg/--surface/…`); nav `&#9680;` toggle + `?theme=light` (persisted
      in localStorage). `ux-smoke --vision` loads `?theme=light` and now OCRs
      **real words**: `board — kanban (state) + gantt (time)` → PASS. It also
      surfaced that the board pane still shows `loading…` at capture — the
      slowness step 2 (offload) targets. **Next: offload the heavy `/api/*`
      off the event loop.**
- [x] UX "vision" via **local OCR** (RULES #65). Audited the model catalog:
      no allow-listed model is vision-capable (`deepseek-v4.1-flash`,
      `gemini-2.5-flash-lite/flash`, `opencode-go/deepseek-v4-flash` are all
      text-only), so paying for a cloud VL model isn't warranted. `ux-smoke.py
      --vision` screenshots the board and OCRs it with **tesseract**
      (downscaled + inverted; the dark theme reads garbled, so it asserts the
      pipeline ran + no `loading`, not words). Result **36/36 PASS**.
      Midscene.js assessed: the right NL/vision framework, but its vision needs
      a VL model (out of policy) and its browsers can't launch in the sandbox —
      host-only. Also: STALE is just a restart gap (fixed live).
- [x] Make it useful, round 2 (user report). (1) The home **Sessions row
      "expands inline"** collapsed because `refreshCost()` rebuilt the whole
      table every 5s (my earlier poll change made it worse); fixed by pinning
      the table open while any row is expanded (`sessOpenCount`). (2) **Gantt
      discoverability**: renamed the tab to **`board · gantt`** and added a
      **"Gantt of sessions over time ▸"** link in the sessions footnote.
      (3) `ux-smoke.py` now asserts the row expands AND persists past the poll.
      Result **34/34 PASS**. Lesson: the first assertion failed on a wrong
      selector (`#sessions .exp` matched the header `<th class="exp">↕</th>`) —
      verify selectors against the DOM, don't assume.
- [x] **UX smoke gate** (e2e bridge). `scripts/ux-smoke.py` drives the six
      `:5099` pages through the host browser over CDP and asserts: each loads,
      `lang`, one `<h1>`, `<main>`+skip, no leftover visible `loading…` after
      the settle wait, `/explore` empty Session-detail hidden, and board
      **Gantt + Kanban render**. Result: **33/33 PASS**. Runnable-now bridge to
      **tester-army/e2e** (natural-language Playwright; run its own browsers on
      the host). Next: offload the slow `/api/*` reads off the single event
      loop.
- [x] UX review fixes from the user's report. (1) The empty **"Session detail"**
      card on `/explore` (rendered always-visible with only a hint + a `close`
      button) is now **hidden until a drill**: `#detail-card hidden`, shown by
      `detail()`, hidden by `close`. (2) The **Gantt was effectively
      invisible** — `board` was the 9th/last tab; moved to **2nd**.
      (3) `/api/board` pre-warmed (earlier). Verified: tab order
      `overview,board,charts,…`; `detailHidden=true` on load.
      **Remaining (dominant):** dashboard **slowness under load** — a fresh
      `/explore` goto timed out at 25s while pre-warm ran (single event loop;
      heavy endpoints block). Needs the expensive reads to yield (worker/
      streaming), not just pre-warm. Tooling: adopt **tester-army/e2e**
      (natural-language Playwright framework) for durable UX assertions.
- [x] **GANTT?** — the `/explore ▸ board` Gantt works (1 SVG + 37-row table
      twin + 70 kanban cards) but had two defects, both fixed and verified via
      the host Chrome over CDP: (1) the time axis rendered raw **epoch ms**
      (`1,790,000,000…`) — now **dates** (`09/28, 08:53 … 10/14, 13:46`) via a
      `tickFormat` on the x scale; (2) `/api/board` was **~19s cold**, so the
      board sat on `loading…` ~20s — now **pre-warmed on boot**
      (`apiBoard()` in the pre-warm `setImmediate`), board renders in ≤6s.
      Root lesson: the first selector (`#board`) was wrong — the pane is
      `#pane-board`, Gantt is `#boardgantt` — verify selectors, don't guess.
- [x] Browser tools applied to the `:5099` pages + UX audit. Drove all six
      (`/`, `/explore`, `/models`, `/runbooks`, `/manage`, `/docs`) through the
      host Chrome over CDP (playwright `connect_over_cdp`): **clean** —
      lang=en, one `<h1>`, 0 images without alt, 0 unnamed buttons/links,
      `<main>` + skip-link present. The one issue found on every page was
      **`STALE served 3dcbfad vs HEAD 8f1a8d2`** — the dashboard process was
      behind. Fixed the root cause: `web-restart.sh` gained a **dockerless
      fallback** (restart the local `dashboard.mjs` process when docker is
      absent), so `:5099` now serves `8f1a8d2` `stale=false` (verified both
      in-container and via `https://192.168.4.24:5099/api/rev`).
- [x] Browser-driver **benchmark + failover** (RULES #64,
      `scripts/browser_bench.py`). Probes cdp_tab / playwright / browser_use /
      selenium against the live CDP endpoint for the same op and writes
      `data/observability/browser-drivers.json` with `order[]`
      fastest-working-first; callers take `order[0]` and fall over down the
      list. Measured: **cdp_tab 1.3s < playwright 11s < browser_use 25s;
      selenium FAIL** (chromedriver needs libnss3/libnspr4/libdbus-1).
      playwright added to the installer. Surfaced in tools.json/README/HANDOFF.
      Note: all four attach over CDP (RULES #62) — none can launch a local
      browser here (missing system libs, no sudo).
- [x] Installed **browser_use + selenium** (scripted:
      `scripts/browser-tools-install.sh`). The image has no pip/ensurepip, so
      the script creates the venv with `--without-pip` and bootstraps pip via
      `get-pip.py`, then pip-installs both. browser-use 0.13.11 works —
      verified it connects to the host Chrome over CDP
      (`BrowserSession(cdp_url=...)`) and lists tabs. selenium 4.51.0 installs
      but its chromedriver cannot run here (needs libnss3/libnspr4/libdbus-1,
      absent with no sudo), so selenium is host-only. Surfaced in
      tools.json/README/HANDOFF.
- [x] Browser control formalized (the recurring "do it in the open chrome"
      ask). `scripts/cdp-tab.mjs` gained reusable form verbs — `fill`
      (prototype-setter + `input`/`change` so React/Vue registers it),
      `click`, `waitfor` — plus a `CDP_HOST` seam so the sandbox can drive a
      browser on the workstation (Chrome's debug port is host-side).
      `RULES.md` #62 (drive via CDP, never X11/Playwright; run where the
      browser runs) and #63 (`gh api` cannot mint a fine-grained PAT — it is
      UI-only, so drive the page). Proven: `cdp-tab.mjs --self-test` 14/14;
      lint 204/0; test-hygiene 52/0.
- [x] SubQ Snap triage gate wired (the "first SubQ Snap then Jev" ask). The
      SubQ key was validated (`GET /v1/models` → 200) and stored as
      `SUBQ_API_KEY` (in `.env.local`; added to `ensure-env.sh`'s wanted set).
      New `scripts/subq_snap.py` calls the **Decisions API**
      (`subq-snap-preview`, `POST /v1/systemone`, typed noul/choice/score,
      $0.05 / 1M input, output free) — a cheap first-pass gate to run on a
      **bounded digest** before an expensive second opinion. Proven:
      `--self-test` + `--dry-run` offline; live call on the 1.5 KB URL-session
      digest → `handoff: noul=0.986 (yes)`, 788 in-tokens (~$0.00004).
      Diagnosis: Jev's errors are the **rejected `JEV_API_KEY`** (8× in the
      DB), not a context-window problem; typesafe.ai login is down so rotation
      is blocked. Pipeline: `session-digest.sh` (curate) → `subq_snap.py`
      (triage) → Jev (deep review, once the key rotates).
- [x] Auto-digest on a non-latest trip (the curation half). On a T5/T6/T7
      trip the sentinel now writes `scripts/session-digest.sh <id>` output to
      `data/observability/digests/<id>.md` (seam: `SENTINEL_DIGEST_DIR`), so
      the curated facts (~1.5 KB, no model call) exist at detection time — the
      operator never replays the transcript into an LLM. `session-digest.sh`
      hardened to tolerate minimal/older DB shapes (missing `message`/`todo`).
      Proven: self-test asserts a digest is emitted for a tripped fixture
      session; live sweep wrote 12 digests (URL session 1526 B) for 12 trips.
- [x] Sentinel de-cry-wolf: **stable per-incident ledger keys**. Root cause
      read from the DB: `ledger.py` is `INSERT OR IGNORE` on
      `UNIQUE(source,key)`, but the sentinel keyed every trip by RUN
      (`sentinel-<ts>-<seq>`), so one chronic condition (slow `GET /provider`,
      up to 137 s) wrote **589** ADVISORY rows and desensitized the watchdog.
      Now every trip carries a stable key — `sentinel-T4-<worst-uri>`,
      `sentinel-T5/T6/T7-<sid>`, `sentinel-t3-<models>`,
      `sentinel-T1/T2-<id>_<sid>` — so a persisting condition stays ONE row
      while a NEW one still logs. Proven: self-test asserts ledger idempotency
      (`n1==n2>0`); live 2×-sweep rewind proof — 12 identical trips → **12**
      rows (was 24); `bash -n` + self-test PASS.
- [x] Observability fixes + DB-only session digest (the "non-latest,
      over-budget, not deny-listed" answer). Dashboard served **312ff85**
      (STALE) — restarted the entrypoint-launched :5099 process to HEAD, and
      code fixes: Live activity/Sessions timestamps now render in the VIEWER's
      local zone with a zone label (were UTC `toISOString`), and the poll loop
      no longer pauses on `document.hidden` (an embedded/preview viewer reports
      hidden and never fires `visibilitychange`, which froze the page until a
      manual reload) and now fires an immediate first tick. New
      `scripts/session-digest.sh`: one-pass **DB-only** digest
      (~1.5 KB vs the 606 KB transcript) — title, ratio, cost, last user ask,
      last assistant text, open todos, running tool, over-budget directive; no
      model call, read-only, redacted. Proven: `test-dashboard-ui` home PASS +
      explore PASS on the live :5099, `node --check`, `session-digest
      --self-test` PASS, live digest 1526 B for the URL session.
- [x] Sentinel T7: trip a recent session whose tool has been `running` past
      `session-health`'s run_ms and started since the last sweep — the
      DB-native stall (S0) the single-threaded server is blocked on.
      Cursor-bounded like T3/T5/T6 (silent first run, so the 12-day archival
      "running" part is history, not news); adds `stall_active` to `--json`.
      Proven: `sentinel.sh --self-test` PASS (T7 fires once on `s_stall`,
      silent after cursor); live-DB proof fired
      `TRIP T7 stall: ses_f0664ed1… bash running 1090140s` with a back-dated
      cursor; `test-hygiene.sh` 30/30. Design note: long inter-part *gaps* are
      deliberately NOT a trip — `session-health.mjs` rejects them (20/20
      overnight-idle), and a duplicate trip would desensitize (cry-wolf).
- [x] a11y cleanup — **all six pages 0 errors / 0 warnings / 0 notes** under
      @ra11y/core (home was already clean; explore 13E→0, the rest →0). Two
      root causes: (1) the `.pane` tabpanels carried `tabindex="0"` + inline
      `style="display:none"`, which together produced every
      `nested-interactive` and `inline-display-none-on-focusable` error across
      the 9 panes — panes now use the `hidden` attribute with no tabindex, and
      `activateTab` toggles `hidden`; (2) headings/names — `<h1>` added to
      explore/models/runbooks/manage/docs, `aria-label` on the docs `<select>`,
      distinct WCAG 2.5.3-compliant names on the two "[csv]" links (accessible
      name must contain the visible "[csv]"), `role="note"` on the chart
      tooltip. Proven: ra11y 0/0/0 on all six; test-dashboard-ui home+explore
      PASS; board still renders; harness --fast 3/3.
- [x] Board — DB-driven Kanban + Gantt shipped as a new `/explore` tab
      (`data-tab="board"`; placement decided: a view, not a new nav page).
      `GET /api/board` (read-only, TTL-cached, zero model calls) joins the
      opencode `todo` (99) ⨝ `session` → 171 cards (db 99 / md 72; states
      pending 21 / in_progress 9 / completed 141) + 91 session spans for the
      Gantt + 200 ledger milestones + heuristic `estimates` (n=85, median 71s /
      $0.0001). Kanban = CSS-grid columns; Gantt = vendored Plot.barX over real
      session spans (todo spans are degenerate); provenance labelled per datum;
      estimates flagged heuristic. Each chart has an accessible `<table>` twin.
      Proven: board renders via a headless shim (kanban 8.9 KB, table twin
      5.3 KB), `test-dashboard.sh` asserts added (tab/pane/kanban + /api/board
      shape), `test-dashboard-ui` explore PASS, `harness --fast` 3/3. ra11y
      /explore: 12→13 errors — the +1 is the SAME pre-existing
      `inline-display-none-on-focusable` on tabpanels (the board pane follows
      its 8 siblings); no new error class. Proper fix (queued): replace inline
      `style=display:none` with the `hidden` attribute across all panes.
- [x] a11y pair from the ra11y pass: skip-link + `<main id="main">` landmark on
      every page (nav() emits `<a class="skip-link" href="#main">` before the
      nav; all six templates wrapped) and `aria-current="page"` on the active
      nav link. ra11y re-scan: home 0E/0W/0N (was 0E/1W/1N); skip-link and
      active-state colour warnings 0 on all pages. Remaining, queued: explore
      12E (`nested-interactive`, `inline-display-none-on-focusable`), docs
      `forms/labels-required`.
- [x] UX/a11y auditor evaluation (audit → adopt/reject; completes the split-out
      turn). **`@ra11y/core`** (npm `npx @ra11y/core`, zero-dep, node>=22) RUNS
      here: home 0E/1W/1N, explore 13E/6W/1N, models+runbooks+manage 1E/3W/1N,
      docs 2E/3W/1N (1.3–2.6 s/page). **Adopted as an on-demand a11y auditor**
      (complements impeccable's design/contrast/heading pass); NOT wired as a
      blocking gate — npx needs network, a gate must stay deterministic. Its
      first audit fixed a real defect impeccable missed: `<html lang="en">` was
      on home only; added to explore/models/runbooks/manage/docs (re-scan:
      0 lang findings). **`@mdvp/cli` REJECT/DEFER**: exact path crashes
      (`ERR_MODULE_NOT_FOUND …/crawler-auth.mjs`, no Chromium here) and the
      static `--fast` path requires a public https URL (mis-parses local http
      → fetch failed). Note: the npm package `ra11y` is an unrelated library —
      the tool is `@ra11y/core`.
- [x] Sentinel T6: trip non-latest over-budget sessions active since last
      sweep (T1 covers latest only — prompting a background session re-sends
      its history, e.g. ses_eca8793c5ffe7gDmY5PGoa7PuX at 1.74M tok / 8.71x).
      T5/T6 share one cursor; T6 reuses the T5 machinery (silent first-run
      init, integer-epoch compare, advisory only, handoff guidance). Adds
      `over_active` to `--json`. Proven: self-test PASS (TRIP T6 fires once,
      silent after cursor), `--json` contract clean. Audit follow-up: the
      fixture now also carries `s_over` (over budget, ALLOW-listed, non-latest)
      so T6 is proven independent of T5 — it must trip T6 and not T5.
- [x] Sentinel T5: trip non-latest deny-listed sessions active since last
      sweep (T2 covers latest only — the $2.04 v4-pro history). Cursor-bounded
      like T3 (silent first-run init), integer-epoch compare, advisory only.
      Proven: self-test 3/3 (TRIP T5 fires once, silent after cursor),
      `test-hygiene.sh` 50 pass / 0 fail. Two real bugs caught by the
      verification loop, not review: `||` on a heredoc-opener line inside
      `$()` is a bash syntax error (moved after `)`), and a heredoc owns
      stdin so piped data never arrives (data now travels by env).
- [x] Impeccable audit patch order for `scripts/dashboard.mjs`. `doSearch`
      uses `AbortSignal.timeout(8000)` with a searching… spinner and falls
      back directly to `/api/search` on timeout/error; the FTS build (measured
      ~19s on 19.6k parts) moved off the event loop into `query-worker.mjs`
      (`apiSemanticFresh` in `query-lib.mjs`, single source; async
      `apiSemantic` with identical inline fallback) and `FTS_MIN_REBUILD_MS`
      raised 30s→120s; live polling is 5s with an in-flight guard +
      `visibilitychange` pause/resume; home HTML has `lang="en"`, `<h1>`,
      `<main>`, `aria-live="polite"` live regions. Proven: `node --check` x3,
      `test-dashboard.sh` 116 pass (+1 fail was sentinel T4, skipped for lack
      of docker CLI — proven identical at clean HEAD via stash, then fixed:
      the `SENTINEL_ACCESSLOG` fixture path no longer requires docker;
      `test-hygiene.sh` now 50 pass / 0 fail), headless UI panes all populate. Follow-up: `impeccable detect`
      on the served page flagged the new `<h1>` skipping to `<h3>` (fixed:
      card headings now `<h2>`) and pre-existing white-on-accent 3.4:1
      (fixed: active nav/tab text uses `var(--bg)`, ~5.6:1, accent token
      untouched). Detector clean (exit 0) on all six pages; explore carries
      1 pre-existing em-dash advisory.
- [x] Tev + JEV alternatives evaluated (choy.in DecideBench). Tev is open
      weights (92.8%) but needs conversion + runtime; imajev-4b leads open
      (95.0%); Laya stays baseline (59%); Strands-2B != Mapika-2B recorded.
      Adopt nothing (deterministic checks suffice); trigger: ASK-routing
      volume. Census now lists ollama models + decision weights.
- [x] Open/outstanding sweep: :5099 was STALE (03c9220 vs 180af26) —
      restarted, serves HEAD. Lossless raw (814 msgs, sha256-verified
      round-trip) archived to notes as _0110 (+provenance); /tmp scratch
      cleared. Still blocked on user: key rotation (needs new key
      material), Tev identity (no distinct tool found).
- [x] Length-gate unit fix (Array.from probe) + faithful stub. The 5-char
      gap proven == 5 astral chars in the pulled slice (U+1F534 etc.);
      stub now emulates browser UTF-16 slicing, fixture carries U+1F534
      (fails pre-fix by construction: 8 units vs 7 code points).
      Live E2E on ses_f1d27512 (814 msgs): sha256 match, 1.43 MB written,
      scratch removed. Gates: lint 127, hygiene 39, dashboard 117.
- [x] tool-census.sh + HANDOFF multi-agent section. Evaluated Strands
      Decider 2B (real, 2026-10-01, Apache-2.0; needs runner+weights —
      ollama 0.32.1 present, no weights), Nimble (rejected: commercial
      cloud, egress/cost policy), Tev (unidentified, no action), Laya
      (already in-repo via test-jev-laya-ab.sh). Census is executable
      evidence for the next evaluation. Coordination protocol installed
      (relay-drop + single committer, 5 rules, empty collision log).
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
