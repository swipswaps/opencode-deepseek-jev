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

## Current state (2026-09-25)
- All audits green: `scripts/audit-config.sh` → 18/18 OK. DeepSeek balance is
  healthy (topped up 2026-09-25; run `./scripts/cost.sh` for the live figure —
  do not hard-code it here).
- Everything is committed and pushed (`main`).
- Added `scripts/test-patterns.sh`: read-only gate proving the tool-sequence
  n-gram substrate (the data layer behind the deferred "patterns view").
  Scoped the three deferred candidates (perspective pivot grid, Plot/Vega-Lite
  charts, patterns view) — see "Next candidates". `cost-bottlenecks.sh` now
  reports per-model cost share + a "model mix check" (flags non-`deepseek-flash`
  spend).
- Hygiene is enforced in three layers (files · runtime detection · runtime
  prevention): `.opencode/plugins/blacklist-guard.js` blocks blacklisted bash
  commands at execution time. Restart opencode to load it.
- Keys rotated. `.env.local` (mode 0600) is the **single source of truth** for
  `DEEPSEEK_API_KEY`, `JEV_API_KEY`, `OPENCODE_SERVER_PASSWORD`. Never `export`
  the password into a shell (a stale `$OPENCODE_SERVER_PASSWORD` caused drift).
- Vision: `opencode.json` declares `deepseek-flash` as image-capable
  (`attachment: true` + `modalities.input: ["text","image"]`), so images go
  straight to DeepSeek — no Zen required. Local fallback is
  `scripts/ocr-image.sh` (tesseract CLI in-image, **tesseract.js pinned in
  `package.json`**, or PaddleOCR like receipts-ocr); `web-entrypoint.sh`
  merges (never wipes) `auth.json`.

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
| `verify-password-drift.sh` | 4-gate password consistency check |
| `test-jev-laya-ab.sh` | A/B the same payload through TypeSafe Jev vs self-hosted Laya; persists each run (latency + parsed `correctness`/`safe_to_merge` scores) to `data/observability/observability.db` (served at `/api/ab`) |
| `cleanup-baks.sh --apply` | remove stale `*.bak.*` snapshots |
| `runbook.sh [--list]` / `runbook.sh run <id>` | host-side menu runner; reads the same `scripts/runbooks.json` the dashboard serves |
| `test-dashboard.sh` | gate for dashboard.mjs (both pages' inline-JS parse + `/api/*` + headless client execution via `test-dashboard-ui.mjs`) |
| `test-dashboard-ui.mjs` | headless DOM execution of the served page script; asserts panes populate (no browser) |
| `cost-bottlenecks.sh [--top N]` | rank cost drivers: $/1k-input, top sessions by cost/context, tiny-session overhead, per model |
| `semantic-search.sh [--rebuild] <q>` | ranked FTS5/bm25 search across sessions; persistent index at `data/search/`; dashboard builds the same index in memory (`/api/semantic`) |
| `ocr-image.sh <img> [lang]` / `ocr-tesseractjs.mjs` | local OCR (tesseract CLI / tesseract.js / PaddleOCR); downscales oversized images; persists to `data/observability/ocr_run`, surfaced at `/api/ocr`, searchable via `/api/semantic` |
| `lint.sh` | static gate: `bash -n`, `shellcheck` (parallel), `node --check`, `py_compile`, `scan-constraints.py`, RULES grep; prints `ms=` per check and names the slowest |
| `test-patterns.sh` | read-only proof of the tool-sequence n-gram substrate (tool parts, distinct tools, bigrams, error chains) — data layer for the "patterns view" candidate |
| `audit-tool-calls.py` | audit the agent's **own runtime tool calls** (from the DB) for the blacklist: `sed`, `2>/dev/null`, `subprocess.run`, `rm -rf`, `echo`; prints substitutes; `--fail` to gate |
| `prompt-lint.py` | fuzzy prompt classifier + preference linter: classifies the topic, fuzzy-matches past prompts (Jaccard), surfaces recurring errors, flags blacklist mentions / secrets / vagueness / missing acceptance |
| `issue-solutions.py [--write]` | mine the chat DB for recurring errors and the command that fixed each (next `completed` call); `--write` persists `data/observability/solutions.json` served at `/api/solutions` — free, local |
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
| `web.sh [--insecure]` / `web-logs.sh` / `web-stop.sh` | web UI lifecycle |

`scripts/runbooks.json` is the single source for the dashboard `/runbooks`
page and `runbook.sh`; edit it once to change either.

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
organised into **tabs** (overview · charts · signals · patterns · data · ocr)
to avoid a ~6000px wall. **overview**: a ranked search box (`/api/semantic`)
and a sortable/filterable sessions table — the essentials only. **data**: the
database-tool views — duplicate grouping (`/api/duplicates`), integrations
(Jev vs Laya counts), the A/B panel (`/api/ab`), and the database map
(`/api/schema`). **signals**: error
tool calls, error signatures, rule mentions, patch churn (`/api/signals`) +
the blacklist-guard panel (`/api/guard`). **patterns**: tool-sequence bigrams
and error tools (`/api/patterns`; the view over `test-patterns.sh`'s data)
plus known fixes (`/api/solutions`, from `issue-solutions.py --write`).
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
- **Ports:** 4096 (opencode web, auth required), 5099 (dashboard, localhost-only),
  5001 (Dockge), 4000 (optional LiteLLM proxy). Firefox blocks 6000–6010 (X11)
  — use 5099/8080/3000.
- **5099 lives inside `opencode-web`.** `web-entrypoint.sh` starts
  `dashboard.mjs` on :5099 and then `opencode web`; compose publishes
  `127.0.0.1:5099`. So `./scripts/web-stop.sh` (or any `restart opencode-web`)
  **takes the dashboard down** until the container's entrypoint reruns — it
  comes back in a few seconds. The dashboard is not a separate service. Same
  corollary: **edits to `dashboard.mjs` are served only after that restart** —
  the running process keeps the old code (this is what made the first host
  `ux-test.py` run report stale `/models` 404s and an old `/explore`).
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

The repo is already a database-driven tool layer: `dashboard.mjs` reads SQLite
and serves JSON; the config surfaces are data (`runbooks.json`,
`models.policy.json`, `learned-rules.json`). A visual builder would be an
*authoring surface* over those files, not a new runtime. Options, ranked:

1. **Blockly** (vendored, offline) — generates code from blocks; best fit to
   author the guard rules / runbook commands visually and emit the same JSON.
   No server, matches the vendored-d3 precedent, gateable by `test-dashboard`.
2. **n8n** / **Node-RED** — flow automation with DB + HTTP nodes; good for
   scheduled learning jobs (`harness.sh`, `learn-rules.py`) and alerts. Heavier
   (a Node service), needs a port and auth, so it lives on the host like Dockge.
3. **Retool / Appsmith / Budibase / ToolJet** — internal-tool builders over
   SQL; fast CRUD UIs, but they want DB credentials with write access, which
   violates the read-only rule here (RULES: never write `opencode.db`).
4. **LangFlow / Flowise** — visual LLM chains; redundant with the local-first
   posture (they add a model hop) and not needed for the deterministic layer.

Recommendation: start with **Blockly** for rule/runbook authoring (offline,
vendored, one gate) and **n8n on the host** for scheduled jobs; keep every
builder's output as JSON consumed by `dashboard.mjs` and the guard. The
machine interface stays stable: `{shape, rate, total}` rules, `{id, title,
commands}` runbooks, `{max_input_per_m_usd, allow, deny}` policy.

### Context & cost optimization — tools to add

Local tool-use that shrinks what is sent to the API (the actual lever once the
model is `deepseek-flash`):

- **Exact tokenizer.** `cost.sh --estimate` uses a blended $/token; a real
  DeepSeek tokenizer gives an exact per-message budget before sending.
- **Retrieval, not replay.** `semantic-search.sh` / `/api/semantic` already
  index every part (FTS5/bm25). Select only matching parts into context
  instead of replaying whole history.
- **Prompt-cache hygiene.** Keep a stable prompt prefix — `opencode stats`
  shows 226M cache-read tokens at ~$0.003/1M (≪ input). Reordering the prefix
  destroys the hit rate.
- **Hard caps + routing.** `docker/litellm.config.yaml` (`max_budget`) is
  scaffolded but not wired: `opencode.json` still points at DeepSeek directly.
  Route `opencode` → LiteLLM (`127.0.0.1:4000/v1`) to enforce a hard cap.
- **Bound replayed context.** `opencode --replay-limit N` / `--no-replay`
  cap what a resumed session re-sends. The DB also tracks compaction
  (`session.time_compacting`, `session_context_epoch`; 0 rows = never used).
- **Visualization transparency (local, offline).** Already present: `/explore`
  (d3 v7.9.0 + d3-sankey, DB map, signals, OCR) and `test-patterns.sh`.
  To add: `finos/perspective` (WASM pivot), `Observable Plot` / `Vega-Lite`
  (declarative charts) — vendor under `scripts/vendor/`, gate in
  `test-dashboard.sh`. See "Next candidates".

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

Depth of learning, three tiers:

1. **Which** (memoisation). `harness.sh` records
   `data/observability/last-gate.json`; `preflight.sh` reads it instead of
   re-running the gates. The rule is "don't re-derive what you already proved."
   Generalised: content-address the *inputs* (repo tree hash + gate
   definitions) → store the outcome → reuse when the hash matches → invalidate
   when it changes. That is a **proof cache**, and it is what stops re-spending
   API calls to re-learn an unchanged result.
2. **Which, ranked** (descriptive). `test-patterns.sh` (n-grams) and
   `audit-tool-calls.py` count recurring shapes. They say *what* recurs, not
   *why*.
3. **Why** (causal-ish). `learn-rules.py` builds contrastive triples from the
   log — **(state, action, outcome)** — where state is the error signature that
   just fired, action is the shape of the next call, outcome is whether that
   call completed. Aggregated, a shape that recovers a state is a *prefer*
   rule; a shape that fails is an *avoid* rule. Same-state/different-action
   comparison is what separates "this failed" from "this fails, and *that*
   works instead."

**Deterministic circumvention is not a prompt.** You cannot make an LLM
reliably obey a remembered rule. So the learned rule is pushed into the
*harness*, not the context: `learn-rules.py` writes rules → the guard reads
`learned-rules.json` and records `learned` advisories on avoid shapes →
a human promotes a confirmed pattern into `RULES.md` / the fixed blacklist →
the guard blocks it deterministically. The corpus supplies evidence; the
harness supplies enforcement; the person supplies the decision. Recency
(`--since-days`) keeps a stale pattern (e.g. a rotated key) from being enforced
forever.

Pointed at many chat logs paired with repo code, the same shape works, one
layer down: extract the patch/command that accompanied each outcome, cluster by
the pre-state, and rank. The scope that is *not* built here is the repo-code
half (pairing diffs to outcomes); the tool-action half already runs. A visual
builder (n8n / Blockly-style) would be the authoring surface over these rules.

## Local tool-use options (ranked by efficacy)

Free, local, read-only over the chat DB or the repo. Ranked by value/effort.
Built ones are marked; the rest are the backlog.

1. **Issue → proven fix miner** (built: `issue-solutions.py`). Pairs each
   error tool call with the next `completed` call and ranks the recurring
   pairs. Evidence: `JEV_API_KEY` rejected ×8, permission rejections ×8,
   `oldString` mismatches ×4 — each with the command that resolved it.
2. **Prompt linter / dedupe** (built: `prompt-lint.py`). Stops re-asking and
   flags underspecified prompts before they cost a session.
3. **Recurring-error gate** (built: `audit-tool-calls.py --fail`,
   `/api/signals`). Fail a push if the same error signature recurs.
4. **Tool-sequence n-grams** (data layer built: `test-patterns.sh`;
   the view is "Next candidates" #1).
5. **Topic/trend timeline** (not built). Classify each session with the
   `prompt-lint.py` categories, plot topic share and cost per topic over time.
   Reuse the `/explore` charts.
6. **Solution library** (not built). Persist `issue-solutions.py` output to
   `data/observability/` so a known fix is proposed at the moment of failure.
7. **Fuzzy code search** (partial: FTS5 in `semantic-search.sh`). Add a
   trigram/`difflib` rerank for typo-tolerant lookup across commands and code.
8. **Prompt cache-hit report** (not built). `opencode stats` shows 226M
   cache-read tokens; a per-session hit-rate view would show whether prefix
   churn is burning money.

A new tool's convention: read-only, `--json`, `--self-test`, no model call,
wire its `--self-test` into `test-hygiene.sh`, document it in the command
table and `scripts/README.txt`.

## Remaining work — doable groups (solution ranked by efficacy)

Each group is independently shippable. Within a group the options are ordered
by value/effort; do the top item first.

**G1 — Observability UX (in progress).** Every page now shares one sticky nav
(`/ · /explore · /runbooks · /docs · /api/export`), `/explore` tabs are
linkable and restore from the URL hash, and `/docs` renders HANDOFF/RULES/
README in-UI (whitelisted, read-only). *Fixed:* `#tabs` had no `id`, so
`getElementById('tabs')` threw and aborted `load()` — the page was dead in a
browser. Remaining, in order: (a) make `/runbooks` cards filterable by tag and
surface the `manual` flag as a badge colour, (b) a keyboard shortcut
(`/` focuses search, `g t` jumps to a tab), (c) a landing card grid on `/`.

**G2 — Learning loop.** Built: `issue-solutions.py` (issues → proven fixes).
Next: (a) persist its output to `data/observability/solutions.db` and show a
"known fix" hint on the `/explore` signals pane, (b) a `--fail` recurring-error
gate in `test-dashboard.sh`, (c) fold the issue signatures into
`prompt-lint.py` so a repeat is flagged at prompt time.

**G3 — Visualization candidates.** (a) patterns view (n-gram tab; data layer
already built by `test-patterns.sh`), (b) finos/perspective pivot grid,
(c) Observable Plot / Vega-Lite declarative charts. See "Next candidates".

**G4 — Cost control.** (a) *user action:* pin `deepseek-flash` (v4-pro is
2.9×), (b) wire `docker/litellm.config.yaml` `max_budget` into routing,
(c) a prompt cache-hit report (`opencode stats` shows 226M cache-read tokens).

**G5 — Security / ops.** (a) Laya self-host to cut Jev cost (runbook exists),
(b) embeddings rerank over FTS5 with a redaction pass and a hard request cap,
(c) confirm the Jev key stays valid (the miner's 8 rejections were
pre-rotation; `verify-api-keys.sh` now shows jev-review connected).

**G6 — Test / quality.** Built: strict-id headless UI test (catches the
missing-`id` class). Next: (a) fuzzy code search (FTS5 + trigram/difflib
rerank), (b) run `test-patterns.sh`/`test-hygiene.sh` from `doctor.sh --full`.

## ECC skills (audit — what to borrow)

Reviewed `github.com/affaan-m/ECC` (292 skills, hooks, "instincts",
AgentShield). Most of what ECC offers this repo already has locally; map:

| ECC skill | this repo's equivalent |
| --------- | ---------------------- |
| search-first | read HANDOFF/RULES/TODO before coding (the `jev-harness` skill) |
| cost-aware-llm-pipeline / cost-tracking / token-budget-advisor | `models.policy.json`, `models.sh`, `preflight.sh`, `cost-bottlenecks.sh` |
| context-budget / strategic-compact | HANDOFF "Cost model"; `--replay-limit`, fresh sessions |
| continuous-learning / unified-memory / knowledge-ops | `learn-rules.py`, `issue-solutions.py`, `audit-tool-calls.py` |
| verification-loop / delivery-gate / gateguard | `harness.sh`, `test-*.sh`, `lint.sh` |
| security-review / security-scan / safety-guard / AgentShield | `blacklist-guard.js`, `scan-constraints.py`, `prompt-lint.py` secrets |
| content-hash-cache-pattern | `last-gate.json` proof cache |
| dashboard-builder / design-system / make-interfaces-feel-better | `dashboard.mjs`, `DESIGN.md` |
| docker-patterns / agent-harness-construction / eval-harness | `docker/`, `harness.sh`, `test-dashboard.sh` |
| repo-scan / workspace-surface-audit / codebase-onboarding | `audit-tool-calls.py`, the unused-capability audit |
| hookify-rules / rules-distill | `RULES.md`, the substitution table |

Do **not** stack a full ECC install here (292 skills + hooks would duplicate
the guard). Borrow patterns; install ECC only if a lane genuinely needs a skill
this repo lacks. The repo's own skill is
`.opencode/skills/jev-harness/SKILL.md`.

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

## Next candidates (deferred, not started)

These are the visualisation layer's next batch. Each has a data substrate
that already exists; none is wired yet.

1. **finos/perspective pivot grid** — WASM pivot table as a new `/explore`
   tab. Vendor the esm bundle like d3 (`scripts/vendor/` + `/vendor/*`
   whitelist), feed it `/api/schema` columns + `/api/sessions` rows. Offline,
   no build step. Gate under `test-dashboard.sh` (inline-script parse +
   headless execution, RULES #61).
2. **Observable Plot / Vega-Lite declarative charts** — replace or augment
   the hand-rolled d3 charts (treemap/burn/scatter/sankey/gantt) with
   declarative specs. Still vendored + offline, still served at `/vendor/*`,
   still gated by `test-dashboard.sh` + `test-dashboard-ui.mjs`.
3. **Patterns view (tool-sequence n-grams)** — mine `part` tool sequences
   (see "Session database & tool-use methods") into a `/api/patterns`
   endpoint + a `/explore` tab: recurring tool chains (`bash->read->edit->bash`)
   and error-prone chains (tool parts with `state.status='error'`). The
   read-only extraction is already proven by `scripts/test-patterns.sh`.

Order of attack: 3 → 1 → 2. Patterns (3) is smallest and unblocks the
n-gram substrate for the other two; the pivot grid (1) is the highest
leverage for the sessions table; declarative charts (2) are the largest
refactor and should land last.

Security/ops notes: the LiteLLM runbook validates with
`docker compose ... config --quiet` — plain `config` resolves `env_file`
and prints every `.env.local` value. `docker-compose.litellm.yml` sets
`name: litellm` so the proxy is a separate compose project and never
treats the agent containers as orphans.

## Jev vs Laya (decision to revisit)
- **Jev** = hosted API (TypeSafe), zero-shot strong, leads on >20-option label
  spaces (Banking77 0.870 vs Laya 0.425). No open weights.
- **Laya** = Apache-2.0 open weights (HuggingFace `convaiinnovations/laya`,
  ModernBERT-large 421M / mmBERT-base 322M). Ships `laya-serve`, a
  **Jev-API-compatible** self-hosted server (`POST /v1/systemone`) — a drop-in
  base-URL swap. Weak zero-shot (0.362) but 0.766 fine-tuned; ~$0 self-hosted.
- Net: keep Jev now; consider Laya self-host to cut TypeSafe cost / go on-prem.

Lever table (ranked by dollar impact here):

| lever | cuts | size |
| ----- | ---- | ---- |
| model on policy (`deepseek-flash` or free) | DeepSeek chat | large (v4-pro was ~94% of lifetime at peak) |
| LiteLLM `max_budget` | caps DeepSeek | guardrail, not a cut |
| prompt cache + fewer turns | DeepSeek input | already 226M cache-read |
| Laya-before-Jev cascade | Jev/TypeSafe | small (11 calls) |

### Does Laya / Muse cut the cost? (answered)
- **Laya is not deployed** (it is a runbook: `pip install "laya[serve]"`).
  It only replaces **Jev** (the `jev-review` MCP — 11 invocations total), *not*
  DeepSeek. The DeepSeek chat spend (v4-pro) is a different model and
  provider entirely. So **Laya will not reduce the API cost, and it is
  irrelevant to the UX upgrades** — the pivot/chart/patterns work is local
  JS + read-only SQLite and needs ~no model calls at all.
- **Muse / other "free" models** (OpenCode Zen) are free-tier *vision* models:
  weaker reasoning (poor for multi-step shell/DB work), rate-limited, and the
  repo rule stands — do not paste secret-bearing screenshots to free tiers.
  They are a fallback for image input, **not** a cost fix for the agent's core
  work. The real lever is the one above: run `deepseek-flash`, not `v4-pro`.

Next-session handoff prompt: see `HANDOFF-PROMPT.txt` (paste verbatim into a
fresh session). It is kept out of this file deliberately — an agent-directed
"read this, then do X" block inside HANDOFF.md trips `jev-guard`'s injection
detector on every read (observed p=0.94).


