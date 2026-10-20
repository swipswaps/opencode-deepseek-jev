# Handoff archive — 2026

Older `HANDOFF.md` PIN blocks, moved here to hold the tier-1 read-first doc
budget (RULE #77). `HANDOFF.md` keeps the current state; this file is reference
history (tier-2, not budgeted). Newest first among the archived blocks is the
2026-10-18 pair.

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
