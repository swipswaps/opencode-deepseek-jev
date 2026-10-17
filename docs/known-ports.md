# Known host ports

Recorded so a conflict is **identified, not rediscovered** (RULES #75). When a
`compose up` fails with *"address already in use"*, look here first, then
`./scripts/free-port.sh --owner PORT` (add `sudo` to name another user's process).

| port | who | notes |
|------|-----|-------|
| **3000** | **`websocket-broker` — a foreign Node daemon** (`node /usr/local/bin/websocket_broker_secure.js`, `websocket-broker.service`) | **Not ours** — it lives in another project: `/home/owner/Documents/6a071452-…/observability-platform/systemd/websocket-broker.service`. Verified 2026-10-17: `sudo ss -ltnp 'sport = :3000'` → `users:(("node",pid=2402))`. Owns 3000 permanently, so Grafana's default collides and `grafana-up.sh` auto-picks a free port. |
| **3001** | Grafana (`opencode-grafana`) | `127.0.0.1:3001 -> 3000`; set `GF_PORT` to force another. Up: `./scripts/grafana-up.sh`. |
| 4000 | LiteLLM proxy (opt-in) | `docker/docker-compose.litellm.yml`; not started by default. |
| 4096 | opencode-web (TUI / JSON API) | TLS via Caddy; `401` unauthenticated by design. |
| 5099 | observability dashboard | TLS via Caddy; `web-restart.sh` keeps it at HEAD. |
| 8788 | notify-sink (self-hosted webhook) | loopback only; `NOTIFY_WEBHOOK` points here. |
| 9222 / 9223 | Chrome DevTools (CDP) | host-side browser control (`cdp-tab.mjs`). |

## Rule
Any script that binds or publishes a port must **discover** it with
`scripts/free-port.sh`, never hardcode it (RULES #75). If a port is foreign and
permanent, add it to this table.
