# Status automation, benchmarks, and the project graph

This document is the map for the 2026-11-06 observability pass. It answers
three questions in one place:

1. **Where do I see progress/status** without reading the transcript?
2. **How are the "fixed" issues actually measured** (and where are the
   residuals)?
3. **How do the remaining human-only items become a decision** instead of a
   blocked turn?

Everything here is local, read-only against the session store, and free of
model calls. The only writes are the observability snapshots and the ledger.

## 1. One screen: `scripts/pulse.py`

```
./scripts/pulse.py              # headline, scores, attention, next automatic
./scripts/pulse.py --refresh    # re-run the benchmark probes first
./scripts/pulse.py --json       # same document the dashboard serves
./scripts/pulse.py --open       # open /graph
```

`pulse` composes three durable sources instead of replaying a conversation:

| Source | Script | Written artifact |
|--------|--------|------------------|
| queue + gate + docs budget | `scripts/next-action.sh --json` | (none) |
| security/stall/tunnel metrics | `scripts/issue-benchmark.py` | `data/observability/benchmark.json`, `issue_bench` rows |
| pending decisions | `scripts/choice-gate.py` | `data/observability/choices.json` |

Output shape (also `GET /api/pulse`, written to `pulse.json`):

- `headline` — one sentence a person can act on
- `scores` — `security`, `stalls`, `tunnel` (0–100, `null` when no probe ran)
- `attention[]` — every FAIL/WARN metric and every undecided choice
- `next_auto[]` — the commands the loop can run without asking

The dashboard home page renders the same document in the **Project pulse**
card (`/api/pulse`). It polls every 15 s, so the page answers "what is true"
without opening a session.

## 2. Real measurements: `scripts/issue-benchmark.py`

```
./scripts/issue-benchmark.py            # cached evidence, no probes
./scripts/issue-benchmark.py --run      # also runs the bounded probes
./scripts/issue-benchmark.py --json
./scripts/issue-benchmark.py --history 20
./scripts/issue-benchmark.py --self-test
```

Metrics are named and stable; each has `area`, `metric`, `value`, `unit`,
`verdict`, `detail`, and `scored` (some evidence is informational and does not
move the score).

| Area | Metric | Source | Fails when |
|------|--------|--------|-----------|
| security | `posture`, `posture_fail` | `security-posture.sh --offline` (`--run`) | any posture FAIL |
| security | `guard_blocks_7d`, `injection_tripwires_7d` | `data/observability/guard.log` | informational; injection is a WARN |
| stalls | `running_tools` | `session-health.mjs --json` or `health-cache.json` | any tool stuck `running` |
| stalls | `blank_tails`, `findings` | same | WARN |
| stalls | `over_budget_sessions`, `denied_model_sessions` | same (`risks`) | WARN |
| stalls | `live_status` | same (`live`) | SKIP when the server password is absent |
| tunnel | `restarts`, `overlay_loss_pct`, `mtu_ok` | newest `logs/tunnel-link-*.log` | flaps / loss; MTU below 1200 |

**SKIP is not PASS.** A source that cannot be read is recorded in `skips[]`
and the area score is `null`, not 100. This is the difference between "no
evidence of a stall" and "the detector did not run".

History lives in `issue_bench(ts,rev,area,metric,value,unit,verdict,detail)` in
`data/observability/observability.db` and in the `benchmark.json` snapshot
served at `GET /api/benchmark`.

### What the 2026-11-06 audit actually found

The first run on this checkout (rev `56fd53d`) recorded real, not synthetic,
values:

- tunnel: `restarts=0`, `overlay_loss_pct=0`, `mtu_ok=1272` (route MTU 1300) —
  the newest probe saw no churn; the open unit remains external.
- stalls: `running_tools=3`, `blank_tails=2`, `findings=5`,
  `over_budget_sessions=18` — addressing the detector is not the same as a
  quiet store; the snapshot says which session is over budget.
- security: guard `block=20`, `injection=3` over 7 days; `posture` depends on
  the host's `.env.local`/certs, so a sandbox run reports those as missing
  instead of pretending they passed.

Run `--run` on the host before quoting the security score.

## 3. Decisions, not blocked turns: `scripts/choice-gate.py`

```
./scripts/choice-gate.py                 # pending choices + recommended option
./scripts/choice-gate.py --apply browser-tabs=open-tabs
./scripts/choice-gate.py --auto          # safe options only
./scripts/choice-gate.py --json
```

`scripts/choices.json` is the single source. Each choice has:

- `question` and `why` (the evidence that it exists)
- `recommended` (the default, shown first)
- `options[]` with `kind`:
  - `script` + `auto: true` — safe, local, and executable by `--auto`
  - `human` — prints the exact commands; never auto-run
  - `accept` / `defer` — records the decision and its reason

The remaining residuals from the handoff map directly:

| Residual | Choice id | Recommended |
|----------|-----------|-------------|
| revoke old console credential | `console-credential` | `revoke-now` |
| refresh Basic-auth browser tabs | `browser-tabs` | `open-tabs` (auto) |
| historical chat-DB secret rows | `chat-db-residual` | `rescan` (auto) |
| external tunnel link | `tunnel-reprobe` | `watch` |
| model-level injection | `model-injection` | `keep-policy` |

Selections are written to `data/observability/choices.json` and one
`DECISION` row is appended to the ledger, so "we decided to accept it" is
auditable instead of lost in a chat.

## 4. Editable project graph: `/graph`

`GET /api/graph` assembles the graph from live repo sources; there are no
synthetic nodes:

- `scripts/tools.json` + `scripts/runbooks.json` → procedures and the
  scripts their commands invoke
- `data/observability/code.db` → files and flags
- `observability.db` tables + `ledger` event types → stores/telemetry
- `benchmark.json` → metric nodes and verdicts
- `choices.json` → decision nodes and pending state
- `pulse.json` → external issues
- `opencode.db` + `ux.db` → stores (read-only)

The page is a custom 3D force layout on `<canvas>` (no extra dependency; d3 is
already vendored, but the simulation is local). It supports:

- orbit (drag background), zoom (wheel), fit/reheat
- click to select; the side panel shows the real fields
- drag a node to move it; the position is saved on release
- edit label/note, hide a node, add/remove an edge
- `export JSON`, `reset layout`
- search and type legend

Edits are rows in `observability.db.graph_edit` (`pos`, `label`, `note`,
`hidden`, `edge_add`, `edge_del`, `reset`) and are applied when `/api/graph`
builds the payload. `POST /api/graph/edit` validates the action and the node
id shape, caps the body at 64 KiB, and never writes the session store.

## 5. Surfaces at a glance

| What | CLI | HTTP |
|------|-----|------|
| pulse / status | `scripts/pulse.py` | `GET /api/pulse`, home card |
| benchmark history | `scripts/issue-benchmark.py` | `GET /api/benchmark` |
| decisions | `scripts/choice-gate.py` | `GET /api/choices` |
| graph read | — | `GET /api/graph`, page `/graph` |
| graph edit | — | `POST /api/graph/edit` |
| raw evidence | `scripts/logs.sh --source ledger` | `/explore#ops` |
| usability screen | `scripts/usability-suite.py` | `GET /api/usability`, pulse card |
| guided human test | `scripts/usability-guided.py` | `/usability`, `/app/#usability`, `GET/POST /api/usability/guided` |
| closeout gate | `scripts/closeout-gate.py` | (CLI; blocks "done") |

The usability screen's constructs, thresholds, validity threats, and verified
references are in [`docs/USABILITY-TESTING.md`](USABILITY-TESTING.md).

## 6. Verification

```bash
./scripts/issue-benchmark.py --self-test
./scripts/choice-gate.py --self-test
./scripts/pulse.py --self-test
node --check scripts/dashboard.mjs
node scripts/test-dashboard-ui.mjs http://127.0.0.1:5099 graph
./scripts/usability-suite.py --self-test
./scripts/usability-suite.py --static-only
./scripts/usability-install.sh --self-test
./scripts/harness.sh --fast
```

`test-dashboard.sh` now asserts the graph page, `/api/graph`, `/api/pulse`,
`/api/benchmark`, and `/api/choices`, runs the graph inline script headlessly
(canvas stubbed), and includes `/graph` in the page parse and route sweeps.

## 7. Automation cadence

The probes are safe to schedule; they never spend and never write the session
store. A 15-minute refresh keeps the dashboard honest without a chat turn:

```bash
# user timer (no sudo), same pattern as progress-review-install.sh
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/status-pulse.service <<'EOF'
[Unit]
Description=Refresh the project pulse + issue benchmark
[Service]
Type=oneshot
WorkingDirectory=/path/to/repo
ExecStart=/usr/bin/env bash -lc '/path/to/repo/scripts/issue-benchmark.py --run >/dev/null && /path/to/repo/scripts/pulse.py >/dev/null'
EOF
cat > ~/.config/systemd/user/status-pulse.timer <<'EOF'
[Unit]
Description=Refresh the project pulse every 15 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl --user daemon-reload && systemctl --user enable --now status-pulse.timer
```

For a one-shot after a commit, run `./scripts/pulse.py --refresh` instead.
`choice-gate.py --auto` is the only automation that acts on decisions, and it
only runs options marked `auto: true`.

## 8. Adding to the loop

- **A metric**: add a function in `issue-benchmark.py` returning metric dicts;
  include it in `build()`. Keep `scored: false` for informational evidence.
- **A decision**: add an entry to `scripts/choices.json`; no code change. Use
  `auto: true` only for local, reversible commands.
- **A graph source**: read it in `apiGraph()` and add nodes/links with stable
  ids (`type:name`). Never invent a node the repo cannot prove.
- **A page**: add the route to `test-dashboard.sh`'s parse loop and route sweep;
  if the page has an inline script, add a `MODE` to `test-dashboard-ui.mjs`.
