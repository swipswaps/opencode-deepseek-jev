# TODO — running log

Living backlog so momentum survives a session boundary. **HANDOFF.md** holds
the durable state; **this file holds the queue.** Update the statuses and the
date each session. Legend: `[x]` done · `[~]` in progress · `[ ]` todo.

Last updated: 2026-10-17

## Done (most recent first)

- [x] **Sentinel T8 — peer-tunnel flap detector (NEBULA-1 follow-up).** The
      recurring event is a tunnel, not a restart, so sentinel now trips on it:
      **T8** counts teardown/re-handshake/`state:dead` events for the nebula
      unit since the cursor (>= `SENTINEL_TUNNEL_MIN`, default 4;
      `journalctl -u <unit> --since` source + `SENTINEL_TUNNEL_LOG` file seam,
      cursor-bounded like T4). Logs a stable-key ADVISORY
      (`sentinel-t8-<peer>`) → the **existing** notify sink + `triage-alerts.py`,
      which gains a `tunnel_flap` kind (severity medium,
      next = `nebula-systemd-override.sh --diagnose`) + runbook **`tunnel-flap`**.
      Reuses the sentinel timer/install — no new daemon. Wired: sentinel
      self-test (T8 trips / names the peer / below-threshold silent),
      triage-alerts self-test (`test-durable`), runbooks 27→28.
      Gate: lint 264/0, hygiene 58/0, tooling 17/0.

- [x] **NEBULA-1 diagnostic + fix, both scripted (premise falsified).**
      `nebula-restart-trace.py` reads `/proc/<pid>/stat` + the parent's
      comm/cmdline for every nebula process; a non-PID-1 parent is the restarter.
      `--watch SECS`; `--json`; `--proc-root` seam; offline `--self-test`. Live
      result: **systemd (PID 1) is the parent** — but `nebula-systemd-override.sh
      --show` then showed **NRestarts=0 + one stable PID**, so the "3 PIDs/10 min
      crash-loop" premise is NOT reproduced; the recurring event is a **tunnel
      flap** to lighthouse-01. `nebula-systemd-override.sh` writes an idempotent
      defensive drop-in (StartLimit*/Burst in `[Unit]`, CPU/IO/Memory/LogRateLimit
      in `[Service]`) and `--diagnose` **classifies restart-churn vs tunnel-flap**.
      Wired: test-hygiene self-tests (+2 → 58/0), test-tooling `--json` (+1 →
      17/0), tools.json + scripts/README. Drop-in applied then **reverted on the
      host (2026-10-17)**; real issue carried forward as TUNNEL-1 (external).

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

## Outstanding issues (audited — resolve or explicitly accept)

- [x] **Telemetry-console upgrade** (deduced from the DB's own frequency:
      `ux 66 / telemetry 60 / dashboard 54 / cost 27 / drill 15 / slow 15 /
      flag 14`). Doctrine codified as **RULE #67** +
      `.opencode/skills/telemetry-dashboard/SKILL.md` (declarative + DB-driven +
      drill-down-native; Grafana / Vega-Lite / TanStack; **not Flutter**).
      Plan, in order: (1) **clickable Gantt** bars → session timeline;
      (2) a **"flagged" panel** — bottlenecks (slow endpoints), high-cost
      ($ by session/model), slowdowns (T4) as counts + examples; (3) drill-down
      across every section; (4) offer **Grafana + SQLite** as the non-bespoke
      ops view. **DONE: offload `/api/board`** to `query-worker.mjs` (RULE:
      heavy reads off the event loop) — `/api/board` now computes in the worker
      (ported `apiBoardFresh` into `query-lib.mjs` + `query-worker.mjs`,
      `asyncCached` + inline fallback). Proof: `/` stayed ~10 ms during the cold
      board compute; api/board shape PASS. **Shipped (2026-10-17 audit):**
      clickable **Gantt** → session timeline (`GANTT_WIRED` + the `drill()`
      listener) and the **Flags panel** (`#flags-card` — bottlenecks · cost ·
      slowdowns · stalls, each example click-to-drill via `data-go`). Residual:
      (3) drill-down on the remaining sections, (4) Grafana+SQLite offer (host).

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
  restart; guard firing; default model `opencode-go/deepseek-v4.1-flash` (was
  `deepseek/deepseek-flash`; both policy-ALLOW, preflight fails closed otherwise);
  orphaned word cloud restored; cache-hit report + patterns view
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

- [x] NEBULA-1: **closed — the event is a tunnel flap, not a process
      restart; drop-in reverted.** `scripts/nebula-restart-trace.py` named the
      parent (systemd, PID 1), but `nebula-systemd-override.sh --show` on the
      host showed **NRestarts=0, one stable PID (1111684) over minutes**, and the
      only recurring log signal was a **tunnel teardown to `lighthouse-01`
      (vpnIp 10.100.0.1)** (`Close tunnel received, tearing down.` / `Taking new
      handshake` / `tunnelCheck state:dead`). So systemd restarts nothing and the
      earlier "3 PIDs/10 min crash-loop" was misattributed. `--diagnose`
      classifies restart-churn vs tunnel-flap (offline self-test). The defensive
      drop-in was applied then **reverted on the host** (`--revert` + confirm
      2026-10-17). Evidence: the live `--show` output + logs/pressure-*.log.
      Carry-forward: the tunnel itself is external (below).
- [~] **TUNNEL-1: detector shipped (sentinel T8); the link fix is external (D).**
      vpnIp `10.100.0.1` (lighthouse-01) tears down / re-handshakes repeatedly
      (`state:dead`) while the nebula process is healthy. **Watch:** sentinel
      gains **T8 tunnel-flap** (>= `SENTINEL_TUNNEL_MIN` default 4
      teardown/re-handshake events since the cursor for the nebula unit;
      `journalctl --since` source, `SENTINEL_TUNNEL_LOG` file seam) → a
      stable-key ADVISORY the existing notify sink + `triage-alerts.py`
      (`tunnel_flap` kind → runbook `tunnel-flap`) deliver and act on. **Hand
      off:** `journalctl -u nebula | grep -E 'Close tunnel|state:dead'` +
      `nebula-systemd-override.sh --diagnose`. **Fix (external):** the
      peer/lighthouse link in `proxmox-dual-plane-mesh` — UDP reachability
      (firewall/NAT/MTU) and reload cadence.
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
- [ ] G5: Laya self-host (cuts Jev only, ~11 calls); embeddings rerank over FTS5
      + redaction + hard request cap
- [ ] G6: run `doctor.sh --full` from a host
- [ ] G7: Blockly (vendored) rule/runbook authoring; n8n scheduled jobs (host)

## Done (older entries archived)

Older Done entries moved to `docs/todo-archive-2026.md` (newest-first; git
history intact) to hold the read-first doc budget — see `./scripts/doc-budget.sh`.
