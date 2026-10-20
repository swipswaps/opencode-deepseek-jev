# PR: one command to arm the durable agents (pi-durable automation)

Status: **implemented in this tree; host enablement pending.**

## Why

The durable loop already has five always-on agents, each with its own tested
installer:

| Agent | Cadence | Job |
|---|---|---|
| `sentinel` | 5 min | trip only on news (budget, deny, gateway failure) |
| `notify-sink` | service | receive + persist pushed alerts |
| `progress-review` | 15 min | PASS on advance / FAIL on a stalled loop |
| `fts-refresh` | 15 min | atomic FTS base refresh (fast semantic search) |
| `proactive` | 15 min | NEW alerts -> owned tasks + a digest |

Arming them one at a time is easy to half-do, and a half-armed loop looks
healthy. The container has no systemd, so the host step is the missing
automation, not the code.

## Changes

- `scripts/durable-agents.sh` (new): `--install` runs the five tested
  installers in order; `--status` prints unit-present + enabled + active and
  prints **SKIP** (not pass) when `systemctl` is absent; `--dry-run` lists the
  commands; `--self-test` checks the nine unit templates and the five
  installers offline.
- `scripts/README.txt` + `scripts/tools.json`: catalog the command.
- (Proposed) a `dev-loop` service that runs `next-action.sh` + `harness.sh
  --fast` on a timer is **not** included: the loop is one-writer
  (`loop-lock.sh`) and agent-initiated runs need an explicit scope decision.
  `progress-review` already proves the timer/supervision pattern.

## Host run

    ./scripts/durable-agents.sh --status     # SKIP in the container
    ./scripts/durable-agents.sh --install    # arm/refresh on the host
    ./scripts/durable-agents.sh --status     # enabled=yes/active=active
    ./scripts/logs.sh --source ledger        # PASS/FAIL + trip evidence

## Acceptance

- `durable-agents.sh --self-test` PASS.
- On the host: all five units `enabled=yes`, `active=active` (timers: `active
  (waiting)`), and the ledger gains sweep rows.
- `harness.sh` 4/0.

## Risks

- The installers are user-level (no sudo) and idempotent.
- Do not run a second writer: keep the loop lock; the agents only observe and
  record.

## Rollback

`./scripts/sentinel-install.sh --uninstall`,
`./scripts/progress-review-install.sh --uninstall`,
`./scripts/fts-refresh-install.sh --uninstall`,
`./scripts/proactive-install.sh --uninstall`, and stop the notify unit;
the ledger and cursors are kept.
