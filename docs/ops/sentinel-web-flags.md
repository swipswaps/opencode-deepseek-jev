# Sentinel T4 — web-endpoint slow fetches (triage)

Source: the caddy access log, grouped by sentinel T4 into the observability
ledger. Rows measured 2026-10-19/20:

| URI | worst | class |
|---|---|---|
| `GET /session/<id>` | 17.3 s | opencode web: large transcript render (upstream) |
| `GET /provider?enc=1` | 22.3 s | opencode web: provider list (edge-cached 120 s) |
| `GET /api/stream` | 14.0 s | dashboard SSE: connection lifetime, not latency |
| `GET /api/event` | 13.1 s | web event stream: connection lifetime |
| `GET /global/config` | 61.1 s | opencode web: config load (upstream, one-off) |

## Decisions

1. **SSE is excluded, not counted.** `duration` for `/global/event`,
   `/api/stream` and `/api/event` is the connection lifetime (RULE #72
   corollary). Sentinel T4 now skips all three; the self-test proves a 333 s
   `/api/stream` cannot trip it. A healthy open stream is not a stall.
2. **`/session/<id>` and `/global/config` are upstream.** They are served by
   opencode web (:4096), not the dashboard. A large transcript render is
   time-in-system; the container-side fix would be pagination/lazy parts in
   the upstream client, which is a separate decision. Accepted bound: these can
   exceed 10 s on a large session; do not rate-limit or restart for them.
3. **`/provider` is edge-cached 120 s** (`docker/Caddyfile`, query-keyed). A
   cache miss can still be slow; that is bounded and expected. The dashboard's
   own `/api/*` endpoints are off-loop (worker pools) + cached.

## Dashboard rows on the pre-restart process

Rows at 2026-10-20 15:02-15:17 (`/api/cost` 16.9 s, `/api/health` 41.4 s,
`/api/config` 16.2 s) were measured against the live `:5099` process started
**before** the 2026-10-20 fixes. HEAD moves cost/activity/config off-loop,
persists health/signals/board, splits the worker pools, and serves the FTS base
from disk; a `opencode-web` restart applies it. Do not rate-limit or raise a
timeout for these; the fix is the restart (which also ends the current agent
session).

## Inspect

```bash
./scripts/logs.sh --source ledger | grep -i slow
python3 scripts/triage-alerts.py            # severity + next command
bash scripts/host-path-probe.sh             # host -> caddy -> container
```

Do **not** raise a timeout to silence this class; the fix is either an SSE
exclusion (done), an upstream pagination change, or a cache (done for
`/provider`).
