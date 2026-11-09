# TODO — running log

Living backlog so momentum survives a session boundary. **HANDOFF.md** holds
the durable state; **this file holds the queue.** Update the statuses and the
date each session. Legend: `[x]` done · `[~]` in progress · `[ ]` todo.

Last updated: 2026-11-09

## Done (most recent first)

- [x] **CLIENT-AUTO — 2026-11-08.** `client-setup.sh`: one-shot client
      bootstrap (discover server, write ssh block, X server, self-heal timer
      via systemd/launchd); `--heal` repairs after a roam. Self-tested.

- [x] **PASTE-ROAM — 2026-11-08 (RULE #95).**
      `scripts/clipboard-preflight.sh` gates the paste path (Wayland vs X11 vs
      SSH-forwarded X11), reads TARGETS, and fails on an image flavour that
      makes opencode abort with "Failed to send prompt" (`--set`,
      `--clear-text`, `--json`, `--self-test`).
      `scripts/network-change-probe.sh` proves the plane after a network change
      (interface x :4096/:5099 matrix, cert SANs, wildcard binds); `--watch`
      re-runs on change and `--peer HOST` is the client-side half (LAN vs
      overlay). `scripts/ssh-x11-setup.sh` codifies clipboard-over-SSH trust.
      Self-tests wired into `test-hygiene.sh`.

- [x] **WEB-REL — 2026-11-08 (RULE #94).** Hardened the access-plane watchdog:
      `web-health.sh` now takes one settle re-probe, requires a
      consecutive-failure threshold (`WEB_HEALTH_FAIL_THRESHOLD`, 2) and a
      recovery cooldown (`WEB_HEALTH_COOLDOWN_SEC`, 600) from a durable state
      file, delegates recovery to the checkpointed `recover-4096.sh --recover`,
      writes its log under `logs/`, and has a behavioral offline `--self-test`.
      `docker-compose.yml` gates caddy on an `opencode-web` healthcheck
      (`depends_on: condition: service_healthy`). User units dropped the no-op
      `network-online.target` ordering; the timer switched to
      `OnUnitInactiveSec`. Both self-tests wired into `test-hygiene.sh`.
      Also fixed clipboard delivery: `rotate-server-password.sh` now
      auto-detects `DISPLAY`/`WAYLAND_DISPLAY` (tty/SSH fallback to the local
      X socket) and backgrounds `xclip`; a guarded `~/.bashrc` block does the
      same for interactive shells (backup kept).

- [x] **UX-8 — 2026-11-06.** Added `usability-suite.py` (ISO 9241-11
      tasks, WCAG automated subset, CWV lab, target/keyboard/reflow/reduced
      motion, optional axe/SUS), a 30-minute timer installer, a CI workflow,
      and the `/usability` guided human runner (+ `usability-guided.py`).
      Added `/app/#usability` + MUI pulse, `/app/<legacy>` redirects, guide,
      and RULES #93 closeout gate (BLOCKED on the post-fix retest).

- [x] **STATUS-1 — 2026-11-06.** Added `issue-benchmark.py` (real
      security/stall/tunnel metrics → `issue_bench` + `benchmark.json`),
      `choice-gate.py` (+ `choices.json`) for the human-only residuals,
      `pulse.py` (one status screen), and the editable `/graph` page
      (`graph_edit` persistence). Map: `docs/STATUS-AUTOMATION.md`.

- [x] **DOCS-2 / SEC-4 — 2026-11-05.** Archived older HANDOFF PINs and TODO
      Done entries to restore tier-1 to **33,873 / 35,000**. Added a
      deterministic `permission` policy (deny secret/cert reads and
      `opencode debug config`; ask on task/webfetch/doom_loop) and a
      `test-hygiene` assertion for it, mitigating the prompt-injection
      residual. Host gate re-run pending after the permission/docs change.

- [x] **TLS-2 / UX-7 — 2026-11-05.** Added 443 + Tailscale + LAN + Nebula TLS
      redundancy, SAN verification, `/ca.crt`, path redirects, and the HTTPS
      self-heal/client CA scripts. PC trust installed (system/Firefox/Chromium);
      strict verification 200 on 5099/443/LAN. Fixed the legacy `time · now`
      header collision and refreshed all 12 screenshots. Added the public
      `opencode-observability` Pages app with live API probing and real
      screenshot fallback. Handoff: `docs/HANDOFF-2026-11-05.md`.

- [x] **DOCS-1 — 2026-11-05.** README, web/README, scripts catalog, UX audit,
      handoff PIN, TODO, screenshots, and the new Pages README refreshed for
      the current TLS/Pages/scripts state.

- [x] **SEC-2 — 2026-11-04.** DB-backed LiteLLM (private postgres, admin login
      200); same-CA TLS leaf rotation after the live key matched 3 snapshots;
      85 findings scrubbed (logs redacted, snapshots/env backups purged,
      post-scan 0/2224); red-team offline+live; `sensitive-read` rule;
      prompt-injection tripwire; host-home mount removed from the override and
      applied by the 2026-11-04 recreate; `security-posture.sh` 16/3
      pre-recreate (the 3 `repo_secrets` checks; expect 19/0 after SEC-3);
      durable key `.config/opencode/container_key` (restrict), `/rag:ro`, and
      `openssh-client` in the Dockerfile (rebuild; `11 --install` for the
      current container).

- [x] **Older Done (2026-10-22 and earlier) archived 2026-11-05.** See [`docs/todo-archive-2026.md`](docs/todo-archive-2026.md).

## Outstanding issues (audited — resolve or explicitly accept)

- [ ] **OPS-4 — gate observability, not blind timeouts.** Use
      `./scripts/gate-watch.sh ./scripts/harness.sh` (live log + heartbeat, no
      deadline) and record the last `ms=/ts=` line. The full-harness attempt
      was killed by a tool-level 420 s timeout under host load 19 (`dsh web`
      117% + Chromium), not a harness hang. Relieve the load and rerun; never
      add a blind timer.

- [x] **DASH-1 — 2026-11-04.** `08` persisted `DASH_SEGMENTS=cost`, so the SSE
      snapshot omitted activity/todos. Restored `cost,activity,todos` in
      `.env.local` and 08; added the `shed` flag/message and
      `dashboard-restart.sh`; live proof activity=80, todos=4.

- [x] **UX-1 — 2026-11-04.** `:5099` readability/copy: larger high-contrast
      text, selectable content, copy buttons for session IDs, activity
      text/commands, timeline rows, and timeline JSON; expand only on the
      control; and a live d3-assisted diagnostic table (last 30 parts: start dot
      on the time axis, relative-duration bar, full command/text, exact
      duration, moving now). Screenshots refreshed (`status-home`,
      `status-timeline`); headless UI test PASS.

- [x] **UX-2 — 2026-11-04.** Combined Live activity + Diagnostic timeline into
      one Activity timeline (newest first, filter chips, 30/all, expand/copy,
      start dot, relative duration, full command/text, exact duration). Moved it
      under the stats; mobile 390 px layout stacks rows with 44 px controls;
      added PWA manifest/service worker/icons and verified Chrome installability
      (`[]`). Decision/sources: `docs/UX-MOBILE-AUDIT.md`. Screenshots
      `status-timeline` + `status-mobile`.

- [x] **UX-3 — 2026-11-04.** Added the separate full MUI/React observability
      app at `/app/` (`web/`: React 19.3 + MUI 9.5 + Vite 8.3; Overview,
      Activity, Sessions, Todos; permanent drawer + mobile bottom nav; app
      manifest + shared service worker; Chrome installability `[]`). Build is
      550 kB minified / 171 kB gzip; legacy `/` remains. Screenshots
      `status-mui-{desktop,activity-desktop,mobile,activity}.png`; details
      `web/README.md`, `docs/UX-MOBILE-AUDIT.md`.

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

- [ ] **SEC-3 — repo-mounted secrets (staged, needs recreate).** The web
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

- [~] **HOTSPOT-1:** `hotspot-reconnect.sh` + `terminal-reset.sh`; self-tests
      green; live roam proof open.
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
- [x] **TUNNEL-1 WATCH: detector shipped (sentinel T8).** vpnIp `10.100.0.1`
      (lighthouse-01) tears down / re-handshakes (`state:dead`) while nebula is
      healthy. T8 trips on >= `SENTINEL_TUNNEL_MIN` (default 4) events since the
      cursor → stable-key ADVISORY → `triage-alerts.py` (`tunnel_flap` → runbook
      `tunnel-flap`). Host check: `journalctl -u nebula | grep -E 'Close
      tunnel|state:dead'` + `nebula-systemd-override.sh --diagnose`.
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
