# Handoff archive — 2026

Older `HANDOFF.md` PIN blocks, moved here to hold the tier-1 read-first doc
budget (RULE #77). `HANDOFF.md` keeps the current state; this file is reference
history (tier-2, not budgeted). Newest first among the archived blocks is the
2026-10-18 pair.

## Archived 2026-11-05 (moved from HANDOFF.md)

These PIN blocks were moved here to hold the tier-1 budget after the 2026-11-05 security/rotation/a11y close. Newest first.

> **PIN 2026-11-04 (SEC-3 / HANDOFF):** verified: LiteLLM DB login 200, TLS
> leaf rotated (same CA), artifact scan 0/2224, red-team offline+live, readme
> audits 8/0 and 6/0, harness 4/0, `security-posture.sh` **16/3** on the
> running container. **Gate note:** the later full-harness attempt was killed
> by a **tool-level 420 s timeout**, not a harness deadline; the host was at
> load **19** (`dsh web` 117% CPU + many Chromium renderers) and no harness
> process remained. Use `./scripts/gate-watch.sh ./scripts/harness.sh` to rerun
> with a live log + heartbeat and read the last `ms=/ts=` line; `test-hygiene`
> is 63/0. The dashboard is verified separately (activity 80, todos 4); its UX
> now has one combined activity timeline (filter/expand/copy, time dot +
> relative duration + full command/text per row), 390 px Android layout, and
> an installable PWA shell, plus a separate full MUI/React app at `/app/`,
> and selectable,
> higher-contrast text; screenshots (home + timeline) refreshed 2026-11-04. **Missing / will break:**
> 1. The repo is mounted at `/workspace`, so the web container can still read
>    `/workspace/.env.local`, `/workspace/docker/litellm-db.env`, and
>    `/workspace/docker/certs/*`. The override now hides them with empty binds
>    (`/dev/null`, `empty-certs`); the 3 `repo_secrets` checks stay red until
>    `./scripts/web-restart.sh --recreate` (drops the session). Expect 19/0.
>    Container-side copies of host-only scripts (`preflight`, `ensure-env`,
>    `certs-verify`, `rotate-*`) will see empty files after that; run them on
>    the host via the durable SSH key.
> 2. `.env.local` values still enter the container environment (`env_file`)
>    because the app needs them; the agent shell inherits them. Removing that
>    needs a separate app/agent user or sidecar. `env` is ASK, not a sandbox.
> 3. `/rag:ro` and `openssh-client` are in the override/Dockerfile but not in
>    the running image/container. The current container uses the durable key
>    plus a runtime ssh client; the next recreate/rebuild applies them. The
>    `/rag` venv is host-specific and read-only: edit via SSH, don't run it
>    in the container.
> 4. The durable key is in the rw `~/.config/opencode` mount. `restrict`
>    blocks pty/forwarding but not exfiltration; rotate/revoke if compromised.
> 5. Stale `opencode-container` public keys remain in `~/.ssh/authorized_keys`;
>    harmless without private keys, clean when convenient.
> 6. Prompt injection is model-level. The tripwire logs `verdict=injection`
>    (advisory); the regex guard is defense-in-depth, not a sandbox.
> **Next probes:** recreate web -> `security-posture.sh` (expect 19/0);
> rebuild the image to bake `openssh-client`; `readme-audit.sh` both repos;
> `red-team.sh` after recreate; clean stale authorized keys; consider an
> app/agent env split.

> **PIN 2026-11-04 (SEC-2):** LiteLLM is DB-backed (private postgres,
> `admin` login 200); the TLS leaf was rotated with the same CA after the live
> key matched 3 snapshots; 85 findings were scrubbed (logs redacted, snapshot
> and env backups purged, post-scan 0/2224). `red-team.sh` passes offline+live;
> the blacklist `sensitive-read` rule and a prompt-injection tripwire are in
> the module. The compose override no longer mounts `/home/owner`; the
> 2026-11-04 recreate applied it and `security-posture.sh` is **15/0**.
> Host access is now durable: `~/.config/opencode/container_key` (host-mounted,
> authorized once with `restrict`), `/rag:ro` for the RAG repo, and
> `openssh-client` in the Dockerfile (rebuild to bake it; `11-host-access.sh
> --install` covers the current container). Residual: prompt injection is
> model-level; the regex guard is defense-in-depth, not a sandbox.

> **PIN 2026-10-21 (JEV-OFF):** cloud JEV is disabled by policy. After the
> rotation, `opencode run` smoke hit the 180 s timeout, but the new DeepSeek key
> is valid (direct balance 200, $7.35), so the timeout is client/store latency,
> not auth. `opencode.json` no longer carries `jev-guard`, `jev-review` or the
> cloud skills; preflight/ensure-env treat `JEV_API_KEY` as optional; the rotate
> script skips JEV. The guard/decisions backend is now **SubQ**
> (`scripts/subq_snap.py`; runbook `subq`): measured 1.4 s for the 4 guard
> questions vs Laya's 33-37 s on this CPU, so Laya is batch-only. jev-guard
> 0.3.1 ignores JEV_BASE_URL; `docker/patch-jev-guard.sh` adds it at start. **Laya** is opt-in for the guard:
> `jev-guard` honors `JEV_BASE_URL`, but `jev-review` hardcodes
> `https://api.typesafe.ai/v1/systemone`, so the review MCP cannot use Laya.
> **Restart `opencode-web` to apply.** History: `docs/todo-archive-2026.md`
> (JEV 401s) and `test-jev-laya-ab.sh` (A/B harness).

> **PIN 2026-10-20 (OBS-1):** `:5099` Live activity and Todos stuck at
> `loading...` was a server bug, not a browser one. `/api/stream` sent
> `{"cost":{},"activity":{}}` because `ssePayload()` returned the **promises**
> from `apiCost()`/`apiActivity()`; `renderCost({})` then threw, so the other
> two panes never rendered. Fixed by awaiting both (snapshot + single-flight
> deltas), isolating the three client renders, and asserting a materialized
> snapshot (`cost.totals`, `activity` array) in `test-dashboard.sh`. Verify:
> `curl -N http://127.0.0.1:5099/api/stream | head` then reload `/`.
> **TUNNEL-1 LINK:** #5 re-read **OPEN** 2026-10-20 ~22:55Z with no new
> comments/labels; still external. The hand-off paste is now
> `scripts/tunnel-link-probe.sh` (header per step, per-step timeouts, one
> `logs/tunnel-link-<ts>.log`, verdict, flap cadence + UDP endpoints).
> **TUNNEL-1 ROOT CAUSE FOUND 2026-10-21 (ws24):** the 130 s teardown cadence
> is `proxmox-dual-plane-mesh/scripts/mesh-recover.sh` — its check2 sees
> `peer 10.100.0.1 unreachable` (ping AND TCP/22) and runs
> `sudo -n systemctl restart nebula`, with a **120 s rate guard** (lines
> 155–172) so it fires every ~127 s. `recover.log`: **70 restarts 09:57–12:36**
> (median gap **127 s**, 121–201), every one preceded by `all peers failed`.
> That is why the tunnel log shows metronomic teardowns and why **NRestarts=0**
> (explicit restarts reset it). The upstream overlay outage was separate
> (LAN untested: `peer ... lan=none`); it recovered at 12:37 and the loop
> stopped. The probe now samples PID/NRestarts at the very end (the first run's
> restart happened after its mid-run sample). **Patched** mesh-recover.sh
> (2026-10-21): peer/lighthouse loss is `UPSTREAM-DOWN` and never restarts
> local nebula; local restarts need 2 consecutive checks over >=120 s plus
> backoff 120→300→600→1800; `lo` judged by operstate; `--self-test` PASS.
> Pushed `9d0850a`/`6cd102c`; 6 stale proactive tasks closed; ledger alert +
> proactive minted `T-c39910` (tunnel_flap). `T-993fc4` stays open until the
> 1 h check. Verification must be **telemetry-first** (heartbeat line every
> interval: ts/elapsed/restarts/healthy/last verdict; `--self-test`; exit 0/2;
> `--close-task` opt-in), not a silent `sleep 3600`. Then post #5.

> **PIN 2026-10-20 (LAT-2):** T4 now **names** the cause of a slow-fetch burst
> instead of reporting it unexplained. A fetch interval `[ts-duration, ts]`
> overlapping a long tool part is attributed from the read-only DB
> (`— overlaps tool bash 307.9s in ses_…`), and `latency-timeline.sh` labels
> each such fetch (`<- tool:bash 307.9s`; `attributed_to` in `--json`). Real
> proof: the 307.9 s gate span (16:55:24–17:00:32) overlaps the 170 s
> `/config` fetch ending 17:02:22. Both self-tests assert the attribution
> (hygiene gate). **Next:** TUNNEL-1 LINK (external, #5).

> **PIN 2026-10-20 (loop equilibrium + gate debt):** session started at
> `ab75d1e` (ahead=0). The controller is healthy: `progress-review` now records
> a **blocked-external PASS** (not a stall) when the top unit is external, and
> `next-action` names TUNNEL-1 whose link fix stays in
> `proxmox-dual-plane-mesh#5`. Live sensors: T4 x64 slow `/config` 170s at
> 17:02Z (a burst/queueing artifact per #72, pre-restart) and T3 gateway
> `AI_APICallError` x4 at 17:11Z (provider-side, retried). **Debt:** the last
> green gate was `8914dcb` (two commits back); this session re-runs full
> `harness.sh` at HEAD. **Docs:** tier-1 was 34,959/35,000 (41 tok) — older PINs
> moved to `docs/handoff-archive-2026.md` (RULE #77). **LAT-1 done:** the 17:02
> T4 burst overlaps self-inflicted long tool spans (a 308 s gate run, a 200 s
> `sleep`) in a single-threaded server; `/api/semantic` and `/config` are
> queueing, not handler cost. **Next:** LAT-2 (off-loop gates / T4 correlation),
> then TUNNEL-1 LINK (external, #5).

> **Running todo:** `TODO.md` (queue) — HANDOFF.md is the durable state, TODO.md
> is what's next. Update both at the end of a session so momentum persists.
>
> **UI design system:** `DESIGN.md` (tokens: one accent, 8px grid, Material
> elevation) injected on every page via `scripts/dashboard.mjs` `THEME_CSS`.
>
> **Working process:** `.opencode/skills/jev-harness/SKILL.md` (auto-loaded by
> opencode) — search-first → gate → guard → learn → document. Run
> **`/status`** (`.opencode/command/status.md`) instead of re-pasting the
> issues/implement prompt: it lists outstanding issues, bounds the work
> (A local-now · B needs-host · C larger · D external), implements one doable
> segment, gates, and defers the rest with a reason.

> **PIN 2026-10-17 (fresh session `ses_eb53d9a62f…`):** the **durable loop is
> complete** — pi-durable's missing *consumer*. `next-action.sh` (#78) resumes
> from the store (rev, last-gate, Δ since gate, next queue unit, **in-flight
> segment**, blockers); `loop-state.sh` (#80) checkpoints the in-flight loop
> segment on `durable-run.sh`'s job store (resume/skip across handoffs);
> `progress-review.sh` (#79) + a 15-min user timer records a durable PASS on an
> advance / FAIL on a stall (host runbook `progress-timer`). The jev-harness
> skill step 1 now runs `next-action` first.
> **Docs:** doc-budget is **tier-aware** (#77: budget the session-start set —
> HANDOFF/RULES/TODO + skills; report README/DESIGN/scripts-README on-demand);
> TODO's old Done archived to `docs/todo-archive-2026.md`.
> **Gates sped up** (loop can be frequent): `test-fixture-db.sh` seeds a small
> store for the contract tools; `test-tooling` contracts run in parallel; the
> sentinel self-test no longer digests on `--no-log`; `test-dashboard` no longer
> re-runs lint/test-hygiene under harness (`GATES_RUN_BY_PARENT`) and rebuilds
> the semantic index on the fixture. Full `harness.sh` ~15min → **9.5min, all 4
> gates green** (lint 261 · hygiene 56 · patterns 6 · dashboard 120).
> **Next:** enable `progress-timer` + `sentinel` user timers on the host;
> telemetry-console residual (drill-down on remaining sections); quirks held-out
> recall (40%); the live-DB-bound dashboard checks + lint shellcheck (~130s) are
> the remaining gate cost.
> **NEBULA-1 + tunnel watch (2026-10-17):** closed — the event is a **tunnel
> flap to lighthouse-01 (10.100.0.1)**, not a restart (NRestarts=0, one stable
> PID; the systemd drop-in was applied then reverted). Scripted: read-only
> `nebula-restart-trace.py` (name the parent) + `nebula-systemd-override.sh`
> (`--diagnose` classifies restart-churn vs tunnel-flap, `--handoff` emits the
> peer-repo issue). **Sentinel T8** now trips on the flap itself → ledger →
> `triage-alerts.py` `tunnel_flap` → runbook `tunnel-flap` (proven live).
> That run also fixed two cry-wolves: `triage-alerts.py` de-dupes `slow_fetch`
> **by URI** (130 → 35 distinct), and `session-health.mjs` drops interactive
> **`question`** from S0/S1 (the [HIGH] stall flags were pending prompts). The
> dominant `slow_fetch /provider` is edge-cached 120s in `docker/Caddyfile`.
> **Filed:** TUNNEL-1 → `swipswaps/proxmox-dual-plane-mesh#5` (2026-10-18);
> watch side stays live (T8).

> **PIN 2026-10-18 (segment A: doc budget + quirks precision):** (1) the tier-1
> (session-start) corpus sat at **34,849 / 35,000** (151 tok) — one HANDOFF/TODO
> edit from the WARN. Per RULES #77, moved the older `TODO.md` Done entries →
> `docs/todo-archive-2026.md` (newest-first); recent Done + the queue stay →
> tier-1 **29,926 tok** (headroom **5,074**). (2) `quirks` keyword surgery: the
> loose single-word match regexes were substring bugs (`import` matched
> **"important"** — the one held-out FP; also `black`→"blacklist",
> `loaded`→"downloaded"); word-bounded them. Held-out **FPR 20% → 0%**,
> constructive recall stays 100%, decoy FPR 0. (3) `ensure-env.sh` regen review:
> a standalone `--rotate` now says to restart the stack (a running container
> keeps the OLD password until restarted), and runbook `rotate-password` uses
> the tested scripted path (`--rotate` → `web.sh`) instead of a manual paste.
> (4) RULES #54 fix: `runbooks.json` referenced **untracked** copies under
> `scripts/archive/one-shot/` (absent on a fresh clone) — repointed to the
> canonical tracked `./scripts/` paths, and `test-dashboard.sh` now asserts
> every runbook/tool `./scripts/...` target is **git-tracked** (falsifiable;
> SKIP outside a worktree). Segment A is now fully done. Nothing else changed:
> TUNNEL-1's fix stays external (#5), T8 watch live.

> **PIN 2026-10-18 (script catalog):** the README's "one entry per script" was
> false — 30 tracked top-level `scripts/*.{sh,py,mjs}` were in neither
> `scripts/README.txt` nor `scripts/tools.json`. Added a "Host checks, repo gates
> and local helpers" section (all 30) + 30 `/manage` entries (`tools.json`
> 72 → 102). `test-hygiene.sh` now asserts every tracked top-level script is
> documented (SKIP off-git; falsified live: an uncatalogued script fails it,
> 0 missing passes). Corrected the audit's premise — `chatlog.sh`/`ask.sh` DO
> exist and are executable. Hygiene 60/0.

> **PIN 2026-10-16 (web session `ses_ec5519e33f…`):** shipped — sentinel **T1–T7**
> + deduped ledger; `cdp-tab`/`browser-bench` failover (#62/#64); dashboard
> **local-time + light theme** (#66), **clickable Gantt + span drill + Flags panel
> + estimate Gantt + trends**, `/api/board` **offloaded**, **snapshot→deltas SSE**
> (`/api/stream`) replacing polling; `ux-smoke` + **local-OCR `--vision`** (#65);
> **`notify.sh`** wired to fire on a trip + the unit loads `.env.local`;
> **self-hosted alert sink** (`notify-sink.mjs` + `notify-selfhost.sh`; RULES
> #70 selectable-text/a11y + #71 alert-isn't-actioned-without-severity+runbook+next-command)
> — **LIVE on the host** (the timer pushed a real 20-flag trip into the sink) and
> `triage-alerts.py` turns each flag into severity + the exact next command + runbook;
> **slow-fetch root cause** (#72: a measured `duration` is time-in-system, not handler
> cost — both servers are single-threaded, so one blocker queues everything; T4 now
> excludes SSE, `docker/Caddyfile` edge-caches immutable statics, runbook `slow-fetch`);
> **durable pass** (pi-durable, RULES #73/#74): `triage-alerts.py` reads the durable
> **ledger** not the sink (**124 vs 21** alerts), `durable-run.sh` checkpoints long jobs
> (`caddy-reload.sh`: validate→restart→verify), `rebuild-derived.sh` regenerates all
> derived state from storage, `grafana-up.sh` attaches a read-only ops client;
> **semantic beforeTool guard** (`guard-classify.py`, SubQ, memoized) in
> `blacklist-guard.js`; **durable-pi** mapping (#69) + `search-history.sh` +
> `harden-services.sh`; ops: `web-restart.sh` **down-race fixed**,
> `host-path-probe.sh`, `tui-audit.py`, `panels-tour.py`. All pushed (`ahead=0`).
> **Next (host-only):** run `panels-tour.py` for README shots + `.webm` (needs
> Chrome on `:9222` / `playwright install chromium`); wire the host browser venv;
> stand up **Grafana+SQLite**; cut the **host→Caddy** TLS cost.

## Historical snapshots (2026-09-25/27)

### Screen blindness, guard, exposure (2026-09-27)

*Durable state after the "web UI freezes / black page" work. The causal summary
at the time; the current invariants live in `RULES.md`.*

- **The symptom is client-side, the truth is server-side.** The interactive
  web view (`:4096`) sits on a Server-Sent-Events projection of
  `data/opencode/opencode.db`; it can visibly "freeze" (Shell stuck, blank
  pane) while the store is complete. Upstream confirms the class:
  `anomalyco/opencode#48623` (blank output), `#46419` (the web client does **no**
  client-side image optimization), `#40231`/`#37803`/`#37339` (black screen).
  None is fixable inside this repo; the route-around is to observe the store.
- **So the repo now detects blindness without a browser.**
  `scripts/session-health.mjs` (read-only, no model call) reports two
  low-false-positive signals from the `part` log — a tool stuck `running`
  (`S0`), and a blank tail (last part is a tool, no text after, `S1`). It
  **rejects** the naive long-gap signal (`S2`), because measured here every such
  gap was overnight user-idle (≈100% false positives; a noisy alert is worse
  than none). Served at `/api/health` and `/explore ▸ signals`; `--live` also
  reads `GET /session/status`; `--self-test` runs offline fixtures and is gated
  in `test-hygiene.sh`.
- **The runtime guard is firing.** It was silently inert because interactive
  sessions root at `$HOME/.opencode`, not `/workspace`, so the project plugin
  glob missed it; `web-entrypoint.sh` now links it into the global plugin dir
  and the plugin writes a `loaded` heartbeat + a one-time `hook` marker.
  Verified: `loaded` + `hook` in `data/observability/guard.log`, and a live
  `sed` was blocked. `sed`/`2>/dev/null`/`subprocess.run` no longer pass
  unrecorded during "Thinking".
- **Exposure is contained, not rotated.** `/proc/1/environ` printed
  `JEV_API_KEY` + `OPENCODE_SERVER_PASSWORD` once; `data/opencode/`,
  `data/observability/` and `logs/` are gitignored (never pushed) and `:4096`
  is now **loopback-only**, so the leaked password no longer gates a LAN
  service. The residual path is session **export** — treat exports as
  secret-bearing. Rotation is deferred (see `TODO.md`).
- **Visualisation:** Observable Plot is vendored (one 209 KB UMD file that reads
  the already-present global `d3`) and drives the tool→tool bigram pivot on
  `/explore ▸ patterns`; finos/perspective remains deferred (WASM + CSP cost).
- **Findings now explain themselves (P2) and models are profiled (P4).**
  `scripts/quirks.mjs` maps a finding's symptom to a **vendored**
  `scripts/known-issues.json` (upstream #48623, #46419, #40231, #37803, #37339,
  #51614, #50434, #49608, #51503) with fuzzy, typo-tolerant matching ("blnak" →
  "blank"), fuzzily scans the chat DB + repo code + docs for prior occurrences,
  and computes a **per-model ledger** (tool-error rate + `sed`/`2>/dev/null`/
  `subprocess.run` usage). It lives in `scripts/` (not `data/observability/`,
  which is gitignored) so it is reviewable and committed; `/api/health` carries
  the correlation, per-model tally and the ledger.

**How we got here (causal chain, in one line each).** A wrong assumption
("restarting serves new code; the guard is configured so it runs") met three
measurements (stale-code symptom, no `guard.log`, a `2>/dev/null` that hid its
own error) and one canonical source (opencode docs: project plugin dir is
scanned *relative to the session root*). The fix follows the evidence: observe
the store (not the view), load the guard globally, and fail closed on spend —
which is exactly the `search-first → gate → guard → learn → document` loop in
the `jev-harness` skill.

**Next (best-practice order).** (1) Confirm on the host: `/explore ▸ signals`
renders the panel and `ux-audit.py` is PASS. (2) P2 done; **P4 done** (per-model
ledger). (3) **P3 deferred to D** — the black-page trigger is client-side
(#46419) and the only server hooks run after the SPA has already rendered the
inline image, so a client-side fix (upstream), not a repo transform, is the
honest scope; guidance only. (4) Rotate keys/password only if 4096 is ever
widened to the LAN.

**2026-09-29 backend addendum (serves after host restarts :5099).**
Single-threaded server + multi-second sync aggregation = head-of-line
blocking (rev 4.8–6.1 s during recomputes). Now: SWR + singleflight on all
cached endpoints, validity from landing time, boot pre-warm, poll/cost/
activity/patterns/words cached, S1 query 80 scans → 1 grouped pass
(healthReport 4.9 s → 1.2 s, output identical), signals pane re-renders on
tab activation, failure-only gate forensics, `docs/ux/` proof shots
referenced from README.md. Result: rev during recomputes 0.07 s. Residual:
background refreshes still freeze the loop for seconds (worker-thread cure
is its own segment); TTLs (`HEALTH_TTL_MS`, `POLL_TTL_MS`, …) are the knobs.

### Current state (2026-09-25)

- Audits green; balance healthy (read the live figure from `./scripts/cost.sh`;
  never hard-code it). Everything committed and pushed (`main`).
- `.env.local` (mode 0600) is the **single source of truth** for
  `DEEPSEEK_API_KEY`, `JEV_API_KEY`, `OPENCODE_SERVER_PASSWORD`. Never `export`
  the password into a shell (a stale `$OPENCODE_SERVER_PASSWORD` caused drift).
- Vision: `opencode.json` declares `deepseek-flash` image-capable; local
  fallback `scripts/ocr-image.sh`. (Hygiene layers — see "Hygiene enforcement".)

## Archived 2026-11-08 (moved from HANDOFF.md)

Moved to hold the tier-1 budget after the 2026-11-08 access-plane
hardening (RULE #77); these are 2026-10-18/19 durable-loop PINs.

> **PIN 2026-10-18 (session `ses_eb04bf350f…` → fresh, E2):** closed the E2
> **external-state bridge** — the hand-off loop had no read-back (an issue was a
> manual body-file relay, so an external unit could not close). New
> **`scripts/issue-bridge.py`**: `link` records a filed issue (repo#number) as
> an OPEN external unit; `poll` reads its state — `gh issue view --json` on the
> host (`--gh`) or a host-written JSON via `--in` (the host bridge when `gh` is
> absent) — into the **same ledger** triage/`next-action` read, de-duped by
> `(source,source_key)` so a re-poll is a no-op; `status [--json]` prints the
> latest state. Wired: `nebula-systemd-override.sh --handoff` now prints the
> link+poll read-back step; `next-action.sh` surfaces open external issues (text
> `external:` + JSON `external`); `issue-bridge` self-test in `test-durable.sh`
> (+1 → 8/0); catalogued in `tools.json` + `scripts/README.txt`. **Live:**
> linked `swipswaps/proxmox-dual-plane-mesh#5` → `next-action` prints
> `external: 1 open issue(s) — … #5 [OPEN]`. Gate: lint 266/0 · hygiene 60/0 ·
> patterns 6/0 · durable 8/0 · dashboard 121/0 — all green (RULES #54 resolved
> once `issue-bridge.py` was git-**tracked**).
> Next: **E1** (claims → enforced gates), **E3** (concurrency lock/merge key),
> **E4** (owned task identity); TUNNEL-1's fix stays external (#5, T8 live).

> **PIN 2026-10-18 (session `ses_eb04be01…` → fresh, E1):** closed **E1**.
> `scripts/capabilities.json` declared 15 capabilities but **9 of its own
> `registration` markers had drifted** (`name.sh --self-test` vs the file's
> `"$REPO/scripts/name.sh" --self-test`), so they read **DEGRADED** and no gate
> said so — only the fixture `--self-test` ran, proving the *checker*, not the
> *claims*. Fixed the markers (live registry **15/15 GREEN**) and made the
> **live** registry **fail closed** on any DEGRADED/MISSING not listed in
> `accepted_degraded` (id → reason; `UNACCEPTED:` + nonzero exit);
> `test-hygiene.sh` runs it (+1 → **61/0**); 2 new self-test cases. New **RULE
> #84** — same class as the 30-script catalog: promote each claim to a gate,
> not a sentence. Next: **E3** (lock/merge key), **E4** (owned task identity);
> TUNNEL-1's fix stays external (#5, T8 live).

> **PIN 2026-10-18 (session `ses_eb04be01…` → fresh, E3):** closed **E3
> concurrency lock**. The loop's shared writers have no merge key, so two live
> sessions could both own a segment. New **`scripts/loop-lock.sh`**: a TTL lease
> (1800s, actor-tagged), `flock`-serialised, atomic write; acquire/refresh/
> release/status/check; stale (TTL) + `--force` takeover, never silent.
> `loop-state.sh --begin` requires it (**refuses a busy loop**, rc 3), `--end`
> releases; `next-action.sh` prints `lock:` + a blocker when another live holder
> owns it. Gated: `test-durable.sh` +2 (loop-lock + loop-state) → **10/0**; new
> **RULE #85**. Moved the older `TODO.md` Done half to `docs/todo-archive-2026.md`
> to hold the tier-1 budget (RULE #77).
> Next: **E4** (owned task identity); TUNNEL-1's fix stays external (#5, T8 live).

> **PIN 2026-10-18 (session `ses_eb04be01…` → fresh, E4 — E-gaps complete):**
> closed **E4 owned task identity**. A unit had no stable ID and the DB `todo`
> is session-local, so begin/close/hand-off could not name the same unit across
> sessions. New **`scripts/task-id.py`**: `TASK`/`TASK_STATE` rows on the same
> ledger — `new` mints (or returns, by title) a stable id (`T-<6hex>`, or an
> explicit `--id` like `TUNNEL-1`) + owner; `close --id|--title`; `show`/`list
> [--all]`; idempotent by `source_key`. Wired: `loop-state.sh --begin` registers
> the unit, `--end` closes it; `next-action.sh` prints `tasks:` + JSON `tasks`.
> Gated: `test-durable.sh` +1 → **11/0**; new **RULE #86**. **All four E-gaps
> (E1–E4) closed.** Local queue is thin (E1 regression-eval deps stay
> D-decisions); TUNNEL-1 external (#5, T8 live).

> **PIN 2026-10-18 (session `ses_eb04be01…` → OVER BUDGET, hand off):** closed
> the **auto-handoff action** (RULES #87): the #76 budget STOP no longer just
> advises — `auto-handoff.sh` targets the latest over-budget session, runs the
> brief chain, and prints the paste path, idempotently; `preflight.sh` invokes
> it on the STOP (`JEV_AUTO_HANDOFF=0` disables). `test-durable.sh` +1 → **12/0**.
> **This session then crossed the hard budget (STOP, 3.1× over)** and the new
> action produced its own brief: `logs/brief-ses_eaf110b93ffeOLMmxLklc5zx7P.md`
> — start a FRESH session and paste it; do NOT `--fork/--continue`. Remaining
> local residual: G1 UX drill-down (telemetry (3)); TUNNEL-1 external (#5, T8).

> **PIN 2026-10-19 (G1 drill-down, fresh session):** closed the last local
> telemetry-console residual (3). **Health** findings + budget/deny risks drill
> to session detail (`data-go`); **patterns** bigram bars now carry
> `example_sid` from `apiPatternsFresh` (`MAX(session_id)`) and drill; **pivot**
> cells get a Plot `href` to an example session and the click is intercepted for
> in-page detail; **word-cloud** terms drill into ranked session search. Proven
> structural + contract checks in `test-dashboard.sh` (api `/api/patterns` must
> expose `example_sid`; the three delegated listeners must exist). Gate: lint
> **271/0** · patterns **6/0** · dashboard **123/0**. **The ranked queue is now
> external/host-only** (TUNNEL-1 #5 + T8 watch; G4 needs the proxy; G6/G7 need a
> host) — the next local unit must come from a new audited gap, not this queue.

## Archived 2026-11-11 (moved from HANDOFF.md; newest first)

> **PIN 2026-11-09:** `hotspot-reconnect.sh` + `terminal-reset.sh` (mouse-spam
> reset); self-tests green; live roam proof open (`docs/HANDOFF-2026-11-09-hotspot.md`).
> **PIN 2026-11-08b (paste + roam — RULE #95):** `clipboard-preflight.sh`
> gates the paste path and exits 3 on an image flavour (opencode aborts with
> `ImageDecodeError`); `--clear-text` fixes it. `network-change-probe.sh` is
> the post-roam test (`--watch`; `--peer HOST` = client-side half, LAN vs
> overlay). One-shot client bootstrap: `client-setup.sh` discovers the server,
> calls `ssh-x11-setup.sh` for the trusted one-Host block, and installs a
> self-heal timer (systemd/launchd). All self-tests wired into test-hygiene.
> **PIN 2026-11-08 (access-plane reliability — RULE #94):** the live web plane
> was healthy (`4096=401`, `5099=200` on loopback, Nebula `10.100.0.24`,
> Tailscale `100.119.125.16`, LAN `192.168.4.24`; caddy logs show the macbook
> `10.100.0.1` getting `200`s), so the "not running" claim was reachability,
> not a process fault. The audit found the **2-minute watchdog could self-induce
> a restart loop**: a probe taken during a caddy restart returned `000`, which
> ran `web.sh` and restarted caddy again. `web-health.sh` now absorbs one sample
> (settle), requires a **consecutive-failure threshold** and a **recovery
> cooldown** held in `data/observability/web-health.state`, delegates the action
> to the checkpointed `recover-4096.sh --recover`, and writes the recovery log
> under `logs/` (not `/tmp`). Compose now gates caddy on an `opencode-web`
> `healthcheck` via `depends_on: condition: service_healthy` (Docker: Compose
> waits for *running*, not *ready*). User units dropped the no-op
> `network-online.target` ordering (user managers cannot see system targets,
> systemd/systemd#3312) and the timer uses `OnUnitInactiveSec` (from FINISH, no
> drift). `test-hygiene.sh` now runs both self-tests. Live re-verify: web-health
> rc=0 on all four paths.
> **PIN 2026-11-06 (status automation):** added `issue-benchmark.py`
> (security/stall/tunnel metrics -> `issue_bench` + `benchmark.json`),
> `choice-gate.py` (+ `choices.json`) for the human-only residuals, `pulse.py`
> (one status screen), and `/graph` (editable 3D graph of real repo data with
> `graph_edit` persistence). Map: `docs/STATUS-AUTOMATION.md`. First audit on
> this checkout: running_tools=3, blank_tails=2, over_budget=18; tunnel clean.
> **PIN 2026-11-06 (gate green):** `harness.sh` is **4/0** at `4107b0f`
> (lint 343/0, hygiene 64/0, patterns 6/0, dashboard 136/0); `next-action` is
> clean (`ahead=0`, docs 34,028/35,000). `test-tooling` contracts are bounded
> at 60s, so a hung tool fails by name instead of wedging the gate. The only
> open unit is external TUNNEL-1 (`proxmox-dual-plane-mesh#5` / `T-c39910`).
> Current handoff: [`docs/HANDOFF-2026-11-05.md`](docs/HANDOFF-2026-11-05.md).
> **PIN 2026-11-05 (security/rotation/a11y):** SEC-3 is closed; `security-posture.sh` is **19/0**; DeepSeek, SUBQ, Anthropic, LiteLLM, the server password, and the OpenCode console token were rotated; `verify-rotation-go.sh` is **11/0/1/1** (manual console-token check); `harness.sh` is **4/0** at **2026-11-05T19:48Z** (hygiene 64/0, tier-1 docs 33,997/35,000); the a11y fix is `50c535b` and the docs/permission close is `77782a5` (pushed). The chat DB is read-only and still lists historical pasted secrets; rotate, do not edit it. The only remaining queue unit is external: `proxmox-dual-plane-mesh#5` / `T-c39910` (tunnel flap). Current handoff: [`docs/HANDOFF-2026-11-05.md`](docs/HANDOFF-2026-11-05.md).
> **PIN 2026-10-18 (session `ses_eb04be01…`):** shipped the script **catalog
> completion + coverage gate** (`25a0576`: 30 uncatalogued scripts documented,
> tools.json 72→102, `test-hygiene.sh` fails closed on an undocumented tracked
> script) and **rule #83** (bounded decision menu) + TODO **§E** durable-agent
> gaps (`268f316`). Both pushed. The session then crossed the hard budget
> (1.17× / 233k in) → `preflight.sh` STOP → scripted handoff; **start fresh**.
> Next: TUNNEL-1's fix is external (#5, T8 watch live); local queue otherwise
> exhausted — sections C/E remain. `gh` is absent in-container (E2).
