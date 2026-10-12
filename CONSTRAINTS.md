# CONSTRAINTS.md — the quality bar, decided once, enforced everywhere.

Adapted from addyosmani/agent-skills `constraint-driven-development`: the bar
is written down so no session negotiates it away, and every check below names
the script that enforces it (an unenforced constraint is a wish).

## 1. Tool-call constraints (enforced by `.opencode/plugins/blacklist-guard.js`)

- No `sed`, no `rm -rf`, no `subprocess.run`, no `2>/dev/null`. See `RULES.md`
  "Substitutions for the blacklist". The guard blocks before execution.
- Evidence before synthesis: read the file, run the command, then claim.
  (`blacklist-guard` fail-open: a guard bug must never block a tool call.)

## 2. Change constraints (enforced by gates)

- Atomic commits, ~100 lines per change; spec before code on multi-file work.
- Every push clears: `lint.sh` (165), `test-hygiene.sh` (39),
  `test-patterns.sh` (6), plus `review-diff.sh` when the reviewer is
  installed (SKIP otherwise — a missing optional tool never blocks).
- Anti-rationalization: "I will add tests later", "this check is noise",
  and "green on retry without a fix" are rebutted — a retry without a fix
  is not evidence. `preflight.sh` fails closed on red gates.

## 3. State constraints (enforced by convention + scripts)

- `data/opencode/opencode.db` is read-only; backups go through the sqlite
  backup API (`pages`/`ux` flows), never `cp` on a live DB.
- Secrets live in `.env.local` (0600, gitignored) and arrive via env only;
  logs and diffs are scanned for keys before commit/push.
- Publish allowlist: session text never leaves the host except through
  `pages-export.sh` (redacted panel) or an explicit user paste.

## 4. Definition of done

A change is done when: gates green, probe verdict PASS (`ux.sh status`),
new scripts carry `--help` + `bash -n` clean + a contract line in
`agents/probe.yaml` where applicable, README updated if behavior changed,
and the TODO entry closed with evidence (log line, count, or screenshot).
