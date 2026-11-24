# guard-self-improvement — reference

On-demand detail for the skill body. Not loaded at session start.

## Mine the session database (read-only)

```bash
DB="$(./scripts/db-path.sh)"
./scripts/learn-rules.py --db "$DB" --since-days 30
./scripts/issue-solutions.py --db "$DB" --recent 40 --top 15
OPENCODE_DB="$DB" python3 ./scripts/recall-sessions.py guard --limit 10
```

- `learn-rules.py` returns `avoid`, `prefer`, and `recovery` shapes.
- `issue-solutions.py` pairs an error with the next completed call that fixed it.
- `recall-sessions.py` is Python, not an executable; call it with `python3`
  and `OPENCODE_DB`. All three print the `db:` they used; when it differs from
  the real store, pass `--db`.

## Codify in the guard

`.opencode/plugins/blacklist-guard.js` is the live layer; `lint.sh` and
`scan-constraints.py` police files; `audit-tool-calls.py` reports the past.
`block` names the substitute. `fix` rewrites the command and then surfaces the
rewrite in `tool.execute.after`, because a silent rewrite teaches the model
nothing. Export any pure function a test needs. Fail-open on every error.

Body inspection rules that survived the false-positive scan (2026-11-23):

- Enforce on bodies: `sed`, `rm -rf`, `irreversible`, `sensitive-read`,
  `secret-interpreter-read`, `subprocess.run`, `config-dump`, `pipe-to-shell`.
- Do **not** enforce on bodies: `exit N`, `set -e`, `kill N`, `2>/dev/null`,
  `>/dev/null 2>&1`, `&>/dev/null`, `echo`, `pipe-to-interp`. They appear in the
  repo's and the skills' long-lived scripts and would break the operator's tools.
- Skip `node_modules`, `.git`, and `scripts/archive`.
- A construct inside a function whose name never appears outside its definition
  is unreachable; do not block it.
- Skip `/etc`, `/proc`, `/sys`, `/dev`, files over the size limit, and anything
  that cannot be read.

## Prove it

```bash
node --check .opencode/plugins/blacklist-guard.js
node scripts/blacklist-guard-self-test.mjs
./scripts/guard-health.sh --self-test
./scripts/test-hygiene.sh          # or ./scripts/harness.sh --fast
```

A detector needs the winning case and the two losing cases: a comment-only
mention allows, and an unreachable helper does not block. For a body rule,
import `inspectScriptBody` and run it over `scripts/` and the skills directory;
expect zero hits, then investigate any that appear.

## Sync and record

```bash
cp -f .opencode/plugins/blacklist-guard.js ~/.config/opencode/plugins/blacklist-guard.js
chmod 0644 ~/.config/opencode/plugins/blacklist-guard.js
cmp -s .opencode/plugins/blacklist-guard.js ~/.config/opencode/plugins/blacklist-guard.js
```

The web server loads the in-memory copy at start: a plugin edit is inert for
existing sessions until a restart. `guard-health.sh` proves it by comparing the
`loaded` hash with the file hash plus a later `hook` marker. Update `TODO.md`,
write a dated handoff under `docs/`, and keep the always-loaded tier small: the
skill body files are budgeted, so put detail here.

## Never hide a red gate

A database scan that fails on historical text is reported with the cursor value
and the part timestamps. Do not run `--advance` to turn it green; the cursor is
a claim that a person reviewed the findings.
