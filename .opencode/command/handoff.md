---
description: Check session budget/model risks and print the numbered fresh-session guidance. Use when a session is slow, the backend banner appears, or before continuing an old session.
---

# /handoff — session risks, then the fresh-session guidance

Run the guard (read-only over `opencode.db`; secrets by name only):

```sh
./scripts/session-guard.sh [--session <id>]
```

- Exit 1 means the focus is over budget or on a deny-listed model: follow the
  printed steps in order (pause, fresh session, brief, allow-listed model).
  Exit 0 means clean. FAIL means *action due now* — a routine handoff, not
  breakage; the human lines say so explicitly.
- For the full offer, run `./scripts/session-guard.sh --handoff --session
  <id>`: it writes the redacted, leak-checked brief, logs the ledger row,
  and prints the paste-ready block. That is the "do it for me" path.
- Carry a brief, not the history: `./scripts/handoff-brief.sh <id>`.
  Never `--fork` / `--continue` an over-budget session (copies the context
  back). The full transcript stays in `logs/`.
- Optional model-assisted summary: `./scripts/handoff-brief.sh <id> --model
  <name>` only prints the prompt plus the spend command after an ALLOW
  verdict; it never calls the model itself.
- Machine form: `./scripts/session-guard.sh --json [--no-log]`.
