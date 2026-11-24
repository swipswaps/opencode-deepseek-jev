# TODO — running log

Living backlog so momentum survives a session boundary. **HANDOFF.md** holds
the durable state; **this file holds the queue.** Update the statuses and the
date each session. Legend: `[x]` done · `[~]` in progress · `[ ]` todo.

Last updated: 2026-11-24

## Done (most recent first)

- [x] **GUARD-BODY-1 — 2026-11-24.** Runtime script-body inspection in
      `blacklist-guard.js`: `bash script.sh` no longer hides a banned construct.
      Body enforcement is the destructive set only (command-line conventions and
      redirects stay out to avoid false positives on repo/skill scripts). New
      self-tests cover block / comment-only allow / unreachable-helper allow /
      reachable-helper block; repo scripts scan clean. Global copy synced and
      the server restarted; `guard-health.sh --check` confirms the loaded plugin
      matches the file (SHA-256), and a temp script was blocked live at its line.
      Also added the `guard-self-improvement` skill
      (`docs/HANDOFF-2026-11-24-guard-body.md`).

Older Done entries are in
[`docs/todo-archive-2026.md`](docs/todo-archive-2026.md) (newest-first); moving
them holds the tier-1 read-first budget (RULE #77).

## Outstanding issues (audited — resolve or explicitly accept)

- [x] **GATE-1 — gate observability, not blind timeouts.** (renamed from OPS-4; that ID collides with OUTSTANDING OPS-4 = eval/bash.) Verified 2026-11-11: full dashboard 161/0; use `gate-watch.sh` for full runs, no blind timers.
      `./scripts/gate-watch.sh ./scripts/harness.sh` (live log + heartbeat, no
      deadline) and record the last `ms=/ts=` line. The full-harness attempt
      was killed by a tool-level 420 s timeout under host load 19 (`dsh web`
      117% + Chromium), not a harness hang. Relieve the load and rerun; never
      add a blind timer.

- [x] **DASH-1 — 2026-11-04.** `08` persisted `DASH_SEGMENTS=cost`, so the SSE
      snapshot omitted activity/todos. Restored `cost,activity,todos` in
      `.env.local` and 08; added the `shed` flag/message and
      `dashboard-restart.sh`; live proof activity=80, todos=4.

- [x] **UX-1..UX-3 — 2026-11-04.** Resolved dashboard/observability work, moved
      to `docs/todo-archive-2026.md` to hold the tier-1 read-first budget.

- [x] **UX-4 — 2026-11-04.** Second `/app/` UX pass: steps hidden by default
      (switch), `/` focuses Activity search, Sessions sort (recent/cost/tokens/
      duration), 14-day cost trend on Overview, and Chrome install prompt.
      Desktop/mobile Playwright rechecked; installability `[]`.

- [x] **UX-5 — 2026-11-04.** Created `swipswaps/opencode-observability` as a
      standalone Vite/MUI Pages build. No synthetic data: GitHub Pages shows
      real `status-mui-*.png` captures with a clear "No live API" notice; the
      local `/app/` keeps the live API. App manifest/service worker, Pages
      workflow, monitoring, and xdg-open included. Public URL:
      <https://swipswaps.github.io/opencode-observability/>.

- [x] **UX-6 — 2026-11-04.** Pages app now probes the live API and renders the
      real Shell when reachable; screenshots remain the fallback. Dashboard
      permits only `https://swipswaps.github.io` with CORS + Private Network
      Access preflight. No changes to the other receipts Pages sites.

- [x] **SEC-3 — repo-mounted secrets (CLOSED 2026-11-11).** Container mounts prove `.env.local` and `docker/litellm-db.env` -> `/dev/null`, `docker/certs` -> `empty-certs`; the only remaining posture fail is the host `../notes/` secret. Original text: The web
      container still reads `/workspace/.env.local`,
      `/workspace/docker/litellm-db.env`, and `/workspace/docker/certs/*`.
      The override now hides them with empty binds (`/dev/null`, `empty-certs`);
      run `./scripts/web-restart.sh --recreate` and expect
      `security-posture.sh` **19/0**. Then: rebuild the image to bake
      `openssh-client`, clean stale `opencode-container` authorized keys, and
      consider an app/agent env split (`.env.local` values still reach the
      agent shell; the guard asks, it is not a sandbox).

- [x] **Prompt-injection residual (mitigated 2026-11-05).** The tripwire still
      logs `verdict=injection` and model-level compliance remains a residual,
      but the blast radius is now bounded deterministically: `opencode.json`
      denies `.env*`, `docker/certs/*`, and `docker/litellm-db.env` reads,
      denies `opencode debug config`, and asks on `task`/`webfetch`/`doom_loop`.
      `test-hygiene.sh` asserts the policy; re-run `red-team.sh` after any
      model/policy change and keep untrusted content out of instruction
      position.

- [x] **Script catalog was incomplete (resolved 2026-10-18, see Done).** The
      dead-ref sweep found 30 tracked scripts uncataloged (the audit's 23 was a
      stricter match; its "chatlog.sh/ask.sh no longer exist" premise was false).
      All 30 cataloged + a `test-hygiene.sh` coverage gate — the README claim is
      true again and now enforced.

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
      slowdowns · stalls, each example click-to-drill via `data-go`).
      **(3) drill-down on the remaining session-bearing sections: DONE
      2026-10-19** (health · patterns · pivot · word cloud; see Done). Residual:
      (4) Grafana+SQLite offer (host).

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

- **A — local, doable now:** **ALL DONE 2026-10-18** — ~~tier-1 doc trim~~ (TODO
  Done → archive; RULES #77; `scripts/README.txt` is tier-2, not budgeted),
  ~~`quirks` fuzzy precision~~ (word-boundary regexes, held-out FPR 0),
  ~~`ensure-env.sh` password-regen review~~ (restart note + scripted runbook).
  Next local work moves to the C groups (own session).
- **B — needs a host/test this container cannot run:** `doctor.sh --full` Tier 10,
  `ux-audit.py`/`ux-test.py`, `test-sidebar-streaming.sh`, `rotate-api-keys.sh`
  end-to-end.
- **C — larger code (own session):** per-model adaptation, client-vs-agent
  stall, Plot migration, embeddings rerank, and auto-handoff **action** — all
  **DONE 2026-10-18** (RULES #87). ~~Residual: G1 UX drill-down~~ **DONE
  2026-10-19** (telemetry (3): health · patterns · pivot · cloud).
- **D — external / new deps (never batch):** upstream SPA, LiteLLM `max_budget`
  routing, finos/perspective, Laya, Blockly/n8n.
- **E — durable-agent gaps (deduced 2026-10-18; own session each).** Four
  structural gaps the loop still has, each with the GitHub tool that closes it.
  **E1 claims → enforced gates: DONE 2026-10-18** (RULE #84): the live
  capability registry now fails closed on unaccepted DEGRADED/MISSING
  (`accepted_degraded` = explicit waivers), gated by `test-hygiene.sh`.
  (Regression-eval tooling `promptfoo`/`inspect_ai` stays a D-decision.)
  **E2 external-state bridge:**
  `gh` is absent in-container, so an issue hand-off was a manual body-file relay
  with no read-back. **DONE 2026-10-18** (`scripts/issue-bridge.py`:
  link/poll/status → ledger; the hand-off now prints the read-back step;
  next-action surfaces open external issues). **`poll --api` (2026-10-19)**
  closes the read-back from the container for public repos (stdlib, no gh/token;
  `GITHUB_TOKEN` optional); TUNNEL-1 `#5` re-read **OPEN** (updated 10-18).
  **E3 concurrency lock/merge key:
  DONE 2026-10-18** (RULE #85): `loop-lock.sh` — a TTL, actor-tagged
  single-writer lease (`flock`-serialised, atomic write) that `loop-state.sh
  --begin` requires and `next-action.sh` surfaces; a dead holder is reclaimed by
  TTL. (Dolt/`backlog` zero-conflict *merge* stays a D-decision — only needed if
  we want parallel writers, not one owner.) **E4 owned task identity: DONE
  2026-10-18** (RULE #86): `task-id.py` — a durable, addressed id (id → title +
  owner) on the ledger; `loop-state.sh` registers/closes it and `next-action.sh`
  surfaces open tasks. (`beads`/`backlog` add zero-conflict *merge* if parallel
  writers are ever wanted.)

## Queue (ranked, top first)

- [x] **HARNESS-STALL-1 — DONE 2026-11-22.** A 5m42s silent gate (it PASSed at
      17:07:04Z) was silence, not a hang. Landed: heartbeats, measured bound,
      `GATE_ABORT`, failure logs, `diag-harness-stall.sh` (`/proc` log + inotify
      + attribution), sandbox/db resolvers, ledger `ts_epoch`, brief State/Next.
      **The 22:30Z host run named it: `test-hygiene`, 112 pass / 1 fail, a
      host-only check.** Bounds are **pass-only** now (failed 178s/82s samples
      dropped; `docs/gate-evidence-2026-11-15/`). **Check named 2026-11-21:**
      `global guard symlink resolves to the repo plugin`
      (`logs/harness-failures.log`, gate 20261120T235457Z). The check now prints
      the actual target + `install-global-guard.sh --install`; that script's
      `--check` now rejects a wrong symlink or a differing copy (self-test
      covers both). Bounds are now env-tagged (`host` vs `sandbox`) and
      untagged samples are ignored, so a 700 s container run cannot inflate the
      host bound. **Closed 2026-11-22:** guard installed and `--check` PASS;
      host `harness.sh --fast` is green (`4 pass / 0 fail`,
      `last-gate.json state=complete`) with `test-hygiene` host `n=3`. The
      `lint` silence was also explained: the parallel shellcheck barrier emits
      nothing until `wait`, which is why a 190 s window looked like a hang
      (the 848 s p95*2 bound was correct).
- [x] **CHROMIUM-VERIFY-1 — DONE 2026-11-22.** Host, after
      `GRAPHIC_DRIVER=amd`: playback verify returned `dec_delta_s=0.109`,
      `verdict=PASS hardware decode is running`. Idle now reports
      `verdict=INCONCLUSIVE` (exit 2) instead of a misleading failure; the
      dying-PID `cat /proc/<pid>/comm` race is closed. Controlled A/B:
      `scripts/chromium-video-ab.sh` (measure/compare, pre-registered rule).
- [x] **CHECK-TIMEOUT-1 — DONE 2026-11-22.** Every `--self-test` in
      `test-hygiene.sh` is wrapped in
      `timeout "${CHECK_TIMEOUT:-120}"`, so one hung test cannot consume the
      gate bound; the existing `bad '<name>'` line names the offender. Also
      fixed the cause of a real 60 s contract timeout found while enabling it:
      `audit-tool-calls.py --recent` filtered in Python after `json_extract`
      over every part row (~15 s live); the session filter is now pushed into
      SQL (0.00 s).
- [ ] **AUDIT-1 — full triage 2026-11-11.** `docs/AUDIT-TRIAGE-2026-11-10.md`; handoff `docs/HANDOFF-2026-11-11.md`.
      P0: rotate the 4 `../notes/` secrets; patch OpenSSH. P1: B43 24–48 h
      measurement (185 total / 184 pre / 1 post at 20:54), TUNNEL-1 external #5, stale
      sessions, JEV key. Fixed this pass: `session-health` default DB path,
      `issue-bridge.py` exec bit, SEC-3 closed (container secret binds hidden).
- [ ] **[~] TUNNEL-1 LINK (external, D):** the peer/lighthouse link in
      `proxmox-dual-plane-mesh` — UDP reachability (firewall/NAT/MTU) and reload
      cadence. Filed as `swipswaps/proxmox-dual-plane-mesh#5` (2026-10-18);
      re-read **2026-10-20 22:5xZ: OPEN, no new comments/labels** (issue-bridge
      poll --api; duplicate-skipped). Local repo cannot reach the host journal
      or the mesh repo; the hand-off paste is now the scripted
      `scripts/tunnel-link-probe.sh` (header per step, per-step timeouts,
      `logs/tunnel-link-<ts>.log`, flap cadence + UDP endpoint distribution).
      **Probe 2026-10-20 19:55 EDT:** NRestarts=0, 0 systemd lifecycle lines;
      `Close tunnel received` is metronomic — median gap **130.0 s**
      (min 127 / max 132) over 7 teardowns; handshake follows in 1–3 s, then
      `tunnelCheck state:dead` ~21 s later; `udpAddr` **alternates**
      `192.168.4.45:4242` / `100.70.43.78:4242` for the same
      `certName=lighthouse-01`; overlay 3/3, 0% loss, 4–12 ms; `nebula0`
      route MTU **1300** (so the 1400/1472 DF probes were invalid locally).
      **ROOT CAUSE (ws24, 2026-10-21):** `mesh-recover.sh` check2 restarts
      nebula whenever `10.100.0.1` fails ping **and** TCP/22, under a **120 s
      rate guard** → a restart every ~127 s. `recover.log` proves **70
      restarts 09:57–12:36** (median gap 127 s), each after `all peers failed`;
      the explicit restart resets `NRestarts` to 0, which is why the old
      "NRestarts=0 = process healthy" inference was wrong. The upstream overlay
      outage (LAN plane untested, `lan=none`) recovered at 12:37 and the loop
      stopped. Probe now takes the PID/NRestarts sample at the **end** (run 1's
      restart landed after the mid-run sample) and still names the caller with
      `--sudo`. Next: (a) patch mesh-recover to require consecutive failures,
      exponential backoff, and a real LAN probe — never restart local nebula
      for a single unreachable peer; (b) fix `check0a` (`lo` is `state
      UNKNOWN`, not down); (c) post the recover.log evidence + cadence to #5.
      **(a)+(b) PATCHED 2026-10-21** in mesh-recover.sh: check2 logs
      `UPSTREAM-DOWN` and never restarts local nebula; local restarts require
      2 consecutive checks/>=120 s + backoff 120→300→600→1800; `lo` uses
      operstate; `--self-test` PASS (exit 0/2). Pushed 9d0850a + 6cd102c;
      6 stale proactive tasks closed; alert + proactive minted `T-c39910`.
      Still to do: 1 h verification as a **telemetry-first script** (heartbeat
      per interval: ts/elapsed/new restarts/healthy/last verdict; `--self-test`
      fixture; exit 0/2; `--close-task` opt-in) — the silent `sleep 3600`
      heredoc was wrong — then close `T-993fc4` and post #5.
- [ ] G4: wire `docker/litellm.config.yaml` `max_budget` into routing (needs proxy)
- [ ] G5: Laya self-host (cuts Jev only, ~11 calls). **Embeddings rerank over
      FTS5 shipped 2026-10-18** (`scripts/rerank.mjs`: offline by default,
      redaction-mandatory external path, hard caps) — remaining: point it at a
      real embedder provider (Laya/OpenAI-compatible) and wire into
      `/api/semantic`.
- [ ] G6: run `doctor.sh --full` from a host
- [ ] G7: Blockly (vendored) rule/runbook authoring; n8n scheduled jobs (host)

## Done (older entries archived)

Older Done entries moved to `docs/todo-archive-2026.md` (newest-first; git
history intact) to hold the read-first doc budget — see `./scripts/doc-budget.sh`.
