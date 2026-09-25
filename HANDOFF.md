# Handoff — opencode-deepseek-jev

## What this is
Docker-packaged coding-agent environment: **OpenCode** + **DeepSeek**
(`deepseek-flash`) + **Jev** (`jev-guard` plugin + `jev-review` MCP).
Managed on the host via Dockge (port 5001). Repo: `github.com/swipswaps/opencode-deepseek-jev`.

## Current state (2026-09-25)
- All audits green: `scripts/audit-config.sh` → 18/18 OK; DeepSeek balance ~$4.72.
- Everything is committed and pushed (`main`).
- Added `scripts/test-patterns.sh`: read-only gate proving the tool-sequence
  n-gram substrate (the data layer behind the deferred "patterns view").
  Scoped the three deferred candidates (perspective pivot grid, Plot/Vega-Lite
  charts, patterns view) — see "Next candidates".
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
| `doctor.sh [--full]` | health check; `--full` Tier 9 = Jev functional proof |
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
| `lint.sh` | static gate: `bash -n` + `shellcheck` (baked into image) + `node --check` + RULES grep (no `sed`/`2>/dev/null`) |
| `test-patterns.sh` | read-only proof of the tool-sequence n-gram substrate (tool parts, distinct tools, bigrams, error chains) — data layer for the "patterns view" candidate |
| `ux-audit.py [url] [outdir]` | host-side Playwright UX audit of `/explore` (page height, panel/tab counts, tab toggle, page errors, full-page screenshot); needs `pip install playwright` on host |
| `web.sh [--insecure]` / `web-logs.sh` / `web-stop.sh` | web UI lifecycle |

`scripts/runbooks.json` is the single source for the dashboard `/runbooks`
page and `runbook.sh`; edit it once to change either.

The dashboard also drills down: click a session row for its detail panel
and per-session chat download (txt/md/json); the search box queries titles,
message text, and tool commands across all sessions.
`/explore` (`/viz` now 302-redirects here) is the database-tool layer,
organised into **tabs** (overview · charts · signals · ocr) to avoid a
~6000px wall. **overview**: a ranked search box (`/api/semantic`), a
sortable/filterable sessions table, a **duplicate-grouping** view
(`/api/duplicates`), an integrations panel (Jev vs Laya counts), the A/B
panel (`/api/ab`), and the database map (`/api/schema`). **signals**: error
tool calls, error signatures, rule mentions, patch churn (`/api/signals`).
**ocr**: screenshot text (`/api/ocr`, also folded into `/api/semantic`, CSV
at `/api/export/ocr`). **charts**: cost treemap, brushable burn-down (linked
to treemap/scatter/sankey/Gantt), latency×cost scatter, token-flow Sankey,
part timeline. d3 v7.9.0 + d3-sankey v0.12.3 are vendored at
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
- Hard caps: `docker/docker-compose.litellm.yml` + `docker/litellm.config.yaml`
  (`max_budget`). Jev/TypeSafe has no public balance API; Laya self-host cuts
  that cost.
- **Rules:** no `sed` (#7), no `2>/dev/null` (#8), `printf` not `echo`,
  `main()` wrapper, no `set -e` (pipefail only). See `RULES.md`.
- **Pinned supply chain:** base image digest, opencode `1.18.32`,
  `jev-guard@0.3.1`, jev-review commit `3fb6042e`.

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

Next-session handoff prompt: see `HANDOFF-PROMPT.txt` (paste verbatim into a
fresh session). It is kept out of this file deliberately — an agent-directed
"read this, then do X" block inside HANDOFF.md trips `jev-guard`'s injection
detector on every read (observed p=0.94).


