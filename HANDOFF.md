# Handoff — opencode-deepseek-jev

## What this is
Docker-packaged coding-agent environment: **OpenCode** + **DeepSeek**
(`deepseek-flash`) + **Jev** (`jev-guard` plugin + `jev-review` MCP).
Managed on the host via Dockge (port 5001). Repo: `github.com/swipswaps/opencode-deepseek-jev`.

## Current state (2026-09-24)
- All audits green: `scripts/audit-config.sh` → 18/18 OK; DeepSeek balance ~$4.72.
- Everything is committed and pushed (`main`).
- Keys rotated. `.env.local` (mode 0600) is the **single source of truth** for
  `DEEPSEEK_API_KEY`, `JEV_API_KEY`, `OPENCODE_SERVER_PASSWORD`. Never `export`
  the password into a shell (a stale `$OPENCODE_SERVER_PASSWORD` caused drift).

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
| `test-jev-laya-ab.sh` | A/B the same payload through TypeSafe Jev vs self-hosted Laya |
| `cleanup-baks.sh --apply` | remove stale `*.bak.*` snapshots |
| `runbook.sh [--list]` / `runbook.sh run <id>` | host-side menu runner; reads the same `scripts/runbooks.json` the dashboard serves |
| `test-dashboard.sh` | gate for dashboard.mjs (both pages' inline-JS parse + `/api/*` + headless client execution via `test-dashboard-ui.mjs`) |
| `test-dashboard-ui.mjs` | headless DOM execution of the served page script; asserts panes populate (no browser) |
| `cost-bottlenecks.sh [--top N]` | rank cost drivers: $/1k-input, top sessions by cost/context, tiny-session overhead, per model |
| `semantic-search.sh [--rebuild] <q>` | ranked FTS5/bm25 search across sessions; persistent index at `data/search/`; dashboard builds the same index in memory (`/api/semantic`) |
| `web.sh [--insecure]` / `web-logs.sh` / `web-stop.sh` | web UI lifecycle |

`scripts/runbooks.json` is the single source for the dashboard `/runbooks`
page and `runbook.sh`; edit it once to change either.

The dashboard also drills down: click a session row for its detail panel
and per-session chat download (txt/md/json); the search box queries titles,
message text, and tool commands across all sessions.

## Architecture gotchas
- **Host vs container.** `scripts/archive/one-shot/*` call `docker` (host only);
  the agent runs *inside* the container with **no docker**. Use
  `verify-from-inside.sh` for in-container checks.
- **`.env.local` is the only source of truth.** `web.sh` and `doctor.sh` read it;
  the container gets it via compose `env_file`.
- **Ports:** 4096 (opencode web, auth required), 5099 (dashboard, localhost-only),
  5001 (Dockge), 4000 (optional LiteLLM proxy). Firefox blocks 6000–6010 (X11)
  — use 5099/8080/3000.

## Cost model
- `session.cost` (USD) and `tokens_input/output/reasoning` live in
  `data/opencode/opencode.db`. **Input tokens (context) are the cost driver** —
  a session that inlines a large file/context can cost ~$0.78 (e.g. "ip addr
  output": 938k in). `cost.sh` summarizes; `dashboard.sh`/`/viz` charts it.
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
