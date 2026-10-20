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

## Durability audit vs the post (2026-10-16)

A re-read of Pi Durable against what we actually built, marked
**have / partial / gap**. North star = the post's own law: *storage is the source
of truth; every delivery, client, and report is a projection that can be
rebuilt.*

| Pi Durable mechanism | Here | Note |
|---|---|---|
| one process owns storage; clients attach | **have** | dashboard + `/api/stream` are the client surface |
| **hello → snapshot → deltas** | **have** | SSE `/api/stream` (snapshot on connect, deltas after) |
| checkpointed tasks; resume after a crash | **partial** | sentinel cursors (`sentinel-*.cursor`) resume; `recover-4096 --recover` and `rotate-server-password` are now checkpointed (`durable-run`, `--resume`). The interactive `rotate-api-keys` (browser console steps) stays manual |
| exactly-once submission (`requestId`) | **have (analog)** | stable per-incident ledger keys (`UNIQUE(source,key)`) — a re-sweep is a no-op |
| external effect observed, not assumed | **have (E2)** | `issue-bridge.py` polls a filed issue's state (host `gh` or a host-written JSON) → the same ledger; the hand-off prints the read-back step; `next-action` surfaces open external issues |
| a declared capability is **enforced, not asserted** | **have (E1)** | `capabilities.mjs` runs the **live** registry as a gate — any DEGRADED/MISSING not named in `accepted_degraded` (id → reason) fails `test-hygiene.sh`, so a claim that silently goes false breaks the build (RULES #84) |
| **one writer** owns the loop; clients attach | **have (E3)** | `loop-lock.sh` is a TTL, actor-tagged single-writer lease (`flock`-serialised, atomic write); `loop-state.sh --begin` refuses a **busy** loop, `next-action` surfaces the holder; a dead holder is reclaimed by TTL, takeover explicit (`--force`) — never a silent concurrent writer (RULES #85) |
| tasks have an **owned, addressed identity** | **have (E4)** | `task-id.py` mints a durable id (id → title + owner) on the ledger (`TASK`/`TASK_STATE`, idempotent by `source_key`); `loop-state --begin` registers the unit and `--end` closes it; `next-action` surfaces open tasks — the id is the address, the title a label (RULES #86) |
| a STOP is **acted on, not just signalled** | **have (#87)** | `auto-handoff.sh` produces the fresh-session brief at the budget trip point (latest over-budget session → redacted brief → paste path), idempotently; `preflight.sh` invokes it, so the over-budget STOP is a routine handoff, not a warning (RULES #76/#87) |
| `reset(note)` + `search_history` | **have** | `handoff-brief.sh` (curate + note) + `search-history.sh` |
| background **compaction** | **partial** | `session-digest.sh` curates a ~1.5 KB digest at trip time; not a model summarizer |
| app state in **durable documents** | **gap (accepted)** | the ledger is a *derived* sidecar, not an atomic commit with the opencode transcript — that store is read-only, so we cannot join the commit. We chose *derived + de-duped* instead of faking atomicity. |
| **malleable** registry (swap tools while running) | **n/a** | we do not own the tool registry; the guard plugin is the one runtime hook |
| multiplayer steering | **partial** | any client attaches to the dashboard; steering stays the TUI's job |
| **read the durable source, not the delivery log** | **have (#73)** | `triage-alerts.py` reads the ledger (`--in` = the sink); proved 124 vs 21 |
| `duration` is time-in-system, not handler cost | **have (#72)** | single-thread M/M/1; T4 excludes SSE |

**Net:** the two mechanisms adopted this pass — **#73 read-the-source** and **#72
time-in-system** — are exactly what the post's *crash-survival* and *long-run*
laws demand. The one real gap (atomic durable documents) is **blocked by design**
(opencode owns and locks the transcript store); we accept a derived, de-duped,
rebuildable sidecar and document it rather than pretend otherwise.
