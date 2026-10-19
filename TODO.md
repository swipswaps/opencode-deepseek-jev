# TODO — running log

Living backlog so momentum survives a session boundary. **HANDOFF.md** holds
the durable state; **this file holds the queue.** Update the statuses and the
date each session. Legend: `[x]` done · `[~]` in progress · `[ ]` todo.

Last updated: 2026-10-19

## Done (most recent first)

- [x] **/api/trends off the event loop (sentinel T4 slow-fetch) — 2026-10-19.**
      A host capture burst produced a 10.7 s `GET /api/trends`; the route was a
      sync cold compute. Body moved to `query-lib.apiTrendsFresh` + the query
      worker (`asyncCached`), inline fallback kept; `test-dashboard.sh` asserts
      the body + array shape (#72: duration is time-in-system).

- [x] **UX accessibility gate + durable-agent arming — 2026-10-19.** New
      `a11y-audit.mjs` gates WCAG basics (landmarks, heading order, control
      names, focus-visible, reduced motion, contrast) in `test-dashboard.sh`;
      dashboard fixes: `main tabindex="-1"`, named nav, no `outline:none`,
      Gantt drill rectangles keyboard-activatable + named. New
      `durable-agents.sh` arms/verifies sentinel + notify-sink + progress-review
      in one idempotent command (host enablement pending). Media: `panels-tour`
      now covers overview/signals/patterns; `--check` reports 3 missing shots
      (host browser required). Plans/PR bodies + chat-DB tool audit in
      `docs/plans/`. Gate: lint 274 · hygiene 62 · patterns 6 · dashboard 123.

- [x] **G1 UX drill-down — every session-bearing datum drills (telemetry (3)) —
      2026-10-19.** Closed the named residual. The **health** panel (stall/blank
      findings + budget/deny risks) now opens the session detail (`data-go` +
      delegated listener); **patterns** bigram bars gained `example_sid`
      (`MAX(session_id)` in `apiPatternsFresh`) and drill the same way; the
      **pivot** cells carry a Plot `href` to an example session, intercepted for
      in-page detail; and **word-cloud** terms drill into ranked session search
      (set `#q2` → overview). `test-dashboard.sh` asserts the `example_sid`
      contract + the three delegated listeners (falsifiable). Gate: lint 271/0 ·
      patterns 6/0 · dashboard 123/0.

- [x] **Auto-handoff action (#76, RULES #87) — 2026-10-18.** The budget STOP was
      advice the agent had to remember to act on. New `auto-handoff.sh`: at the
      trip point it targets the **latest** over-budget session (the row
      `preflight.sh` gates on), runs the brief chain (redacted, leak-checked),
      and prints the paste path — **idempotent** (an existing brief is reused;
      `--force` regenerates), no model call, never `--fork/--continue`.
      `preflight.sh` calls it on the budget STOP (`JEV_AUTO_HANDOFF=0`
      disables). Gated: `test-durable.sh` (+1 → 12/0), and the **wiring** itself
      is now locked (preflight must call it, and the switch must gate it) → 13/0.
      New **RULE #87**. Live: this session crossed budget and the auto-handoff
      produced its own brief.

- [x] **E4 owned task identity (`scripts/task-id.py`) — 2026-10-18.** A unit had
      no stable ID and the DB `todo` is session-local, so begin/close/hand-off
      could not name the same unit across sessions. New `task-id.py` records
      `TASK`/`TASK_STATE` rows on the same ledger: `new` mints (or returns, by
      title) a stable id (`T-<6hex>`, or explicit `--id` like `TUNNEL-1`) +
      owner; `close --id|--title`; `show`/`list [--all]`; idempotent by
      `source_key`. Wired: `loop-state.sh --begin` registers the unit, `--end`
      closes it; `next-action.sh` surfaces open tasks (text `tasks:` + JSON
      `tasks`). New **RULE #86**; `test-durable.sh` +1 → 11/0.

- [x] **E3 concurrency lock (`scripts/loop-lock.sh`) — 2026-10-18.** The dev
      loop has several shared writers (`TODO.md`, `HANDOFF.md`, the `dev-loop`
      checkpoint, the ledger) and no merge key, so two **live** sessions could
      both claim a segment and clobber each other. New `loop-lock.sh`: a TTL
      lease (default 1800s), **actor-tagged**, with explicit stale + `--force`
      takeover; acquire/refresh/release/status/check. The critical section is
      `flock`-serialised and the file written atomically, so two sessions can
      never both acquire; a dead holder is reclaimed by **TTL**, never by
      replaying history (durable = crash-safe, not exactly-once). Wired:
      `loop-state.sh --begin` requires the lease and **refuses a busy loop**
      (rc 3), `--end` releases it; `next-action.sh` surfaces the holder (text
      `lock:` + JSON `lock`) and blocks. Gated in `test-durable.sh` (+2 → 10/0).
      New **RULE #85**. Gate: lint 266/0 · hygiene 61/0 · durable 10/0 ·
      patterns 6/0.

## Outstanding issues (audited — resolve or explicitly accept)

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
      (firewall/NAT/MTU) and reload cadence. **Filed:** issue
      `swipswaps/proxmox-dual-plane-mesh#5` (2026-10-18) from
      `bash scripts/nebula-systemd-override.sh --handoff --out F` +
      `gh issue create --repo … --body-file F`. Watch side stays live (T8).
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
