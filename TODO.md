# TODO — running log

Living backlog so momentum survives a session boundary. **HANDOFF.md** holds
the durable state; **this file holds the queue.** Update the statuses and the
date each session. Legend: `[x]` done · `[~]` in progress · `[ ]` todo.

Last updated: 2026-10-18

## Done (most recent first)

- [x] **E1 claims → enforced gates (capability live gate) — 2026-10-18.**
      `capabilities.json` declared 15 capabilities but **9 of its own
      `registration` markers had drifted** (`name.sh --self-test` vs the file's
      `"$REPO/scripts/name.sh" --self-test`), so they read DEGRADED unseen — only
      the fixture `--self-test` was gated, proving the checker, not the claims.
      Fixed the markers (15/15 GREEN) and made the **live** registry fail closed
      on any DEGRADED/MISSING not named in `accepted_degraded` (id → reason);
      `test-hygiene.sh` runs it (+1). New **RULE #84**. Gate: lint 266/0 ·
      hygiene 61/0 · patterns 6/0.

- [x] **E2 external-state bridge (`scripts/issue-bridge.py`) — 2026-10-18.** `gh`
      is absent in-container, so an issue hand-off (`nebula-systemd-override.sh
      --handoff`) was a manual body-file relay with **no read-back** — the filed
      issue's state never returned to the store, so an external unit
      (TUNNEL-1 → `swipswaps/proxmox-dual-plane-mesh#5`) could not close. New
      `issue-bridge.py`: `link` records a filed issue (repo#number) as an OPEN
      external unit; `poll` reads its state — `gh issue view --json` on the host
      (`--gh`) or a host-written JSON via `--in` (the host bridge when gh is
      absent) — into the **same ledger** triage/next-action read, de-duped by
      `(source,source_key)` (a re-poll is a no-op); `status [--json]` prints the
      latest state. Wired: `--handoff` now prints the link+poll read-back step;
      `next-action.sh` surfaces open external issues (text `external:` + JSON
      `external`); self-test added to `test-durable.sh`. Live: linked `#5` →
      next-action shows `external: 1 open issue(s)`. Gate: lint 266/0 · hygiene
      60/0 · durable 8/0 · patterns 6/0.

- [x] **Script catalog completed + gated — 2026-10-18.** The README's "one
      entry per script" claim was false: 30 tracked top-level `scripts/*.{sh,py,mjs}`
      were in neither `scripts/README.txt` nor `scripts/tools.json`. Added a
      "Host checks, repo gates and local helpers" section (all 30) + 30 `/manage`
      entries (`tools.json` 72 → 102). `test-hygiene.sh` now asserts every tracked
      top-level script is documented (SKIP off-git) — falsified live: an
      uncatalogued script fails it, 0 missing passes. Corrected the audit's
      dead-ref premise: `chatlog.sh`/`ask.sh` DO exist and are executable; only
      `test-tools.sh` is wired into no gate. Gate: hygiene 60/0.

- [x] **Chat-DB audit (PhD pass) — 2026-10-18.** Read-only audit of
      `data/opencode/opencode.db` (99 sessions · 14,750 msgs · 56,499 parts ·
      114 todos; $10.68 lifetime; 97.1% cache hit) + `observability.db` (798
      ledger rows). **Outstanding (pending):** the CURRENT session is **2.5× over
      budget** → `preflight.sh` **STOP** (RULES #76); the one hard action is a
      handoff (`session-guard.sh --handoff`). **Outstanding (stands out):**
      (1) `edit` oldString mismatch **70×** — the #1 recurring failure →
      **RULE #81**; (2) the "free" `muse-spark-*` model accrued **real cost**
      ($1.74 / 26 sessions, one $1.51) → **RULE #82** (gateway-metered, not
      free); (3) 632 ADVISORY/FAIL ledger rows, sentinel-dominated and
      stable-keyed; (4) 24 stale session-local DB todos (not a backlog).
      Addressed: persisted the learning outputs (`issue-solutions.py --write` →
      `/api/solutions`, `learn-rules.py --write`), promoted #81/#82, documented
      the DB-todo caveat in HANDOFF.

- [x] **Host runbooks verified + RULES #54 gate broadened — 2026-10-18.** Audited
      every host (`where=host`) runbook (G4 litellm, G5 laya, G6 doctor --full,
      G7 grafana / adopt-durable-pi / host-*): **all 87** `scripts/*.{sh,py,mjs}`
      targets they name exist and are **tracked** (0 bad). The RULES #54 gate
      matched only the `./scripts/` form — broadened it to also catch
      `bash scripts/…` / `python3 scripts/…` (the old pattern would have missed
      `bash scripts/snapshot-audit.sh`). The remaining G4–G7 steps stay
      host-bound (no docker/systemd in-sandbox). Gate: dashboard 121/0.

- [x] **Embeddings rerank over FTS5 (`scripts/rerank.mjs`) — 2026-10-18.** The
      semantic step over lexical search, with the three standing constraints
      baked in: (1) **offline by default** — a deterministic, dependency-free
      hashing embedder (word unigrams+bigrams, L2-normalised), no model/key;
      (2) **redaction is mandatory** on the external path (every text through
      `redact.mjs` *before* egress — proven: a live-looking `sk-…` becomes
      `[REDACTED]` in the request body); (3) a **hard cap** (`RERANK_MAX_TEXTS`
      per call, `RERANK_MAX_REQUESTS` per process — over cap is a **refusal**,
      not a truncation) *and* an explicit `RERANK_ALLOW=1` gate (an agent never
      auto-spends). `--fts data/search/opencode-index.db` pulls bm25 candidates
      straight from the FTS5 index and reranks; `--docs FILE|-` takes JSONL.
      Wired into test-hygiene. Self-test 14/0.

- [x] **Per-model adaptation (not just the ledger) — 2026-10-18.** `quirks.mjs`
      gains `adaptModel(ledgerRow)`: the measured per-model ledger (tool-error
      rate, blacklist-construct usage) becomes a thresholded verdict
      (`ok`/`watch`/`adapt`) + a concrete recommendation — evidence → action,
      RULES #69 (never a prompt). Attached to every `modelLedger()` row and
      rendered per model in the `/api/health` panel. Self-test +4 → PASS.

- [x] **client-vs-agent stall locus (`session-health.mjs`) — 2026-10-18.** Every
      finding now names the **side** when live data is present: `locus: agent`
      (server reports the session busy → the agent side is active) vs
      `locus: idle` (server idle/absent → the agent side is not progressing; a
      client-side freeze is *invisible* from the store, which is exactly why
      this tool reads the store, not the view). Offline assigns **no** locus
      (never guesses the side). Works off the existing `GET /session/status`
      adjudication — no new network on the default path. Self-test +3 → PASS.

- [x] **RULES #54: runbook/tool script targets must be git-tracked — 2026-10-18.**
      `runbooks.json` told you to run `./scripts/archive/one-shot/rotate-api-keys.sh`
      and `.../verify-password-drift.sh` — **untracked** files (absent on a fresh
      clone); the canonical scripts live at `./scripts/`. Repointed all three
      commands. Added a **falsifiable** guard to `test-dashboard.sh`: every
      `./scripts/...` named in `runbooks.json`/`tools.json` must pass
      `git ls-files --error-unmatch` (a SKIP, never a PASS, outside a git
      worktree). Gate: test-dashboard 121/0, lint 264/0.

- [x] **`ensure-env.sh` password-regen review — 2026-10-18.** Re-verified the
      regen invariants (behavior test now 19/19: no-op / warn / rotate /
      preserve). Two gaps fixed: a standalone `--rotate` now prints *"restart the
      stack to apply it"* (a running container keeps the OLD password until
      restarted), and the `rotate-password` runbook now uses the tested scripted
      path (`./scripts/ensure-env.sh --rotate` → `./scripts/web.sh`) instead of a
      manual paste. Gate: lint 264/0, test-hygiene 58/0, test-dashboard 120/0.

- [x] **`quirks` precision: word-boundary the loose regexes — 2026-10-18.** The
      `matchIssues()` regexes for `#50434` (`import`), `#37339` (`black`) and
      `#51614` (`loaded`) matched **substrings** (`import` ⊂ "important" — the
      single held-out false positive; `black` ⊂ "blacklist"; `loaded` ⊂
      "downloaded"). Anchored them (`\bimport\b`, `\bblack\b`, `\bloaded\b`) with
      no keyword loss. Eval (frozen key `quirks-eval.json`): held-out **FPR
      20% → 0%**, constructive recall **100%**, decoy FPR **0**, real FPR **0**.
      Gate: lint 264/0, test-hygiene 58/0.

- [x] **Tier-1 doc trim (doc-budget headroom) — 2026-10-18.** The read-first
      corpus was at **34,849 / 35,000** (151-tok headroom) — the next
      HANDOFF/TODO edit would trip the WARN. Per RULES #77's method, moved the
      older `TODO.md` Done entries ("Kill the gate double-run" through "Estimate
      Gantt + OCR crop", ~19.5 KB) into `docs/todo-archive-2026.md`
      (newest-first); the recent Done + the queue stay. Tier-1 `doc-budget.sh`:
      **34,849 → 29,926 tokens** (headroom **151 → 5,074**). Gate: lint 264/0,
      test-tooling 17/0, doc-budget/next-action/progress-review self-tests PASS.

- [x] **Three triage follow-ups (2026-10-17 live triage).** (1) The [HIGH]
      `stall` flags were all the interactive **`question`** tool (age ~2h)
      awaiting the OPERATOR — `session-health.mjs` now excludes
      `INTERACTIVE_TOOLS` from S0 + the S1 tool-set (live running_tools 2→0;
      self-test: a running `question` is not flagged). (2) The dominant
      `slow_fetch /provider` (97 grouped rows) is now edge-cached 120s in
      `docker/Caddyfile` (`path /provider*`, query-keyed; runbook third drain).
      (3) TUNNEL-1 hand-off is scripted: `nebula-systemd-override.sh --handoff`
      emits a paste-ready peer-repo issue from the `--diagnose` evidence.
      Gate: lint 264/0, hygiene 58/0.

- [x] **triage de-dup by condition, not text (130-alert cry-wolf).** The live
      T8 run showed **130 distinct from 200 rows**, nearly all `slow_fetch` to
      `GET /provider` differing only in `slowest`. `summarize()` now keys
      `slow_fetch` **by URI** (max slowest) and `tunnel_flap` by resource:
      **130 → 35 distinct**; self-test asserts it (`test-durable`).

- [x] **Sentinel T8 — peer-tunnel flap detector (NEBULA-1 follow-up).** **T8**
      counts teardown/re-handshake/`state:dead` events for the nebula unit since
      the cursor (`>= SENTINEL_TUNNEL_MIN`, default 4; `journalctl --since` +
      `SENTINEL_TUNNEL_LOG` seam, cursor-bounded like T4) → stable-key ADVISORY
      → the existing notify sink + `triage-alerts.py` `tunnel_flap` kind +
      runbook `tunnel-flap`. Reuses the sentinel timer — no new daemon.
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

- **A — local, doable now:** **ALL DONE 2026-10-18** — ~~tier-1 doc trim~~ (TODO
  Done → archive; RULES #77; `scripts/README.txt` is tier-2, not budgeted),
  ~~`quirks` fuzzy precision~~ (word-boundary regexes, held-out FPR 0),
  ~~`ensure-env.sh` password-regen review~~ (restart note + scripted runbook).
  Next local work moves to the C groups (own session).
- **B — needs a host/test this container cannot run:** `doctor.sh --full` Tier 10,
  `ux-audit.py`/`ux-test.py`, `test-sidebar-streaming.sh`, `rotate-api-keys.sh`
  end-to-end.
- **C — larger code (own session):** per-model adaptation (not just the ledger),
  auto-handoff **action**, client-vs-agent stall, Plot migration, G1 UX
  residuals, embeddings rerank.
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
  next-action surfaces open external issues). **E3 concurrency lock/merge
  key:** history is linear with no lock/CRDT — `beads` (Dolt cell-level merge,
  hash IDs) or `backlog` (SQLite, actor-signed writes) supply zero-conflict
  merge. **E4 owned task identity:** DB `todo` is session-local (94 done / 10
  in_progress / 14 pending, all ended) with no ID linking it to `TODO.md` —
  `beads`/`backlog` give a durable, addressed unit that survives every session.

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
