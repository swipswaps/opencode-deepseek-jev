# Tool + UX audit from the chat store

Read-only audit of the OpenCode store
(`~/.local/share/opencode/opencode.db`, opened `mode=ro`; 58,991 parts,
106 sessions). "Repo-scoped" means sessions whose `directory` is `/workspace`
or this repo's host paths (33,917 parts). The mesh/ops sessions live in the
same store but are a different repo.

## What the agent actually uses

| tool | calls |
|---|---|
| `bash` | 8,114 |
| `edit` | 3,145 |
| `read` | 1,756 |
| `todowrite` | 674 |
| `write` | 449 |
| `grep` | 125 |
| `webfetch` / `websearch` | 93 / 48 |
| `question` | 76 |
| MCP `repo-tools` | 10 |

The durable loop's own tools (`next-action`, `loop-state`, `auto-handoff`,
`issue-bridge`) are recent and therefore rare in the history; that is expected,
not evidence they are unused.

## Scripts named in chat but absent here

Almost every `scripts/*` with **NO-FILE** belongs to the peer/ops repo
(`proxmox-dual-plane-mesh`) or an older host layout — do **not** add them here:

    mesh*.sh, mesh-*.py, wifi-audit.sh, eero-forward.py, cloudflare-dns.sh,
    duckdns-update.sh, hostinger-*.sh, net-path.sh, roam-test.sh,
    rotate-ssh-ca.sh, nm-50-mesh-recover.sh

The two local-looking names are renames/archives:

- `scripts/check_constraints.sh` -> `scripts/scan-constraints.py` (live)
- `scripts/archive/one-shot/push_notes_v18.sh` (one-shot, not tracked here)

## Suggested-but-deferred UX/a11y work (now partly closed)

Mentions in repo-scoped text: `keyboard` 132, `contrast` 33, `APG` 26,
`a11y` 21, `accessib` 19, `WCAG` 16, `reduced-motion` 7, `axe` 2. A prior
session explicitly split out "Lighthouse/axe/clinic" and deferred
"screen-reader certification, reduced-motion, contrast redesign,
treemap/sankey keyboard inspection".

| Item | Status now |
|---|---|
| Deterministic WCAG basics (names, landmarks, heading order, focus, contrast) | **done** — `scripts/a11y-audit.mjs`, gated by `test-dashboard.sh` |
| Gantt drill rectangles: keyboard + accessible name | **done** — Enter/Space + `aria-label` |
| Reduced motion | **N/A by measurement** — no motion CSS; the audit fails if one is added without a guard |
| Treemap/sankey keyboard inspection | **done** — marks are focusable with `aria-label`; Enter/Space shows the same tooltip; the table twins stay; `test-dashboard.sh` asserts the contract |
| Screen-reader certification / axe / Lighthouse | **host-only** — needs a browser; keep as a periodic host audit, do not add to the container |

## Tools the census says are missing (decision, not a bug)

`tool-census.sh` (offline) reports: Playwright (Python + browsers),
`browser_use`, `selenium`, `ollama`, `strands-decider`, `llama.cpp`, `nimble`.
Decision: the browser stack stays **host-only** (`panels-tour.py`,
`ux-test.py`, `ux-audit.py`); no heavy browser/model runtime is added to the
served container. `nimble` is commercial and not wanted for localhost work.

## Catalog state

- `scripts/tools.json`: 106 -> **108** (`a11y-audit`, `durable-agents`).
- `scripts/` top-level: 151 files; `test-hygiene.sh` enforces that every
  tracked top-level script is documented, so the catalog cannot silently drift.
- `capabilities.mjs`: **15 GREEN / 0 DEGRADED / 0 MISSING** (the E1 gate).

## Recommended order

1. ~~Run `panels-tour.py` on the host and commit the media (PR-02).~~ Done
   2026-10-19: six panels + a 717 KiB tour.
2. Arm the durable agents on the host (`durable-agents.sh --install`, PR-03).
3. Wire README media-existence into `test-hygiene.sh` (cheap, prevents rot).
4. Decide whether to add per-mark keyboard activation for treemap/sankey
   (usability), or accept the table twins as the accessible path.
5. If a browser is available on the host, run axe/Lighthouse as a periodic,
   non-blocking audit; do not make a network browser a container gate.
