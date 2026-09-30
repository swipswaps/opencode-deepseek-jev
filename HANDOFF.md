# Handoff — opencode-deepseek-jev

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

## What this is
Docker-packaged coding-agent environment: **OpenCode** + **DeepSeek**
(`deepseek-flash`) + **Jev** (`jev-guard` plugin + `jev-review` MCP).
Managed on the host via Dockge (port 5001). Repo: `github.com/swipswaps/opencode-deepseek-jev`.

## Where we are (2026-09-27) — screen blindness, guard, exposure

*Durable state after the "web UI freezes / black page" work. Read this with the
tables below; it is the causal summary, not a task list (that is `TODO.md`).*

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
referenced from README.txt. Result: rev during recomputes 0.07 s. Residual:
background refreshes still freeze the loop for seconds (worker-thread cure
is its own segment); TTLs (`HEALTH_TTL_MS`, `POLL_TTL_MS`, …) are the knobs.

## Current state (2026-09-25) — historical
- Audits green; balance healthy (read the live figure from `./scripts/cost.sh`;
  never hard-code it). Everything committed and pushed (`main`).
- `.env.local` (mode 0600) is the **single source of truth** for
  `DEEPSEEK_API_KEY`, `JEV_API_KEY`, `OPENCODE_SERVER_PASSWORD`. Never `export`
  the password into a shell (a stale `$OPENCODE_SERVER_PASSWORD` caused drift).
- Vision: `opencode.json` declares `deepseek-flash` image-capable; local
  fallback `scripts/ocr-image.sh`. (Hygiene layers — see "Hygiene enforcement".)


## Command surface (scripts/)
| Script | Purpose |
|--------|---------|
| `doctor.sh [--full]` | health check; `--full` Tier 9 = Jev functional proof, Tier 10 = repo gates (hygiene + patterns) |
| `cost.sh [--estimate IN OUT [REAS]]` | DeepSeek cost/balance + Jev invocation count |
| `thinking.sh` | live agent activity (tail -F over the DB) |
| `dashboard.sh` | read-only observability web UI (http://127.0.0.1:5099) |
| `audit-config.sh [--json]` | actual-vs-expected settings audit + remediation hints |
| `test-jev-functional.sh` | behavioral Jev proof (invokes jev_review) |
| `verify-from-inside.sh [--full]` | in-container self-check (no docker) |
| `test-jev-laya-ab.sh` | A/B the same payload through TypeSafe Jev vs self-hosted Laya; persists each run (latency + parsed `correctness`/`safe_to_merge` scores) to `data/observability/observability.db` (served at `/api/ab`) |
| `cleanup-baks.sh --apply` | remove stale `*.bak.*` snapshots |
| `runbook.sh [--list]` / `runbook.sh run <id>` | host-side menu runner; reads the same `scripts/runbooks.json` the dashboard serves |
| `test-dashboard.sh` | gate for dashboard.mjs (both pages' inline-JS parse + `/api/*` + headless client execution via `test-dashboard-ui.mjs`) |
| `test-dashboard-ui.mjs` | headless DOM execution of the served page script; asserts panes populate (no browser) |
| `cost-bottlenecks.sh [--top N]` | rank cost drivers: $/1k-input, top sessions by cost/context, tiny-session overhead, per model |
| `semantic-search.sh [--rebuild] [--fuzzy] <q>` | ranked FTS5/bm25 search across sessions; persistent index at `data/search/`; dashboard builds the same index in memory (`/api/semantic`); `--fuzzy` = typo tolerance |
| `fuzzy-search.py <q>` | tokenize + exact hits + `difflib` near-matches over the on-disk index; `edti` finds `edit`; `--limit N`, `--json`, `--self-test` |
| `ocr-image.sh <img> [lang]` / `ocr-tesseractjs.mjs` | local OCR (tesseract CLI / tesseract.js / PaddleOCR); downscales oversized images; persists to `data/observability/ocr_run`, surfaced at `/api/ocr`, searchable via `/api/semantic` |
| `lint.sh` | static gate: `bash -n`, `shellcheck` (parallel), `node --check`, `py_compile`, `scan-constraints.py`, RULES grep; prints `ms=` per check and names the slowest |
| `test-patterns.sh` | read-only proof of the tool-sequence n-gram substrate (tool parts, distinct tools, bigrams, error chains) — data layer for the "patterns view" candidate |
| `session-health.mjs [db] [--json] [--live] [--self-test]` | read-only, browser-independent detection of **stalled** (tool stuck `running`) and **blank** (last part is a tool, no text after) turns; served at `/api/health` + `/explore ▸ signals`; `--live` adds `GET /session/status`; self-test uses offline fixtures |
| `quirks.mjs [--query TEXT] [--report] [--check-issues] [--self-test]` | correlates a symptom with a vendored `scripts/known-issues.json` map (fuzzy + typo-tolerant), fuzzily searches the DB/code/docs, and exposes a **per-model quirk ledger** (`modelLedger`: tool-error rate + `sed`/`2>/dev/null`/`subprocess.run` usage); `--check-issues` validates the map offline; `/api/health` carries both; no network |
| `redact.mjs [--self-test]` | strips key shapes + `NAME=value` secrets at every egress boundary (`/api/export/session`, the sessions/patterns/guard CSVs); `node scripts/redact.mjs` filters stdin. Defence in depth for a value already in the transcript; self-test gated in `test-hygiene.sh` |
| `audit-tool-calls.py` | audit the agent's **own runtime tool calls** (from the DB) for the blacklist: `sed`, `2>/dev/null`, `subprocess.run`, `rm -rf`, `echo`; prints substitutes; `--fail` to gate |
| `prompt-lint.py` | fuzzy prompt classifier + preference linter: classifies the topic, fuzzy-matches past prompts (Jaccard), surfaces recurring errors, flags blacklist mentions / secrets / vagueness / missing acceptance |
| `issue-solutions.py [--write]` | mine the chat DB for recurring errors and the command that fixed each (next `completed` call); `--write` persists `data/observability/solutions.json` served at `/api/solutions` — free, local |
| `code-index.py [--flags] [--grep RE]` | index + flag the repo's own code into `data/observability/code.db` (symbols, blacklist, TODO/FIXME); served at `/api/code`, `/explore ▸ code` |
| `learn-rules.py [--since-days N] [--write]` | contrastive corpus learning: state (error) → action shape → outcome; emits advisory avoid/prefer/recovery rules to `data/observability/learned-rules.json` |
| `logs.sh` | aggregate telemetry: `guard` (blacklist actions during Thinking), `error` (tool failures + stack traces), `event`, `app`, `system`, `packet` — read-only, local |
| `harness.sh [--fast] [--export] [--json]` | one command for the whole state: every gate + telemetry + cost + TODO in-flight; `--export` writes a report, `--json` emits only `{ts,rev,passed,failed,gates[]}`; `--fast` skips the slow dashboard gate |
| `preflight.sh [--json] [--allow-pro]` | fail-closed spend gate: keys, last gate result, balance, model; exit 1 = do not spend until resolved |
| `models.sh [--write] [--json]` / `models.py` | model catalog + cost policy from `opencode models --verbose`; verdict ALLOW / ASK / BLOCK; surfaced at `/models` |
| `doc-budget.sh [--json] [--fail]` | token size + content-hash of the read-first doc corpus (RULES/HANDOFF/README/TODO/DESIGN/skills); budget `DOC_BUDGET_TOKENS`; unchanged hash = nothing new to re-learn |
| `test-tooling.sh` | contract test for the tooling's `--json` interfaces (preflight/doc-budget/learn-rules/issue-solutions/audit-tool-calls/prompt-lint/models/logs); wired into `test-hygiene.sh`, never calls `harness.sh` |
| `scan-constraints.py` | code-vs-string/comment blacklist scan of shell files; now run by `lint.sh` |
| `.opencode/plugins/blacklist-guard.js` | execution-time guard on the agent's own bash calls: blocks `sed`/`subprocess.run`/`rm -rf`, **removes `2>/dev/null`** so stderr (the proof) flows, warns `echo`; auto-loaded, reload with `docker compose -f docker/docker-compose.yml restart opencode-web` |
| `ux-audit.py [url] [outdir]` | host-side Playwright UX audit of `/explore` (page height, panel/tab counts, tab toggle, page errors, full-page screenshot); needs `pip install playwright` on host |
| `ux-test.py [url] [--check]` | host-side Playwright UX **test** (assertions: console, 390px overflow, tab toggles, compact overview); `--check` reports readiness; SKIP without a browser; runbook `ux-test` |
| `ux-trace.py [url] [--out DIR] [--db DB] [--ocr] [--json] [--self-test]` | host-side Playwright **interaction trace**: injects a recorder so every click/drag/scroll is logged (element + coords + per-step screenshot), enumerates interactive hotspots with bounding boxes + an overlay screenshot, and persists `ux_run`/`ux_event`/`ux_hotspot`/`ux_finding` to `data/observability/ux.db` + `logs/ux/report.md` — the database is the handoff substrate; `--ocr` also reads each shot back to text into `ux_shot` (tesseract, opt-in/slow); `--self-test` is offline and gated in `test-hygiene.sh` |
| `web.sh [--insecure]` / `web-logs.sh` / `web-stop.sh` | web UI lifecycle |

`scripts/runbooks.json` is the single source for the dashboard `/runbooks`
page and `runbook.sh`; `scripts/tools.json` is the single source for the
`/manage` page (`/api/tools`) — the tool catalog with purpose, host/container
and copyable commands. Edit the JSON once to change either.

### Built-in opencode tools (use these before writing new scripts)

| Command | Gives |
|---------|-------|
| `opencode stats --models` | per-model + total cost/token breakdown (cost transparency) |
| `opencode models [provider] --verbose` | per-model pricing (input/output/cache) + context limit |
| `opencode db path` · `opencode db "SQL"` | the DB path · run SQL directly (no custom read layer needed) |
| `opencode session list` / `export <id>` | session management · full session JSON |
| `opencode run -m deepseek/deepseek-flash "…"` | pin the model for one run (cost routing) |

2026-09-25 `opencode stats --models`: v4-pro **$1.69** vs flash **$0.65** vs
`opencode/muse-spark-1.3-contributor-free` **$0.00** (29 msgs / 543.8K in).
`opencode models deepseek --verbose`: v4-pro input **$0.435/1M** vs flash
**$0.15/1M** (2.9×). Cache read is doing real work (226M tokens).

The dashboard also drills down: click a session row for its detail panel
and per-session chat download (txt/md/json); the search box queries titles,
message text, and tool commands across all sessions.
`/explore` (`/viz` now 302-redirects here) is the database-tool layer,
organised into **tabs** (overview · charts · signals · patterns · code · data · ocr)
to avoid a ~6000px wall. **overview**: a ranked search box (`/api/semantic`)
and a sortable/filterable sessions table — the essentials only. **data**: the
database-tool views — duplicate grouping (`/api/duplicates`), integrations
(Jev vs Laya counts), the A/B panel (`/api/ab`), and the database map
(`/api/schema`). **signals**: error
tool calls, error signatures, rule mentions, patch churn (`/api/signals`) +
the blacklist-guard panel (`/api/guard`) and the **session-health** panel
(`/api/health`) that flags stalled/blank turns without a browser. **patterns**: tool-sequence bigrams
and error tools (`/api/patterns`; the view over `test-patterns.sh`'s data)
plus known fixes (`/api/solutions`, from `issue-solutions.py --write`), and a
declarative **tool→tool pivot** (from × to bigram matrix) rendered with
vendored Observable Plot (see "Next candidates").
**ocr**: screenshot text (`/api/ocr`, also folded into `/api/semantic`, CSV
at `/api/export/ocr`). **charts**: cost treemap, brushable burn-down (linked
to treemap/scatter/sankey/Gantt), latency×cost scatter, token-flow Sankey,
part timeline, word cloud. d3 v7.9.0 + d3-sankey v0.12.3 are vendored at
`scripts/vendor/` (served at `/vendor/*.js`, whitelisted).

RULES #61 ("no escape-dependent generated code") was added after two
recurring template-literal escape incidents (`\n`, `\'` collapsing inside
the backtick page templates). Countermeasure: `test-dashboard.sh` now
parses the inline script of EVERY served page and executes the client
headlessly via `test-dashboard-ui.mjs`.

## Architecture gotchas
- **Host vs container.** `scripts/archive/one-shot/*` call `docker` (host only);
  the agent runs *inside* the container with **no docker**. Use
  `verify-from-inside.sh` for in-container checks.
- **`.env.local` is the only source of truth.** `web.sh` and `doctor.sh` read it;
  the container gets it via compose `env_file`.
- **Ports:** 4096 (opencode web, auth required; **loopback-only** since
  2026-09-27), 5099 (dashboard, localhost-only),
  5001 (Dockge), 4000 (optional LiteLLM proxy). Firefox blocks 6000–6010 (X11)
  — use 5099/8080/3000.
- **Exposing 4096 to the LAN (only if you truly need it).** The single gate on
  4096 is `OPENCODE_SERVER_PASSWORD`; binding `0.0.0.0` puts it on the LAN. If
  you widen it, do all three together, never just the port: (1) rotate the
  password first (`./scripts/archive/one-shot/rotate-api-keys.sh` preserves it
  now; the `rotate-password` runbook covers a password-only rotation);
  (2) change only the publish line in `docker/docker-compose.yml` to
  `"4096:4096"` and recreate; (3) add a host firewall rule that allows the
  LAN CIDR and denies the rest, e.g.
  `sudo ufw allow from 192.168.1.0/24 to any port 4096 proto tcp` then
  `sudo ufw deny 4096/tcp`. Revert by restoring `"127.0.0.1:4096:4096"`.
- **5099 lives inside `opencode-web`.** `web-entrypoint.sh` starts
  `dashboard.mjs` on :5099 and then `opencode web`; compose publishes
  `127.0.0.1:5099`. So `./scripts/web-stop.sh` (or any `restart opencode-web`)
  **takes the dashboard down** until the container's entrypoint reruns — it
  comes back in a few seconds. The dashboard is not a separate service. Same
  corollary: **edits to `dashboard.mjs` are served only after that restart** —
  the running process keeps the old code (this is what made the first host
  `ux-test.py` run report stale `/models` 404s and an old `/explore`). The nav
  now shows the **served revision** and turns red (`STALE served … vs HEAD …`)
  when the on-disk HEAD has moved — so staleness is visible, not guessed.
- **Runbooks are data, not code.** `scripts/runbooks.json` is the single
  source for the dashboard `/runbooks` page and `runbook.sh`; add an entry
  there (never hardcode in `dashboard.mjs`) and bump the `count=N` assertion
  in `test-dashboard.sh`.

## Session database & tool-use methods

The agent's entire history — **including every tool call** — is one SQLite
database at `data/opencode/opencode.db` (mounted read-only by the dashboard;
node reads it via `node:sqlite` / `--experimental-sqlite`). This is the
substrate for *database-driven session management*: nothing extra has to be
captured to answer "what did the agent do, in what order, for how much".

| Table | Holds | Key columns (JSON is in `data`) |
|-------|-------|---------------------------------|
| `session` | one row per session | `id`, `parent_id`, `title`, `directory`, `cost`, `tokens_input/output/reasoning/cache_read/write`, `model`, `agent`, `time_created/updated`, `time_compacting/archived` |
| `message` | one row per turn | `id`, `session_id`, `data.role` |
| `part` | one row per message part — the granular event log | `message_id`, `session_id`, `time_created`, `data` |
| `todo` | the live plan | `session_id`, `content`, `status`, `priority`, `position` |

**Tool calls are `part` rows.** A tool part's `data` JSON looks like:

```json
{"type":"tool","tool":"bash","callID":"call_…",
 "state":{"status":"running|completed|error",
          "input":{"command":"…","filePath":"…"}}}
```

So the *ordered tool sequence for a session* is:

```sql
SELECT json_extract(data,'$.tool') FROM part
WHERE session_id=? AND json_extract(data,'$.type')='tool'
ORDER BY time_created;
```

and a corpus-wide **n-gram (bigram) count** over tool sequences is a single
window query (`lead` over `PARTITION BY session_id ORDER BY time_created`).
Observed distribution (988 tool parts / 11 tools): `bash->bash` 273,
`edit->edit` 168, `read->read` 111, `edit->bash` 74, `bash->read` 74 …
`error` status accounts for 22 parts. `scripts/test-patterns.sh` gates this
exactly (read-only, non-zero unless tool parts + distinct tools + >=1 bigram
exist). **This is the data substrate for the "patterns view (tool-sequence
n-grams)" candidate — no new capture needed.**

## Cost model
- `session.cost` (USD) and `tokens_input/output/reasoning` live in
  `data/opencode/opencode.db`. **Input tokens (context) are the cost driver** —
  a session that inlines a large file/context can cost ~$0.78 (e.g. "ip addr
  output": 938k in). `cost.sh` summarizes; `dashboard.sh`/`/viz` charts it.
  **Long sessions re-send the whole history every turn and spike cost —
  start a fresh session (read this HANDOFF) once a session gets large.**
- **Compaction is on.** `opencode.json` sets `compaction: { auto, prune,
  tail_turns: 20 }` (ECC `strategic-compact`) to bound replayed context, and
  `cost-bottlenecks.sh` prints a "context budget (latest session)" check
  (`CONTEXT_BUDGET`, default 200k input tokens) plus a `handoff:` verdict
  line (ok/warn/over + action). The same verdict rides `/api/health` and
  banners on `/explore ▸ signals` (via `handoffAdvice()` in
  `session-health.mjs`). Over budget → fresh session.
- **Model mix is the #1 cost lever — check it before anything else.**
  `deepseek-v4-pro` was ~94% of *lifetime* spend at its peak (3 long
  "audit/handoff" sessions, long since ended); as `deepseek-flash` sessions
  accumulate the live share is ~70% and falling. The figure drifts — read it
  from `cost-bottlenecks.sh` "model mix check" or `opencode stats --models`,
  never from a hard-coded percentage. A non-flash reasoning model re-prices the
  whole context every turn (v4-pro input $0.435/1M vs flash $0.15/1M, 2.9×).
- **Choosing a model is a policy, not a hard-code.** `/models` is a **TUI
  slash command** (a picker, not a chat "send"); the web UI (4096) has its own
  picker; for one run, `opencode run -m <id> "…"`. The ceiling/allow/deny live
  in `models.policy.json` and `models.py` returns ALLOW / ASK / BLOCK; the
  `/models` observer page lists the catalog, the recommended alternative and
  the policy. `preflight.sh` fails closed on ASK/BLOCK.
- **Adding a provider (Gemini).** No native `google` provider in this build
  (`opencode models google` → "Provider not found"), so Gemini is an
  OpenAI-compatible block in `opencode.json` (`gemini`, baseURL
  `https://generativelanguage.googleapis.com/v1beta/openai/`, `{env:GEMINI_API_KEY}`).
  Put the key in `.env.local`, restart, `models.sh --write`. Models are
  allow-listed in `models.policy.json`; runbook `connect-gemini`.
- Hard caps: `docker/docker-compose.litellm.yml` + `docker/litellm.config.yaml`
  (`max_budget`). Jev/TypeSafe has no public balance API; Laya self-host cuts
  that cost.
- **Rules:** no `sed` (#7), no `2>/dev/null` (#8), `printf` not `echo`,
  `main()` wrapper, no `set -e` (pipefail only). See `RULES.md`.
- **Pinned supply chain:** base image digest, opencode `1.18.32`,
  `jev-guard@0.3.1`, jev-review commit `3fb6042e`.

### Avoiding spend while a gate is red (fail closed)

`harness.sh` records `data/observability/last-gate.json`; `preflight.sh`
reads it and refuses (exit 1) unless every critical check passes: keys
present, **last gate run passed**, balance ≥ `MIN_BALANCE` ($1.00 default),
and the model is `deepseek-flash`. Run `preflight.sh` before any paid session
— cheaper than discovering a red gate after spending. Best practice, in
order: gate on a cheap local signal, fail closed, check the cheapest signal
first, never retry blind (capture `logs.sh` output before retrying).

### Laya / Muse and the cost

Single source: "Jev vs Laya" near the end of this file (facts + lever table).
Short version: the Laya cascade cuts **Jev** calls only (11 here, tiny); it
does **not** cut DeepSeek; free Muse-style models are a vision fallback, not a
chat replacement. Keep the model on policy (pin `deepseek-flash` or a free
model) and wire the LiteLLM cap before investing in Laya.

### Model choice is a policy, not a hard-code

The catalog (`opencode models --verbose`, 2026-09-25) has **7 free Zen models**
(several tool-capable; `mimo-v2.6-flash-free`, `space-bunny-free`,
`muse-spark-1.3-contributor-free` are image-capable) plus `deepseek-flash`
($0.15) and `deepseek-v4-pro` ($0.435). `models.policy.json` sets the ceiling,
allow-list and deny-list; `models.py` returns **ALLOW / ASK / BLOCK**; `preflight`
fails closed on ASK/BLOCK. The UI `/models` page shows the catalog, the current
model, the recommended alternative and the policy — the interactive chooser.
So a non-flash model is not a blind STOP: it is an alert with options.

## Drag-and-drop, database-driven tooling (options)

A visual builder here would be an *authoring surface* over the existing JSON
config (`runbooks.json`, `models.policy.json`, `learned-rules.json`), not a new
runtime. Recommendation: **Blockly** (vendored, offline) for rule/runbook
authoring and **n8n on the host** for scheduled jobs; keep every builder's
output as the same JSON the guard and dashboard read. Rejected: Retool/Appsmith
(want write DB creds, violating read-only), LangFlow/Flowise (extra model hop).
Full ranked list + interfaces: `TODO.md` G7.

### Context & cost optimization — tools to add

- **Exact tokenizer** (`cost.sh --estimate` uses a blended rate).
- **Retrieval, not replay** (`semantic-search.sh` / `/api/semantic`, FTS5/bm25).
- **Prompt-cache hygiene** (stable prefix; 226M cache-read at ≪ input).
- **Hard caps + routing** (`docker/litellm.config.yaml` `max_budget`, not wired).
- **Bound replayed context** (`--replay-limit`, compaction).
- **Visualization transparency** — see "Next candidates".

## Hygiene enforcement (three layers)

The rule set is enforced at three points — the gap was *detection only*:

1. **Files** — `lint.sh` → `bash -n`, shellcheck, `node --check`,
   `py_compile`, a `subprocess.run` grep, and `scan-constraints.py`
   (code/string/comment classifier) over `scripts/*.sh`. Fails the build.
2. **Runtime detection** — `scripts/audit-tool-calls.py` reads the DB and
   reports the agent's **own** tool calls against the blacklist
   (`sed` ×22, `2>/dev/null` ×141, `echo` ×289 as of 2026-09-25) with the
   substitute per pattern; `--fail` to gate. `scripts/prompt-lint.py`
   fuzzy-matches user prompts and flags recurring errors.
3. **Runtime prevention** — `.opencode/plugins/blacklist-guard.js`
   (auto-loaded from `.opencode/plugins/`; **no `opencode.json` entry**, adding
   one would double-load). It hooks `tool.execute.before` and acts on the
   agent's own bash commands *before they execute*. Quote-aware: `grep 'sed'`
   passes; `sed -n …` is acted on. Three verdicts, because the failure modes
   differ:

   | verdict | patterns | action |
   | ------- | -------- | ------ |
   | **block** | `sed`, `rm -rf`, `subprocess.run` | throw; return the substitute so the model retries correctly |
   | **fix** | `2>/dev/null` | **remove the redirect** so stderr — the proof of what went wrong — reaches the tool result |
   | **warn** | `echo` | log only |

   The `fix` verdict is the point: these constructs fail opaquely and the
   suppressed stderr is the evidence needed to fix them. Blocking `2>/dev/null`
   would just make the agent skip the step; *removing* it keeps the proof.

Policy / operation:

| `OPENCODE_BLACKLIST_GUARD` | Behaviour |
| -------------------------- | --------- |
| unset / `block` | block destructive, fix `2>/dev/null`, warn `echo` |
| `warn` | log every match; never block or rewrite |
| `off` | disabled |

**Reloading** (config is read once at startup, not hot-reloaded) — restart
just the web service, not the whole stack:

    docker compose -f docker/docker-compose.yml restart opencode-web
    # or: ./scripts/web-stop.sh && ./scripts/web.sh
    # or: Dockge UI (http://localhost:5001) -> restart the opencode stack

`opencode-web` runs `opencode web` with `working_dir: /workspace`, so the
repo's `.opencode/plugins/` is found automatically. The plugin is ESM;
`.opencode/package.json` (`"type": "module"`) makes that explicit, and
opencode auto-pins `@opencode-ai/plugin` into it on startup. opencode also
generates `.opencode/.gitignore` (node_modules, package-lock, bun.lock) —
those stay uncommitted. Kill switch if the guard misbehaves:
`OPENCODE_BLACKLIST_GUARD=off` (via `.env.local`/compose env) then restart. The
matcher and the `2>/dev/null` rewriter are unit-tested by
`scripts/blacklist-guard-self-test.mjs` (in `test-hygiene.sh`).

**Proving the guard is actually loaded (do not trust "it's configured").** An
interactive session's project `directory` is not always `/workspace`: the web
UI boots sessions at `$HOME/.opencode` (`booting location services
directory=/home/node/.opencode`), so the project-scoped
`{plugin,plugins}/*.{ts,js}` glob under `/workspace/.opencode/` is **never
scanned** for those sessions — the guard silently never loads, `sed` /
`2>/dev/null` / `subprocess.run` pass through, and there is no telemetry. The
fix is in `docker/web-entrypoint.sh`: it symlinks the guard into the **global**
plugin dir (`$XDG_CONFIG_HOME/opencode/plugins/blacklist-guard.js`), which
opencode scans for every project (verified: a fresh `opencode run` from
`/home/node/.opencode` writes the heartbeat only after the symlink exists).

The plugin (1) anchors its log to `<repo>/data/observability/guard.log` via
`import.meta.url` (not the session directory), and (2) writes a
`{"verdict":"loaded"}` **heartbeat** at registration plus a one-time
`{"verdict":"hook"}` on the first `bash` call. After a restart:

    grep -h '"verdict":"loaded"' data/observability/guard.log
    grep -h '"verdict":"hook"'   data/observability/guard.log   # after any bash tool call

No `loaded` line ⇒ not loaded (check the symlink: `readlink -f
~/.config/opencode/plugins/blacklist-guard.js`), then restart. `loaded` but no
`hook` ⇒ the hook is not wired (opencode version mismatch). This is the
falsifiable check that was missing — on 2026-09-27 neither line existed and
`2>/dev/null` was flowing unmodified.

**Session root gotcha.** Interactive (web/TUI) sessions can have
`session.directory = /home/node/.opencode` (HOME) while `opencode run` from the
container is rooted at `/workspace`. Project-scoped config/plugins therefore
differ between them; anything that must apply everywhere (the guard) belongs in
the global config dir or the global plugin dir, not only `.opencode/`.



### Writing the next prompt (rigorous template)

A prompt is an interface contract. State the falsifiable outcome, the
constraints, and the evidence — then the work is checkable without re-reading
the whole chat (which is also what keeps context cost down).

```text
## Objective
<one sentence: the falsifiable outcome>

## Context (read first)
HANDOFF.md, RULES.md, README.txt; <specific files / endpoints>

## Constraints (non-negotiable)
RULES.md; the blacklist is enforced by .opencode/plugins/blacklist-guard.js;
read-only over data/opencode/opencode.db; no new runtime deps unless vendored.

## Deliverable
<exact artifacts: files, endpoints, docs>

## Acceptance criteria (each independently checkable)
- [ ] `<command>` prints `<expected>`
- [ ] `./scripts/<gate>.sh` exits 0

## Evidence (paste back)
gate outputs, `git diff --stat`, the exact commands run.

## Out of scope
<what not to touch>
```

## Corpus learning — why, not just which

Three depths: **(1) which** (memoise) — `last-gate.json` proof cache, so an
unchanged result is never re-derived; **(2) which, ranked** (descriptive) —
`test-patterns.sh` n-grams + `audit-tool-calls.py` say *what* recurs;
**(3) why** (causal-ish) — `learn-rules.py` builds contrastive
**(state, action, outcome)** triples; a shape that recovers a state is a
*prefer* rule, one that fails is an *avoid* rule.

**Deterministic circumvention is not a prompt.** A learned rule is pushed into
the *harness*, not the context: `learn-rules.py --write` → the guard reads
`learned-rules.json` and records `learned` advisories → a human promotes a
confirmed pattern into `RULES.md` / the blacklist → the guard blocks it. The
corpus supplies evidence, the harness enforces, the person decides. `--since-days`
expires stale patterns.

## Local tool-use options

Built (all read-only, local, no model call): `issue-solutions.py` (error →
proven fix), `prompt-lint.py` (dedupe/vagueness), `audit-tool-calls.py --fail`
(recurring-error gate), `test-patterns.sh` (n-grams), `issue-solutions.py --write`
+ `/api/solutions` (solution library), `fuzzy-search.py` +
`semantic-search.sh --fuzzy`, `cost-bottlenecks.sh` (cache-hit report). Backlog:
a topic/trend timeline (classify sessions, plot topic share/cost over time).
Convention for a new tool: read-only, `--json`, `--self-test`, no model call,
self-test wired into `test-hygiene.sh`, documented in the command table and
`scripts/README.txt`.

## Remaining work — doable groups

The live queue (with dispositions and segment letters A–D) is **`TODO.md`** —
read it there, do not duplicate it here. Standing groups: **G1** observability
UX (nav/tabs/`/docs`/`ux-trace` built; remaining: runbook tag filter, keyboard
shortcuts, landing grid), **G2** learning loop (solutions + recurring-error gate
built), **G3** visualization (patterns done, Plot pivot done, perspective
deferred), **G4** cost control (pin model; wire LiteLLM `max_budget`), **G5**
security/ops (Laya, embeddings rerank), **G6** test/quality.

## External audit triage (2026-09-26)

A second-opinion audit was run against the README (it never reached the code —
every raw/API read failed), so treat it as low-confidence. Triage:

- **Real, fixed:** the blacklist guard was bypassable via interpreter wrappers
  (`bash -c 'sed -i x'`, `sh -lc "rm -rf …"`, `python3 -c "subprocess.run(…)"`,
  `eval '2>/dev/null …'`) because quote-stripping hid the inner script.
  `blacklist-guard.js` now extracts and re-inspects wrapped scripts (unquoted
  wrappers only, so `echo "bash -c '…'"` is not a false positive). Also added
  a **CSP + `X-Content-Type-Options: nosniff`** header to every dashboard page.
- **Already handled:** unauthenticated server (`web.sh` refuses without
  `OPENCODE_SERVER_PASSWORD`); secrets (`\.env.local` 0600, gitignored, never
  printed); indirect prompt injection (`jev-guard` plugin); Docker UID
  (README troubleshooting); `2>/dev/null` removal (deliberate, documented);
  duplicate sessions (read-only — we never write the DB).
- **Rejected / hallucinated:** an invented CVE, a non-existent
  `scripts/staging.sh`, and "no dark mode" (the UI is dark by default).

## ECC skills (audit — what to borrow)

The confirmed applicable subset (per-skill INC / REF / N/A + the repo
equivalent) is **`ECC-SKILLS.md`** — read it there. Do **not** stack a full ECC
install (292 skills + hooks would duplicate `blacklist-guard.js`); borrow
patterns. The repo's own skill is `.opencode/skills/jev-harness/SKILL.md`.

## Triage status
S1 auth ✅ · S2 rotate+cleanup ✅ · S3 pin ✅ · B1 Jev proof ✅ · B2 sidebar test ✅ ·
B6 cleanup ✅ · C1 thinking ✅ · U1 dashboard ✅ · U2 verify-from-inside ✅.

Open next steps (not done): embeddings-based semantic rerank over the
FTS5 candidate set (Jev hosted or Laya self-hosted) with a mandatory
redaction pass (`sk-`, `apikey_`, `OPENCODE_SERVER_PASSWORD`) and a hard
request cap before any external call — local FTS5/bm25 ships now
(`/api/semantic`, `semantic-search.sh`); wire LiteLLM budgets into agent
routing (proxy runs, opencode.json still points at DeepSeek directly);
verify the LiteLLM model id (`deepseek/deepseek-chat`) against the live
API and opencode.json (`deepseek-flash`); optional Langfuse/Phoenix
tracing.

## Next candidates (status)

These are the visualisation layer's batch. Each has a data substrate that
already exists.

1. **Patterns view (tool-sequence n-grams)** — **done.** `/api/patterns`
   (bigrams + error tools) + `/explore ▸ patterns`; read-only extraction
   proven by `scripts/test-patterns.sh`. `apiPatterns` now also returns
   `from`/`to` per row (not just the joined `gram`) for the pivot below.
2. **Observable Plot declarative charts** — **started.** Plot v0.6.17 UMD is
   vendored at `scripts/vendor/plot.umd.min.js` (209 KB, one file, reads the
   **global `d3`** — load order d3 → d3-sankey → Plot; no WASM, no CSP
   change, no build step). The first spec is the **tool→tool bigram pivot**
   (`Plot.cell` + band x/y + quantile `greens`) in `/explore ▸ patterns`
   (`renderPivot`). **Scatter migrated second** (`Plot.dot` + log scales +
   sqrt radius + model colors; click-drill, tooltip strings, brush-filter
   re-render and empty text preserved bit-for-bit; one delegated
   container listener per RULES #61). **Gantt third, timeline fourth**
   (`Plot.barX` / `Plot.rect` lane strip; COST/type colors, 7px rows,
   click-to-timeline, tips, empty states preserved; delegation maps
   rebuilt per render with count guards). Measured verdicts for the rest:
   **treemap / sankey / word-cloud stay hand-rolled** — Plot v0.6 has no
   treemap, sankey, or cloud marks (d3.hierarchy / d3-sankey / custom
   spiral have no declarative equivalent). Remaining order: gantt +
   timeline (`Plot.barX` fits) then burn last (brush-linked to four
   views — highest regression surface).
3. **finos/perspective pivot grid** — **deferred, low fit.** The full viewer
   stack is ~28 MB unpacked plus WASM, needs `'wasm-unsafe-eval'` added to
   the dashboard CSP, and cannot be exercised by the in-container headless
   gate (no `WebAssembly`, no layout, no canvas). Ship it only if a host-only
   page (like Dockge) accepts the cost; the pivot *value* is already covered
   by the Plot matrix without the payload.

Order of attack settlement: 3 → 2 (pivot via Plot) → 1 last. The Plot UMD
is one vendored file and reuses the already-present d3, so it lands the
"declarative charts" lane and the pivot's useful part together; Perspective
is the largest and least verifiable, so it goes last (if at all).

Security/ops notes: the LiteLLM runbook validates with
`docker compose ... config --quiet` — plain `config` resolves `env_file`
and prints every `.env.local` value. `docker-compose.litellm.yml` sets
`name: litellm` so the proxy is a separate compose project and never
treats the agent containers as orphans.

## Jev vs Laya (decision)
- **Jev** = hosted TypeSafe API; strong zero-shot (Banking77 0.870) — keep for now.
- **Laya** = Apache-2.0 open weights, ships a Jev-API-compatible `laya-serve`
  (`POST /v1/systemone`) — a drop-in base-URL swap; weak zero-shot (0.362),
  0.766 fine-tuned, ~$0 self-hosted.
- **It does not cut DeepSeek chat cost** (Jev is a different provider, ~11
  calls). The real lever is running `deepseek-flash`, not `v4-pro`. Zen "free"
  models are vision fallbacks, not a chat-cost fix — and never paste
  secret-bearing screenshots to a free tier.

| lever | cuts | size |
| ----- | ---- | ---- |
| model on policy (`deepseek-flash`/free) | DeepSeek chat | large |
| LiteLLM `max_budget` | caps DeepSeek | guardrail, not a cut |
| prompt cache + fewer turns | DeepSeek input | already 226M cache-read |
| Laya-before-Jev cascade | Jev/TypeSafe | small (11 calls) |

Next-session prompt: `HANDOFF-PROMPT.txt` (kept out of this file — an
agent-directed "read this, then do X" block here trips `jev-guard`'s injection
detector, p≈0.94).


