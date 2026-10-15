---
name: telemetry-dashboard
description: Use when building or reviewing DB-driven telemetry, dashboards, or visualization (this repo's :5099 pages; Grafana / Vega-Lite / Observable Plot; drill-downs; bottleneck, cost, or latency flagging). Guides toward declarative, drill-down-native, low-bespoke stacks and away from hand-rolled SVG and app frameworks like Flutter.
---

# Skill: telemetry-dashboard

## Principle
A telemetry surface exists to answer **"where is time/cost going, what is blocked,
what changed"** for the operator **and** the agent — with evidence you can **click
into**. Bespoke chart code is a liability; declarative, DB-driven,
drill-down-native tools win.

## Tool choices (less bespoke -> more)
1. **Grafana + a SQLite datasource** (`frser-sqlite-datasource`): panels,
   time-series, templating/variables, **annotations** (flags/events), **alerting**,
   and native **drill-down links**. Default for exploration/ops telemetry over the
   existing SQLite stores; run via docker compose on the host.
2. **Vega-Lite** (or the vendored **Observable Plot** at
   `scripts/vendor/plot.umd.min.js`): declarative interactive charts when the
   chart must live inside our own served page.
3. **TanStack Table**: grid sort/filter/virtualize/drill-down instead of a
   hand-rolled `<table>` + DOM.
4. **d3**: only for bespoke composition the above cannot express.
5. **NOT Flutter / SwiftUI / Compose**: this is a served web app in a Node+Caddy
   stack; an app framework adds weight and is *more* bespoke for DB dashboards.

## Rules for a *useful* panel
1. **Every datum drills down** — a Gantt bar / point / row / cell clicks through
   to the session -> turn -> part timeline (the repo's `detail()`), never a dead end.
2. **Flag, don't just plot** — surface bottlenecks (slow endpoints, blocked loop),
   high-cost areas ($ by session/model), and slowdowns (T4 slow fetches, latency)
   as explicit **counts + summaries with examples**, not just a chart.
3. **Annotate events** — put the observability ledger's GATE/ADVISORY rows on the
   time axis so cause and effect are visible.
4. **Provenance on every panel** (`db` / `md` / `derived`) and label heuristics.
5. **No dead controls** — a button either acts or is removed.
6. **Fast by construction** — heavy reads off the event loop (worker), pre-warm,
   and a shell that paints before data.
7. **One source of truth for human and agent** — the number a human sees is the
   number the agent can query from the same DB/JSON.

## Anti-patterns
- Hand-rolled SVG charts with no click-through.
- Panels that block the server (synchronous heavy reads on the event loop).
- Empty sections shown by default (drill-down panels visible before any selection).
- Buried features (a key view living as the 9th tab).
- "loading..." with no progress or error state.

## Checks / tools in this repo
- `scripts/ux-smoke.py` (+ `--vision` local OCR) — served-page UX gate.
- `scripts/browser_bench.py` — driver choice + failover (RULES #64).
- `scripts/cdp-tab.mjs` — drive the live page (RULES #62).
- Prefer asserting on the **DB/API the panel is built from**, not pixels.
