# Handoff — blacklist guard script-body inspection (2026-11-24)

Status: implemented, self-tested, global copy synced, server restarted. The
running plugin is the current file (same SHA-256) and the body check is live.
Changes are uncommitted. This session started fresh from
`docs/HANDOFF-2026-11-23-guard-dedupe.md` and did not fork.

## Why (the operator's question)

The operator asked what explains persistent evasion of the blacklist rules and
said: find a way to check every line. The answer is in the hook itself: it only
inspected the command line. A command like `bash script.sh` passes the check
while the banned construct sits in the file, so writing a small script was a
reliable bypass. The guard could not see the executed program.

## What changed

- `.opencode/plugins/blacklist-guard.js`
  - New exports: `scriptTargets()` (resolve the local files a shell command
    executes or sources), `liveCode()` (blank comments and quoted strings),
    `inspectScriptBody()` (per-line hits with line numbers), and
    `inspectScriptTargets()` (read under a 256 KiB limit and inspect).
  - `tool.execute.before` now inspects the body of every executed or sourced
    local script and blocks with the file path and line.
  - Body enforcement is deliberately narrower than the command line. It applies
    only the destructive/opaque set: `sed`, `rm -rf`, irreversible, secret
    reads, `subprocess.run`, config dump, and download-pipe-to-shell. The
    convention rules (`exit N`, `set -e`, `kill N`) and the stderr-redirect
    family are left to the command line, because long-lived repo and skill
    scripts legitimately contain them and enforcing them on bodies would break
    the operator's own tools. This was measured, not assumed (see below).
  - A construct inside a helper function whose name never appears outside its
    own definition is unreachable and is not blocked.
  - Skipped targets: `/etc`, `/proc`, `/sys`, `/dev`, `node_modules`, `.git`,
    `scripts/archive`, unreadable files, and files over the size limit.
- `scripts/blacklist-guard-self-test.mjs`
  - New end-to-end cases: a banned construct in an executed file blocks;
    direct `./script.sh` execution blocks; a comment-only mention allows; an
    unreachable helper allows; a reachable helper blocks.

## Evidence from the session database

The learning tools were run against the sandbox store resolved by
`scripts/db-path.sh` (the tools default to the repo path, which does not exist
in the container; pass `--db`):

- `issue-solutions.py`: the top signature is
  `blacklist-guard blocked this command` (67 occurrences), and the usual
  "fix" is `cd` plus the same shape — a block that teaches nothing.
- `learn-rules.py`: no shape is above the avoid threshold, so no new advisory
  rule was promoted.

The corpus therefore supports a detection gap, not a new advisory pattern,
which is why the fix is in the guard's detection surface.

## False-positive measurement (done before shipping)

Importing `inspectScriptBody` and scanning the real trees with the body set
returned zero hits across 257 repo scripts and one hit across 39 skill files
(a Python file that genuinely calls `subprocess.run`). The wider command-line
rules were rejected for bodies because they fire on 145 repo scripts, the
skills, and the archive. That measurement is why the body set is narrow.

## Verification

```text
node --check .opencode/plugins/blacklist-guard.js            syntax ok
node scripts/blacklist-guard-self-test.mjs                   result: pass
./scripts/guard-health.sh --self-test                        self-test pass
./scripts/guard-health.sh --check                            pass (loaded sha = file sha)
./scripts/test-hygiene.sh                                    119 pass, 0 fail, 3 skip
./scripts/lint.sh (under harness --fast)                     453 pass, 0 fail
./scripts/test-patterns.sh                                   6 pass, 0 fail
./scripts/doc-budget.sh                                      ~34912 / 35000 (within budget)
bash <temp script with sed -i>                               blocked at file:2 (body check live)
```

The last line is the post-restart proof: `guard.log` records the `loaded` marker
with SHA-256 `e796ded5...` (equal to the repo and global copies) and a `hook`
marker, and executing a temporary script produced
`an executed script contains a banned construct ... at <file>:2`.

The global copy at `~/.config/opencode/plugins/blacklist-guard.js` is
content-equal to the repo plugin (verified with `cmp -s`), so the entrypoint and
`test-hygiene.sh` agree.

## Remaining work

1. **Done** — the web server was restarted (2026-11-24 02:47Z). `guard-health.sh
   --check` now reports `loaded instance is current and its hook fired`, the
   `loaded`/`hook` markers are in `guard.log`, and a temporary script body was
   blocked live with its file path and line number.
2. The placeholder database scan is red on historical text, not on this work:
   cursor `1795417597829`, flagged parts at timestamps `1795436619887` to
   `1795437485082` (earlier sessions that wrote placeholders such as a tailnet
   address). The cursor was not advanced; advancing is a claim that a person
   reviewed the findings. Go-forward rule: no placeholders (RULES #99/#100).
   Re-run 2026-11-24: 18 flagged tokens in 4 part IDs, all historical (one part
   echoes the scan output itself); cursor still `1795417597829`. This needs a
   human disposition, not `--advance`.
3. Foil host and admin items are unchanged; see
   `docs/HANDOFF-2026-11-23-foil-tailnet.md`.
4. Commit only when the operator asks. Nothing was committed.

## Skill added

`.opencode/skills/guard-self-improvement/` (copied to the global skills
directory): the mine -> classify -> codify -> prove -> record loop, with the
exact learning commands and the false-positive set in `reference.md`. The skill
body is a thin pointer so it does not inflate the session-start corpus.

## Start here

Open a fresh session and read this file, then `TODO.md` and the guard skill.
Do not fork or continue the previous session; restore state from the store.
