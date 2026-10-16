# Adopting durable-pi wholesale (device-owned agents) — plan

Status: **NOT installed here.** This is the concrete plan + decision gate for
running disler/durable-pi (pi-durable network) as a separate host service
*alongside* our current stack — not a replacement. Requires Node 24, `just`,
`zsh`, an **OpenRouter** key, and (for remote devices) passwordless `ssh`.

## What you get that we don't have
- **Durable checkpoints** — an agent survives its process dying mid-tool and
  resumes from the last checkpoint (directly answers the ws24 lockup / crash-loop
  class: work is not lost or repeated).
- **Device-owned agents** — the agent lives on the device (`dpi-backend`), every
  UI is a thin client; close the browser/terminal and the run continues.
- **Multiplayer + any client** — web hub, `dpi-tui`, or one `curl` reach the same
  agent; many people steer the same run.
- **Proactive agents** — a cheap classifier over an event stream (their demo
  uses **Jev** per row, ~$0.00003) opens an incident agent before you sit down.
- **Compaction + `reset(note)` + `search_history`** and **fork at any entry**.

## Why this is a *parallel* service, not a migration
pi-durable is its own **harness**. Our sessions/traces live in opencode's store
(`data/opencode/opencode.db`) and are *not* importable into pi-durable — you
would run **new** agents on it, not move the old ones. Keep OpenCode + Caddy +
`:5099` as-is; add durable-pi beside it.

## Steps (ON THE HOST)
```bash
git clone https://github.com/disler/durable-pi && cd durable-pi
cp .env.example .env                            # set OPENROUTER_API_KEY
cp dpi-network.example.yaml dpi-network.yaml    # starts with only `local`
just install                                    # dpi-sdk, dpi-backend, hub, tui
just net up local                               # writes ~/.dpi/backend.env + token
just hub build                                  # build the web UI once
just backend run                                # device server on :4780
just hub start                                  # web UI on http://localhost:4781
just tui attach local                           # or attach from the terminal
# proactive demo (their hook):
just proactive install && just proactive build && just proactive take
```
One-shot from a script/agent:
```bash
curl -s "$URL/v1/sessions/oneshot/agents/main/messages" \
  -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"content":"How many files are here? Use bash.","requestId":"o1","waitMs":120000}'
```

## Decision gate (adopt only if ≥1 is true)
1. You want **proactive** agents (start from an event, ready before you arrive).
2. You want **many clients / multiplayer** on the same agent.
3. You want runs to **survive reboots/process death** without a bespoke resume.

If none apply, the patterns (RULE #69) — already implemented here
(`search-history`, `guard-classify`, `harden-services`, SSE) — are enough.

## Their own "still can fail" caveats (read before adopting)
- **Durable = checkpointed, not exactly-once**; external effects still need their
  own idempotency.
- **A token is a shell** — anyone with a device token runs commands as that user;
  `start_dirs` is not a sandbox.
- **LAN `ssh` devices speak plain HTTP** — tokens cross the LAN in cleartext.
- **The hub holds every token** and binds `127.0.0.1`; binding it to the LAN
  exposes every device.
- **`jev-damage-control` is a guard, not a sandbox**; when Jev is unreachable it
  runs the command (we mirror that fail-open in `guard-classify.py`).
- **Experimental**, pins pi-durable `1.0.3`.
