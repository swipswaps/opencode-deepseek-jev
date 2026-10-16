# pi-durable → this repo: mapping and adopted patterns

Audit of two sources (2026-10-16) and how their **code logic** addresses our
outstanding issues. Sources: Earendil's *Pi Durable* post
(https://earendil.com/posts/pi-durable/) and disler/durable-pi
(https://github.com/disler/durable-pi).

## What they are (one line each)
- **Pi Durable**: a harness = storage + the machinery to run many LLM
  conversations in parallel. Every step of a run is a **task with a checkpoint**;
  the process can die and a new process resumes unfinished tasks. `requestId`
  makes a submission exactly-once. Conversations **fork**; **extensions**
  (sections, tools, hooks, tasks) are pluggable and **malleable** at runtime;
  **compaction** runs as a background task; `reset(note)` starts a new context
  from a handoff note while `search_history` still reaches the old entries;
  application state lives in durable **documents**; clients get
  **hello → snapshot → deltas**.
- **disler/durable-pi**: a playground that puts pi-durable to work as a network
  where **the agent lives on the device, not the client**. A device runs
  `dpi-backend` (owns agents + per-session SQLite + a bearer token); the hub/web
  UI and `dpi-tui` are thin clients. Its hook is a **proactive agent** with a
  **layered decision**: deterministic **code thresholds** → a cheap **classifier
  per row** (Jev, ~$0.00003/row) → the **agent** only for open-ended work. It
  ships a **`jev-damage-control` beforeTool hook** that classifies each `bash`
  command and blocks irreversible ones, storing the verdict as a **durable
  memo** (a restart never asks twice).

## Mapping to our outstanding issues
| Our issue | Their code logic | Adopted here |
|---|---|---|
| over-budget / non-latest spiral (re-sends context) | background **compaction** + `reset(note)` + `search_history` | `session-digest.sh` (curate) + `handoff-brief.sh` (paste) + **`search-history.sh`** (search the old store) |
| client polling stalls the single-thread server | **hello → snapshot → deltas** (reconnect from a fresh snapshot) | planned: SSE on `/api/stream` (snapshot + deltas) |
| crash-looping `deepseek-harness` + host lockup | **checkpointed tasks** + supervision | `harden-services.sh` (Restart/StartLimit/CPUQuota) + the runbook |
| Jev down / irreversible-command risk | **`jev-damage-control` beforeTool guard**, memoized | `guard-classify.py` (SubQ/Jev classifier; block irreversible) |
| LLM cost per event | **layered** code → classifier → agent | SubQ Snap gate (`subq_snap.py`) + sentinel thresholds |
| device-owned agents / multiplayer | `dpi-backend` + hub + tui (one API, thin clients) | adoption plan (`docs/`), not installed here |

## Why we are NOT importing the code wholesale
pi-durable is TypeScript, needs Node 24 + OpenRouter, and disler/durable-pi adds
a device server, hub, and TUI. Our stack is a single OpenCode container + a
read-only SQLite sidecar. We **lift the patterns** (above); adopting the network
is a separate, larger decision (see "Adopt durable-pi wholesale").

## The three durable ideas worth internalizing
1. **Durable = checkpointed, not exactly-once.** A `requestId` is admitted once,
   but an external effect may have happened right before a crash; unsafe tools
   return an *interrupted* result so the agent decides. (Their own caveat.)
2. **Secrets are shells, not sandboxes.** A device token runs commands as that
   user; `start_dirs` is not isolation.
3. **One reducer, two renderers.** Committed state → any client renders the same
   view; that is what makes snapshot→deltas possible (and why our polling is the
   thing to remove).
